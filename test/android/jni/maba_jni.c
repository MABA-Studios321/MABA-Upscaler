/* MABA Upscaler test app - JNI bridge.
 *
 * Runs the REAL maba_upscaler.h controller on-device (not a port) and exposes
 * EXT_disjoint_timer_query GPU timing, which the Android Java bindings lack.
 *
 * Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
 */
#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <android/log.h>
#define GL_GLEXT_PROTOTYPES 1
#include <GLES3/gl31.h>
#include <GLES2/gl2ext.h>
#include "../../../src/maba_upscaler.h"

#define JNI(name) Java_com_maba_upscalertest_MabaNative_##name

/* ---- Controller (the actual C header) ---- */

JNIEXPORT jlong JNICALL JNI(ctrlCreate)(JNIEnv* env, jclass cls, jint mode, jfloat fps)
{
    MabaUpscaler* u = (MabaUpscaler*)malloc(sizeof(MabaUpscaler));
    if (!u) return 0;   /* Java side treats 0 as "no native controller" */
    MabaInit(u, (MabaMode)mode, fps);
    return (jlong)(intptr_t)u;
}

JNIEXPORT void JNICALL JNI(ctrlDestroy)(JNIEnv* env, jclass cls, jlong p)
{
    free((void*)(intptr_t)p);
}

JNIEXPORT void JNICALL JNI(ctrlSetMode)(JNIEnv* env, jclass cls, jlong p, jint mode)
{
    if (p) MabaSetMode((MabaUpscaler*)(intptr_t)p, (MabaMode)mode);
}

JNIEXPORT void JNICALL JNI(ctrlSetTargetFps)(JNIEnv* env, jclass cls, jlong p, jfloat fps)
{
    if (p) MabaSetTargetFps((MabaUpscaler*)(intptr_t)p, fps);
}

/* Returns the rung; outFrame = {renderWidth, renderHeight, qualityShader}. */
JNIEXPORT jint JNICALL JNI(ctrlBeginFrame)(JNIEnv* env, jclass cls, jlong p, jfloat ms,
                                           jint outW, jint outH, jintArray outFrame)
{
    if (!p) return MABA_DYN_START_RUNG;
    MabaFrame f = MabaBeginFrameGpu((MabaUpscaler*)(intptr_t)p, ms, outW, outH);
    jint vals[3] = { f.renderWidth, f.renderHeight, f.qualityShader };
    (*env)->SetIntArrayRegion(env, outFrame, 0, 3, vals);
    return f.rung;
}

/* ---- GPU timer (EXT_disjoint_timer_query) ---- */

#define RING 3
#define ZERO_FRAMES_UNUSABLE 8   /* begin == end this many times: timer is frame-granular */
static GLuint qBegin[RING], qEnd[RING];
static int timerFrame;
static int timerSupported = -1;
static float lastGpuMs;
static int zeroFrames;   /* frames whose begin and end timestamps were identical */

JNIEXPORT jboolean JNICALL JNI(timerSupported)(JNIEnv* env, jclass cls)
{
    /* Called once per GL context (onSurfaceCreated). Query objects belong to the context, so
       after a context loss they are created again rather than reused. */
    const char* ext = (const char*)glGetString(GL_EXTENSIONS);
    timerSupported = ext && strstr(ext, "GL_EXT_disjoint_timer_query") ? 1 : 0;
    timerFrame = 0;
    lastGpuMs = 0.0f;
    zeroFrames = 0;
    if (timerSupported) {
        GLuint all[RING * 2];
        glGenQueriesEXT(RING * 2, all);
        for (int i = 0; i < RING; i++) { qBegin[i] = all[i * 2]; qEnd[i] = all[i * 2 + 1]; }
    }
    return timerSupported ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL JNI(timerBegin)(JNIEnv* env, jclass cls)
{
    if (timerSupported != 1 || zeroFrames >= ZERO_FRAMES_UNUSABLE) return;
    glQueryCounterEXT(qBegin[timerFrame % RING], GL_TIMESTAMP_EXT);
}

JNIEXPORT jfloat JNICALL JNI(timerEnd)(JNIEnv* env, jclass cls)
{
    if (timerSupported != 1) return 0.0f;
    if (zeroFrames >= ZERO_FRAMES_UNUSABLE) return -1.0f;   /* known unusable: no more queries */
    glQueryCounterEXT(qEnd[timerFrame % RING], GL_TIMESTAMP_EXT);
    int old = (timerFrame + 1) % RING;
    GLint available = 0;
    /* The oldest ring slot has only been issued once RING - 1 frames have gone by. */
    if (timerFrame >= RING - 1)
        glGetQueryObjectivEXT(qEnd[old], GL_QUERY_RESULT_AVAILABLE_EXT, &available);
    if (available) {
        GLuint64 b = 0, e = 0;
        glGetQueryObjectui64vEXT(qBegin[old], GL_QUERY_RESULT_EXT, &b);
        glGetQueryObjectui64vEXT(qEnd[old], GL_QUERY_RESULT_EXT, &e);
        GLint disjoint = 0;
        glGetIntegerv(GL_GPU_DISJOINT_EXT, &disjoint);
        if (!disjoint) {
            /* Some drivers (Mali-G52 r49) latch timestamps once per frame, so begin == end and
               the occasional non-zero reading is just one vsync interval. Such a timer cannot
               measure GPU time; after ZERO_FRAMES_UNUSABLE such frames report it as unusable. */
            if (e == b) zeroFrames++;
            else lastGpuMs = (float)((double)(e - b) / 1e6);
        }
    }
    timerFrame++;
    return zeroFrames >= ZERO_FRAMES_UNUSABLE ? -1.0f : lastGpuMs;
}
