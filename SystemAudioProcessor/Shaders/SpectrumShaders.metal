#include <metal_stdlib>
using namespace metal;

struct SpectrumUniforms {
    float4 viewportAndCount;
    float4 layout;
};

struct SpectrumVertexOut {
    float4 position [[position]];
    float heightMix;
};

vertex SpectrumVertexOut spectrumVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant float *amplitudes [[buffer(0)]],
    constant SpectrumUniforms &uniforms [[buffer(1)]]
) {
    constexpr float2 corners[6] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(0.0, 1.0),
        float2(1.0, 0.0),
        float2(1.0, 1.0)
    };

    const float width = max(uniforms.viewportAndCount.x, 1.0);
    const float height = max(uniforms.viewportAndCount.y, 1.0);
    const float barCount = max(uniforms.viewportAndCount.z, 1.0);
    const float topPadding = uniforms.layout.x;
    const float bottomPadding = uniforms.layout.y;
    const float gap = min(max(uniforms.layout.z, 0.0), width / barCount * 0.35);
    const float usableWidth = max(width - gap * (barCount - 1.0), 0.0);
    const float barWidth = usableWidth / barCount;
    const float amplitude = clamp(amplitudes[instanceID], 0.0, 1.0);
    const float availableHeight = max(height - topPadding - bottomPadding, 1.0);
    const float barHeight = amplitude * availableHeight;
    const float2 corner = corners[vertexID];
    const float xPixels = float(instanceID) * (barWidth + gap) + corner.x * barWidth;
    const float yPixels = bottomPadding + corner.y * barHeight;

    SpectrumVertexOut output;
    output.position = float4(
        xPixels / width * 2.0 - 1.0,
        yPixels / height * 2.0 - 1.0,
        0.0,
        1.0
    );
    output.heightMix = corner.y;
    return output;
}

fragment float4 spectrumFragment(SpectrumVertexOut input [[stage_in]]) {
    const float3 bottomColor = float3(0.38, 0.38, 0.38);
    const float3 topColor = float3(0.96, 0.96, 0.96);
    return float4(mix(bottomColor, topColor, input.heightMix), 0.92);
}
