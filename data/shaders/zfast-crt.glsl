/*
    zfast_crt_standard - A simple, fast CRT shader.

    Copyright (C) 2017 Greg Hogan (SoltanGris42)

    This program is free software; you can redistribute it and/or modify it
    under the terms of the GNU General Public License as published by the Free
    Software Foundation; either version 2 of the License, or (at your option)
    any later version.

    sketerm port of the RetroArch original
    (libretro/glsl-shaders crt/shaders/zfast_crt.glsl).
    Port changes: Texture/TextureSize/OutputSize mapped onto
    iChannel0/iResolution; the passthrough vertex stage's varyings
    (maskFade, invDims) computed inline; FINEMASK kept; a `v_scale`
    parameter added so the terminal frame acts as a low-res source.

    See data/shaders/README for per-file licensing.
*/

//@name zfast CRT
//@desc Greg Hogan's fast CRT (RetroArch, GPL-2+): sharpened Quilez scaling, luminance-weighted scanlines, fine aperture mask. v_scale sets the virtual source resolution.

#pragma parameter v_scale "Virtual scale (source px size)" 2.0 1.0 6.0 1.0
#pragma parameter BLURSCALEX "Blur Amount X-Axis" 0.30 0.0 1.0 0.05
#pragma parameter LOWLUMSCAN "Scanline Darkness - Low" 6.0 0.0 10.0 0.5
#pragma parameter HILUMSCAN "Scanline Darkness - High" 8.0 0.0 50.0 1.0
#pragma parameter BRIGHTBOOST "Dark Pixel Brightness Boost" 1.25 0.5 1.5 0.05
#pragma parameter MASK_DARK "Mask Effect Amount" 0.25 0.0 1.0 0.05
#pragma parameter MASK_FADE "Mask/Scanline Fade" 0.8 0.0 1.0 0.05

uniform float v_scale;
uniform float BLURSCALEX;
uniform float LOWLUMSCAN;
uniform float HILUMSCAN;
uniform float BRIGHTBOOST;
uniform float MASK_DARK;
uniform float MASK_FADE;

void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    // Port plumbing (was the vertex stage + RetroArch uniforms).
    vec2 TextureSize = iResolution.xy / v_scale;
    vec2 invDims = 1.0 / TextureSize;
    float maskFade = 0.3333 * MASK_FADE;
    vec2 vTexCoord = (fragCoord / iResolution.xy) * 1.0001;

    //This is just like "Quilez Scaling" but sharper
    vec2 p = vTexCoord * TextureSize;
    vec2 i = floor(p) + 0.50;
    vec2 f = p - i;
    p = (i + 4.0 * f * f * f) * invDims;
    p.x = mix(p.x, vTexCoord.x, BLURSCALEX);
    float Y = f.y * f.y;
    float YY = Y * Y;

    // FINEMASK variant (ratio = 1 at native sampling).
    float whichmask = floor(fragCoord.x) * -0.5;
    float mask = 1.0 + float(fract(whichmask) < 0.5) * -MASK_DARK;

    vec3 colour = texture(iChannel0, p).rgb;

    float scanLineWeight = (BRIGHTBOOST - LOWLUMSCAN * (Y - 2.05 * YY));
    float scanLineWeightB = 1.0 - HILUMSCAN * (YY - 2.8 * YY * Y);

    fragColor = vec4(colour.rgb * mix(scanLineWeight * mask, scanLineWeightB, dot(colour.rgb, vec3(maskFade))), 1.0);
}
