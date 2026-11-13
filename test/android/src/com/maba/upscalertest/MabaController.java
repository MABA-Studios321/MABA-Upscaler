package com.maba.upscalertest;

/**
 * Pure-Java port of the Dynamic controller in maba_upscaler.h (no Android dependencies, so it
 * can be unit-tested on the host). Kept line-for-line in sync with the C header; the parity
 * test in test/android/src/.../Parity.java feeds both the same trace and diffs the sequences.
 */
public final class MabaController implements DynController {
    public static final int RUNG_COUNT = 29;
    public static final int RUNG_MIN = 0, RUNG_MAX = RUNG_COUNT - 1;

    public static final int MODE_DYNAMIC = 0, MODE_ULTRA_QUALITY = 1, MODE_QUALITY = 2,
        MODE_BALANCED = 3, MODE_PERFORMANCE = 4;

    public static final int START_RUNG = 10;
    public static final float OVER_RATIO = 1.02f;
    public static final int DOWN_FRAMES = 20, UP_FRAMES = 180, UP_FRAMES_MAX = 3600,
        PROVEN_FRAMES = 300;

    public int mode;
    public float targetMs;
    public int rung;
    public float avgMs;
    public int overFrames, goodFrames, upWait;
    public boolean probing;

    public MabaController(int mode, float targetFps) {
        targetMs = 1000f / (targetFps > 1f ? targetFps : 60f);
        setMode(mode);
    }

    public static float rungScale(int rung) {
        return (rung <= 9) ? (50 + rung) * 0.01f : (49 + rung) * 0.01f;
    }

    public static boolean rungQuality(int rung) {
        return rung >= 10;
    }

    public static int modeRung(int mode) {
        switch (mode) {
            case MODE_ULTRA_QUALITY: return 28;
            case MODE_QUALITY: return 18;
            case MODE_BALANCED: return 10;
            case MODE_PERFORMANCE: return 0;
            default: return START_RUNG;
        }
    }

    public void setMode(int mode) {
        this.mode = mode;
        rung = modeRung(mode);
        avgMs = 0f;
        overFrames = 0;
        goodFrames = 0;
        upWait = UP_FRAMES;
        probing = false;
    }

    public void setTargetFps(float targetFps) {
        targetMs = 1000f / (targetFps > 1f ? targetFps : 60f);
        avgMs = 0f;
        overFrames = 0;
        goodFrames = 0;
        probing = false;
    }

    public void seedRung(int r) {
        rung = Math.max(RUNG_MIN, Math.min(RUNG_MAX, r));
        avgMs = 0f;
        overFrames = 0;
        goodFrames = 0;
        probing = false;
    }

    public void updateDynamic(float frameMs) {
        if (frameMs <= 0f || frameMs > 1000f) return;
        avgMs = avgMs <= 0f ? frameMs : avgMs + (frameMs - avgMs) * 0.1f;
        if (avgMs > targetMs * OVER_RATIO) {
            goodFrames = 0;
            if (++overFrames >= DOWN_FRAMES && rung > RUNG_MIN) {
                rung--;
                overFrames = 0;
                avgMs = targetMs;
                if (probing) {
                    upWait = Math.min(upWait * 2, UP_FRAMES_MAX);
                    probing = false;
                }
            }
        } else {
            overFrames = 0;
            goodFrames++;
            if (probing && goodFrames >= PROVEN_FRAMES) {
                probing = false;
                upWait = Math.max(UP_FRAMES, upWait / 2);
            }
            if (!probing && goodFrames >= upWait && rung < RUNG_MAX) {
                rung++;
                goodFrames = 0;
                probing = true;
            }
        }
    }

    /** Call once per frame (present-to-present or GPU-only ms); returns the rung to render at. */
    public int beginFrame(float lastFrameMs) {
        if (mode == MODE_DYNAMIC) updateDynamic(lastFrameMs);
        return rung;
    }

    @Override public int rung() { return rung; }

    public int renderWidth(int outW) {
        return Math.max(2, Math.round(outW * rungScale(rung)));
    }

    public int renderHeight(int outH) {
        return Math.max(2, Math.round(outH * rungScale(rung)));
    }
}