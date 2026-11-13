/* MABA-Upscaler 2 (Temporal) - host tests for the resolve math and maba_temporal.h
 *
 * Mirrors src/maba_temporal.frag.glsl in plain C and property-tests it:
 *   reset / sky / off-screen / disocclusion -> current frame passthrough
 *   ghosting bound: history can never pull the result outside the current neighborhood box
 *   static scene: repeated identical frames converge to the current frame
 *   Halton jitter: range, phase cycle, determinism
 *
 * Build:  gcc -std=c99 -O2 -Wall -Wextra -o test_temporal test_temporal.c -lm
 * Run:    test_temporal
 *
 * Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "../../src/maba_temporal.h"

static int g_failures = 0;
#define CHECK(cond) do { if (!(cond)) { printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); g_failures++; } } while (0)

#define W 32
#define H 24

typedef struct { float r, g, b; } RGB;
typedef struct { float m[16]; } Mat4;   /* column-major, GL style */

static float clampf(float x, float lo, float hi) { return x < lo ? lo : (x > hi ? hi : x); }

static RGB cur[H * W], hist[H * W];
static float depth[H * W], prevDepth[H * W];
static float params[4] = {0.9f, 0.01f, 0.0f, 1.25f};
static Mat4 invVP, prevVP;

/* Orthographic camera: world (x,y) in [0,1] maps to NDC [-1,1]; z in [0,1] maps to GL NDC. */
static Mat4 ortho(float shiftX, float shiftY)
{
    Mat4 m; memset(&m, 0, sizeof(m));
    m.m[0] = 2.0f; m.m[5] = 2.0f; m.m[10] = 2.0f; m.m[15] = 1.0f;
    m.m[12] = -1.0f + shiftX; m.m[13] = -1.0f + shiftY; m.m[14] = -1.0f;
    return m;
}

static Mat4 invert_ortho(const Mat4* m)
{
    Mat4 r; memset(&r, 0, sizeof(r));
    r.m[0] = 1.0f / m->m[0]; r.m[5] = 1.0f / m->m[5]; r.m[10] = 1.0f / m->m[10]; r.m[15] = 1.0f;
    r.m[12] = -m->m[12] / m->m[0]; r.m[13] = -m->m[13] / m->m[5]; r.m[14] = -m->m[14] / m->m[10];
    return r;
}

static void mul(const Mat4* m, float x, float y, float z, float w, float out[4])
{
    int i;
    for (i = 0; i < 4; i++)
        out[i] = m->m[i] * x + m->m[4 + i] * y + m->m[8 + i] * z + m->m[12 + i] * w;
}

static RGB toYCoCg(RGB c)
{
    RGB o;
    o.r = 0.25f * c.r + 0.5f * c.g + 0.25f * c.b;
    o.g = 0.5f * c.r - 0.5f * c.b;
    o.b = -0.25f * c.r + 0.5f * c.g - 0.25f * c.b;
    return o;
}

static RGB fromYCoCg(RGB c)
{
    RGB o;
    o.r = c.r + c.g - c.b;
    o.g = c.r + c.b;
    o.b = c.r - c.g - c.b;
    return o;
}

static RGB sample_clamped(const RGB* img, float u, float v)
{
    int x = (int)clampf(u * W - 0.5f, 0.0f, W - 1.0f);
    int y = (int)clampf(v * H - 0.5f, 0.0f, H - 1.0f);
    return img[y * W + x];
}

static float sample_depth_clamped(const float* d, float u, float v)
{
    int x = (int)clampf(u * W - 0.5f, 0.0f, W - 1.0f);
    int y = (int)clampf(v * H - 0.5f, 0.0f, H - 1.0f);
    return d[y * W + x];
}

