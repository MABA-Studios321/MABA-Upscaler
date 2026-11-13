// MABA Upscaler - C# port of the dynamic controller in maba_upscaler.h.
// Kept line-for-line in sync; parity-tested against the C header on the host (test/native).
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
namespace Maba
{
    public sealed class MabaController
    {
        public const int RungCount = 29;
        public const int RungMin = 0, RungMax = RungCount - 1;

        public const int ModeDynamic = 0, ModeUltraQuality = 1, ModeQuality = 2,
            ModeBalanced = 3, ModePerformance = 4;

        public const int StartRung = 10;
        public const float OverRatio = 1.02f;
        public const int DownFrames = 20, UpFrames = 180, UpFramesMax = 3600, ProvenFrames = 300;

        public int Mode;
        public float TargetMs;
        public int Rung;
        public float AvgMs;
        public int OverFrames, GoodFrames, UpWait;
        public bool Probing;

        public MabaController(int mode, float targetFps)
        {
            TargetMs = 1000f / (targetFps > 1f ? targetFps : 60f);
            SetMode(mode);
        }

        public static float RungScale(int rung)
        {
            return (rung <= 9) ? (50 + rung) * 0.01f : (49 + rung) * 0.01f;
        }

        public static bool RungQuality(int rung) { return rung >= 10; }

        public static int ModeRung(int mode)
        {
            switch (mode)
            {
                case ModeUltraQuality: return 28;
                case ModeQuality: return 18;
                case ModeBalanced: return 10;
                case ModePerformance: return 0;
                default: return StartRung;
            }
        }

        public float Scale { get { return RungScale(Rung); } }
        public bool QualityShader { get { return RungQuality(Rung); } }

        public void SetMode(int mode)
        {
            Mode = mode;
            Rung = ModeRung(mode);
            AvgMs = 0f;
            OverFrames = 0;
            GoodFrames = 0;
            UpWait = UpFrames;
            Probing = false;
        }

        public void SetTargetFps(float fps)
        {
            TargetMs = 1000f / (fps > 1f ? fps : 60f);
            AvgMs = 0f;
            OverFrames = 0;
            GoodFrames = 0;
            Probing = false;
        }

        public void SeedRung(int rung)
        {
            Rung = (rung < RungMin ? RungMin : (rung > RungMax ? RungMax : rung));
            AvgMs = 0f;
            OverFrames = 0;
            GoodFrames = 0;
            Probing = false;
        }

        public void UpdateDynamic(float frameMs)
        {
            if (frameMs <= 0f || frameMs > 1000f) return;
            AvgMs = AvgMs <= 0f ? frameMs : AvgMs + (frameMs - AvgMs) * 0.1f;
            if (AvgMs > TargetMs * OverRatio)
            {
                GoodFrames = 0;
                if (++OverFrames >= DownFrames && Rung > RungMin)
                {
                    Rung--;
                    OverFrames = 0;
                    AvgMs = TargetMs;
                    if (Probing)
                    {
                        UpWait = System.Math.Min(UpWait * 2, UpFramesMax);
                        Probing = false;
                    }
                }
            }
            else
            {
                OverFrames = 0;
                GoodFrames++;
                if (Probing && GoodFrames >= ProvenFrames)
                {
                    Probing = false;
                    UpWait = System.Math.Max(UpFrames, UpWait / 2);
                }
                if (!Probing && GoodFrames >= UpWait && Rung < RungMax)
                {
                    Rung++;
                    GoodFrames = 0;
                    Probing = true;
                }
            }
        }

        public int BeginFrame(float lastFrameMs)
        {
            if (Mode == ModeDynamic) UpdateDynamic(lastFrameMs);
            return Rung;
        }
    }
}