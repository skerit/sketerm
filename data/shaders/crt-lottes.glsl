// CRT-Lottes for sketerm — adaptation of Timothy Lottes' classic
// "CRT shader" (released by him as PUBLIC DOMAIN), the most-loved
// CRT look in the RetroArch ecosystem. Gaussian scanline beam,
// shadow mask, warp. Parameters follow the original's names.
//
//   custom_shader = /usr/share/sketerm/shaders/crt-lottes.glsl
//
// Tune via right-click > "Configure Shader…".

//@name CRT Lottes
//@desc Timothy Lottes' classic CRT: gaussian beam scanlines, shadow mask, warp. Public domain original.

#pragma parameter hardScan "Scanline hardness" -8.0 -20.0 0.0 1.0
#pragma parameter hardPix "Pixel sharpness" -3.0 -20.0 0.0 1.0
#pragma parameter warpX "Warp X" 0.031 0.0 0.125 0.01
#pragma parameter warpY "Warp Y" 0.041 0.0 0.125 0.01
#pragma parameter maskDark "Mask dark" 0.5 0.0 2.0 0.1
#pragma parameter maskLight "Mask light" 1.5 0.0 2.0 0.1
#pragma parameter shadowMask "Mask style (0-4)" 3.0 0.0 4.0 1.0
#pragma parameter brightBoost "Brightness boost" 1.0 0.5 2.0 0.05

uniform float hardScan;
uniform float hardPix;
uniform float warpX;
uniform float warpY;
uniform float maskDark;
uniform float maskLight;
uniform float shadowMask;
uniform float brightBoost;

// sRGB <-> linear helpers (the beam math runs in linear light).
float ToLinear1(float c) {
    return (c <= 0.04045) ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}
vec3 ToLinear(vec3 c) {
    return vec3(ToLinear1(c.r), ToLinear1(c.g), ToLinear1(c.b));
}
float ToSrgb1(float c) {
    return (c < 0.0031308) ? c * 12.92 : 1.055 * pow(c, 0.41666) - 0.055;
}
vec3 ToSrgb(vec3 c) {
    return vec3(ToSrgb1(c.r), ToSrgb1(c.g), ToSrgb1(c.b));
}

// Nearest emulated sample given floating-point position.
vec3 Fetch(vec2 pos, vec2 off) {
    pos = (floor(pos * iResolution.xy + off) + vec2(0.5, 0.5)) / iResolution.xy;
    if (pos.x < 0.0 || pos.x > 1.0 || pos.y < 0.0 || pos.y > 1.0) return vec3(0.0);
    return ToLinear(brightBoost * texture(iChannel0, pos).rgb);
}

vec2 Dist(vec2 pos) {
    pos = pos * iResolution.xy;
    return -((pos - floor(pos)) - vec2(0.5));
}

float Gaus(float pos, float scale) {
    return exp2(scale * pos * pos);
}

// 3-tap horizontal filter on one line.
vec3 Horz3(vec2 pos, float off) {
    vec3 b = Fetch(pos, vec2(-1.0, off));
    vec3 c = Fetch(pos, vec2(0.0, off));
    vec3 d = Fetch(pos, vec2(1.0, off));
    float dst = Dist(pos).x;
    float scale = hardPix;
    float wb = Gaus(dst - 1.0, scale);
    float wc = Gaus(dst + 0.0, scale);
    float wd = Gaus(dst + 1.0, scale);
    return (b * wb + c * wc + d * wd) / (wb + wc + wd);
}

// 5-tap horizontal filter on one line.
vec3 Horz5(vec2 pos, float off) {
    vec3 a = Fetch(pos, vec2(-2.0, off));
    vec3 b = Fetch(pos, vec2(-1.0, off));
    vec3 c = Fetch(pos, vec2(0.0, off));
    vec3 d = Fetch(pos, vec2(1.0, off));
    vec3 e = Fetch(pos, vec2(2.0, off));
    float dst = Dist(pos).x;
    float scale = hardPix;
    float wa = Gaus(dst - 2.0, scale);
    float wb = Gaus(dst - 1.0, scale);
    float wc = Gaus(dst + 0.0, scale);
    float wd = Gaus(dst + 1.0, scale);
    float we = Gaus(dst + 2.0, scale);
    return (a * wa + b * wb + c * wc + d * wd + e * we) / (wa + wb + wc + wd + we);
}

// Beam weight for a given scanline distance.
float Scan(vec2 pos, float off) {
    float dst = Dist(pos).y;
    return Gaus(dst + off, hardScan);
}

// Three-line gaussian beam.
vec3 Tri(vec2 pos) {
    vec3 a = Horz3(pos, -1.0);
    vec3 b = Horz5(pos, 0.0);
    vec3 c = Horz3(pos, 1.0);
    float wa = Scan(pos, -1.0);
    float wb = Scan(pos, 0.0);
    float wc = Scan(pos, 1.0);
    return a * wa + b * wb + c * wc;
}

// Tube warp.
vec2 Warp(vec2 pos) {
    pos = pos * 2.0 - 1.0;
    pos *= vec2(1.0 + (pos.y * pos.y) * warpX, 1.0 + (pos.x * pos.x) * warpY);
    return pos * 0.5 + 0.5;
}

// Shadow mask variants (0 = off, 1 = compressed TV, 2 = aperture
// grille, 3 = stretched VGA, 4 = VGA).
vec3 Mask(vec2 pos) {
    vec3 mask = vec3(maskDark, maskDark, maskDark);
    if (shadowMask < 0.5) {
        return vec3(1.0);
    } else if (shadowMask < 1.5) {
        float line_w = maskLight;
        float odd = 0.0;
        if (fract(pos.x / 6.0) < 0.5) odd = 1.0;
        if (fract((pos.y + odd) / 2.0) < 0.5) line_w = maskDark;
        pos.x = fract(pos.x / 3.0);
        if (pos.x < 0.333) mask.r = maskLight;
        else if (pos.x < 0.666) mask.g = maskLight;
        else mask.b = maskLight;
        mask *= line_w;
    } else if (shadowMask < 2.5) {
        pos.x = fract(pos.x / 3.0);
        if (pos.x < 0.333) mask.r = maskLight;
        else if (pos.x < 0.666) mask.g = maskLight;
        else mask.b = maskLight;
    } else if (shadowMask < 3.5) {
        pos.xy = floor(pos.xy * vec2(1.0, 0.5));
        pos.x += pos.y * 3.0;
        pos.x = fract(pos.x / 6.0);
        if (pos.x < 0.333) mask.r = maskLight;
        else if (pos.x < 0.666) mask.g = maskLight;
        else mask.b = maskLight;
    } else {
        pos.xy = floor(pos.xy * vec2(1.0, 0.5));
        pos.x += pos.y * 3.0;
        pos.x = fract(pos.x / 6.0);
        if (pos.x < 0.333) mask.r = maskLight;
        else if (pos.x < 0.666) mask.g = maskLight;
        else mask.b = maskLight;
    }
    return mask;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 pos = Warp(fragCoord / iResolution.xy);
    if (pos.x < 0.0 || pos.x > 1.0 || pos.y < 0.0 || pos.y > 1.0) {
        fragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    vec3 col = Tri(pos) * Mask(fragCoord);
    fragColor = vec4(ToSrgb(col), 1.0);
}
