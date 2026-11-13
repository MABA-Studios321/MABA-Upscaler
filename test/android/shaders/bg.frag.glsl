// MABA test scene - background sky, drawn first with depth test/write off. Matches the sky,
// exposure and tonemap in scene3d.frag.glsl, plus a sparse star field (sub-pixel detail stress).
precision highp float;
in highp vec2 vMabaUV;
layout(location = 0) out vec4 oColor;

const vec3 ORANGE = vec3(1.0, 0.45, 0.08);

vec3 skyColor(float y)
{
    vec3 c = mix(vec3(0.030, 0.022, 0.035), vec3(0.004, 0.006, 0.016), smoothstep(0.0, 0.6, y));
    c = mix(vec3(0.003, 0.003, 0.005), c, smoothstep(-0.25, 0.02, y));
    c += ORANGE * 0.12 * exp(-abs(y) * 12.0);
    return c;
}

vec3 acesTonemap(vec3 x)
{
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

float hash12(vec2 p)
{
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

void main()
{
    // The camera looks slightly down at the core, so the horizon sits a little above centre.
    float y = (vMabaUV.y - 0.58) * 1.3;
    vec3 col = skyColor(y);

    // Stars on a fixed angular grid (independent of render resolution), fading to the horizon.
    // Each cell may hold one small round star at a random offset (not a whole lit square).
    vec2 grid = vMabaUV * vec2(150.0, 80.0);
    vec2 cell = floor(grid);
    float h = hash12(cell);
    vec2 off = vec2(hash12(cell + 17.0), hash12(cell + 41.0)) * 0.6 + 0.2;
    float d = length(fract(grid) - off);
    float star = step(0.975, h) * smoothstep(0.10, 0.0, d) * smoothstep(0.08, 0.5, y);
    col += vec3(0.75, 0.82, 1.0) * star * (0.3 + 1.2 * fract(h * 97.0));

    vec3 outc = pow(acesTonemap(col * 1.35), vec3(1.0 / 2.2));
    outc += (hash12(gl_FragCoord.xy) - 0.5) / 255.0;
    oColor = vec4(clamp(outc, 0.0, 1.0), 1.0);
}
