#include "FlockCommon.hlsl"

void FlockApply(inout VFXAttributes attributes,
    uint maxParticleCount,
    uint maxCellCount,
    float3 cellSize,
    StructuredBuffer<uint> bounds,
    StructuredBuffer<uint2>cellInstanceBuffer,
    StructuredBuffer<uint> cellStartBuffer,
    StructuredBuffer<uint> previousBounds,
    ByteAddressBuffer dataBuffer,
    float deltaTime)
{
    uint currentId = attributes.particleId % maxCellCount;
    float3 currentPos = attributes.position;
    float3 currentVel = attributes.velocity;

    uint neighborCount;
    FlockApply(
        maxParticleCount,
        maxCellCount,
        cellSize,
        bounds,
        cellInstanceBuffer,
        cellStartBuffer,
        previousBounds,
        dataBuffer,
        deltaTime,
        currentId,
        currentPos,
        currentVel,
        neighborCount);

    attributes.velocity = currentVel;

    if (neighborCount == 0)
    {
        //Slowly kill alone particles
        attributes.age += deltaTime;
    }
    else
    {
        
        attributes.age = 0.0f;
    }
#if USE_NEIGHBORCOUNT
    attributes.neighborCount = neighborCount;
#endif

}

