#ifndef GRID_COMMON_HLSL
#define GRID_COMMON_HLSL

#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/SpaceFillingCurves.hlsl"

#define INVALID_POSITION 0xffffffff
#define INVALID_CELL_INDEX 0xffffffff
#define NB_THREADS_PER_GROUP 64
#define USE_Z_CURVE 0
#define USE_COMPRESSED_DATA 1
#define USE_STRUCTURE_OF_ARRAYS 0
#define USE_NEIGHBORCOUNT 1
#define STORE_RELATIVE_POSITION 1

#define CELL_INSTANCE_BUFFER_PREFETCH 1

#ifndef BYTEADDRESSBUFFERDATA_READ_FMT
#define BYTEADDRESSBUFFERDATA_READ_FMT ByteAddressBuffer
#endif

//http://stereopsis.com/radix.html
uint FloatFlip(uint f)
{
    uint mask = -int(f >> 31) | 0x80000000;
    return f ^ mask;
}

uint IFloatFlip(uint f)
{
    uint mask = ((f >> 31) - 1) | 0x80000000;
    return f ^ mask;
}

#define MIN_FLOAT_FLIP FloatFlip(0x7f7fffff)
#define MAX_FLOAT_FLIP FloatFlip(0xff7fffff)

float3 InverseLerp(float3 x, float3 y, float3 v)
{
    return (v - x) / max(y - x, (float3)10e-6f);
}

uint3 ceilpow2(uint3 x)
{
    return 2 << firstbithigh(max(1u, x) - 1u);
}

float3 GetBBMin(StructuredBuffer<uint> bounds)
{
    return float3(
    asfloat(IFloatFlip(bounds[0])),
    asfloat(IFloatFlip(bounds[1])),
    asfloat(IFloatFlip(bounds[2])));
}

float3 GetBBMax(StructuredBuffer<uint> bounds)
{
    return float3(
    asfloat(IFloatFlip(bounds[3])),
    asfloat(IFloatFlip(bounds[4])),
    asfloat(IFloatFlip(bounds[5])));
}

void GetGridLayout(StructuredBuffer<uint> bounds, float3 cellSize, out float3 bbMin, out float3 bbMax, out uint3 dimensions)
{
    bbMin = GetBBMin(bounds);
    bbMax = GetBBMax(bounds);

    dimensions = (uint3)ceil((bbMax - bbMin) / cellSize);

#if USE_Z_CURVE
    dimensions = ceilpow2(dimensions);
    dimensions = (uint3)max(max(dimensions.x, dimensions.y), dimensions.z);
    bbMax = bbMin + dimensions * cellSize;
#endif
}

uint CalculateHash(StructuredBuffer<uint> bounds, float3 cellSize, uint maxCellCount, uint3 cellId)
{
#if USE_Z_CURVE
    uint id = EncodeMorton3D(cellId);
#else
    //Linear 3D indexing
    float3 bbMin, bbMax;
    uint3 dimensions;
    GetGridLayout(bounds, cellSize, bbMin, bbMax, dimensions);
    uint id = cellId.z * dimensions.x * dimensions.y + cellId.y * dimensions.x + cellId.x;
#endif

    return id % maxCellCount;
}

uint3 GetCell(StructuredBuffer<uint> bounds, float3 cellSize, float3 position)
{
    float3 bbMin, bbMax;
    uint3 dimensions;
    GetGridLayout(bounds, cellSize, bbMin, bbMax, dimensions);

    float3 normalizedPosition = InverseLerp(bbMin, bbMax, position);
    uint3 currentCell = (uint3) floor(normalizedPosition * dimensions);
    return currentCell;
}

struct CellIterator
{
    uint m_CurrentOffset;
    uint m_CellHash;

#if CELL_INSTANCE_BUFFER_PREFETCH > 1
    uint m_PrefetchInstances[CELL_INSTANCE_BUFFER_PREFETCH];
    uint m_PrefetchCursor;
#endif

