using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using Unity.Collections;
using Unity.Mathematics;
using Unity.Profiling;
using Unity.Profiling.LowLevel;
using UnityEngine;
using UnityEngine.Profiling;
using UnityEngine.Rendering;
using UnityEngine.VFX;

namespace VFXGridPartitioning
{

    public enum HashGridDebugMode
    {
        None,
        Profile,
        Debug
    }

    [ExecuteInEditMode]
    public class HashGrid : MonoBehaviour
    {
        public HashGridDebugMode m_DebugMode = HashGridDebugMode.Profile;

        public VisualEffect m_EffectMain;
        public VisualEffect m_EffectDebug;
        public Vector3 m_CellSize = new(1.5f, 1.5f, 1.5f);
        public uint m_MaxParticleCount = 65536;
        public uint m_MaxCellCount = 65536;

        public ComputeShader m_GridUpdateBounds;
        public ComputeShader m_GridUpdateList;
        public ComputeShader m_GridSortList;
        public ComputeShader m_GridCellStart;

        private GraphicsBuffer m_DataBuffer;
        private GraphicsBuffer m_PreviousBoundsBuffer;
        private GraphicsBuffer m_BoundsBuffer;
        private GraphicsBuffer m_CellInstanceUnsortedBuffer;
        private GraphicsBuffer m_CellInstanceSortedBuffer;
        private GraphicsBuffer m_CellStartBuffer;

        private int m_BitonicPrePassKernelIndex;
        private int m_BitonicSort128KernelIndex;
        private int m_BitonicSort1024KernelIndex;
        private int m_BitonicSort2048KernelIndex;
        private int m_BitonicSort4096KernelIndex;
        private int m_MergePassIndex;

        private GraphicsBuffer m_GridStatisticsBuffer;
        private NativeArray<uint> m_StatisticsReadbackBuffer;

        private Recorder m_VFXUpdateRecorder;
        private CustomSampler m_HashGridRecorder;
        private StringBuilder m_DebugGUI;

        private CommandBuffer m_CommandBuffer;

        private static readonly int kCellSizeID = Shader.PropertyToID("CellSize");
        private static readonly int kMaxParticleCountID = Shader.PropertyToID("MaxParticleCount");
        private static readonly int kMaxCellCountID = Shader.PropertyToID("MaxCellCount");
        private static readonly int kDataBufferID = Shader.PropertyToID("_DataBuffer");
        private static readonly int kPreviousBoundsBufferID = Shader.PropertyToID("PreviousBoundsBuffer");
        private static readonly int kBoundsBufferID = Shader.PropertyToID("BoundsBuffer");
        private static readonly int kCellInstanceBufferID = Shader.PropertyToID("CellInstanceBuffer");
        private static readonly int kCellStartBufferID = Shader.PropertyToID("CellStartBuffer");
        private static readonly int kGridStatisticsBufferID = Shader.PropertyToID("GridStatisticsBuffer");
        private static readonly int kDispatchWidthID = Shader.PropertyToID("DispatchWidth");
        private static readonly int kSubArraySizeID = Shader.PropertyToID("SubArraySize");
        private static readonly int kInputSequenceID = Shader.PropertyToID("InputSequence");
        private static readonly int kSortedSequenceID = Shader.PropertyToID("SortedSequence");

        private static readonly uint[] kGridStatisticDefaultData = {0u, 0u, uint.MaxValue, 0u};

        private static readonly uint[] kPreviousBoundsDefaultData = {0x407FFFFF, 0x407FFFFF, 0x407FFFFF, 0xBF800000, 0xBF800000, 0xBF800000};
        private static readonly uint[] kBoundsDefaultData = {uint.MaxValue, uint.MaxValue, uint.MaxValue, 0u, 0u, 0u};

        private static readonly ProfilerMarker kComputeBoundsMarker = new("ComputeBounds");
        private static readonly ProfilerMarker kComputeCellIdListMarker = new("ComputeCellIdList");

        private static readonly ProfilerMarker kSortCellIdListMarker = new(ProfilerCategory.Render, "SortCellIdList", MarkerFlags.SampleGPU);

