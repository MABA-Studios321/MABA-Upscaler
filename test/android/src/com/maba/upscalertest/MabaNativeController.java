package com.maba.upscalertest;

/** The REAL C controller from maba_upscaler.h, running on-device via JNI. */
public final class MabaNativeController implements DynController {
    private long ptr;
    private int rung;
    private int outW = 1541, outH = 720;
    private final int[] frame = new int[3];

    public MabaNativeController(int mode, float targetFps) {
        ptr = MabaNative.ctrlCreate(mode, targetFps);
        rung = MabaController.modeRung(mode);
    }

    public void setOutSize(int w, int h) { outW = w; outH = h; }

    @Override public void setMode(int mode) {
        MabaNative.ctrlSetMode(ptr, mode);
        rung = MabaController.modeRung(mode);
    }

    @Override public void setTargetFps(float fps) {
        MabaNative.ctrlSetTargetFps(ptr, fps);
    }

    @Override public void updateDynamic(float frameMs) {
        rung = MabaNative.ctrlBeginFrame(ptr, frameMs, outW, outH, frame);
    }

    @Override public int rung() { return rung; }

    @Override protected void finalize() {
        if (ptr != 0) MabaNative.ctrlDestroy(ptr);
    }
}