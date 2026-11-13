package com.maba.upscalertest;

/** Controller surface used by the app; implemented by the native C header and the Java port. */
public interface DynController {
    void setMode(int mode);
    void setTargetFps(float fps);
    void updateDynamic(float frameMs);
    int rung();
}