// sketerm CRT shader — amber phosphor monitor.
//
//   custom_shader           = /usr/share/sketerm/shaders/crt-amber.glsl
//   custom_shader_animation = true        # for the subtle flicker
//
// Or per pane via right-click > "Pane Shader…", or per profile.
// Effects: monochrome amber phosphor, scanlines, barrel curvature,
// glow (bloom), vignette, faint flicker. Tuning knobs below.

#define PHOSPHOR vec3(1.00, 0.70, 0.20)   // amber
#define CURVATURE 0.06                    // 0.0 = flat screen
#define SCANLINE_STRENGTH 0.22
#define GLOW 0.55
#define VIGNETTE 0.28
#define FLICKER 0.015                     // needs animation for life

vec2 curve(vec2 uv) {
    uv = uv * 2.0 - 1.0;
    vec2 off = abs(uv.yx) / vec2(1.0 / CURVATURE, 1.0 / CURVATURE);
    uv = uv + uv * off * off;
    return uv * 0.5 + 0.5;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = curve(fragCoord / iResolution.xy);

    // Outside the curved tube: black bezel.
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        fragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    vec3 col = texture(iChannel0, uv).rgb;

    // Cheap bloom: 4-tap cross blur added on top.
    vec2 px = 1.5 / iResolution.xy;
    vec3 glow = texture(iChannel0, uv + vec2(px.x, 0.0)).rgb
              + texture(iChannel0, uv - vec2(px.x, 0.0)).rgb
              + texture(iChannel0, uv + vec2(0.0, px.y)).rgb
              + texture(iChannel0, uv - vec2(0.0, px.y)).rgb;
    col += glow * 0.25 * GLOW;

    // Monochrome phosphor: luminance through the tint.
    float lum = dot(col, vec3(0.299, 0.587, 0.114));
    col = PHOSPHOR * lum;

    // Scanlines locked to output pixels (stable while scrolling).
    float scan = sin(fragCoord.y * 3.14159) * 0.5 + 0.5;
    col *= 1.0 - SCANLINE_STRENGTH * scan;

    // Vignette darkens the corners like a real tube.
    vec2 v = uv * (1.0 - uv);
    col *= pow(v.x * v.y * 16.0, VIGNETTE);

    // Mains-hum flicker (only moves when animation is on).
    col *= 1.0 - FLICKER * (0.5 + 0.5 * sin(iTime * 120.0));

    fragColor = vec4(col, 1.0);
}
