/* MABA Upscaler - CPU reference implementation of the fragment shader math.
 *
 * Mirrors src/maba_upscaler.frag.glsl (fast and MABA_QUALITY paths) in plain C so the algorithm
 * can be property-tested on the host and used as a golden reference for GPU output comparison.
 * Uses float (highp); the GPU fast build uses mediump, so allow ~2/255 tolerance when comparing.
 *
 * Build:  gcc -std=c99 -O2 -Wall -Wextra -o reference reference.c -lm
 * Run:    reference selftest          (property tests)
 *         reference golden <dir>      (write golden PPMs)
 *         reference render <pattern> <fast|quality> <scale> <out.ppm> [outW outH]
 *
 * Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define EDGE_LO (10.0f / 255.0f)
#define EDGE_HI (24.0f / 255.0f)
#define DARK_LO 0.02f
#define DARK_HI 0.12f

typedef struct { float r, g, b; } RGB;
typedef struct { int w, h; RGB* px; } Image;   /* allocated texture */

static float clampf(float x, float lo, float hi) { return x < lo ? lo : (x > hi ? hi : x); }
static float minf(float a, float b) { return a < b ? a : b; }
static float maxf(float a, float b) { return a > b ? a : b; }
static float lerp(float a, float b, float t) { return a + (b - a) * t; }

static Image img_new(int w, int h)
{
    Image im; im.w = w; im.h = h;
    im.px = (RGB*)calloc((size_t)w * h, sizeof(RGB));
    if (!im.px) { printf("out of memory (%dx%d image)\n", w, h); exit(1); }
    return im;
}
static void img_free(Image* im) { free(im->px); im->px = NULL; }

static RGB img_texel(const Image* im, int x, int y)
{
    x = (int)clampf((float)x, 0.0f, (float)(im->w - 1));
    y = (int)clampf((float)y, 0.0f, (float)(im->h - 1));
    return im->px[(size_t)y * im->w + x];
}

/* LINEAR, CLAMP_TO_EDGE sample at pixel-centre coordinates (u in texels). */
static RGB img_bilinear(const Image* im, float u, float v)
{
    float x = u - 0.5f, y = v - 0.5f;
    int i0 = (int)floorf(x), j0 = (int)floorf(y);
    float fx = x - i0, fy = y - j0;
    RGB f = img_texel(im, i0, j0), g = img_texel(im, i0 + 1, j0);
    RGB j = img_texel(im, i0, j0 + 1), k = img_texel(im, i0 + 1, j0 + 1);
    RGB o;
    o.r = lerp(lerp(f.r, g.r, fx), lerp(j.r, k.r, fx), fy);
    o.g = lerp(lerp(f.g, g.g, fx), lerp(j.g, k.g, fx), fy);
    o.b = lerp(lerp(f.b, g.b, fx), lerp(j.b, k.b, fx), fy);
    return o;
}

/* textureGather footprint: the four texels around the sample point, green channel.
 * Returns w=(i,j), z=(i+1,j), x=(i,j+1), y=(i+1,j+1) as in GLSL. */
static void gather_g(const Image* im, float u, float v, float* w, float* z, float* x, float* y)
{
    int i = (int)floorf(u - 0.5f), j = (int)floorf(v - 0.5f);
    *w = img_texel(im, i, j).g;
    *z = img_texel(im, i + 1, j).g;
    *x = img_texel(im, i, j + 1).g;
    *y = img_texel(im, i + 1, j + 1).g;
}

//----------------------------------------------------------------------------------------------
// Shader math, line-for-line from the GLSL.
//----------------------------------------------------------------------------------------------

static float sharp_pos(float pp, float brightness, float sharpness, float* out)
{
    float s = sharpness * clampf((brightness - DARK_LO) * (1.0f / (DARK_HI - DARK_LO)), 0.0f, 1.0f);
    *out = pp + s * pp * (pp - 1.0f) * (1.0f - 2.0f * pp);
    return s;
}

