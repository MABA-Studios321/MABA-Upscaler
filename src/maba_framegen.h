/*==============================================================================================
  MABA Frame Gen (2x) - slot policy and honest frame counters (C99 / C++, header only)

  Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
  SPDX-License-Identifier: Apache-2.0

  Companion to maba_framegen.frag.glsl. MABA Frame Gen shows TWO frames for every REAL frame the
  game renders: the real frame, then one generated frame that extrapolates it forward by half a
  real-frame interval using per-pixel motion vectors and depth. Because the generated frame is
  predicted FORWARD from the newest real frame (not interpolated between two real frames), no
  real frame is ever held back, so frame generation adds no waiting latency.

  FRAME LOOP
      MabaFrameGen fg;  MabaFgInit(&fg);  MabaFgSetEnabled(&fg, 1);

      // Every frame the platform asks for (once per vsync):
      MabaFgSlot slot = MabaFgNextSlot(&fg);
      if (slot == MABA_FG_REAL)
      {
          // render the scene at render resolution into the next ping-pong slot, writing colour,
          // depth and per-pixel motion vectors (UV units, previous real frame -> this one)
      }
      else
      {
          // run the warp pass of maba_framegen.frag.glsl (one full-screen pass at render
          // resolution) on the last real frame, offset by MABA_FG_GEN_OFFSET of one real-frame
          // interval
      }
      // upscale to the screen with maba_upscaler.frag.glsl, draw the UI, present, then:
      int rolled = MabaFgPresented(&fg, slot, nowMs);   // nowMs: any monotonic clock
      if (rolled) show fg.realFps / fg.generatedFps / fg.displayedFps   // updates once per second

  HONEST COUNTERS
      Every counter counts frames actually handed to the platform for presentation, over a
      one-second window, and is only published when that window completes - there is no
      smoothing and no multiplication. displayedFps is real + generated frames per second, which
      is what a 60 Hz panel is physically able to show; it can never exceed the panel's refresh
      rate. With frame generation off every frame is real and displayedFps == realFps.

  CAMERA CUTS
      Call MabaFgInvalidate() on cuts, teleports, resolution changes and scene loads: the next
      frame is real and no frame is extrapolated from stale motion vectors.
==============================================================================================*/
#ifndef MABA_FRAMEGEN_H
#define MABA_FRAMEGEN_H

#ifdef __cplusplus
extern "C" {
#endif

/* How far ahead of the real frame the generated frame is predicted, as a fraction of the real
   frame interval. 0.5 = halfway to the next real frame; assumes evenly paced real frames. */
#define MABA_FG_GEN_OFFSET 0.5f
/* Length of the counting window; counters are published once per window. */
#define MABA_FG_WINDOW_MS  1000.0

typedef enum MabaFgSlot
{
    MABA_FG_REAL = 0,
    MABA_FG_GENERATED = 1
} MabaFgSlot;

typedef struct MabaFrameGen
{
    int    enabled;
    int    nextSlot;           /* MabaFgSlot to produce next while enabled */
    int    haveReal;           /* a real frame exists to extrapolate from */
    double windowStartMs;      /* < 0 until the first presented frame */
    int    windowReal;         /* frames presented in the current window */
    int    windowGenerated;
    float  realFps;            /* last completed window */
    float  generatedFps;
    float  displayedFps;
    int    statsValid;         /* 1 once a full window has completed */
} MabaFrameGen;

static inline void MabaFgResetStats(MabaFrameGen* g)
{
    g->windowStartMs = -1.0;
    g->windowReal = 0;
    g->windowGenerated = 0;
    g->realFps = 0.0f;
    g->generatedFps = 0.0f;
    g->displayedFps = 0.0f;
    g->statsValid = 0;
}

static inline void MabaFgInit(MabaFrameGen* g)
{
    g->enabled = 0;
    g->nextSlot = MABA_FG_REAL;
    g->haveReal = 0;
    MabaFgResetStats(g);
}

/* Turn frame generation on or off. Restarts the counters so a window never mixes both states. */
static inline void MabaFgSetEnabled(MabaFrameGen* g, int enabled)
{
    g->enabled = enabled ? 1 : 0;
    g->nextSlot = MABA_FG_REAL;
    g->haveReal = 0;
    MabaFgResetStats(g);
}

/* Camera cut / resolution change: the next frame is real; stats keep running. */
static inline void MabaFgInvalidate(MabaFrameGen* g)
{
    g->nextSlot = MABA_FG_REAL;
    g->haveReal = 0;
}

/* Which kind of frame to produce next. Without a valid real frame it is always REAL. */
static inline MabaFgSlot MabaFgNextSlot(const MabaFrameGen* g)
{
    if (!g->enabled || !g->haveReal) return MABA_FG_REAL;
    return (MabaFgSlot)g->nextSlot;
}

/* Record that a frame of the given kind was handed to the platform for presentation.
   Returns 1 when a one-second window just completed (the published fps values changed). */
static inline int MabaFgPresented(MabaFrameGen* g, MabaFgSlot slot, double nowMs)
{
    double elapsed;
    if (slot == MABA_FG_REAL)
    {
        g->haveReal = 1;
        g->nextSlot = g->enabled ? MABA_FG_GENERATED : MABA_FG_REAL;
    }
    else
    {
        g->nextSlot = MABA_FG_REAL;
    }

    if (g->windowStartMs < 0.0)
    {
        /* This frame only marks the start of the first window; counting begins after it. */
        g->windowStartMs = nowMs;
        g->windowReal = 0;
        g->windowGenerated = 0;
        return 0;
    }
    if (slot == MABA_FG_REAL) g->windowReal++; else g->windowGenerated++;

    elapsed = nowMs - g->windowStartMs;
    if (elapsed < MABA_FG_WINDOW_MS) return 0;

    g->realFps = (float)((double)g->windowReal * 1000.0 / elapsed);
    g->generatedFps = (float)((double)g->windowGenerated * 1000.0 / elapsed);
    g->displayedFps = g->realFps + g->generatedFps;
    g->statsValid = 1;
    g->windowStartMs = nowMs;   /* this frame starts the next window */
    g->windowReal = 0;
    g->windowGenerated = 0;
    return 1;
}

#ifdef __cplusplus
}
#endif
#endif /* MABA_FRAMEGEN_H */
