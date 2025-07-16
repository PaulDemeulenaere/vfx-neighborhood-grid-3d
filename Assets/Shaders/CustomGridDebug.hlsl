#include "GridCommon.hlsl"

#define ABSOLUTE_MAXIMUM_CAPACITY 262144
void GridDebug(inout VFXAttributes attributes,
    uint maxParticleCount,
    uint maxCellCount,
    float3 cellSize,
    StructuredBuffer<uint> bounds,
    StructuredBuffer<uint2> cellInstanceBuffer,
    StructuredBuffer<uint> cellStartBuffer,
    StructuredBuffer<uint> previousBounds,
    ByteAddressBuffer dataBuffer,
    RWStructuredBuffer<uint> gridStatistics)
{
    uint cellhash = attributes.particleId % ABSOLUTE_MAXIMUM_CAPACITY;

    [branch]
    if (cellhash > maxCellCount)
        return;

    uint cellStart = cellStartBuffer[cellhash];

    float3 bbMin, bbMax;
    uint3 dimensions;
    GetGridLayout(bounds, cellSize, bbMin, bbMax, dimensions);

    uint neighborCount = 0u;
    if (cellStart != INVALID_CELL_INDEX)
    {
        //N.B.: This code isn't efficient (should be done in LDS and then merged) but only used for debug
        InterlockedAdd(gridStatistics[0], 1);

        float3 readPos;
        uint2 readInstanceBuffer = cellInstanceBuffer[cellStart];
        GetPosition(bounds, dataBuffer, readInstanceBuffer.y, readPos);
        uint3 currentCell = GetCell(bounds, cellSize, readPos);
        float3 cellMin, cellMax;
        GetCellBounds(bounds, cellSize, currentCell, cellMin, cellMax);
        float3 centeredPosition = (cellMin + cellMax) * 0.5f;
        attributes.position = centeredPosition;

        uint maxStep = 2048;
        bool hashCollision = false;
        while (maxStep-- != 0 && cellStart < maxParticleCount)
        {
            readInstanceBuffer = cellInstanceBuffer[cellStart++];
            if (readInstanceBuffer.x != cellhash)
                break;

            float3 neighborPosition;
            if (GetPosition(previousBounds, dataBuffer, readInstanceBuffer.y, neighborPosition))
            {
                neighborCount++;
                uint3 neighborCell = GetCell(bounds, cellSize, neighborPosition);
                if (neighborCell.x != currentCell.x
                || neighborCell.y != currentCell.y
                || neighborCell.z != currentCell.z)
                {
                    hashCollision = true;
                }
            }
        }

        if (hashCollision)
        {
            InterlockedAdd(gridStatistics[1], 1);
        }

        InterlockedMin(gridStatistics[2], neighborCount);
        InterlockedMax(gridStatistics[3], neighborCount);
    }
    attributes.neighborCount = neighborCount;
}