static float diagonal(float f, float g, float j, float k)
{
    float dFK = fabsf(f - k), dGJ = fabsf(g - j);
    return clampf(0.5f + (dGJ - dFK) / (dGJ + dFK + 1.0f / 255.0f), 0.0f, 1.0f);
}

static float twist_weight(float px, float py, float preferFK)
{
    return lerp(maxf(px + py - 1.0f, 0.0f), minf(px, py), preferFK);
}

static float block_delta(float f, float g, float j, float k, float ppx, float ppy, float sharpness)
{
    float px, py;
    sharp_pos(ppx, maxf(maxf(f, g), maxf(j, k)), sharpness, &px);
    sharp_pos(ppy, maxf(maxf(f, g), maxf(j, k)), sharpness, &py);
    float w = twist_weight(px, py, diagonal(f, g, j, k));
    return (g - f) * (px - ppx) + (j - f) * (py - ppy)
         + (f - g - j + k) * (w - ppx * ppy);
}

static void maba_set(float* dirx, float* diry, float* len, float w,
                     float lA, float lB, float lC, float lD, float lE)
{
    float dirX = lD - lB;
    float lenX = maxf(fabsf(lD - lC), fabsf(lC - lB));
    lenX = clampf(fabsf(dirX) / maxf(lenX, 1.0f / 512.0f), 0.0f, 1.0f);
    *dirx += dirX * w;
    *len += lenX * lenX * w;

    float dirY = lE - lA;
    float lenY = maxf(fabsf(lE - lC), fabsf(lC - lA));
    lenY = clampf(fabsf(dirY) / maxf(lenY, 1.0f / 512.0f), 0.0f, 1.0f);
    *diry += dirY * w;
    *len += lenY * lenY * w;
}

static void maba_tap(float* aC, float* aW, float offx, float offy, float dirx, float diry,
                     float len2x, float len2y, float lob, float clp, float c)
{
    float vx = (offx * dirx + offy * diry) * len2x;
    float vy = (offy * dirx - offx * diry) * len2y;
    float d2 = minf(vx * vx + vy * vy, clp);
    float wB = 0.4f * d2 - 1.0f;
    float wA = lob * d2 - 1.0f;
    wB *= wB; wA *= wA;
    wB = 1.5625f * wB - 0.5625f;
    float w = wB * wA;
    *aC += c * w;
    *aW += w;
}

