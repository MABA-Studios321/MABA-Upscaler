/* MABA Frame Gen - host tests for maba_framegen.h and the warp maths of maba_framegen.frag.glsl
 *
 * Part 1 tests the slot policy and the honest one-second counters.
 * Part 2 mirrors the shader in plain C (same constants, same order of operations)
 * and checks them on synthetic scenes:
 *   static scene            -> generated frame equals the real frame
 *   camera pan              -> generated frame equals the real frame shifted by half the motion
 *   object over background  -> object advances by half its motion, nearest surface wins at the
 *                              leading edge, no copy of the object is left behind, uncovered
 *                              background is background
 *
 * Build:  gcc -std=c99 -O2 -Wall -Wextra -o test_framegen test_framegen.c -lm
 * Run:    test_framegen
 *
 * Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "../../src/maba_framegen.h"

static int g_failures = 0;
#define CHECK(cond) do { if (!(cond)) { printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); g_failures++; } } while (0)

/*----------------------------------------------------------------------------------------------
  Part 1: header
----------------------------------------------------------------------------------------------*/

static void test_slots(void)
{
    MabaFrameGen g;
    MabaFgInit(&g);
    CHECK(MabaFgNextSlot(&g) == MABA_FG_REAL);

    /* disabled: always real, even after real frames */
    MabaFgPresented(&g, MABA_FG_REAL, 0.0);
    CHECK(MabaFgNextSlot(&g) == MABA_FG_REAL);

    MabaFgSetEnabled(&g, 1);
    CHECK(MabaFgNextSlot(&g) == MABA_FG_REAL);          /* nothing to extrapolate from yet */
    MabaFgPresented(&g, MABA_FG_REAL, 0.0);
    CHECK(MabaFgNextSlot(&g) == MABA_FG_GENERATED);
    MabaFgPresented(&g, MABA_FG_GENERATED, 16.7);
    CHECK(MabaFgNextSlot(&g) == MABA_FG_REAL);
    MabaFgPresented(&g, MABA_FG_REAL, 33.3);
    CHECK(MabaFgNextSlot(&g) == MABA_FG_GENERATED);

    MabaFgInvalidate(&g);                                /* camera cut */
    CHECK(MabaFgNextSlot(&g) == MABA_FG_REAL);
    MabaFgPresented(&g, MABA_FG_REAL, 50.0);
    CHECK(MabaFgNextSlot(&g) == MABA_FG_GENERATED);

    MabaFgSetEnabled(&g, 0);
    MabaFgPresented(&g, MABA_FG_REAL, 66.7);
    CHECK(MabaFgNextSlot(&g) == MABA_FG_REAL);
    printf("slot policy (alternate, cut, disable): %s\n", g_failures ? "FAILED" : "ok");
}

/* Simulate a 60 Hz panel for `frames` frames; returns how many windows completed. */
static int run_panel(MabaFrameGen* g, int frames, double* t, double dt)
{
    int i, rolled = 0;
    for (i = 0; i < frames; i++)
    {
        MabaFgSlot s = MabaFgNextSlot(g);
        rolled += MabaFgPresented(g, s, *t);
        *t += dt;
    }
    return rolled;
}

static void test_counters(void)
{
    MabaFrameGen g;
    double t = 1000.0;
    const double dt = 1000.0 / 60.0;
    int rolled;

    /* generation on: 60 presented frames per second = 30 real + 30 generated */
    MabaFgInit(&g);
    MabaFgSetEnabled(&g, 1);
    rolled = run_panel(&g, 59, &t, dt);
    CHECK(rolled == 0 && !g.statsValid);                 /* nothing published before 1 s */
    rolled = run_panel(&g, 61, &t, dt);                  /* well past the first window */
    CHECK(rolled >= 1 && g.statsValid);
    CHECK(fabsf(g.realFps - 30.0f) < 1.0f);
    CHECK(fabsf(g.generatedFps - 30.0f) < 1.0f);
    CHECK(fabsf(g.displayedFps - 60.0f) < 1.0f);
    CHECK(fabsf(g.displayedFps - (g.realFps + g.generatedFps)) < 1e-3f);

    /* generation off: every frame is real */
    MabaFgSetEnabled(&g, 0);
    CHECK(!g.statsValid && g.displayedFps == 0.0f);      /* reset on toggle */
    run_panel(&g, 130, &t, dt);
    CHECK(g.statsValid);
    CHECK(fabsf(g.realFps - 60.0f) < 1.0f);
    CHECK(g.generatedFps == 0.0f);
    CHECK(fabsf(g.displayedFps - g.realFps) < 1e-3f);

    /* a slow device: only 40 presented frames per second -> 20 real + 20 generated, shown as 40 */
    MabaFgSetEnabled(&g, 1);
    run_panel(&g, 90, &t, 1000.0 / 40.0);
    CHECK(g.statsValid && fabsf(g.displayedFps - 40.0f) < 1.5f);
    CHECK(fabsf(g.realFps - 20.0f) < 1.5f && fabsf(g.generatedFps - 20.0f) < 1.5f);

    /* the published numbers only change when a window completes */
    {
        float before = g.displayedFps;
        MabaFgPresented(&g, MabaFgNextSlot(&g), t);      /* one more frame, window not over */
        CHECK(g.displayedFps == before);
    }
    printf("honest counters (1 s windows, on/off, slow device): %s\n", g_failures ? "FAILED" : "ok");
}

