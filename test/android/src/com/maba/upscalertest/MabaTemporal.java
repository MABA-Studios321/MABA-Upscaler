package com.maba.upscalertest;

/** Pure-Java port of maba_temporal.h (Halton jitter + reset state). No Android dependencies. */
public final class MabaTemporal {
    public static final int PHASES = 16;

    public int phase;
    public boolean resetNext;
    public float historyWeight, depthTolerance, clipGamma;

    public MabaTemporal() {
        this(0.9f, 0.01f, 1.25f);
    }

    public MabaTemporal(float historyWeight, float depthTolerance, float clipGamma) {
        // Same validation as MabaTemporalInit in maba_temporal.h.
        this.historyWeight = (historyWeight > 0f && historyWeight < 1f) ? historyWeight : 0.9f;
        this.depthTolerance = depthTolerance > 0f ? depthTolerance : 0.01f;
        this.clipGamma = clipGamma > 0f ? clipGamma : 1.25f;
        reset();
    }

    public void reset() {
        resetNext = true;
        phase = 0;
    }

    public static float halton(int index, int base) {
        float f = 1f, r = 0f;
        while (index > 0) {
            f /= base;
            r += f * (index % base);
            index /= base;
        }
        return r;
    }

    /** Returns {jitterX, jitterY, reset(0/1), phase}. */
    public float[] beginFrame() {
        float[] f = new float[4];
        f[3] = phase;
        f[2] = resetNext ? 1f : 0f;
        resetNext = false;
        f[0] = halton(phase + 1, 2) - 0.5f;
        f[1] = halton(phase + 1, 3) - 0.5f;
        phase = (phase + 1) % PHASES;
        return f;
    }

    public float[] uniforms(float[] frame) {
        return new float[]{historyWeight, depthTolerance, frame[2], clipGamma};
    }
}
