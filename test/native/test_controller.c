/* MABA Upscaler - native tests for maba_upscaler.h
 *
 * Build (host):  gcc -std=c99 -O2 -Wall -Wextra -o test_controller test_controller.c
 * Run:           test_controller selftest   (assertions)
 *                test_controller trace      (deterministic rung trace for Java parity)
 *
 * Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "../../src/maba_upscaler.h"

static int g_failures = 0;

#define CHECK(cond) do { \
    if (!(cond)) { \
        printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); \
        g_failures++; \
    } \
} while (0)

static void test_rung_ladder(void)
{
    /* Anchors must reproduce the classic presets exactly (within float representation). */
    CHECK(fabsf(MabaRungScale(0) - 0.50f) < 1e-6f && MabaRungQuality(0) == 0);
    CHECK(fabsf(MabaRungScale(9) - 0.59f) < 1e-6f && MabaRungQuality(9) == 0);
    CHECK(fabsf(MabaRungScale(10) - 0.59f) < 1e-6f && MabaRungQuality(10) == 1);
    CHECK(fabsf(MabaRungScale(18) - 0.67f) < 1e-6f && MabaRungQuality(18) == 1);
    CHECK(fabsf(MabaRungScale(28) - 0.77f) < 1e-6f && MabaRungQuality(28) == 1);
    /* Non-decreasing scale; 1% steps except rung 9->10, which swaps shader at the same scale. */
    int r;
    for (r = 1; r < MABA_RUNG_COUNT; r++) {
        CHECK(MabaRungScale(r) >= MabaRungScale(r - 1));
        if (r == 10) {
            CHECK(MabaRungScale(r) == MabaRungScale(r - 1));
        } else {
            float step = MabaRungScale(r) - MabaRungScale(r - 1);
            CHECK(step > 0.009f && step < 0.011f);
        }
    }
}

static void test_modes(void)
{
    MabaUpscaler u;
    MabaInit(&u, MABA_MODE_PERFORMANCE, 60.0f);
    CHECK(u.rung == 0);
    MabaFrame f = MabaBeginFrame(&u, 16.0f, 1541, 720);
    CHECK(f.renderWidth == 771);   /* round(1541 * 0.50) */
    CHECK(f.renderHeight == 360);
    CHECK(f.qualityShader == 0);

    MabaSetMode(&u, MABA_MODE_ULTRA_QUALITY);
    f = MabaBeginFrame(&u, 16.0f, 1541, 720);
    CHECK(f.rung == 28);
    CHECK(f.renderWidth == 1187);  /* round(1541 * 0.77) */
    CHECK(f.qualityShader == 1);

    MabaSetMode(&u, MABA_MODE_BALANCED);
    f = MabaBeginFrame(&u, 16.0f, 1541, 720);
    CHECK(f.rung == 10);
    CHECK(f.renderWidth == 909);   /* round(1541 * 0.59) */
    CHECK(f.qualityShader == 1);

    MabaSetMode(&u, MABA_MODE_QUALITY);
    f = MabaBeginFrame(&u, 16.0f, 1541, 720);
    CHECK(f.rung == 18);
    CHECK(f.renderWidth == 1032);  /* round(1541 * 0.67) */

    int tw, th;
    MabaMaxRenderSize(1541, 720, &tw, &th);
    CHECK(tw == 1187 && th == 554);

    float size[4], params[4];
    MabaUniforms(&f, tw, th, 0.5f, size, params);
    CHECK(size[0] == (float)f.renderWidth && size[1] == (float)f.renderHeight);
    CHECK(size[2] == 1.0f / (float)tw && size[3] == 1.0f / (float)th);
    CHECK(params[0] == 0.5f && params[1] == 0.0f);
}

static void feed(MabaUpscaler* u, float ms, int frames)
{
    int i;
    for (i = 0; i < frames; i++) MabaBeginFrame(u, ms, 1541, 720);
}