/*----------------------------------------------------------------------------------------------
  Part 2: CPU port of maba_framegen.frag.glsl

  The grid is 64 x 48 texels times GRID_SCALE. GRID_SCALE 1 stands for the reference render height
  the shader's texel constants were tuned for (MABA_FG_REF_HEIGHT); GRID_SCALE n models a render n
  times taller showing the SAME scene. T() turns reference texels into texels of this grid, so
  every size, distance and speed grows by n while velocities (UV units) stay the same. The shader
  scales its texel constants by k = n, so the generated frame must not depend on n.

  Build for another resolution:  gcc -DGRID_SCALE=3 ... ;  other masks:  test_framegen <mask>
----------------------------------------------------------------------------------------------*/
#ifndef GRID_SCALE
#define GRID_SCALE 1
#endif
#ifndef MABA_FG_SCALE_MASK
#define MABA_FG_SCALE_MASK 1      /* same default as the shader: bit 0 probe radius, bit 1 threshold, bit 2 validity */
#endif
#define W (64 * GRID_SCALE)
#define H (48 * GRID_SCALE)
#define T(n) ((n) * GRID_SCALE)

typedef struct { float x, y; } V2;

static float g_color[H][W];       /* newest real frame, luma */
static V2    g_vel[H][W];
static float g_depth[H][W];       /* window depth */
static float g_pcolor[H][W];      /* previous real frame */
static float g_pdepth[H][W];

static float clampf(float x, float lo, float hi) { return x < lo ? lo : (x > hi ? hi : x); }
static int clampi(int x, int lo, int hi) { return x < lo ? lo : (x > hi ? hi : x); }

static float linearize(float d)
{
    const float n = 0.1f, f = 40.0f;
    return 2.0f * n * f / ((f + n) - (2.0f * d - 1.0f) * (f - n));
}

static int texel_x(float u) { return clampi((int)(u * W), 0, W - 1); }
static int texel_y(float v) { return clampi((int)(v * H), 0, H - 1); }
static V2 fetch_vel(float u, float v) { return g_vel[texel_y(v)][texel_x(u)]; }
static float fetch_lin(float u, float v) { return linearize(g_depth[texel_y(v)][texel_x(u)]); }

/* CLAMP_TO_EDGE bilinear at a region UV, kept half a texel inside the region (W x H region). */
static float sample_color(const float img[H][W], float u, float v)
{
    float tx = clampf(u * W, 0.5f, W - 0.5f) - 0.5f;
    float ty = clampf(v * H, 0.5f, H - 0.5f) - 0.5f;
    int x0 = (int)floorf(tx), y0 = (int)floorf(ty);
    float fx = tx - (float)x0, fy = ty - (float)y0;
    int x1 = clampi(x0 + 1, 0, W - 1), y1 = clampi(y0 + 1, 0, H - 1);
    x0 = clampi(x0, 0, W - 1); y0 = clampi(y0, 0, H - 1);
    return (img[y0][x0] * (1 - fx) + img[y0][x1] * fx) * (1 - fy)
         + (img[y1][x0] * (1 - fx) + img[y1][x1] * fx) * fy;
}

static float mag2(float x, float y) { return x * x + y * y; }

static int g_taps = 8;                    /* probe taps read (MABA_FG_PROBE_TAPS in the shader) */
static int g_mask = MABA_FG_SCALE_MASK;   /* which texel constants grow with the render height */

