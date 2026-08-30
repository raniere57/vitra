#include <metal_stdlib>
using namespace metal;

// One instance draws one rectangle. Backgrounds, glyphs, underlines, and the
// cursor are all the same primitive; a glyph is simply a rectangle whose colour
// is masked by the atlas. That keeps a full frame to a single draw call.
struct CellInstance {
    float2 origin;   // top-left in pixels, y down
    float2 size;     // pixels
    float4 color;
    float2 uvMin;    // uvMin == uvMax means a solid fill, not a glyph
    float2 uvMax;
};

struct Uniforms {
    float2 viewportSize;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float isGlyph;
};

vertex VertexOut cell_vertex(uint vertexID [[vertex_id]],
                             uint instanceID [[instance_id]],
                             const device CellInstance *instances [[buffer(0)]],
                             constant Uniforms &uniforms [[buffer(1)]])
{
    const float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1)
    };
    const float2 corner = corners[vertexID];
    const device CellInstance &instance = instances[instanceID];

    float2 pixel = instance.origin + corner * instance.size;
    float2 ndc = (pixel / uniforms.viewportSize) * 2.0 - 1.0;
    ndc.y = -ndc.y;  // pixels grow downward, Metal's clip space grows upward

    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.uv = mix(instance.uvMin, instance.uvMax, corner);
    out.color = instance.color;
    out.isGlyph = instance.uvMax.x > instance.uvMin.x ? 1.0 : 0.0;
    return out;
}

fragment float4 cell_fragment(VertexOut in [[stage_in]],
                              texture2d<float> atlas [[texture(0)]])
{
    if (in.isGlyph < 0.5) {
        return in.color;
    }
    constexpr sampler atlasSampler(filter::linear, address::clamp_to_edge);
    float coverage = atlas.sample(atlasSampler, in.uv).r;
    return float4(in.color.rgb, in.color.a * coverage);
}
