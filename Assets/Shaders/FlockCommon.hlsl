#include "GridCommon.hlsl"

void FlockApply(
    uint maxParticleCount,
    uint maxCellCount,
    float3 cellSize,
    StructuredBuffer<uint> bounds,
    StructuredBuffer<uint2> cellInstanceBuffer,
    StructuredBuffer<uint> cellStartBuffer,
    StructuredBuffer<uint> previousBounds,
    ByteAddressBuffer dataBuffer,
    float deltaTime,
    uint currentId,
    float3 position,
    inout float3 velocity,
    out uint neighborCount)
{
    neighborCount = 0u;

    uint3 currentCell = GetCell(bounds, cellSize, position);
    int3 corner;
    {
        float3 cellMin, cellMax;
        GetCellBounds(bounds, cellSize, currentCell, cellMin, cellMax);
        float3 normalizedPositionInCell = InverseLerp(cellMin, cellMax, position);
        corner = (int3)step((float3)0.5f, normalizedPositionInCell) * 2 - 1;
    }

    float3 accumulatedAlignment = 0.0f;
    float3 accumulatedPosition = 0.0f;
    float3 accumulatedAvoidPosition = 0.0f;
    float sqrCellSize = dot(cellSize, cellSize);
    float maxSqrRadiusSeparation = sqrCellSize * 0.33f;

    for (int k = 0; k <= 1; ++k) for (int j = 0; j <= 1; ++j) for (int i = 0; i <= 1; ++i)
    {
        int3 otherCell = (int3) currentCell + int3(i, j, k) * corner;
        if (!IsInBounds(bounds, cellSize, otherCell))
            continue;

        CellIterator it = GetCellIterator(bounds, cellStartBuffer, cellSize, maxCellCount, otherCell);

        uint maxStep = 16;
        uint readInstanceId;
        while (it.GetNext(cellInstanceBuffer, maxParticleCount, readInstanceId) && maxStep-- != 0)
        {
            if (readInstanceId == currentId)
                continue;

            float3 neighborPosition, neighborVelocity;
            if (!GetPositionAndVelocity(previousBounds, maxParticleCount, dataBuffer, readInstanceId, neighborPosition, neighborVelocity))
                continue;

            float3 positionVector = position - neighborPosition;
            float sqrLength = dot(positionVector, positionVector);

            if (sqrLength < sqrCellSize && sqrLength > 10e-5f)
            {
                accumulatedAlignment += neighborVelocity;
                accumulatedPosition += neighborPosition;

                if (sqrLength < maxSqrRadiusSeparation)
                {
                    float dampingAvoid = smoothstep(1.0f, 0.0f, sqrLength / maxSqrRadiusSeparation);
                    accumulatedAvoidPosition += normalize(positionVector) * dampingAvoid * sqrt(maxSqrRadiusSeparation);
                }

                neighborCount++;
            }
        }
    }

    if (neighborCount > 0u)
    {
        float3 cohesionVector = (accumulatedPosition / (float)neighborCount) - position;
        float3 alignmentVector = accumulatedAlignment / (float)neighborCount;
        float3 separationVector = accumulatedAvoidPosition;

        float separation = 15.0f;
        float alignment = 10.0f;
        float cohesion = 8.0f;

        velocity = lerp(velocity, separationVector, saturate(deltaTime * separation));
        velocity = lerp(velocity, alignmentVector, saturate(deltaTime * alignment));
        velocity = lerp(velocity, cohesionVector, saturate(deltaTime * cohesion));
    }
}