        private static readonly ProfilerMarker kComputeCellStartMarker = new("ComputeCellStart");

        private static readonly uint kNB_THREADS_PER_GROUP = 64;
        private static readonly bool kUSE_COMPRESSED_DATA = true; //Must be in sync with USE_COMPRESSED_DATA in GridCommon.hlsl 
        private static readonly int kMaxComputeSharedMemorySize = 32768; //Maximum total storage size in bytes (default to 32768 because generally greater than 32kb in most platform)
        private static readonly uint kLDSSortMaxElementCount = kMaxComputeSharedMemorySize < 32768 ? 2048u : 4096u;
        private static int kMaxComputeWorkGroupSize = -1;

        void OnEnable()
        {
            Init();
        }

        void OnDisable()
        {
            Release();
        }

        uint GetDataBufferCount()
        {
            if (kUSE_COMPRESSED_DATA)
            {
                return m_MaxParticleCount * 3;
            }

            return m_MaxParticleCount * 6;
        }

        void Init()
        {
            if (m_GridUpdateBounds == null) { Debug.LogError("Missing 'Grid Update Bounds' ComputeShader assignment"); return; }
            if (m_GridUpdateList == null) { Debug.LogError("Missing 'Grid Update List' ComputeShader assignment"); return; }
            if (m_GridSortList == null) { Debug.LogError("Missing 'Grid Sort List' ComputeShader assignment"); return; }
            if (m_GridCellStart == null) { Debug.LogError(" Missing 'Grid Cell Start' ComputeShader assignment"); return; }

            kMaxComputeWorkGroupSize = SystemInfo.maxComputeWorkGroupSize;

            m_PreviousBoundsBuffer = new GraphicsBuffer(GraphicsBuffer.Target.Structured,GraphicsBuffer.UsageFlags.None, 6, Marshal.SizeOf(typeof(uint)));
            m_PreviousBoundsBuffer.SetData(kPreviousBoundsDefaultData);
            m_BoundsBuffer = new GraphicsBuffer(GraphicsBuffer.Target.Structured, GraphicsBuffer.UsageFlags.None, 6, Marshal.SizeOf(typeof(uint)));

            m_CellInstanceUnsortedBuffer = new GraphicsBuffer(GraphicsBuffer.Target.Structured, GraphicsBuffer.UsageFlags.None, (int) m_MaxParticleCount, Marshal.SizeOf(typeof(uint)) * 2);
            m_CellInstanceSortedBuffer = new GraphicsBuffer(GraphicsBuffer.Target.Structured, GraphicsBuffer.UsageFlags.None, (int) m_MaxParticleCount, Marshal.SizeOf(typeof(uint)) * 2);
            m_CellStartBuffer = new GraphicsBuffer(GraphicsBuffer.Target.Structured, GraphicsBuffer.UsageFlags.None, (int)m_MaxCellCount, Marshal.SizeOf(typeof(uint)));

            m_DataBuffer = new GraphicsBuffer(GraphicsBuffer.Target.Raw, GraphicsBuffer.UsageFlags.None, (int)GetDataBufferCount(), Marshal.SizeOf(typeof(uint)));
            var initData = new uint[m_DataBuffer.count];
            for (int i = 0; i < initData.Length; i++) initData[i] = uint.MaxValue;
                m_DataBuffer.SetData(initData);

            m_GridStatisticsBuffer = new GraphicsBuffer(GraphicsBuffer.Target.Structured,
                GraphicsBuffer.UsageFlags.None, 4, Marshal.SizeOf(typeof(uint)));
            m_StatisticsReadbackBuffer = new NativeArray<uint>(4, Allocator.Persistent);

            m_CommandBuffer = new CommandBuffer();
            m_CommandBuffer.name = "HashGridUpdate";

            m_BitonicPrePassKernelIndex = m_GridSortList.FindKernel("BitonicPrePass");
            m_BitonicSort128KernelIndex = m_GridSortList.FindKernel("BitonicSort128");
            m_BitonicSort1024KernelIndex = m_GridSortList.FindKernel(kMaxComputeWorkGroupSize >= 256 ? "BitonicSort1024" : "BitonicSort1024_128");
            m_BitonicSort2048KernelIndex = m_GridSortList.FindKernel(kMaxComputeWorkGroupSize >= 512 ? "BitonicSort2048" : "BitonicSort2048_128");
            m_BitonicSort4096KernelIndex = m_GridSortList.FindKernel(kMaxComputeWorkGroupSize >= 1024 ? "BitonicSort4096" : "BitonicSort4096_128");

            m_MergePassIndex = m_GridSortList.FindKernel("MergePass");

            m_VFXUpdateRecorder = Recorder.Get("VFX.ParticleSystem.BatchUpdate");
            m_HashGridRecorder = CustomSampler.Create(m_CommandBuffer.name, true);

            m_HistoryPerformance = null;
        }