/* Render one output pixel. region = image region size, tex = allocated texture. */
static RGB maba_pixel(const Image* tex, int regionW, int regionH, int outW, int outH,
                      int x, int y, int quality, float sharpness)
{
    float uvx = (x + 0.5f) / outW, uvy = (y + 0.5f) / outH;
    float posx = clampf(uvx * regionW - 0.5f, 0.0f, regionW - 1.001f);
    float posy = clampf(uvy * regionH - 0.5f, 0.0f, regionH - 1.001f);
    float fpx = floorf(posx), fpy = floorf(posy);
    float ppx = posx - fpx, ppy = posy - fpy;

    float bu = minf(uvx * regionW, regionW - 0.5f);
    float bv = minf(uvy * regionH, regionH - 0.5f);
    RGB color = img_bilinear(tex, bu, bv);

    float f, g, j, k;
    gather_g(tex, fpx + 1.0f, fpy + 1.0f, &f, &g, &j, &k);
    /* GLSL: q.w=f q.z=g q.x=j q.y=k; gather_g returns w,z,x,y in that order */
    float mn = minf(minf(f, g), minf(j, k));
    float mx = maxf(maxf(f, g), maxf(j, k));
    float bd = block_delta(f, g, j, k, ppx, ppy, sharpness);

    if (!quality) {
        RGB o;
        o.r = clampf(color.r + bd, 0.0f, 1.0f);
        o.g = clampf(color.g + bd, 0.0f, 1.0f);
        o.b = clampf(color.b + bd, 0.0f, 1.0f);
        return o;
    }

    float contrast = mx - mn;
    if (contrast < EDGE_LO || fpx < 1.0f || fpy < 1.0f
        || fpx + 2.5f > regionW || fpy + 2.5f > regionH) {
        RGB o;
        o.r = clampf(color.r + bd, 0.0f, 1.0f);
        o.g = clampf(color.g + bd, 0.0f, 1.0f);
        o.b = clampf(color.b + bd, 0.0f, 1.0f);
        return o;
    }

    /* 12-tap footprint gathers (green), offsets relative to (fpx+1, fpy-1). */
    float b, c, i, e, l, h, o, n;
    {
        float zw[4];
        gather_g(tex, fpx + 1.0f, fpy - 1.0f, &zw[0], &zw[1], &b, &c);
        gather_g(tex, fpx, fpy + 1.0f, &e, &zw[1], &i, &zw[3]);
        gather_g(tex, fpx + 2.0f, fpy + 1.0f, &zw[0], &h, &zw[2], &l);
        gather_g(tex, fpx + 1.0f, fpy + 3.0f, &n, &o, &zw[2], &zw[3]);
    }

    float dirx = 0.0f, diry = 0.0f, len = 0.0f;
    maba_set(&dirx, &diry, &len, (1.0f - ppx) * (1.0f - ppy), b, e, f, g, j);
    maba_set(&dirx, &diry, &len, ppx * (1.0f - ppy),         c, f, g, h, k);
    maba_set(&dirx, &diry, &len, (1.0f - ppx) * ppy,         f, i, j, k, n);
    maba_set(&dirx, &diry, &len, ppx * ppy,                  g, j, k, l, o);

    float dirR = dirx * dirx + diry * diry;
    if (dirR < 1.0f / 8192.0f) { dirx = 1.0f; diry = 0.0f; }
    else { float inv = 1.0f / sqrtf(dirR); dirx *= inv; diry *= inv; }

    len *= 0.5f; len *= len;
    float stretch = 1.0f / maxf(fabsf(dirx), fabsf(diry));
    float len2x = 1.0f + (stretch - 1.0f) * len;
    float len2y = 1.0f - 0.5f * len;
    float lob = 0.5f - 0.29f * len;
    float clp = 1.0f / lob;

    float aC = 0.0f, aW = 0.0f;
    maba_tap(&aC, &aW,  0.0f - ppx, -1.0f - ppy, dirx, diry, len2x, len2y, lob, clp, b);
    maba_tap(&aC, &aW,  1.0f - ppx, -1.0f - ppy, dirx, diry, len2x, len2y, lob, clp, c);
    maba_tap(&aC, &aW, -1.0f - ppx,  1.0f - ppy, dirx, diry, len2x, len2y, lob, clp, i);
    maba_tap(&aC, &aW,  0.0f - ppx,  1.0f - ppy, dirx, diry, len2x, len2y, lob, clp, j);
    maba_tap(&aC, &aW,  0.0f - ppx,  0.0f - ppy, dirx, diry, len2x, len2y, lob, clp, f);
    maba_tap(&aC, &aW, -1.0f - ppx,  0.0f - ppy, dirx, diry, len2x, len2y, lob, clp, e);
    maba_tap(&aC, &aW,  1.0f - ppx,  1.0f - ppy, dirx, diry, len2x, len2y, lob, clp, k);
    maba_tap(&aC, &aW,  2.0f - ppx,  1.0f - ppy, dirx, diry, len2x, len2y, lob, clp, l);
    maba_tap(&aC, &aW,  2.0f - ppx,  0.0f - ppy, dirx, diry, len2x, len2y, lob, clp, h);
    maba_tap(&aC, &aW,  1.0f - ppx,  0.0f - ppy, dirx, diry, len2x, len2y, lob, clp, g);
    maba_tap(&aC, &aW,  1.0f - ppx,  2.0f - ppy, dirx, diry, len2x, len2y, lob, clp, o);
    maba_tap(&aC, &aW,  0.0f - ppx,  2.0f - ppy, dirx, diry, len2x, len2y, lob, clp, n);

    float edgeG = clampf(aC / aW, mn, mx);
    float bilG = lerp(lerp(f, g, ppx), lerp(j, k, ppx), ppy);
    float t = clampf((bilG - DARK_LO) / (DARK_HI - DARK_LO), 0.0f, 1.0f);
    float gain = 1.0f + 0.5f * sharpness * (t * t * (3.0f - 2.0f * t));   /* MABA_QUALITY_GAIN 0.5 */
    float outG = clampf(bilG + (edgeG - bilG) * gain, mn, mx);
    float blend = clampf((contrast - EDGE_LO) * (1.0f / (EDGE_HI - EDGE_LO)), 0.0f, 1.0f);
    float delta = lerp(bd, outG - bilG, blend);

    RGB out;
    out.r = clampf(color.r + delta, 0.0f, 1.0f);
    out.g = clampf(color.g + delta, 0.0f, 1.0f);
    out.b = clampf(color.b + delta, 0.0f, 1.0f);
    return out;
}

