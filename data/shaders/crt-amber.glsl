// sketerm CRT shader — amber phosphor monitor.
//
//   custom_shader           = /usr/share/sketerm/shaders/crt-amber.glsl
//   custom_shader_animation = true        # for the subtle flicker
//
// Or per pane via right-click > "Pane Shader…", or per profile.
// Effects: monochrome amber phosphor, scanlines, barrel curvature,
// glow (bloom), vignette, faint flicker.
//
// Every knob below is tunable from config.conf without editing this
// file — the `//@param name default` lines declare the defaults and
// `shader_param.<name> = <value>` overrides them (applied live on
// config reload):
//
//   shader_param.glow      = 1.2
//   shader_param.curvature = 0.0     # flat screen
//   shader_param.scanlines = 0.4
//   shader_param.vignette  = 0.1
//   shader_param.flicker   = 0.03
//   shader_param.mono      = 0.0     # keep original colors, tint off

#define PHOSPHOR vec3(1.00, 0.70, 0.20)   // amber

//@param curvature 0.06
//@param scanlines 0.22
//@param glow 0.55
//@param vignette 0.28
//@param flicker 0.015
//@param mono 1.0
uniform float curvature;
uniform float scanlines;
uniform float glow;
uniform float vignette;
uniform float flicker;
uniform float mono;

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
    col = mix(col, PHOSPHOR * lum, mono);

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