        void Release()
        {
            m_DataBuffer.Dispose();
            m_BoundsBuffer.Dispose();
            m_PreviousBoundsBuffer.Dispose();
            m_CellInstanceUnsortedBuffer.Dispose();
            m_CellInstanceSortedBuffer.Dispose();
            m_CellStartBuffer.Dispose();
            m_GridStatisticsBuffer.Dispose();
            m_StatisticsReadbackBuffer.Dispose();

            m_CommandBuffer.Dispose();
        }

        List<float> m_HistoryPerformance;

        void OnGUI()
        {
            if (m_DebugMode != HashGridDebugMode.None)
            {
                m_DebugGUI ??= new();
                m_DebugGUI.Clear();

                if (m_DebugMode >= HashGridDebugMode.Profile && SystemInfo.supportsGpuRecorder)
                {
                    m_DebugGUI.AppendLine(SystemInfo.graphicsDeviceName);

                    float gridUpdate = -1.0f;
                    float vfxUpdate = -1.0f;
                    if (m_HashGridRecorder.isValid)
                    {
                        gridUpdate = m_HashGridRecorder.GetRecorder().gpuElapsedNanoseconds / 1000000.0f;
                        m_DebugGUI.AppendLine($"Grid Update (ms): {gridUpdate:0.##}");
                    }

                    if (m_VFXUpdateRecorder.isValid)
                    {
                        vfxUpdate = m_VFXUpdateRecorder.gpuElapsedNanoseconds / 1000000.0f;
                        m_DebugGUI.AppendLine($"VFX Update (ms): {m_VFXUpdateRecorder.gpuElapsedNanoseconds / 1000000.0:0.##}");
                    }

                    if (gridUpdate > 0 && vfxUpdate > 0)
                    {
                        m_HistoryPerformance ??= new List<float>(64);
                        if (m_HistoryPerformance.Count == m_HistoryPerformance.Capacity)
                            m_HistoryPerformance.RemoveAt(0);
                        m_HistoryPerformance.Add(gridUpdate + vfxUpdate);

                        float sum = 0;
                        foreach (var performance in m_HistoryPerformance)
                            sum += performance;
                        sum /= m_HistoryPerformance.Count;
                        m_DebugGUI.AppendLine($"Average (ms): {sum:0.##}");
                    }
                }

                if (m_DebugMode == HashGridDebugMode.Debug)
                {
                    m_DebugGUI.AppendLine($"Cell Count: {m_StatisticsReadbackBuffer[0]}");
                    m_DebugGUI.AppendLine($"Hash Collision: {m_StatisticsReadbackBuffer[1]} ({((float) m_StatisticsReadbackBuffer[1] * 100.0f / m_StatisticsReadbackBuffer[0]):0.##}%)");

                    m_DebugGUI.AppendLine($"Minimum Instances per cell: {m_StatisticsReadbackBuffer[2]}");
                    m_DebugGUI.AppendLine($"Average Instances per cell: {m_EffectMain.aliveParticleCount / (float) m_StatisticsReadbackBuffer[0]:0.##}");
                    m_DebugGUI.AppendLine($"Maximum Instances per cell: {m_StatisticsReadbackBuffer[3]}");
                }

                if (m_DebugGUI.Length > 0)
                    GUILayout.Label(m_DebugGUI.ToString());
            }
        }

