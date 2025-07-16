
//We are reading and storing position/velocity within the same compute, override read buffer format
#define BYTEADDRESSBUFFERDATA_READ_FMT RWByteAddressBuffer

#include "GridCommon.hlsl"

void ReadVelocity(inout VFXAttributes attributes, StructuredBuffer<uint> bounds, uint maxParticleCount, RWByteAddressBuffer dataBuffer)
{
    float3 position, velocity;
    if (GetPositionAndVelocity(bounds, maxParticleCount, dataBuffer, attributes.particleId % maxParticleCount, position, velocity))
    {
        attributes.velocity = velocity;
#if USE_NEIGHBORCOUNT
        attributes.neighborCount = (uint)position.z;
#endif
    }
}

void StorePositionAndVelocity(inout VFXAttributes attributes, StructuredBuffer<uint> bounds, uint maxParticleCount, RWByteAddressBuffer dataBuffer, float deltaTime)
{
#if USE_NEIGHBORCOUNT
    if (attributes.neighborCount == 0)
    {
        //Slowly kill alone particles
        attributes.age += deltaTime;
    }
    else
    {
        attributes.age = 0.0f;
    }
    bool alive = attributes.age + deltaTime < attributes.lifetime && attributes.alive;
#else
    bool alive = true;
#endif


    StorePositionAndVelocity(bounds, maxParticleCount, dataBuffer, attributes.particleId % maxParticleCount, attributes.position, attributes.velocity, true);
}