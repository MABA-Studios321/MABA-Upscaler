/* MABA Upscaler - native tests for maba_upscaler.h
 *
 * Build (host):  gcc -std=c99 -O2 -Wall -Wextra -o test_controller test_controller.c
 * Run:           test_controller selftest   (assertions)
 *                test_controller trace      (deterministic rung trace for Java / C# parity)
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

/* A frame time just inside the 60 fps budget (16.67 ms, over-budget threshold 17.0 ms): good, but
   with no headroom, so a step up climbs exactly one rung. */
#define BARELY_GOOD_MS 16.0f

static void test_rung_ladder(void)
{
    /* Anchors must reproduce the classic presets exactly (within float representation). */
    CHECK(fabsf(MabaRungScale(0) - 0.50f) < 1e-6f && MabaRungQuality(0) == 0);
    CHECK(fabsf(MabaRungScale(9) - 0.59f) < 1e-6f && MabaRungQuality(9) == 0);
    CHECK(fabsf(MabaRungScale(10) - 0.59f) < 1e-6f && MabaRungQuality(10) == 1);
    CHECK(fabsf(MabaRungScale(18) - 0.67f) < 1e-6f && MabaRungQuality(18) == 1);
    CHECK(fabsf(MabaRungScale(28) - 0.77f) < 1e-6f && MabaRungQuality(28) == 1);
    /* The ends of the whole ladder: 0.35 (fast shader) .. 1.00 = native (quality shader). */
    CHECK(fabsf(MabaRungScale(MABA_RUNG_FLOOR) - 0.35f) < 1e-6f && MabaRungQuality(MABA_RUNG_FLOOR) == 0);
    CHECK(fabsf(MabaRungScale(-1) - 0.49f) < 1e-6f && MabaRungQuality(-1) == 0);
    CHECK(fabsf(MabaRungScale(MABA_RUNG_CEIL) - 1.00f) < 1e-6f && MabaRungQuality(MABA_RUNG_CEIL) == 1);
    /* Non-decreasing scale over the whole ladder; 1% steps except rung 9->10, which swaps shader
       at the same scale. */
    int r;
    for (r = MABA_RUNG_FLOOR + 1; r <= MABA_RUNG_CEIL; r++) {
        CHECK(MabaRungScale(r) >= MabaRungScale(r - 1));
        if (r == 10) {
            CHECK(MabaRungScale(r) == MabaRungScale(r - 1));
        } else {
            float step = MabaRungScale(r) - MabaRungScale(r - 1);
            CHECK(step > 0.009f && step < 0.011f);
        }
    }
    /* Scale -> rung is the inverse (0.59 maps to the quality build) and clamps to the ladder. */
    for (r = MABA_RUNG_FLOOR; r <= MABA_RUNG_CEIL; r++) {
        if (r == 9) CHECK(MabaScaleToRung(MabaRungScale(r)) == 10);
        else CHECK(MabaScaleToRung(MabaRungScale(r)) == r);
    }
    CHECK(MabaScaleToRung(0.0f) == MABA_RUNG_FLOOR);
    CHECK(MabaScaleToRung(7.5f) == MABA_RUNG_CEIL);
    CHECK(MabaScaleToRung(0.50f) == 0 && MabaScaleToRung(0.77f) == 28);
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
    CHECK(f.isNative == 0);

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

    /* The render target is sized for the largest rung a controller can ask for. The default range
       is the whole ladder, so that is the output size. */
    int tw, th;
    MabaMaxRenderSize(1541, 720, &tw, &th);
    CHECK(tw == 1541 && th == 720);
    MabaUpscaler w;
    MabaInit(&w, MABA_MODE_DYNAMIC, 60.0f);
    MabaMaxRenderSizeFor(&w, 1541, 720, &tw, &th);
    CHECK(tw == 1541 && th == 720);
    MabaSetScaleRange(&w, 0.50f, 0.77f);
    MabaMaxRenderSizeFor(&w, 1541, 720, &tw, &th);
    CHECK(tw == 1187 && th == 554);   /* a narrower range allocates less */

    float size[4], params[4];
    MabaUniforms(&f, tw, th, 0.5f, size, params);
    CHECK(size[0] == (float)f.renderWidth && size[1] == (float)f.renderHeight);
    CHECK(size[2] == 1.0f / (float)tw && size[3] == 1.0f / (float)th);
    CHECK(params[0] == 0.5f && params[1] == 0.0f);

    /* Native: the top rung renders at output size and says so; the rung below does not. */
    MabaSeedRung(&w, 0);
    MabaSetScaleRange(&w, 0.35f, 1.00f);
    MabaSeedRung(&w, MABA_RUNG_CEIL);
    f = MabaMakeFrame(&w, 1541, 720);
    CHECK(f.isNative == 1 && f.renderWidth == 1541 && f.renderHeight == 720 && f.qualityShader == 1);
    MabaSeedRung(&w, MABA_RUNG_CEIL - 1);
    f = MabaMakeFrame(&w, 1541, 720);
    CHECK(f.isNative == 0 && f.renderWidth == 1526);   /* round(1541 * 0.99) */
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

/* Feed frames until the rung changes at all (a headroom jump skips past any exact target);
 * returns frames fed, or maxFrames if it never changed. */
static int feed_until_change(MabaUpscaler* u, float ms, int maxFrames)
{
    int start = u->rung;
    int i;
    for (i = 0; i < maxFrames; i++) {
        MabaBeginFrame(u, ms, 1541, 720);
        if (u->rung != start) return i + 1;
    }
    return maxFrames;
}

static void test_step_down(void)
{
    MabaUpscaler u;
    MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
    CHECK(u.rung == 10);
    feed(&u, 25.0f, 1000);
    CHECK(u.rung == MABA_RUNG_FLOOR);   /* walked down to the floor of the whole ladder and stayed */
    feed(&u, 25.0f, 500);
    CHECK(u.rung == MABA_RUNG_FLOOR);
}

static void test_step_up(void)
{
    MabaUpscaler u;
    MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
    feed(&u, 25.0f, 1000);         /* down to the floor */
    CHECK(u.rung == MABA_RUNG_FLOOR);
    int n = feed_until_rung(&u, BARELY_GOOD_MS, MABA_RUNG_FLOOR + 1, 1000);
    CHECK(n < 1000);
    CHECK(n >= MABA_DYN_UP_FRAMES);          /* never sooner than the good-frame window */
    CHECK(n <= MABA_DYN_UP_FRAMES + 30);     /* EMA convergence adds only a few frames */
    CHECK(u.rung == MABA_RUNG_FLOOR + 1);    /* no headroom: exactly one rung */
    CHECK(u.probing == 1);
    feed(&u, BARELY_GOOD_MS, 30000);
    CHECK(u.rung == MABA_RUNG_CEIL);         /* climbed to native */
    feed(&u, BARELY_GOOD_MS, 500);
    CHECK(u.rung == MABA_RUNG_CEIL);
}

static void test_backoff(void)
{
    MabaUpscaler u;
    MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
    feed(&u, 25.0f, 1000);         /* floor */
    feed_until_rung(&u, BARELY_GOOD_MS, MABA_RUNG_FLOOR + 1, 1000);    /* step up, probing */
    CHECK(u.rung == MABA_RUNG_FLOOR + 1 && u.probing == 1);
    CHECK(u.upWait == MABA_DYN_UP_FRAMES);
    feed(&u, 25.0f, 200);          /* fails: step down, back off */
    CHECK(u.rung == MABA_RUNG_FLOOR);
    CHECK(u.upWait == MABA_DYN_UP_FRAMES * 2);
    CHECK(u.probing == 0);
    /* next attempt must wait the doubled window */
    int n = feed_until_rung(&u, BARELY_GOOD_MS, MABA_RUNG_FLOOR + 1, 2000);
    CHECK(n >= MABA_DYN_UP_FRAMES * 2);
    CHECK(u.rung == MABA_RUNG_FLOOR + 1);
    /* fail again so the back-off (720) is larger than the proof window (300) */
    feed(&u, 25.0f, 200);
    CHECK(u.rung == MABA_RUNG_FLOOR);
    CHECK(u.upWait == MABA_DYN_UP_FRAMES * 4);
    feed_until_rung(&u, BARELY_GOOD_MS, MABA_RUNG_FLOOR + 1, 2000);
    CHECK(u.rung == MABA_RUNG_FLOOR + 1 && u.probing == 1);
    /* proven: hold 300 good frames, back-off relaxes by half, no instant re-step */
    feed(&u, BARELY_GOOD_MS, MABA_DYN_PROVEN_FRAMES);
    CHECK(u.probing == 0);
    CHECK(u.upWait == MABA_DYN_UP_FRAMES * 2);
    CHECK(u.rung == MABA_RUNG_FLOOR + 1);
}

static void test_backoff_cap(void)
{
    MabaUpscaler u;
    MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
    int i;
    for (i = 0; i < 20; i++) {
        feed(&u, 25.0f, 200);      /* toward the floor */
        feed(&u, 25.0f, 800);      /* ensure floor */
        int n = feed_until_rung(&u, BARELY_GOOD_MS, u.rung + 1, u.upWait + 100);
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
    feed(&u, 30.0f, 30000);
    CHECK(u.rung == MABA_RUNG_CEIL);   /* 30 ms frames are fine for a 30 fps target */
    MabaInit(&u, MABA_MODE_DYNAMIC, 0.0f);   /* invalid target falls back to 60 */
    CHECK(u.targetMs > 16.0f && u.targetMs < 17.0f);
}

static void test_set_target_fps(void)
{
    MabaUpscaler u;
    MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
    feed(&u, 25.0f, 1000);         /* settle at the floor */
    CHECK(u.rung == MABA_RUNG_FLOOR);
    MabaSetTargetFps(&u, 30.0f);   /* thermal throttle: budget doubles */
    CHECK(u.rung == MABA_RUNG_FLOOR);   /* rung preserved */
    CHECK(u.avgMs == 0.0f && u.overFrames == 0 && u.goodFrames == 0);
    feed(&u, 25.0f, 30000);
    CHECK(u.rung == MABA_RUNG_CEIL);    /* 25 ms is under the 33 ms budget: climbs */
}

static void test_seed_rung(void)
{
    MabaUpscaler u;
    MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
    MabaSeedRung(&u, 22);
    CHECK(u.rung == 22);
    MabaSeedRung(&u, 999);
    CHECK(u.rung == MABA_RUNG_CEIL);
    MabaSeedRung(&u, -5);
    CHECK(u.rung == -5);                /* below the classic floor is valid on the full ladder */
    MabaSeedRung(&u, -999);
    CHECK(u.rung == MABA_RUNG_FLOOR);
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

static void test_scale_range(void)
{
    /* Defaults: the whole ladder; nothing is capped for a hardware class. */
    MabaUpscaler u;
    MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
    CHECK(u.rungMin == MABA_RUNG_FLOOR && u.rungMax == MABA_RUNG_CEIL);

    /* The classic range reproduces the old behaviour exactly: floor 0, ceiling 28. */
    MabaSetScaleRange(&u, 0.50f, 0.77f);
    CHECK(u.rungMin == 0 && u.rungMax == 28);
    feed(&u, 25.0f, 1000);
    CHECK(u.rung == 0);
    feed(&u, BARELY_GOOD_MS, 30000);
    CHECK(u.rung == 28);
    feed(&u, BARELY_GOOD_MS, 1000);
    CHECK(u.rung == 28);

    /* Narrowing moves the current rung inside the range; inverted ranges collapse to one rung. */
    MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
    MabaSeedRung(&u, 40);
    MabaSetScaleRange(&u, 0.50f, 0.77f);
    CHECK(u.rung == 28);
    MabaSetScaleRange(&u, 0.90f, 0.60f);
    CHECK(u.rungMin == u.rungMax);
    CHECK(u.rung == u.rungMin);

    /* A quality floor holds under load; a fixed preset ignores the range. */
    MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
    MabaSetScaleRange(&u, 0.67f, 1.00f);
    CHECK(u.rung == 18);                /* the start rung (10) is raised to the floor (18) */
    feed(&u, 40.0f, 2000);
    CHECK(u.rung == 18);
    MabaInit(&u, MABA_MODE_PERFORMANCE, 60.0f);
    MabaSetScaleRange(&u, 0.67f, 1.00f);
    CHECK(u.rung == 0);
    MabaSetMode(&u, MABA_MODE_DYNAMIC);
    CHECK(u.rung == 18);                /* switching to Dynamic enters the range */
}

static void test_headroom_jump(void)
{
    /* With plenty of spare time a step up climbs several rungs at once, but never further than the
       measured frame time predicts will fit, and never more than MABA_DYN_MAX_JUMP. */
    MabaUpscaler u;
    MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
    feed(&u, 25.0f, 1000);
    CHECK(u.rung == MABA_RUNG_FLOOR);
    int from = u.rung;
    int n = feed_until_change(&u, 5.0f, 600);     /* the first step up */
    CHECK(n < 600);
    CHECK(u.rung > from + 1);                     /* more than one rung */
    CHECK(u.rung - from <= MABA_DYN_MAX_JUMP);
    CHECK(u.probing == 1 && u.probeFrom == from);

    /* Moderate headroom: the jump stops where the prediction (cost ~ pixels) exceeds the budget.
       From 0.67 at 12 ms against a 16.67 ms budget (15.0 ms after the headroom margin): the
       highest rung r with 12 * (pct(r) / 67)^2 <= 15.0 is pct 74 (0.74), rung 25. */
    MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
    MabaSeedRung(&u, 18);
    n = feed_until_change(&u, 12.0f, 600);
    CHECK(n < 600);
    CHECK(u.rung == 25);
    CHECK(u.avgMs * (float)(MabaRungPercent(25) * MabaRungPercent(25)) / (float)(67 * 67)
          <= u.targetMs * MABA_DYN_HEADROOM + 1e-3f);   /* it fits... */
    CHECK(u.avgMs * (float)(MabaRungPercent(26) * MabaRungPercent(26)) / (float)(67 * 67)
          > u.targetMs * MABA_DYN_HEADROOM);            /* ...and one rung further would not */

    /* No headroom at all: single steps, as before. */
    MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
    feed(&u, 25.0f, 1000);
    from = u.rung;
    feed_until_change(&u, BARELY_GOOD_MS, 1000);
    CHECK(u.rung == from + 1);
}

static void test_failed_jump_returns(void)
{
    /* A multi-rung step up that does not hold goes back to where it started in ONE step, instead of
       needing a 20-frame over-budget window per rung. */
    MabaUpscaler u;
    MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
    feed(&u, 25.0f, 1000);
    int from = u.rung;
    feed_until_change(&u, 5.0f, 600);
    CHECK(u.rung > from + 1 && u.probing == 1);
    int jumped = u.rung;
    int i;
    int frames = 0;
    for (i = 0; i < 400 && u.rung == jumped; i++) { MabaBeginFrame(&u, 25.0f, 1541, 720); frames++; }
    CHECK(u.rung == from);
    CHECK(frames < 2 * MABA_DYN_DOWN_FRAMES + 40);   /* one window (plus EMA convergence), not one per rung */
    CHECK(u.probing == 0 && u.upWait == MABA_DYN_UP_FRAMES * 2);
}

static void test_native_reachable(void)
{
    MabaUpscaler u;
    MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
    feed(&u, 5.0f, 20000);
    CHECK(u.rung == MABA_RUNG_CEIL);               /* a fast GPU ends up at native resolution... */
    MabaFrame f = MabaMakeFrame(&u, 1541, 720);
    CHECK(f.isNative == 1 && f.renderWidth == 1541 && f.renderHeight == 720);
    feed(&u, 25.0f, 200);                          /* ...and leaves it when frames run over */
    CHECK(u.rung < MABA_RUNG_CEIL);
    f = MabaMakeFrame(&u, 1541, 720);
    CHECK(f.isNative == 0);
}

/* Deterministic trace shared with the Java and C# parity runners (Parity.java, parity_cs).
 * 64-bit LCG, identical wrap-around semantics in C (uint64), Java (long) and C# (ulong). */
static unsigned long long lcg_state = 12345ULL;
static float next_frame_ms(float base, unsigned int span)
{
    lcg_state = lcg_state * 6364136223846793005ULL + 1442695040888963407ULL;
    unsigned int r = (unsigned int)(lcg_state >> 33);
    return base + (float)(r % span);
}

/* Frame times are base .. base + span - 1 ms; every 500th frame is a 2 s loading hitch. */
static void trace_frames(MabaUpscaler* u, int from, int to, float base, unsigned int span)
{
    int i;
    for (i = from; i < to; i++) {
        float ms = (i % 500 == 499) ? 2000.0f : next_frame_ms(base, span);
        MabaFrame f = MabaBeginFrame(u, ms, 1541, 720);
        printf("%d %d %d %d\n", i, f.rung, f.renderWidth, f.renderHeight);
    }
}

static void run_trace(void)
{
    MabaUpscaler u;
    MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
    trace_frames(&u, 0, 20000, 8.0f, 25u);       /* the whole ladder, 8..32 ms: mostly over budget */
    MabaSetScaleRange(&u, 0.50f, 0.77f);         /* then the classic range, mid-run */
    trace_frames(&u, 20000, 25000, 8.0f, 25u);
    MabaSetScaleRange(&u, 0.35f, 1.00f);         /* then the whole ladder again, in three load phases: */
    trace_frames(&u, 25000, 30000, 3.0f, 17u);   /*   spare time (3..19 ms): climbs and jumps */
    trace_frames(&u, 30000, 36000, 14.0f, 21u);  /*   load rises (14..34 ms): probes fail, steps down */
    trace_frames(&u, 36000, 45000, 3.0f, 17u);   /*   spare time again: climbs under the back-off */
    {   /* bursts: 400 light frames (a jump) then 400 heavy ones, inside the jump's proof window,
           so failed jumps return to where they started */
        int k;
        for (k = 0; k < 25; k++)
            trace_frames(&u, 45000 + k * 400, 45000 + (k + 1) * 400,
                         (k % 2 == 0) ? 3.0f : 20.0f, (k % 2 == 0) ? 17u : 20u);
    }
    printf("final %d %d %d %d %d %d\n", u.rung, u.overFrames, u.goodFrames, u.upWait, u.probing, u.probeFrom);
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
    test_scale_range();
    test_headroom_jump();
    test_failed_jump_returns();
    test_native_reachable();
    if (g_failures == 0) printf("ALL CONTROLLER TESTS PASSED\n");
    else printf("%d FAILURES\n", g_failures);
    return g_failures == 0 ? 0 : 1;
}
