// One footprint implementation for direct light and fog scattering.
// Caller declares uniform vec4 u_lamp[5]. All dimensions are screen pixels.
float condenserLampEnvelope(vec2 pixel, vec4 shape, vec4 reach, vec4 style)
{
    vec2 cell = (floor(pixel / reach.z) + vec2(0.5)) * reach.z;
    float dy = cell.y - shape.y;
    float extent = dy < 0.0 ? reach.x : reach.y;
    if (shape.z <= 0.0 || extent <= 0.0 || abs(dy) >= extent) return 0.0;
    float edge = shape.z * 0.5 + style.x * abs(dy) / extent - abs(cell.x - shape.x);
    float h = style.y <= 0.0 ? step(0.0, edge) : clamp(edge / style.y, 0.0, 1.0);
    float v = max(0.0, 1.0 - abs(dy) / extent);
    return h * pow(v, style.z);
}
float condenserLampFlicker()
{
    return 1.0 - u_lamp[4].x * (0.5 + 0.5 * sin(u_lamp[4].y * 6.2831853));
}
float condenserLampAt(vec2 pixel)
{
    return condenserLampEnvelope(pixel, u_lamp[0], u_lamp[1], u_lamp[3]) *
        u_lamp[0].w * u_lamp[1].w * u_lamp[3].w * condenserLampFlicker();
}
float condenserReferenceLamp(vec2 pixel)
{
    return condenserLampEnvelope(pixel, vec4(309.0,12.0,348.0,1.0),
        vec4(12.0,132.0,6.0,1.0), vec4(0.0,6.0,2.0,1.0));
}
float condenserLampSource(vec2 pixel)
{
    if (u_lamp[0].z <= 0.0) return 0.0;
    float x = (floor(pixel.x / u_lamp[1].z) + 0.5) * u_lamp[1].z;
    float edge = u_lamp[0].z * 0.5 - abs(x - u_lamp[0].x);
    float h = u_lamp[3].y <= 0.0 ? step(0.0, edge) : clamp(edge / u_lamp[3].y, 0.0, 1.0);
    return h * clamp(u_lamp[0].w * condenserLampFlicker(), 0.0, 1.0) * u_lamp[1].w;
}
