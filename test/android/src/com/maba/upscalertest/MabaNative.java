package com.maba.upscalertest;

/** JNI bridge to the real C controller (maba_upscaler.h) and EXT_disjoint_timer_query. */
public final class MabaNative {
    private static boolean loaded;

    static {
        try {
            System.loadLibrary("maba_jni");
            loaded = true;
        } catch (UnsatisfiedLinkError e) {
            loaded = false;
        }
    }

    public static boolean available() { return loaded; }

    public static native long ctrlCreate(int mode, float fps);
    public static native void ctrlDestroy(long ptr);
    public static native void ctrlSetMode(long ptr, int mode);
    public static native void ctrlSetTargetFps(long ptr, float fps);
    /** Returns rung; outFrame = {renderWidth, renderHeight, qualityShader}. */
    public static native int ctrlBeginFrame(long ptr, float ms, int outW, int outH, int[] outFrame);

    public static native boolean timerSupported();
    public static native void timerBegin();
    /** Latest GPU frame time in ms; 0 while warming up; -1 if the driver's timestamps are
     *  frame-granular and cannot measure GPU time. */
    public static native float timerEnd();
}