/* The resolve pass, line-for-line from the shader (GL depth convention). */
static RGB resolve(int x, int y)
{
    RGB c = cur[y * W + x];
    float d = depth[y * W + x];
    if (params[2] > 0.5f || d >= 1.0f || d <= 0.0f) return c;

    float ndcX = (x + 0.5f) / W * 2.0f - 1.0f;
    float ndcY = (y + 0.5f) / H * 2.0f - 1.0f;
    float wp[4], pc[4];
    mul(&invVP, ndcX, ndcY, d * 2.0f - 1.0f, 1.0f, wp);
    wp[0] /= wp[3]; wp[1] /= wp[3]; wp[2] /= wp[3];
    mul(&prevVP, wp[0], wp[1], wp[2], 1.0f, pc);
    if (pc[3] <= 0.0f) return c;
    float pu = pc[0] / pc[3] * 0.5f + 0.5f;
    float pv = pc[1] / pc[3] * 0.5f + 0.5f;
    if (pu < 0.0f || pu > 1.0f || pv < 0.0f || pv > 1.0f) return c;

    float expected = pc[2] / pc[3] * 0.5f + 0.5f;
    float pd = sample_depth_clamped(prevDepth, pu, pv);
    float tol = params[1] * (0.1f + expected);
    if (fabsf(expected - pd) > tol) return c;

    RGB m1 = {0, 0, 0}, m2 = {0, 0, 0}, mn = {1e9f, 1e9f, 1e9f}, mx = {-1e9f, -1e9f, -1e9f};
    int dx, dy;
    for (dy = -1; dy <= 1; dy++) {
        for (dx = -1; dx <= 1; dx++) {
            int px = (int)clampf((float)(x + dx), 0.0f, W - 1.0f);
            int py = (int)clampf((float)(y + dy), 0.0f, H - 1.0f);
            RGB cc = toYCoCg(cur[py * W + px]);
            m1.r += cc.r; m1.g += cc.g; m1.b += cc.b;
            m2.r += cc.r * cc.r; m2.g += cc.g * cc.g; m2.b += cc.b * cc.b;
            mn.r = fminf(mn.r, cc.r); mn.g = fminf(mn.g, cc.g); mn.b = fminf(mn.b, cc.b);
            mx.r = fmaxf(mx.r, cc.r); mx.g = fmaxf(mx.g, cc.g); mx.b = fmaxf(mx.b, cc.b);
        }
    }
    RGB mean = {m1.r / 9, m1.g / 9, m1.b / 9};
    RGB sigma = {
        sqrtf(fmaxf(m2.r / 9 - mean.r * mean.r, 0.0f)),
        sqrtf(fmaxf(m2.g / 9 - mean.g * mean.g, 0.0f)),
        sqrtf(fmaxf(m2.b / 9 - mean.b * mean.b, 0.0f))};
    float g = params[3];
    RGB lo = {fmaxf(mean.r - g * sigma.r, mn.r), fmaxf(mean.g - g * sigma.g, mn.g),
              fmaxf(mean.b - g * sigma.b, mn.b)};
    RGB hi = {fminf(mean.r + g * sigma.r, mx.r), fminf(mean.g + g * sigma.g, mx.g),
              fminf(mean.b + g * sigma.b, mx.b)};

    RGB h = toYCoCg(sample_clamped(hist, pu, pv));
    h.r = clampf(h.r, lo.r, hi.r);
    h.g = clampf(h.g, lo.g, hi.g);
    h.b = clampf(h.b, lo.b, hi.b);

    float dispX = (pu - (x + 0.5f) / W) * W;
    float dispY = (pv - (y + 0.5f) / H) * H;
    float disp = sqrtf(dispX * dispX + dispY * dispY);
    float w = params[0] / (1.0f + 0.05f * disp);

    RGB cy = toYCoCg(c);
    RGB mixv = {cy.r + (h.r - cy.r) * w, cy.g + (h.g - cy.g) * w, cy.b + (h.b - cy.b) * w};
    RGB o = fromYCoCg(mixv);
    o.r = clampf(o.r, 0, 1); o.g = clampf(o.g, 0, 1); o.b = clampf(o.b, 0, 1);
    return o;
}

static void fill_flat(RGB* img, float v)
{
    int i; for (i = 0; i < W * H; i++) { img[i].r = v; img[i].g = v; img[i].b = v; }
}

static void setup_camera(float motionTexelsX)
{
    /* prevVP shifts the image by motionTexelsX texels: shift in NDC = 2*motion/W. */
    Mat4 curVP = ortho(0.0f, 0.0f);
    prevVP = ortho(-2.0f * motionTexelsX / W, 0.0f);
    invVP = invert_ortho(&curVP);
}