static float warp_pixel(int px, int py, float h)
{
    static const float TAPS[5] = {0.0f, 0.5f, 1.0f, 1.5f, 2.0f};
    float u = ((float)px + 0.5f) / W, v = ((float)py + 0.5f) / H;
    /* The 8-tap neighbourhood probe (mirrors the shader). */
    static const float OFFS[8][2] = {{6, 0}, {-6, 0}, {0, 6}, {0, -6}, {10, 10}, {-10, 10}, {10, -10}, {-10, -10}};
    const float k = (float)GRID_SCALE;                     /* the shader: max(height / REF_HEIGHT, 1) */
    const float kProbe = (g_mask & 1) ? k : 1.0f;
    const float kThr = (g_mask & 2) ? k : 1.0f;
    const float kValid = (g_mask & 4) ? k : 1.0f;
    V2 v0 = fetch_vel(u, v);
    float vmx = v0.x, vmy = v0.y, vnx = v0.x, vny = v0.y;
    float mmax = mag2(v0.x, v0.y), mmin = mmax;
    float spread;
    int i;
    for (i = 0; i < g_taps; i++)
    {
        V2 q = fetch_vel(clampf(u + OFFS[i][0] * kProbe / W, 0.0f, 1.0f),
                         clampf(v + OFFS[i][1] * kProbe / H, 0.0f, 1.0f));
        float m = mag2(q.x, q.y);
        if (m > mmax) { mmax = m; vmx = q.x; vmy = q.y; }
        if (m < mmin) { mmin = m; vnx = q.x; vny = q.y; }
    }
    {
        float sx = (vmx - vnx) * W, sy = (vmy - vny) * H;
        spread = sqrtf(sx * sx + sy * sy) * h;
    }

    if (spread < 1.25f * kThr)
    {
        float su = clampf(u - h * v0.x, 0.0f, 1.0f), sv = clampf(v - h * v0.y, 0.0f, 1.0f);
        V2 b = fetch_vel(su, sv);
        su = clampf(u - h * b.x, 0.0f, 1.0f); sv = clampf(v - h * b.y, 0.0f, 1.0f);
        return sample_color(g_color, su, sv);
    }
    else
    {
        float bestD = 1e30f;
        float bestU = u, bestVv = v;
        int found = 0;
        for (i = 0; i < 5; i++)
        {
            float pu = clampf(u - TAPS[i] * h * vmx, 0.0f, 1.0f);
            float pv = clampf(v - TAPS[i] * h * vmy, 0.0f, 1.0f);
            V2 vel = (i == 0) ? v0 : fetch_vel(pu, pv);
            float su = clampf(u - h * vel.x, 0.0f, 1.0f), sv = clampf(v - h * vel.y, 0.0f, 1.0f);
            V2 vs = fetch_vel(su, sv);
            float dx = (vs.x - vel.x) * W, dy = (vs.y - vel.y) * H;
            if (sqrtf(dx * dx + dy * dy) * h < 1.0f * kValid)
            {
                float ds = fetch_lin(su, sv);
                if (ds < bestD) { bestD = ds; bestU = su; bestVv = sv; found = 1; }
            }
        }
        if (found)
        {
            return sample_color(g_color, bestU, bestVv);
        }
        else
        {
            float bgD = -1.0f, bgU = u, bgV = v;
            V2 vb;
            float spu, spv;
            int inside, same = 0;
            for (i = 0; i < 5; i++)
            {
                float pu = clampf(u - TAPS[i] * h * vmx, 0.0f, 1.0f);
                float pv = clampf(v - TAPS[i] * h * vmy, 0.0f, 1.0f);
                float d = fetch_lin(pu, pv);
                if (d > bgD) { bgD = d; bgU = pu; bgV = pv; }
            }
            vb = fetch_vel(bgU, bgV);
            spu = u - (1.0f + h) * vb.x; spv = v - (1.0f + h) * vb.y;
            inside = spu >= 0.0f && spu <= 1.0f && spv >= 0.0f && spv <= 1.0f;
            if (inside)
            {
                float pd = linearize(g_pdepth[clampi((int)(spv * H), 0, H - 1)][clampi((int)(spu * W), 0, W - 1)]);
                same = fabsf(pd - bgD) < 0.1f * bgD;
            }
            return same ? sample_color(g_pcolor, spu, spv) : sample_color(g_color, bgU, bgV);
        }
    }
}

static void warp_all(float h, float out[H][W])
{
    int x, y;
    for (y = 0; y < H; y++)
        for (x = 0; x < W; x++)
            out[y][x] = warp_pixel(x, y, h);
}

static float bg_value(int x, int y) { return 0.1f + 0.3f * ((float)x + 0.5f) / W + 0.1f * ((float)y + 0.5f) / H; }