    bool GetNext(StructuredBuffer<uint2> cellInstanceBuffer, uint maxParticleCount, out uint readInstanceId)
    {
        readInstanceId = INVALID_CELL_INDEX;
        if (m_CurrentOffset != INVALID_CELL_INDEX)
        {
#if CELL_INSTANCE_BUFFER_PREFETCH > 1
            [branch]
            if (m_PrefetchCursor == CELL_INSTANCE_BUFFER_PREFETCH)
            {
                [unroll]
                for (int i = 0; i < CELL_INSTANCE_BUFFER_PREFETCH; i++)
                {
                    m_PrefetchInstances[i] = INVALID_CELL_INDEX;
                    uint prefetchAddress = m_CurrentOffset + i;
                    if (prefetchAddress >= maxParticleCount)
                        break;

                    uint2 readInstanceBuffer = cellInstanceBuffer[prefetchAddress];
                    if (readInstanceBuffer.x != m_CellHash)
                        break;

                    m_PrefetchInstances[i] = readInstanceBuffer.y;
                }
                m_PrefetchCursor = 0u;
                m_CurrentOffset += CELL_INSTANCE_BUFFER_PREFETCH;
            }

            uint readPrefetchInstanceId = m_PrefetchInstances[m_PrefetchCursor++];
            readInstanceId = readPrefetchInstanceId;
#else
            uint2 readInstanceBuffer = cellInstanceBuffer[m_CurrentOffset++];
            if (readInstanceBuffer.x == m_CellHash)
                readInstanceId = readInstanceBuffer.y;
#endif
        }
        return readInstanceId != INVALID_CELL_INDEX;
    }
};

CellIterator GetCellIterator(StructuredBuffer<uint> bounds, StructuredBuffer<uint> cellStartBuffer, float3 cellSize, uint maxCellCount, uint3 cellId)
{
    CellIterator cellIterator = (CellIterator)0;
    cellIterator.m_CellHash = CalculateHash(bounds, cellSize, maxCellCount, cellId);
    cellIterator.m_CurrentOffset = cellStartBuffer[cellIterator.m_CellHash];
#if CELL_INSTANCE_BUFFER_PREFETCH > 1
    cellIterator.m_PrefetchCursor = CELL_INSTANCE_BUFFER_PREFETCH;
#endif
    return cellIterator;

}

void GetCellBounds(StructuredBuffer<uint> bounds, float3 cellSize, uint3 cell, out float3 localCellMin, out float3 localCellMax)
{
    float3 bbMin, bbMax;
    uint3 dimensions;
    GetGridLayout(bounds, cellSize, bbMin, bbMax, dimensions);

    float3 minCell = (float3)cell / (float3)dimensions;
    float3 maxCell = (float3) (cell + (uint3)1u) / (float3)dimensions;

    localCellMin = lerp(bbMin, bbMax, minCell);
    localCellMax = lerp(bbMin, bbMax, maxCell);
}

bool IsInBounds(StructuredBuffer<uint> bounds, float3 cellSize, int3 cell)
{
    float3 bbMin, bbMax;
    uint3 dimensions;
    GetGridLayout(bounds, cellSize, bbMin, bbMax, dimensions);
    return all((cell > 0) & (cell < int3(dimensions)));
}

uint GetFlatThreadId(uint3 groupId, uint3 groupThreadId, uint dispatchWidth)
{
    return groupThreadId.x + groupId.x * NB_THREADS_PER_GROUP + groupId.y * dispatchWidth * NB_THREADS_PER_GROUP;
}

uint PackToR16G16F(float2 rg)
{
    uint r = f32tof16(rg.x);
    uint g = f32tof16(rg.y);
    return (r << 16u) | g;
}

float2 UnpackFromR16G16F(uint rg)
{
    return float2(f16tof32(rg >> 16u), f16tof32(rg));
}

#if USE_COMPRESSED_DATA
//The position is stored relative to bounding box minimum
//uint2 => half(position.x, position.y), half(position.z, velocity.x)
//uint => half(velocity.x, velocity.y)

float3 GetReferenceCorner(StructuredBuffer<uint> bounds)
{
    float3 corner = (float3) -256.0f;
    if (bounds[0] != MIN_FLOAT_FLIP)
    {
        corner = GetBBMin(bounds);
    }
    return corner;
}


uint GetOffsetPosition(uint id)
{
#if USE_STRUCTURE_OF_ARRAYS
    return (id * 2) << 2;
#else
    return (id * 3 + 0) << 2;
#endif
}

uint GetOffsetVelocity(uint maxParticleCount, uint id)
{
#if USE_STRUCTURE_OF_ARRAYS
    return (id * 1 + maxParticleCount * 2) << 2;
#else
    return (id * 3 + 2) << 2;
#endif
}

uint2 GetRawPosition(BYTEADDRESSBUFFERDATA_READ_FMT data, uint id)
{
    return data.Load2(GetOffsetPosition(id));
}

uint GetRawVelocity(uint maxParticleCount, BYTEADDRESSBUFFERDATA_READ_FMT data, uint id)
{
    return data.Load(GetOffsetVelocity(maxParticleCount, id));
}