static void test_passthroughs(void)
{
    int x, y, bad;
    setup_camera(0.0f);
    fill_flat(cur, 0.5f); fill_flat(hist, 0.9f);
    for (y = 0; y < H; y++) for (x = 0; x < W; x++) { depth[y * W + x] = 0.5f; prevDepth[y * W + x] = 0.5f; }

    /* reset */
    params[2] = 1.0f;
    bad = 0;
    for (y = 0; y < H; y++) for (x = 0; x < W; x++) { RGB o = resolve(x, y); if (o.r != 0.5f) bad++; }
    CHECK(bad == 0);
    params[2] = 0.0f;

    /* sky */
    depth[5 * W + 5] = 1.0f;
    CHECK(resolve(5, 5).r == 0.5f);
    depth[5 * W + 5] = 0.5f;

    /* disocclusion: previous depth disagrees */
    prevDepth[10 * W + 10] = 0.9f;
    CHECK(resolve(10, 10).r == 0.5f);
    prevDepth[10 * W + 10] = 0.5f;

    /* off-screen reprojection: huge camera motion */
    setup_camera(1000.0f);
    bad = 0;
    for (y = 0; y < H; y++) for (x = 0; x < W; x++) { RGB o = resolve(x, y); if (o.r != 0.5f) bad++; }
    CHECK(bad == 0);
    setup_camera(0.0f);
    printf("passthroughs (reset/sky/disocclusion/off-screen): %s\n", g_failures ? "FAILED" : "ok");
}

static void test_ghost_bound(void)
{
    /* Current frame all black, history all white: the clamp must keep the result near black. */
    int x, y;
    setup_camera(0.0f);
    fill_flat(cur, 0.0f); fill_flat(hist, 1.0f);
    for (y = 0; y < H; y++) for (x = 0; x < W; x++) { depth[y * W + x] = 0.5f; prevDepth[y * W + x] = 0.5f; }
    float worst = 0.0f;
    for (y = 0; y < H; y++) for (x = 0; x < W; x++) {
        RGB o = resolve(x, y);
        worst = fmaxf(worst, fmaxf(o.r, fmaxf(o.g, o.b)));
    }
    CHECK(worst < 0.02f);
    printf("ghost bound (white history over black frame): worst channel %.4f - %s\n",
           worst, worst < 0.02f ? "ok" : "FAILED");
}

static void test_convergence(void)
{
    /* Static camera, smooth content (every pixel inside its neighborhood box): the resolve
     * must converge to the current frame. Pure per-pixel noise is intentionally NOT expected
     * to converge to cur: variance clipping pulls outlier samples toward the neighborhood,
     * which is the anti-ghosting guarantee (checked separately below). */
    int x, y, iter;
    setup_camera(0.0f);
    for (y = 0; y < H; y++) for (x = 0; x < W; x++) {
        float v = 0.2f + 0.6f * (float)x / W;   /* smooth horizontal gradient */
        cur[y * W + x].r = v; cur[y * W + x].g = v; cur[y * W + x].b = v;
        depth[y * W + x] = 0.5f; prevDepth[y * W + x] = 0.5f;
    }
    fill_flat(hist, 0.9f);   /* wrong history to start */
    for (iter = 0; iter < 60; iter++) {
        RGB next[H * W];
        for (y = 0; y < H; y++) for (x = 0; x < W; x++) next[y * W + x] = resolve(x, y);
        memcpy(hist, next, sizeof(hist));
    }
    float worst = 0.0f;
    for (y = 0; y < H; y++) for (x = 0; x < W; x++) {
        RGB o = resolve(x, y);
        worst = fmaxf(worst, fabsf(o.r - cur[y * W + x].r));
    }
    CHECK(worst < 0.02f);
    printf("static convergence after 60 frames: worst diff %.4f - %s\n",
           worst, worst < 0.02f ? "ok" : "FAILED");

    /* Noisy content: the guarantee is that the result stays inside the neighborhood box,
     * never that it equals an outlier current sample. */
    unsigned int s = 42u;
    for (y = 0; y < H; y++) for (x = 0; x < W; x++) {
        s = s * 1664525u + 1013904223u;
        float v = 0.3f + 0.4f * ((s >> 8) & 0xFFFF) / 65536.0f;
        cur[y * W + x].r = v; cur[y * W + x].g = v; cur[y * W + x].b = v;
    }
    fill_flat(hist, 0.9f);
    int bad = 0;
    for (y = 1; y < H - 1; y++) for (x = 1; x < W - 1; x++) {
        float mn = 1e9f, mx = -1e9f;
        int dx, dy;
        for (dy = -1; dy <= 1; dy++) for (dx = -1; dx <= 1; dx++) {
            float v = cur[(y + dy) * W + (x + dx)].r;
            mn = fminf(mn, v); mx = fmaxf(mx, v);
        }
        RGB o = resolve(x, y);
        if (o.r < mn - 1e-4f || o.r > mx + 1e-4f) bad++;
    }
    CHECK(bad == 0);
    printf("noisy content stays in neighborhood AABB: %s\n", bad ? "FAILED" : "ok");
}

