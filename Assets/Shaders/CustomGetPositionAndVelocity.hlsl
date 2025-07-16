#include "GridCommon.hlsl"

void CustomHLSL(StructuredBuffer<uint> bounds,
uint maxParticleCount,
ByteAddressBuffer data,
uint index,
out bool alive,
out float3 position,
out float3 velocity)
{
    position = velocity = (float3)0;

    [branch]
    if (index == ~0u)
    {
        alive = false;
    }
    else
    {
        alive = GetPositionAndVelocity(bounds, maxParticleCount, data, index, position, velocity);
    }
}