static void clear_scene(void)
{
    int x, y;
    memset(g_vel, 0, sizeof(g_vel));
    for (y = 0; y < H; y++)
        for (x = 0; x < W; x++)
        {
            g_color[y][x] = g_pcolor[y][x] = bg_value(x, y);
            g_depth[y][x] = g_pdepth[y][x] = 0.99f;
        }
}

static void test_static(void)
{
    static float out[H][W];
    int x, y, bad = 0;
    clear_scene();
    warp_all(MABA_FG_GEN_OFFSET, out);
    for (y = 0; y < H; y++)
        for (x = 0; x < W; x++)
            if (fabsf(out[y][x] - g_color[y][x]) > 1e-5f) bad++;
    CHECK(bad == 0);
    printf("static scene: generated frame equals real frame (%d bad pixels): %s\n", bad, bad ? "FAILED" : "ok");
}

static void test_pan(void)
{
    static float out[H][W];
    int x, y, bad = 0;
    float worst = 0.0f;
    clear_scene();
    for (y = 0; y < H; y++)
        for (x = 0; x < W; x++)
        {
            g_vel[y][x].x = 4.0f / 64.0f;    /* the whole view moved 4 reference texels right */
            g_vel[y][x].y = 0.0f;
        }
    warp_all(MABA_FG_GEN_OFFSET, out);
    for (y = 0; y < H; y++)
        for (x = T(4); x < W; x++)           /* columns whose source is inside the image */
        {
            /* generated frame = real frame content shifted right by h * motion = 2 reference texels */
            float want = bg_value(x - T(2), y);
            float e = fabsf(out[y][x] - want);
            if (e > worst) worst = e;
            if (e > 1e-3f) bad++;
        }
    CHECK(bad == 0);
    printf("camera pan: generated = real shifted by half the motion (worst error %.5f): %s\n",
           worst, bad ? "FAILED" : "ok");
}

/* An object moving horizontally over the background. Returns the number of wrong pixels. */
static int scene_moving_object(int verbose)
{
    static float out[H][W];
    int x, y, ghost = 0, lead_bad = 0, hole_bad = 0, bg_bad = 0;
    clear_scene();
    for (y = T(16); y < T(32); y++)
        for (x = T(12); x < T(24); x++) { g_pcolor[y][x] = 0.9f; g_pdepth[y][x] = 0.9f; }     /* previous */
    for (y = T(16); y < T(32); y++)
        for (x = T(20); x < T(32); x++)
        {
            g_color[y][x] = 0.9f;
            g_depth[y][x] = 0.9f;
            g_vel[y][x].x = 8.0f / 64.0f;                                                    /* 8 reference texels per interval */
        }
    warp_all(MABA_FG_GEN_OFFSET, out);

    for (y = T(18); y < T(30); y++)
    {
        for (x = T(24); x < T(36); x++)                 /* where the object must be now */
            if (out[y][x] < 0.85f) lead_bad++;          /* includes the newly covered strip */
        for (x = T(20); x < T(24); x++)                 /* uncovered trailing strip */
        {
            if (out[y][x] > 0.55f) ghost++;             /* a copy of the object left behind */
            if (fabsf(out[y][x] - bg_value(x, y)) > 0.12f) hole_bad++;
        }
        for (x = T(4); x < T(18); x++)                  /* untouched background */
            if (fabsf(out[y][x] - bg_value(x, y)) > 0.01f) bg_bad++;
        for (x = T(38); x < W; x++)
            if (fabsf(out[y][x] - bg_value(x, y)) > 0.01f) bg_bad++;
    }
    if (verbose)
        printf("moving object: leading edge wins %d bad, ghost copies %d, uncovered bg %d bad, "
               "untouched bg %d bad: %s\n", lead_bad, ghost, hole_bad, bg_bad,
               (lead_bad || ghost || hole_bad || bg_bad) ? "FAILED" : "ok");
    return lead_bad + ghost + hole_bad + bg_bad;
}

/* A square object moving DIAGONALLY and fast: the case a probe with fewer taps is most likely to
   miss. Judged like the horizontal one: the leading side must show the object, the trailing side
   must not keep a copy of it, the background must be untouched. Sizes and speeds are in reference
   texels. Returns the number of wrong pixels. Known limit, also true of the default 8 taps: objects
   of about 6 reference texels or less fit between the probe taps and are not found (README, "Known
   limits"); only larger objects are required to pass. With 4 taps, even a 10-texel diagonal mover
   loses leading-edge pixels, which is why MABA_FG_PROBE_TAPS defaults to 8 and 4 is documented as
   the fast, less robust option. */
