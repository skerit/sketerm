// sketerm CRT shader — green phosphor monitor (P1).
//
//   custom_shader           = /usr/share/sketerm/shaders/crt-green.glsl
//   custom_shader_animation = true        # for the subtle flicker
//
// Or per pane via right-click > "Pane Shader…", or per profile.
// Effects: monochrome amber phosphor, scanlines, barrel curvature,
// glow (bloom), vignette, faint flicker.
//
// Every knob below is tunable WITHOUT editing this file: right-click
// a pane using it > "Configure Shader…" for live sliders + color
// picker, or set `shader_param.<name> = <value>` (floats, or #rrggbb
// for colors) in config.conf — applied live on reload. Param
// declarations use the RetroArch `#pragma parameter` format
// (name "Label" default min max step) plus sketerm's //@color,
// //@name and //@desc extensions.

//@name Green CRT
//@desc Monochrome phosphor tube: scanlines, curvature, glow, vignette and mains-hum flicker (enable custom_shader_animation).

#pragma parameter curvature "Tube curvature" 0.06 0.0 0.5 0.01
#pragma parameter scanlines "Scanline strength" 0.22 0.0 1.0 0.01
#pragma parameter glow "Glow / bloom" 0.55 0.0 2.0 0.05
#pragma parameter vignette "Vignette" 0.28 0.0 1.0 0.01
#pragma parameter flicker "Flicker" 0.015 0.0 0.2 0.005
#pragma parameter mono "Monochrome mix" 1.0 0.0 1.0 0.05
//@color phosphor 0.25 1.00 0.35 "Phosphor tint"
uniform float curvature;
uniform float scanlines;
uniform float glow;
uniform float vignette;
uniform float flicker;
uniform float mono;
uniform vec3 phosphor;

vec2 curve(vec2 uv) {
    uv = uv * 2.0 - 1.0;
    vec2 off = abs(uv.yx) * curvature;
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
    vec3 bloom = texture(iChannel0, uv + vec2(px.x, 0.0)).rgb
               + texture(iChannel0, uv - vec2(px.x, 0.0)).rgb
               + texture(iChannel0, uv + vec2(0.0, px.y)).rgb
               + texture(iChannel0, uv - vec2(0.0, px.y)).rgb;
    col += bloom * 0.25 * glow;

    // Monochrome phosphor: luminance through the tint. mono=0 keeps
    // the original colors (scanlines/curvature only).
    float lum = dot(col, vec3(0.299, 0.587, 0.114));
    col = mix(col, phosphor * lum, mono);

    // Scanlines locked to output pixels (stable while scrolling).
    float scan = sin(fragCoord.y * 3.14159) * 0.5 + 0.5;
    col *= 1.0 - scanlines * scan;

    // Vignette darkens the corners like a real tube.
    vec2 v = uv * (1.0 - uv);
    col *= pow(v.x * v.y * 16.0, vignette);

    // Mains-hum flicker (only moves when animation is on).
    col *= 1.0 - flicker * (0.5 + 0.5 * sin(iTime * 120.0));

    fragColor = vec4(col, 1.0);
}