static Image render(const Image* tex, int regionW, int regionH, int outW, int outH,
                    int quality, float sharpness)
{
    Image out = img_new(outW, outH);
    int x, y;
    for (y = 0; y < outH; y++)
        for (x = 0; x < outW; x++)
            out.px[(size_t)y * outW + x] =
                maba_pixel(tex, regionW, regionH, outW, outH, x, y, quality, sharpness);
    return out;
}

//----------------------------------------------------------------------------------------------
// Test patterns
//----------------------------------------------------------------------------------------------

static unsigned int rng = 777u;
static float frand(void) { rng = rng * 1664525u + 1013904223u; return (float)(rng >> 8) / 16777216.0f; }

/* kind: 0 diagonal step, 1 checker, 2 circle, 3 gradient, 4 noise, 5 flat, 6 thin lines */
static Image pattern(int kind, int w, int h)
{
    Image im = img_new(w, h);
    int x, y;
    for (y = 0; y < h; y++) {
        for (x = 0; x < w; x++) {
            RGB p = {0, 0, 0};
            float fx = (float)x / w, fy = (float)y / h;
            switch (kind) {
                case 0: { float v = (fx + fy > 1.0f) ? 0.9f : 0.1f; p.r = v; p.g = v; p.b = v; break; }
                case 1: { float v = ((x / 4 + y / 4) & 1) ? 0.85f : 0.15f; p.r = v; p.g = v; p.b = v; break; }
                case 2: { float dx = fx - 0.5f, dy = fy - 0.5f;
                          float v = (dx * dx + dy * dy < 0.09f) ? 0.95f : 0.05f;
                          p.r = v; p.g = v * 0.6f; p.b = v * 0.3f; break; }
                case 3: p.r = fx; p.g = fy; p.b = 0.5f; break;
                case 4: { float v = frand(); p.r = v; p.g = v; p.b = v; break; }
                case 5: p.r = 0.4f; p.g = 0.4f; p.b = 0.4f; break;
                case 6: { float v = ((x % 7 == 0) || (y % 9 == 0)) ? 0.9f : 0.08f;
                          p.r = v; p.g = v; p.b = v; break; }
            }
            im.px[(size_t)y * w + x] = p;
        }
    }
    return im;
}

static int write_ppm(const char* path, const Image* im)
{
    FILE* f = fopen(path, "wb");
    if (!f) return 0;
    fprintf(f, "P6\n%d %d\n255\n", im->w, im->h);
    size_t n = (size_t)im->w * im->h;
    unsigned char* row = (unsigned char*)malloc(n * 3);
    size_t i;
    if (!row) { fclose(f); return 0; }
    for (i = 0; i < n; i++) {
        row[i * 3 + 0] = (unsigned char)(clampf(im->px[i].r, 0, 1) * 255.0f + 0.5f);
        row[i * 3 + 1] = (unsigned char)(clampf(im->px[i].g, 0, 1) * 255.0f + 0.5f);
        row[i * 3 + 2] = (unsigned char)(clampf(im->px[i].b, 0, 1) * 255.0f + 0.5f);
    }
    fwrite(row, 1, n * 3, f);
    free(row);
    fclose(f);
    return 1;
}