        void OnStatisticsReadback(AsyncGPUReadbackRequest asyncGpuReadbackRequest)
        {
            if (!m_StatisticsReadbackBuffer.IsCreated)
                return;

            m_StatisticsReadbackBuffer.CopyFrom(asyncGpuReadbackRequest.GetData<uint>());
        }

        static uint DivideUpMultiple(uint count, uint multiple)
        {
            Debug.Assert(multiple > 0, "Illegal division by zero");
            Debug.Assert(count + multiple > count, "UInt32 Overflow");
            return (count + multiple - 1u) / multiple;
        }

        static uint CeilPowerOfTwo(uint x)
        {
            return math.ceilpow2(x);
        }

        static int HighestBit(uint x)
        {
            return math.tzcnt(x);
        }

        static Vector2Int GetDispatchSize(uint count, uint threadCountPerGroup)
        {
            var nbGroupNeeded = DivideUpMultiple(count, threadCountPerGroup);
            var dispatchSizeY = (int) DivideUpMultiple(nbGroupNeeded, 0xffff);
            var dispatchSizeX = (int) DivideUpMultiple(nbGroupNeeded, (uint) dispatchSizeY);
            return new Vector2Int(dispatchSizeX, dispatchSizeY);
        }
        void Update()
        {
            if (!m_EffectMain)
                return;

            if (m_DataBuffer.count != GetDataBufferCount() || m_CellStartBuffer.count != m_MaxCellCount)
            {
                Release();
                Init();
            }

            var dispatchParticle = GetDispatchSize(m_MaxParticleCount, kNB_THREADS_PER_GROUP);
            var dispatchCell = GetDispatchSize(m_MaxCellCount, kNB_THREADS_PER_GROUP);

            m_CommandBuffer.Clear();

            if (m_DebugMode >= HashGridDebugMode.Profile)
                m_CommandBuffer.BeginSample(m_HashGridRecorder);

            //Bounds computation
            m_CommandBuffer.BeginSample(kComputeBoundsMarker);
            {
                m_CommandBuffer.SetBufferData(m_BoundsBuffer, kBoundsDefaultData);

                m_CommandBuffer.SetComputeBufferParam(m_GridUpdateBounds, 0, kDataBufferID, m_DataBuffer);
                m_CommandBuffer.SetComputeBufferParam(m_GridUpdateBounds, 0, kPreviousBoundsBufferID, m_PreviousBoundsBuffer);
                m_CommandBuffer.SetComputeBufferParam(m_GridUpdateBounds, 0, kBoundsBufferID, m_BoundsBuffer);
                m_CommandBuffer.SetComputeIntParam(m_GridUpdateBounds, kMaxParticleCountID, (int) m_MaxParticleCount);
                m_CommandBuffer.SetComputeVectorParam(m_GridUpdateBounds, kCellSizeID, new Vector4(m_CellSize.x, m_CellSize.y, m_CellSize.z, 0.0f));
                m_CommandBuffer.SetComputeIntParam(m_GridUpdateBounds, kDispatchWidthID, dispatchParticle.x);
                m_CommandBuffer.DispatchCompute(m_GridUpdateBounds, 0, dispatchParticle.x, dispatchParticle.y, 1);
            }
            m_CommandBuffer.EndSample(kComputeBoundsMarker);

            //Generate Cell/ParticleId pair
            m_CommandBuffer.BeginSample(kComputeCellIdListMarker);
            {
                m_CommandBuffer.SetComputeBufferParam(m_GridUpdateList, 0, kDataBufferID, m_DataBuffer);
                m_CommandBuffer.SetComputeBufferParam(m_GridUpdateList, 0, kPreviousBoundsBufferID, m_PreviousBoundsBuffer);
                m_CommandBuffer.SetComputeBufferParam(m_GridUpdateList, 0, kBoundsBufferID, m_BoundsBuffer);
                m_CommandBuffer.SetComputeBufferParam(m_GridUpdateList, 0, kCellInstanceBufferID, m_CellInstanceUnsortedBuffer);
                m_CommandBuffer.SetComputeVectorParam(m_GridUpdateList, kCellSizeID, new Vector4(m_CellSize.x, m_CellSize.y, m_CellSize.z, 0.0f));
                m_CommandBuffer.SetComputeIntParam(m_GridUpdateList, kMaxCellCountID, (int) m_MaxCellCount);
                m_CommandBuffer.SetComputeIntParam(m_GridUpdateList, kDispatchWidthID, dispatchParticle.x);
                m_CommandBuffer.DispatchCompute(m_GridUpdateList, 0, dispatchParticle.x, dispatchParticle.y, 1);
            }
            m_CommandBuffer.EndSample(kComputeCellIdListMarker);

            //Sort of Cell/ParticleId tuples
            m_CommandBuffer.BeginSample(kSortCellIdListMarker);
            {
                var dispatchSort = GetDispatchSize(m_MaxParticleCount, kLDSSortMaxElementCount);
                Debug.Assert(dispatchSort.y == 1);

                int bitonicKernel;
                bool needsMergePass = m_MaxParticleCount > kLDSSortMaxElementCount;
                if (needsMergePass)
                {
                    bitonicKernel = m_BitonicPrePassKernelIndex;
                }
                else
                {
                    if (m_MaxParticleCount <= 128)
                        bitonicKernel = m_BitonicSort128KernelIndex;
                    else if (m_MaxParticleCount <= 1024)
                        bitonicKernel = m_BitonicSort1024KernelIndex;
                    else if (m_MaxParticleCount <= 2048)
                        bitonicKernel = m_BitonicSort2048KernelIndex;
                    else
                        bitonicKernel = m_BitonicSort4096KernelIndex;
                }

                m_CommandBuffer.SetComputeIntParam(m_GridSortList, kDispatchWidthID, dispatchParticle.x);
                m_CommandBuffer.SetComputeIntParam(m_GridSortList, kMaxParticleCountID, (int) m_MaxParticleCount);
                m_CommandBuffer.SetComputeBufferParam(m_GridSortList, bitonicKernel, kInputSequenceID, m_CellInstanceUnsortedBuffer);
                m_CommandBuffer.SetComputeBufferParam(m_GridSortList, bitonicKernel, kSortedSequenceID, m_CellInstanceSortedBuffer);
                m_CommandBuffer.DispatchCompute(m_GridSortList, bitonicKernel, dispatchSort.x, 1, 1);

                if (needsMergePass)
                {
                    var nbPasses = HighestBit(CeilPowerOfTwo(m_MaxParticleCount) / kLDSSortMaxElementCount);
                    var currentSubArraySize = kLDSSortMaxElementCount;

                    for (int pass = 0; pass < nbPasses; pass++)
                    {
                        (m_CellInstanceUnsortedBuffer, m_CellInstanceSortedBuffer) = (m_CellInstanceSortedBuffer, m_CellInstanceUnsortedBuffer);
                        m_CommandBuffer.SetComputeBufferParam(m_GridSortList, m_MergePassIndex, kInputSequenceID, m_CellInstanceUnsortedBuffer);
                        m_CommandBuffer.SetComputeBufferParam(m_GridSortList, m_MergePassIndex, kSortedSequenceID, m_CellInstanceSortedBuffer);
                        m_CommandBuffer.SetComputeIntParam(m_GridSortList, kSubArraySizeID, (int) currentSubArraySize);
                        m_CommandBuffer.DispatchCompute(m_GridSortList, m_MergePassIndex, dispatchParticle.x, dispatchParticle.y, 1);

                        currentSubArraySize <<= 1;
                    }
                }
            }
            m_CommandBuffer.EndSample(kSortCellIdListMarker);

            //Grid Start Computation
            m_CommandBuffer.BeginSample(kComputeCellStartMarker);
            {
                m_CommandBuffer.SetComputeBufferParam(m_GridCellStart, 0, kCellStartBufferID, m_CellStartBuffer);
                m_CommandBuffer.DispatchCompute(m_GridCellStart, 0, dispatchCell.x, dispatchCell.y, 1);

                m_CommandBuffer.SetComputeBufferParam(m_GridCellStart, 1, kCellInstanceBufferID, m_CellInstanceSortedBuffer);
                m_CommandBuffer.SetComputeBufferParam(m_GridCellStart, 1, kCellStartBufferID, m_CellStartBuffer);
                m_CommandBuffer.SetComputeIntParam(m_GridCellStart, kDispatchWidthID, dispatchCell.x);
                m_CommandBuffer.SetComputeIntParam(m_GridCellStart, kMaxCellCountID, (int) m_MaxCellCount);
                m_CommandBuffer.DispatchCompute(m_GridCellStart, 1, dispatchCell.x, dispatchCell.y, 1);
            }
            m_CommandBuffer.EndSample(kComputeCellStartMarker);

            if (m_EffectDebug)
            {
                var enableDebug = m_DebugMode == HashGridDebugMode.Debug;
                m_EffectDebug.enabled = enableDebug;
                if (enableDebug)
                {
                    m_EffectDebug.SetVector3(kCellSizeID, m_CellSize);
                    m_EffectDebug.SetUInt(kMaxParticleCountID, m_MaxParticleCount);
                    m_EffectDebug.SetUInt(kMaxCellCountID, m_MaxCellCount);
                    m_EffectDebug.SetGraphicsBuffer(kDataBufferID, m_DataBuffer);
                    m_EffectDebug.SetGraphicsBuffer(kPreviousBoundsBufferID, m_PreviousBoundsBuffer);
                    m_EffectDebug.SetGraphicsBuffer(kBoundsBufferID, m_BoundsBuffer);
                    m_EffectDebug.SetGraphicsBuffer(kCellInstanceBufferID, m_CellInstanceSortedBuffer);
                    m_EffectDebug.SetGraphicsBuffer(kCellStartBufferID, m_CellStartBuffer);
                    m_EffectDebug.SetGraphicsBuffer(kGridStatisticsBufferID, m_GridStatisticsBuffer);

                    AsyncGPUReadback.Request(m_GridStatisticsBuffer, OnStatisticsReadback);
                    m_GridStatisticsBuffer.SetData(kGridStatisticDefaultData);
                }
            }

            if (m_DebugMode >= HashGridDebugMode.Profile)
                m_CommandBuffer.EndSample(m_HashGridRecorder);

            Graphics.ExecuteCommandBuffer(m_CommandBuffer);

            m_EffectMain.SetVector3(kCellSizeID, m_CellSize);
            m_EffectMain.SetUInt(kMaxParticleCountID, m_MaxParticleCount);
            m_EffectMain.SetUInt(kMaxCellCountID, m_MaxCellCount);
            m_EffectMain.SetGraphicsBuffer(kDataBufferID, m_DataBuffer);
            m_EffectMain.SetGraphicsBuffer(kPreviousBoundsBufferID, m_PreviousBoundsBuffer);
            m_EffectMain.SetGraphicsBuffer(kBoundsBufferID, m_BoundsBuffer);
            m_EffectMain.SetGraphicsBuffer(kCellInstanceBufferID, m_CellInstanceSortedBuffer);
            m_EffectMain.SetGraphicsBuffer(kCellStartBufferID, m_CellStartBuffer);

            if (m_DebugMode >= HashGridDebugMode.Profile)
            {
                m_VFXUpdateRecorder.enabled = true;
                m_HashGridRecorder.GetRecorder().enabled = true;
            }
            else
            {
                m_VFXUpdateRecorder.enabled = false;
                m_HashGridRecorder.GetRecorder().enabled = false;
            }

            (m_PreviousBoundsBuffer, m_BoundsBuffer) = (m_BoundsBuffer, m_PreviousBoundsBuffer);
        }
    }
}
