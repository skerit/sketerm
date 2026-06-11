// sketerm CRT shader — the full retro-terminal effect engine.
//
//   custom_shader           = /usr/share/sketerm/shaders/crt.glsl
//   custom_shader_animation = true   # flicker/noise/jitter/trails
//
// Or per pane via right-click > "Pane Shader…"; tune everything via
// "Configure Shader…" (live sliders + phosphor color picker).
// All effects re-implemented from scratch (cool-retro-term is GPL;
// its code is not used — only the ideas, which are older than us).
//
// Classic looks, all from this one file:
//   amber terminal:  colorize 1.0, phosphor #ffb333
//   green terminal:  colorize 1.0, phosphor #40ff59
//   modern colors:   colorize 0.0 (scanlines/curvature only)
//   trashy VHS-ish:  jitter 0.4, chroma 0.5, noise 0.2
//   slow phosphor:   persistence 0.6 (+ animation on)

//@name CRT
//@desc Retro tube engine: phosphor colorization (0 = keep colors), scanlines, curvature, glow, chromatic aberration, static noise, horizontal sync jitter, persistence trails, flicker. Animation recommended.

#pragma parameter colorize "Colorization (0 = original colors)" 1.0 0.0 1.0 0.05
#pragma parameter curvature "Tube curvature" 0.06 0.0 0.5 0.01
#pragma parameter scanlines "Scanline strength" 0.22 0.0 1.0 0.01
#pragma parameter glow "Glow / bloom" 0.55 0.0 2.0 0.05
#pragma parameter vignette "Vignette" 0.28 0.0 1.0 0.01
#pragma parameter chroma "Chromatic aberration" 0.0 0.0 2.0 0.05
#pragma parameter noise "Static noise" 0.0 0.0 0.5 0.01
#pragma parameter jitter "Horizontal sync jitter" 0.0 0.0 1.0 0.02
#pragma parameter persistence "Phosphor persistence" 0.0 0.0 0.95 0.05
#pragma parameter flicker "Flicker" 0.015 0.0 0.2 0.005
#pragma parameter brightness "Brightness" 1.0 0.5 1.6 0.02
#pragma parameter saturation "Saturation" 1.0 0.0 2.0 0.05
//@color phosphor 1.00 0.70 0.20 "Phosphor tint"
//@texture noiseTex builtin:noise

uniform sampler2D noiseTex;
uniform float colorize;
uniform float curvature;
uniform float scanlines;
uniform float glow;
uniform float vignette;
uniform float chroma;
uniform float noise;
uniform float jitter;
uniform float persistence;
uniform float flicker;
uniform float brightness;
uniform float saturation;
uniform vec3 phosphor;

float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

vec2 curve(vec2 uv) {
    uv = uv * 2.0 - 1.0;
    vec2 off = abs(uv.yx) * curvature;
    uv = uv + uv * off * off;
    return uv * 0.5 + 0.5;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = curve(fragCoord / iResolution.xy);

    // Horizontal sync jitter: per-scanline random offset that only
    // moves while animating (uses iTime). Occasional bigger "tear".
    if (jitter > 0.0) {
        float line_rnd = hash12(vec2(floor(fragCoord.y), floor(iTime * 60.0)));
        float tear = step(0.995, hash12(vec2(floor(iTime * 13.0), 7.0)));
        uv.x += (line_rnd - 0.5) * 0.003 * jitter
              + tear * (hash12(vec2(floor(fragCoord.y * 0.1), floor(iTime * 13.0))) - 0.5) * 0.04 * jitter;
    }

    // Outside the curved tube: black bezel.
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        fragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    // Chromatic aberration: split R/B horizontally around the center.
    vec3 col;
    if (chroma > 0.0) {
        vec2 d = (uv - 0.5) * 0.002 * chroma;
        col = vec3(
            texture(iChannel0, uv + d).r,
            texture(iChannel0, uv).g,
            texture(iChannel0, uv - d).b);
    } else {
        col = texture(iChannel0, uv).rgb;
    }

    // Cheap bloom: 4-tap cross blur added on top.
    vec2 px = 1.5 / iResolution.xy;
    vec3 bloom = texture(iChannel0, uv + vec2(px.x, 0.0)).rgb
               + texture(iChannel0, uv - vec2(px.x, 0.0)).rgb
               + texture(iChannel0, uv + vec2(0.0, px.y)).rgb
               + texture(iChannel0, uv - vec2(0.0, px.y)).rgb;
    col += bloom * 0.25 * glow;

    // Saturation + brightness.
    float lum = dot(col, vec3(0.299, 0.587, 0.114));
    col = mix(vec3(lum), col, saturation) * brightness;

    // Phosphor colorization: 0 keeps the original colors entirely.
    col = mix(col, phosphor * lum * brightness, colorize);

    // Scanlines locked to output pixels (stable while scrolling).
    float scan = sin(fragCoord.y * 3.14159) * 0.5 + 0.5;
    col *= 1.0 - scanlines * scan;

    // Static noise — texture grain (cool-retro-term style). The
    // repeating 256² noise tile reads softer than per-pixel hash
    // noise. A CONTINUOUS uv offset would translate the tile and
    // look like a diagonal crawl; instead jump to a fresh random
    // tile position each ~frame so it flickers in place like real
    // tube static, with no direction.
    if (noise > 0.0) {
        float frame = floor(iTime * 24.0);
        vec2 jump = vec2(hash12(vec2(frame, 11.0)), hash12(vec2(frame, 23.0)));
        vec2 nuv = fragCoord / 256.0 + jump;
        col += (texture(noiseTex, nuv).rgb - 0.5) * noise;
    }

    // Vignette darkens the corners like a real tube.
    vec2 v = uv * (1.0 - uv);
    col *= pow(v.x * v.y * 16.0, vignette);

    // Phosphor persistence: decaying max with LAST frame's output
    // (iChannel1) — moving text leaves fading trails. Decays per
    // rendered frame; enable animation for a smooth fade.
    vec3 prev = texture(iChannel1, fragCoord / iResolution.xy).rgb;
    col = max(col, prev * persistence);

    // Mains-hum flicker (only moves when animation is on).
    col *= 1.0 - flicker * (0.5 + 0.5 * sin(iTime * 120.0));

    fragColor = vec4(col, 1.0);
}