static void test_motion_falloff(void)
{
    /* More motion must trust history less (result closer to current). Textured current frame
     * so the clamp box has nonzero width. */
    int x, y;
    for (y = 0; y < H; y++) for (x = 0; x < W; x++) {
        float v = ((x / 2 + y / 2) & 1) ? 0.3f : 0.1f;
        cur[y * W + x].r = v; cur[y * W + x].g = v; cur[y * W + x].b = v;
        depth[y * W + x] = 0.5f; prevDepth[y * W + x] = 0.5f;
    }
    fill_flat(hist, 0.8f);
    setup_camera(0.0f);
    float still = resolve(16, 12).r;
    setup_camera(20.0f);
    float moving = resolve(16, 12).r;
    CHECK(moving < still);
    printf("motion falloff: still %.3f vs moving %.3f - %s\n", still, moving,
           moving < still ? "ok" : "FAILED");
}

static void test_ycocg_roundtrip(void)
{
    int i, bad = 0;
    unsigned int s = 7u;
    for (i = 0; i < 1000; i++) {
        s = s * 1664525u + 1013904223u;
        RGB c = {(float)((s >> 8) & 0xFF) / 255, (float)((s >> 16) & 0xFF) / 255,
                 (float)((s >> 24) & 0xFF) / 255};
        RGB r = fromYCoCg(toYCoCg(c));
        if (fabsf(r.r - c.r) > 1e-5f || fabsf(r.g - c.g) > 1e-5f || fabsf(r.b - c.b) > 1e-5f) bad++;
    }
    CHECK(bad == 0);
    printf("YCoCg roundtrip: %s\n", bad ? "FAILED" : "ok");
}

static void test_jitter_header(void)
{
    MabaTemporal t;
    MabaTemporalInit(&t, 0.0f, 0.0f, 0.0f);   /* invalid -> defaults */
    CHECK(t.historyWeight == 0.9f && t.depthTolerance == 0.01f && t.clipGamma == 1.25f);

    MabaTemporalFrame f0 = MabaTemporalBeginFrame(&t);
    CHECK(f0.reset == 1);                      /* first frame resets */
    MabaTemporalFrame f1 = MabaTemporalBeginFrame(&t);
    CHECK(f1.reset == 0);

    int i;
    for (i = 0; i < 200; i++) {
        MabaTemporalFrame f = MabaTemporalBeginFrame(&t);
        CHECK(f.jitterX >= -0.5f && f.jitterX <= 0.5f);
        CHECK(f.jitterY >= -0.5f && f.jitterY <= 0.5f);
        CHECK(f.phase >= 0 && f.phase < MABA_TEMPORAL_PHASES);
    }
    /* phase cycle repeats exactly */
    MabaTemporalReset(&t);
    MabaTemporalFrame a = MabaTemporalBeginFrame(&t);
    for (i = 0; i < MABA_TEMPORAL_PHASES - 1; i++) MabaTemporalBeginFrame(&t);
    MabaTemporalFrame b = MabaTemporalBeginFrame(&t);
    CHECK(a.jitterX == b.jitterX && a.jitterY == b.jitterY);

    float p[4];
    MabaTemporalUniforms(&t, &b, p);
    CHECK(p[0] == 0.9f && p[1] == 0.01f && p[3] == 1.25f);

    /* Halton values are in [0,1) and distinct within a cycle */
    float seen[MABA_TEMPORAL_PHASES];
    for (i = 0; i < MABA_TEMPORAL_PHASES; i++) {
        seen[i] = MabaHalton(i + 1, 2);
        CHECK(seen[i] >= 0.0f && seen[i] < 1.0f);
        int j;
        for (j = 0; j < i; j++) CHECK(seen[i] != seen[j]);
    }
    printf("jitter header (reset, cycle, range, Halton): %s\n", g_failures ? "FAILED" : "ok");
}

int main(void)
{
    test_passthroughs();
    test_ghost_bound();
    test_convergence();
    test_motion_falloff();
    test_ycocg_roundtrip();
    test_jitter_header();
    if (g_failures == 0) printf("ALL TEMPORAL TESTS PASSED\n");
    else printf("%d FAILURES\n", g_failures);
    return g_failures == 0 ? 0 : 1;
}