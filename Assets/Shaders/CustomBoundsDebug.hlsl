#include "GridCommon.hlsl"

void GridDebug(inout VFXAttributes attributes,
    float3 cellSize,
    StructuredBuffer<uint> bounds)
{
    float3 bbMin, bbMax;
    uint3 dimensions;
    GetGridLayout(bounds, cellSize, bbMin, bbMax, dimensions);

    float3 boundsCorner[8] =
    {
        float3(bbMin.x, bbMin.y, bbMin.z),
        float3(bbMax.x, bbMin.y, bbMin.z),
        float3(bbMax.x, bbMax.y, bbMin.z),
        float3(bbMin.x, bbMax.y, bbMin.z),
        float3(bbMin.x, bbMin.y, bbMax.z),
        float3(bbMax.x, bbMin.y, bbMax.z),
        float3(bbMax.x, bbMax.y, bbMax.z),
        float3(bbMin.x, bbMax.y, bbMax.z),
    };

    uint3 nextCorner[8] =
    {
        uint3(1, 3, 4),
        uint3(0, 2, 5),
        uint3(1, 3, 6),
        uint3(0, 2, 7),
        uint3(0, 5, 7),
        uint3(1, 4, 6),
        uint3(2, 5, 7),
        uint3(3, 4, 6),
    };

    uint id = attributes.particleId % 128u;
    uint direction = id % 3u;
    uint corner = (id / 3u) % 8u;
    uint depth = id / (3u * 8u);

    float3 normalizedDirection = normalize(boundsCorner[nextCorner[corner][direction]] - boundsCorner[corner]);
    attributes.position = boundsCorner[corner] + normalizedDirection * ((float) depth * cellSize[direction]);

    attributes.color = corner == 0 ? float3(0, 1, 0) : float3(1, 0, 0);

}