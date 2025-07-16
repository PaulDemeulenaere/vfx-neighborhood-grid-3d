#include "GridCommon.hlsl"

void CustomHLSL(inout VFXAttributes attributes,
    uint maxParticleCount,
    uint maxCellCount,
    float3 cellSize,
    StructuredBuffer<uint> bounds,
    StructuredBuffer<uint2>cellInstanceBuffer,
    StructuredBuffer<uint> cellStartBuffer,
    StructuredBuffer<uint> previousBounds,
    ByteAddressBuffer dataBuffer)
{
    float3 currentPos = attributes.position;
    uint3 currentCell = GetCell(bounds, cellSize, currentPos);
    uint currentId = attributes.particleId % maxParticleCount;

    int3 corner;
    {
        float3 cellMin, cellMax;
        GetCellBounds(bounds, cellSize, currentCell, cellMin, cellMax);
        float3 normalizedPositionInCell = InverseLerp(cellMin, cellMax, currentPos);
        corner = (int3)step((float3)0.5f, normalizedPositionInCell) * 2 - 1;
    }

    float maxDistances[4] = { FLT_MAX, FLT_MAX, FLT_MAX, FLT_MAX };
    uint neighborIds[4] = { ~0u, ~0u, ~0u, ~0u };

    for (int k = 0; k <= 1; ++k) for (int j = 0; j <= 1; ++j) for (int i = 0; i <= 1; ++i)
    {
        int3 otherCell = (int3)currentCell + int3(i, j, k) * corner;
        if (!IsInBounds(bounds, cellSize, otherCell))
            continue;

        uint cellHash = CalculateHash(bounds, cellSize, maxCellCount, otherCell);
        uint cellStart = cellStartBuffer[cellHash];

        float maxLength = dot(cellSize, cellSize);

        if (cellStart != INVALID_CELL_INDEX)
        {
            uint maxStep = 64;
            while (maxStep-- != 0 && cellStart < maxParticleCount)
            {
                uint2 readInstanceBuffer = cellInstanceBuffer[cellStart++];
                if (readInstanceBuffer.x != cellHash)
                    break;

                if (readInstanceBuffer.y == currentId)
                    continue;

                float3 neighborPosition;
                if (!GetPosition(previousBounds, dataBuffer, readInstanceBuffer.y, neighborPosition))
                    continue;

                float3 positionVector = currentPos - neighborPosition;
                float sqrLength = dot(positionVector, positionVector);

                //If there are hash cell collision, we can sample far from the cellSize
                if (sqrLength > maxLength)
                    continue;

                uint replaceCandidate = ~0u;
                for (int neighbor = 0; neighbor < 4; ++neighbor)
                {
                    if (sqrLength < maxDistances[neighbor])
                    {
                        if (replaceCandidate == ~0u || maxDistances[neighbor] < maxDistances[replaceCandidate])
                        {
                            replaceCandidate = neighbor;
                        }
                    }
                }

                if (replaceCandidate != ~0u)
                {
                    maxDistances[replaceCandidate] = sqrLength;
                    neighborIds[replaceCandidate] = readInstanceBuffer.y;
                }
            }
        }
    }

    attributes.neighbor_A = neighborIds[0];
    attributes.neighbor_B = neighborIds[1];
    attributes.neighbor_C = neighborIds[2];
    attributes.neighbor_D = neighborIds[3];
}