//----------------------------------------------------------------------------------------------
// Property tests
//----------------------------------------------------------------------------------------------

static int g_failures = 0;
#define CHECK(cond) do { if (!(cond)) { printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); g_failures++; } } while (0)

static float luma(RGB p) { return p.g; }   /* shader uses green as luma */

/* For every output pixel, the shader's luma must stay inside the 2x2 block's luma range
 * (both paths clamp to it), and all channels must stay in [0,1]. */
static void check_range(const Image* tex, int rw, int rh, const Image* out, float eps)
{
    int x, y;
    for (y = 0; y < out->h; y++) {
        for (x = 0; x < out->w; x++) {
            float uvx = (x + 0.5f) / out->w, uvy = (y + 0.5f) / out->h;
            float posx = clampf(uvx * rw - 0.5f, 0.0f, rw - 1.001f);
            float posy = clampf(uvy * rh - 0.5f, 0.0f, rh - 1.001f);
            int fx = (int)floorf(posx), fy = (int)floorf(posy);
            float f = img_texel(tex, fx, fy).g, g = img_texel(tex, fx + 1, fy).g;
            float j = img_texel(tex, fx, fy + 1).g, k = img_texel(tex, fx + 1, fy + 1).g;
            float mn = minf(minf(f, g), minf(j, k)), mx = maxf(maxf(f, g), maxf(j, k));
            RGB p = out->px[(size_t)y * out->w + x];
            CHECK(luma(p) >= mn - eps && luma(p) <= mx + eps);
            CHECK(p.r >= 0 && p.r <= 1 && p.g >= 0 && p.g <= 1 && p.b >= 0 && p.b <= 1);
        }
    }
}

static void selftest(void)
{
    const int OUTW = 320, OUTH = 180;
    int kinds[] = {0, 1, 2, 3, 4, 5, 6};
    int ki, q;
    for (ki = 0; ki < 7; ki++) {
        Image tex = pattern(kinds[ki], 189, 106);   /* 0.59 of 320x180 */
        for (q = 0; q <= 1; q++) {
            Image out = render(&tex, 189, 106, OUTW, OUTH, q, 0.5f);
            check_range(&tex, 189, 106, &out, 1.0f / 255.0f);
            img_free(&out);
        }
        img_free(&tex);
    }
    printf("range/no-ring properties: %s\n", g_failures ? "FAILED" : "ok");

    /* Flat input must pass through unchanged (both paths, any sharpness). */
    {
        Image tex = pattern(5, 189, 106);
        for (q = 0; q <= 1; q++) {
            Image out = render(&tex, 189, 106, OUTW, OUTH, q, 1.0f);
            int x, y, bad = 0;
            for (y = 0; y < OUTH; y++) for (x = 0; x < OUTW; x++) {
                RGB p = out.px[(size_t)y * OUTW + x];
                if (fabsf(p.r - 0.4f) > 1e-4f || fabsf(p.g - 0.4f) > 1e-4f || fabsf(p.b - 0.4f) > 1e-4f) bad++;
            }
            CHECK(bad == 0);
            img_free(&out);
        }
        img_free(&tex);
        printf("flat passthrough: %s\n", g_failures ? "FAILED" : "ok");
    }

    /* Determinism: two renders of the same input are bit-identical. */
    {
        Image tex = pattern(4, 189, 106);
        Image a = render(&tex, 189, 106, OUTW, OUTH, 1, 0.5f);
        Image b = render(&tex, 189, 106, OUTW, OUTH, 1, 0.5f);
        CHECK(memcmp(a.px, b.px, (size_t)OUTW * OUTH * sizeof(RGB)) == 0);
        img_free(&a); img_free(&b); img_free(&tex);
        printf("determinism: %s\n", g_failures ? "FAILED" : "ok");
    }

    /* Edge direction: on a diagonal step, the fast path must produce fewer intermediate luma
     * values than bilinear (it follows the edge instead of blurring across it). */
    {
        Image tex = pattern(0, 189, 106);
        Image out = render(&tex, 189, 106, OUTW, OUTH, 0, 0.5f);
        int mid = 0, x, y;
        for (y = 0; y < OUTH; y++) for (x = 0; x < OUTW; x++) {
            float v = out.px[(size_t)y * OUTW + x].g;
            if (v > 0.2f && v < 0.8f) mid++;
        }
        Image bil = img_new(OUTW, OUTH);
        for (y = 0; y < OUTH; y++) for (x = 0; x < OUTW; x++) {
            float bu = minf((x + 0.5f) / OUTW * 189, 188.5f);
            float bv = minf((y + 0.5f) / OUTH * 106, 105.5f);
            bil.px[(size_t)y * OUTW + x] = img_bilinear(&tex, bu, bv);
        }
        int midB = 0;
        for (y = 0; y < OUTH; y++) for (x = 0; x < OUTW; x++) {
            float v = bil.px[(size_t)y * OUTW + x].g;
            if (v > 0.2f && v < 0.8f) midB++;
        }
        CHECK(mid < midB);
        printf("edge-directed vs bilinear: %d vs %d intermediate pixels - %s\n",
               mid, midB, mid < midB ? "ok" : "FAILED");
        img_free(&out); img_free(&bil); img_free(&tex);
    }

    /* Region edge safety: region smaller than texture, all scales, no out-of-region reads.
     * Verified implicitly by check_range above; here render an extreme upscale (4x). */
    {
        Image tex = pattern(6, 40, 24);
        Image out = render(&tex, 40, 24, 160, 96, 1, 0.5f);
        check_range(&tex, 40, 24, &out, 1.0f / 255.0f);
        img_free(&out); img_free(&tex);
        printf("4x extreme upscale: %s\n", g_failures ? "FAILED" : "ok");
    }
}

