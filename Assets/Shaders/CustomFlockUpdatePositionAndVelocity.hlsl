#include "GridCommon.hlsl"

void StorePosition(inout VFXAttributes attributes, StructuredBuffer<uint> bounds, uint maxParticleCount, RWByteAddressBuffer dataBuffer, float deltaTime)
{
#if USE_NEIGHBORCOUNT
    bool alive = attributes.age + deltaTime < attributes.lifetime && attributes.alive;
#else
    bool alive = true;
#endif
    StorePositionAndVelocity(bounds, maxParticleCount, dataBuffer, attributes.particleId % maxParticleCount, attributes.position, attributes.velocity, alive);
}