static int scene_diagonal(int taps, int size_ref, int move_ref, int verbose, int required)
{
    static float out[H][W];
    int x, y, ghost = 0, lead_bad = 0, bg_bad = 0;
    const int size = T(size_ref);
    const int mv = T(move_ref);                              /* texels per real interval */
    const int x0 = T(22), y0 = T(18);                        /* the object's position in the newest frame */
    const int d = (int)((float)mv * MABA_FG_GEN_OFFSET + 0.5f);   /* how far it moves by the generated frame */
    const int margin = T(8);
    g_taps = taps;
    clear_scene();
    for (y = y0 - mv; y < y0 - mv + size; y++)               /* previous frame */
        for (x = x0 - mv; x < x0 - mv + size; x++) { g_pcolor[y][x] = 0.9f; g_pdepth[y][x] = 0.9f; }
    for (y = y0; y < y0 + size; y++)
        for (x = x0; x < x0 + size; x++)
        {
            g_color[y][x] = 0.9f;
            g_depth[y][x] = 0.9f;
            g_vel[y][x].x = (float)move_ref / 64.0f;
            g_vel[y][x].y = (float)move_ref / 48.0f;
        }
    warp_all(MABA_FG_GEN_OFFSET, out);
    for (y = 0; y < H; y++)
        for (x = 0; x < W; x++)
        {
            int in_gen = x >= x0 + d && x < x0 + d + size && y >= y0 + d && y < y0 + d + size;
            int in_cur = x >= x0 && x < x0 + size && y >= y0 && y < y0 + size;
            int near_obj = x >= x0 - margin && x < x0 + d + size + margin && y >= y0 - margin && y < y0 + d + size + margin;
            if (in_gen && x >= x0 + d + 1 && x < x0 + d + size - 1 && y >= y0 + d + 1 && y < y0 + d + size - 1
                && out[y][x] < 0.85f) lead_bad++;
            if (in_cur && !in_gen && out[y][x] > 0.55f) ghost++;
            if (!near_obj && fabsf(out[y][x] - bg_value(x, y)) > 0.01f) bg_bad++;
        }
    g_taps = 8;
    if (verbose)
        printf("diagonal object %2dx%-2d %2d texels/interval, %d probe taps: leading side %2d bad, ghost copies %d, "
               "background %d bad%s\n", size_ref, size_ref, move_ref, taps, lead_bad, ghost, bg_bad,
               required ? ((lead_bad || ghost || bg_bad) ? ": FAILED" : ": ok") : "  (informational)");
    return lead_bad + ghost + bg_bad;
}

/* Every object scene the 8-tap default must handle, with the given scaling mask. Returns the number
   of wrong pixels over the required scenes. `enforce` also records them as test failures. */
static int object_suite(int mask, int verbose, int enforce)
{
    static const int sizes[3] = {4, 6, 10};
    static const int moves[3] = {6, 8, 12};
    int a, b, bad;
    g_mask = mask;
    bad = scene_moving_object(verbose);
    if (enforce) CHECK(bad == 0);
    for (a = 0; a < 3; a++)
        for (b = 0; b < 3; b++)
        {
            /* 8 taps (the default) must handle every object large enough to be seen by the probe */
            int required = sizes[a] >= 10;
            int n = scene_diagonal(8, sizes[a], moves[b], verbose, required);
            if (required) { bad += n; if (enforce) CHECK(n == 0); }
            if (verbose) scene_diagonal(4, sizes[a], moves[b], 1, 0);
        }
    g_mask = MABA_FG_SCALE_MASK;
    return bad;
}

int main(int argc, char** argv)
{
    int mask = MABA_FG_SCALE_MASK;
    if (argc > 1) mask = atoi(argv[1]);
    printf("render height x%d of the reference, texel constants scaled by mask %d\n", GRID_SCALE, mask);
    test_slots();
    test_counters();
    test_static();
    test_pan();
    object_suite(mask, 1, 1);
    if (GRID_SCALE > 1)
    {
        /* The point of scaling: the same scene at a taller render, with the constants left at their
           reference-height values, loses objects the probe can no longer reach. */
        int scaled = object_suite(mask, 0, 0), fixed = object_suite(0, 0, 0);
        printf("render x%d, wrong pixels over the required object scenes: constants scaled %d, "
               "constants fixed at the reference values %d (informational)\n", GRID_SCALE, scaled, fixed);
    }
    if (g_failures == 0) printf("ALL FRAME GEN TESTS PASSED\n");
    else printf("%d FAILURES\n", g_failures);
    return g_failures == 0 ? 0 : 1;
}