static void golden(const char* dir)
{
    const int OUTW = 320, OUTH = 180;
    const char* names[] = {"diag", "checker", "circle", "gradient", "noise", "flat", "lines"};
    int ki, q;
    char path[512];
    for (ki = 0; ki < 7; ki++) {
        Image tex = pattern(ki, 189, 106);
        for (q = 0; q <= 1; q++) {
            Image out = render(&tex, 189, 106, OUTW, OUTH, q, 0.5f);
            snprintf(path, sizeof(path), "%s/%s_%s.ppm", dir, names[ki], q ? "quality" : "fast");
            if (!write_ppm(path, &out)) { printf("cannot write %s\n", path); exit(1); }
            img_free(&out);
        }
        img_free(&tex);
    }
    printf("golden images written to %s\n", dir);
}

int main(int argc, char** argv)
{
    if (argc >= 3 && strcmp(argv[1], "golden") == 0) { golden(argv[2]); return 0; }
    if (argc >= 6 && strcmp(argv[1], "render") == 0) {
        int kind = atoi(argv[2]);
        int quality = strcmp(argv[3], "quality") == 0;
        float scale = (float)atof(argv[4]);
        int outW = argc >= 8 ? atoi(argv[6]) : 320;
        int outH = argc >= 8 ? atoi(argv[7]) : 180;
        int rw = (int)(outW * scale + 0.5f), rh = (int)(outH * scale + 0.5f);
        Image tex = pattern(kind, rw, rh);
        Image out = render(&tex, rw, rh, outW, outH, quality, 0.5f);
        if (!write_ppm(argv[5], &out)) { printf("cannot write %s\n", argv[5]); return 1; }
        img_free(&out); img_free(&tex);
        return 0;
    }
    selftest();
    if (g_failures == 0) printf("ALL REFERENCE TESTS PASSED\n");
    else printf("%d FAILURES\n", g_failures);
    return g_failures == 0 ? 0 : 1;
}