/* Feed frames until the rung reaches target; returns frames fed, or maxFrames if it never did.
 * The smoothed frame time needs a few frames to converge after a burst, so exact frame counts
 * are not asserted. */
static int feed_until_rung(MabaUpscaler* u, float ms, int target, int maxFrames)
{
    int i;
    for (i = 0; i < maxFrames; i++) {
        MabaBeginFrame(u, ms, 1541, 720);
        if (u->rung == target) return i + 1;
    }
    return maxFrames;
}

static void test_step_down(void)
{
    MabaUpscaler u;
    MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
    CHECK(u.rung == 10);
    feed(&u, 25.0f, 1000);
    CHECK(u.rung == 0);            /* walked down to the floor and stayed */
    feed(&u, 25.0f, 500);
    CHECK(u.rung == 0);
}

static void test_step_up(void)
{
    MabaUpscaler u;
    MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
    feed(&u, 25.0f, 1000);         /* down to 0 */
    CHECK(u.rung == 0);
    int n = feed_until_rung(&u, 10.0f, 1, 1000);
    CHECK(n < 1000);
    CHECK(n >= MABA_DYN_UP_FRAMES);          /* never sooner than the good-frame window */
    CHECK(n <= MABA_DYN_UP_FRAMES + 30);     /* EMA convergence adds only a few frames */
    CHECK(u.rung == 1);
    CHECK(u.probing == 1);
    feed(&u, 10.0f, 20000);
    CHECK(u.rung == 28);           /* climbed to the ceiling */
    feed(&u, 10.0f, 500);
    CHECK(u.rung == 28);
}

static void test_backoff(void)
{
    MabaUpscaler u;
    MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
    feed(&u, 25.0f, 1000);         /* rung 0 */
    feed_until_rung(&u, 10.0f, 1, 1000);    /* step up to 1, probing */
    CHECK(u.rung == 1 && u.probing == 1);
    CHECK(u.upWait == MABA_DYN_UP_FRAMES);
    feed(&u, 25.0f, 200);          /* fails: step down, back off */
    CHECK(u.rung == 0);
    CHECK(u.upWait == MABA_DYN_UP_FRAMES * 2);
    CHECK(u.probing == 0);
    /* next attempt must wait the doubled window */
    int n = feed_until_rung(&u, 10.0f, 1, 2000);
    CHECK(n >= MABA_DYN_UP_FRAMES * 2);
    CHECK(u.rung == 1);
    /* fail again so the back-off (720) is larger than the proof window (300) */
    feed(&u, 25.0f, 200);
    CHECK(u.rung == 0);
    CHECK(u.upWait == MABA_DYN_UP_FRAMES * 4);
    feed_until_rung(&u, 10.0f, 1, 2000);
    CHECK(u.rung == 1 && u.probing == 1);
    /* proven: hold 300 good frames, back-off relaxes by half, no instant re-step */
    feed(&u, 10.0f, MABA_DYN_PROVEN_FRAMES);
    CHECK(u.probing == 0);
    CHECK(u.upWait == MABA_DYN_UP_FRAMES * 2);
    CHECK(u.rung == 1);
}

static void test_backoff_cap(void)
{
    MabaUpscaler u;
    MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
    int i;
    for (i = 0; i < 20; i++) {
        feed(&u, 25.0f, 200);      /* toward rung 0 */
        feed(&u, 25.0f, 800);      /* ensure floor */
        int n = feed_until_rung(&u, 10.0f, u.rung + 1, u.upWait + 100);
        if (n >= u.upWait + 100) break;
        feed(&u, 25.0f, 200);      /* fail it */
    }
    CHECK(u.upWait == MABA_DYN_UP_FRAMES_MAX);
}

static void test_pause_ignore(void)
{
    MabaUpscaler u;
    MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
    feed(&u, 16.0f, 50);
    float avg = u.avgMs;
    int good = u.goodFrames;
    feed(&u, 2000.0f, 10);         /* loading hitch: ignored */
    feed(&u, -5.0f, 10);           /* nonsense: ignored */
    CHECK(u.avgMs == avg);
    CHECK(u.goodFrames == good);
}