bool GetPosition(StructuredBuffer<uint> bounds, BYTEADDRESSBUFFERDATA_READ_FMT data, uint id, out float3 position)
{
    uint2 rawPosition = GetRawPosition(data, id);
    position.xy = UnpackFromR16G16F(rawPosition.x);
    position.z = UnpackFromR16G16F(rawPosition.y).x;
#if STORE_RELATIVE_POSITION
    position.xyz += GetReferenceCorner(bounds);
#endif
    return rawPosition.x != INVALID_POSITION;
}

bool GetPositionAndVelocity(StructuredBuffer<uint> bounds, uint maxParticleCount, BYTEADDRESSBUFFERDATA_READ_FMT data, uint id, out float3 position, out float3 velocity)
{
    uint2 rawPosition = GetRawPosition(data, id);
    uint rawVelocity = GetRawVelocity(maxParticleCount, data, id);

    position.xy = UnpackFromR16G16F(rawPosition.x);
    position.z = UnpackFromR16G16F(rawPosition.y).x;
#if STORE_RELATIVE_POSITION
    position.xyz += GetReferenceCorner(bounds);
#endif

    velocity.x = UnpackFromR16G16F(rawPosition.y).y;
    velocity.yz = UnpackFromR16G16F(rawVelocity);

    return rawPosition.x != INVALID_POSITION;
}

void StorePositionAndVelocity(StructuredBuffer<uint> bounds, uint maxParticleCount, RWByteAddressBuffer data, uint id, float3 position, float3 velocity, bool alive)
{
    if (alive)
    {
#if STORE_RELATIVE_POSITION
        position -= GetReferenceCorner(bounds);
#endif
        uint2 storePosition;
        storePosition.x = PackToR16G16F(position.xy);
        storePosition.y = PackToR16G16F(float2(position.z, velocity.x));
        uint storeVelocity = PackToR16G16F(velocity.yz);

        data.Store2(GetOffsetPosition(id), storePosition);
        data.Store(GetOffsetVelocity(maxParticleCount, id), storeVelocity);
    }
    else
    {
        data.Store(GetOffsetPosition(id), INVALID_POSITION);
    }
}

#else //!USE_COMPRESSED_DATA
uint GetOffsetPosition(uint id)
{
#if USE_STRUCTURE_OF_ARRAYS
    return (id * 3) << 2;
#else
    return (id * 6) << 2;
#endif
}

uint GetOffsetVelocity(uint maxParticleCount, uint id)
{
#if USE_STRUCTURE_OF_ARRAYS
    return (id * 3 + maxParticleCount * 3) << 2;
#else
    return (id * 3 + 3) << 2;
#endif
}

uint3 GetRawPosition(BYTEADDRESSBUFFERDATA_READ_FMT data, uint id)
{
    return data.Load3(GetOffsetPosition(id));
}

uint3 GetRawVelocity(uint maxParticleCount, BYTEADDRESSBUFFERDATA_READ_FMT data, uint id)
{
    return data.Load3(GetOffsetVelocity(maxParticleCount, id));
}

bool GetPosition(StructuredBuffer<uint> bounds, BYTEADDRESSBUFFERDATA_READ_FMT data, uint id, out float3 position)
{
    uint3 rawPosition = GetRawPosition(data, id);
    position = asfloat(rawPosition);
    return rawPosition.x != INVALID_POSITION;
}

bool GetPositionAndVelocity(StructuredBuffer<uint> bounds, uint maxParticleCount, BYTEADDRESSBUFFERDATA_READ_FMT data, uint id, out float3 position, out float3 velocity)
{
    uint3 rawPosition = GetRawPosition(data, id);
    uint3 rawVelocity = GetRawVelocity(maxParticleCount, data, id);
    position = asfloat(rawPosition);
    velocity = asfloat(rawVelocity);
    return rawPosition.x != INVALID_POSITION;
}

void StorePositionAndVelocity(StructuredBuffer<uint> bounds, uint maxParticleCount, RWByteAddressBuffer data, uint id, float3 position, float3 velocity, bool alive)
{
    if (alive)
    {
        uint3 storePosition = asuint(position);
        uint3 storeVelocity = asuint(velocity);

        data.Store3(GetOffsetPosition(id), storePosition);
        data.Store3(GetOffsetVelocity(maxParticleCount, id), storeVelocity);
    }
    else
    {
        data.Store(GetOffsetPosition(id), INVALID_POSITION);
    }
}

#endif

#endif //GRID_COMMON_HLSL