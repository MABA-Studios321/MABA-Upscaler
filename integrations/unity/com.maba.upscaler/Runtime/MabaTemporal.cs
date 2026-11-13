// MABA-Upscaler 2 (Temporal) - C# port of maba_temporal.h (Halton jitter + reset state).
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
namespace Maba
{
    public sealed class MabaTemporal
    {
        public const int Phases = 16;

        public int Phase;
        public bool ResetNext;
        public float HistoryWeight, DepthTolerance, ClipGamma;

        public MabaTemporal(float historyWeight = 0.9f, float depthTolerance = 0.01f, float clipGamma = 1.25f)
        {
            // Same validation as MabaTemporalInit in maba_temporal.h.
            HistoryWeight = (historyWeight > 0f && historyWeight < 1f) ? historyWeight : 0.9f;
            DepthTolerance = depthTolerance > 0f ? depthTolerance : 0.01f;
            ClipGamma = clipGamma > 0f ? clipGamma : 1.25f;
            Reset();
        }

        public void Reset()
        {
            ResetNext = true;
            Phase = 0;
        }

        public static float Halton(int index, int baseNum)
        {
            float f = 1f, r = 0f;
            while (index > 0)
            {
                f /= baseNum;
                r += f * (index % baseNum);
                index /= baseNum;
            }
            return r;
        }

        public struct Frame
        {
            public float JitterX, JitterY;
            public bool Reset;
            public int Phase;
        }

        public Frame BeginFrame()
        {
            Frame f;
            f.Phase = Phase;
            f.Reset = ResetNext;
            ResetNext = false;
            f.JitterX = Halton(Phase + 1, 2) - 0.5f;
            f.JitterY = Halton(Phase + 1, 3) - 0.5f;
            Phase = (Phase + 1) % Phases;
            return f;
        }
    }
}