static void test_target_fps(void)
{
    MabaUpscaler u;
    MabaInit(&u, MABA_MODE_DYNAMIC, 30.0f);
    CHECK(u.targetMs > 33.0f && u.targetMs < 34.0f);
    feed(&u, 30.0f, 20000);
    CHECK(u.rung == 28);           /* 30 ms frames are fine for a 30 fps target */
    MabaInit(&u, MABA_MODE_DYNAMIC, 0.0f);   /* invalid target falls back to 60 */
    CHECK(u.targetMs > 16.0f && u.targetMs < 17.0f);
}

static void test_set_target_fps(void)
{
    MabaUpscaler u;
    MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
    feed(&u, 25.0f, 1000);         /* settle at rung 0 */
    CHECK(u.rung == 0);
    MabaSetTargetFps(&u, 30.0f);   /* thermal throttle: budget doubles */
    CHECK(u.rung == 0);            /* rung preserved */
    CHECK(u.avgMs == 0.0f && u.overFrames == 0 && u.goodFrames == 0);
    feed(&u, 25.0f, 20000);
    CHECK(u.rung == 28);           /* 25 ms is under the 33 ms budget: climbs */
}

static void test_seed_rung(void)
{
    MabaUpscaler u;
    MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
    MabaSeedRung(&u, 22);
    CHECK(u.rung == 22);
    MabaSeedRung(&u, 999);
    CHECK(u.rung == MABA_RUNG_MAX);
    MabaSeedRung(&u, -5);
    CHECK(u.rung == MABA_RUNG_MIN);
}

static void test_gpu_entry(void)
{
    /* GPU and present-to-present entry points must drive the identical controller. */
    MabaUpscaler a, b;
    MabaInit(&a, MABA_MODE_DYNAMIC, 60.0f);
    MabaInit(&b, MABA_MODE_DYNAMIC, 60.0f);
    int i;
    for (i = 0; i < 5000; i++) {
        float ms = 10.0f + (float)(i % 17);
        MabaFrame fa = MabaBeginFrame(&a, ms, 1541, 720);
        MabaFrame fb = MabaBeginFrameGpu(&b, ms, 1541, 720);
        CHECK(fa.rung == fb.rung && fa.renderWidth == fb.renderWidth);
    }
}

/* Deterministic trace shared with the Java parity runner (Parity.java).
 * 64-bit LCG, identical wrap-around semantics in C (uint64) and Java (long). */
static unsigned long long lcg_state = 12345ULL;
static float next_frame_ms(void)
{
    lcg_state = lcg_state * 6364136223846793005ULL + 1442695040888963407ULL;
    unsigned int r = (unsigned int)(lcg_state >> 33);
    return 8.0f + (float)(r % 25u);      /* 8..32 ms */
}

static void run_trace(void)
{
    MabaUpscaler u;
    MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
    int i;
    for (i = 0; i < 20000; i++) {
        float ms = (i % 500 == 499) ? 2000.0f : next_frame_ms();
        MabaFrame f = MabaBeginFrame(&u, ms, 1541, 720);
        printf("%d %d %d %d\n", i, f.rung, f.renderWidth, f.renderHeight);
    }
    printf("final %d %d %d %d %d\n", u.rung, u.overFrames, u.goodFrames, u.upWait, u.probing);
}

int main(int argc, char** argv)
{
    if (argc > 1 && strcmp(argv[1], "trace") == 0) {
        run_trace();
        return 0;
    }
    test_rung_ladder();
    test_modes();
    test_step_down();
    test_step_up();
    test_backoff();
    test_backoff_cap();
    test_pause_ignore();
    test_target_fps();
    test_set_target_fps();
    test_seed_rung();
    test_gpu_entry();
    if (g_failures == 0) printf("ALL CONTROLLER TESTS PASSED\n");
    else printf("%d FAILURES\n", g_failures);
    return g_failures == 0 ? 0 : 1;
}