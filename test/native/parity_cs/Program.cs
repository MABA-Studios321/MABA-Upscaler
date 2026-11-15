// Host parity runner: same deterministic trace as test_controller.c, through the Unity C#
// controller. Output format matches the C trace so the two can be diffed.
// Run: dotnet run --project test/native/parity_cs > trace_cs.txt
using Maba;

class Program
{
    static ulong lcg = 12345UL;

    static float NextFrameMs(float basems, uint span)
    {
        lcg = lcg * 6364136223846793005UL + 1442695040888963407UL;
        uint r = (uint)(lcg >> 33);
        return basems + (r % span);
    }

    // Frame times are basems .. basems + span - 1 ms; every 500th frame is a 2 s loading hitch.
    static void Frames(MabaController u, System.Text.StringBuilder sb, int from, int to, float basems, uint span)
    {
        for (int i = from; i < to; i++)
        {
            float ms = (i % 500 == 499) ? 2000f : NextFrameMs(basems, span);
            int rung = u.BeginFrame(ms);
            int w = System.Math.Max(2, (int)System.Math.Round(1541 * MabaController.RungScale(rung), System.MidpointRounding.AwayFromZero));
            int h = System.Math.Max(2, (int)System.Math.Round(720 * MabaController.RungScale(rung), System.MidpointRounding.AwayFromZero));
            sb.Append(i).Append(' ').Append(rung).Append(' ').Append(w).Append(' ').Append(h).Append('\n');
        }
    }

    static void Main()
    {
        var u = new MabaController(MabaController.ModeDynamic, 60f);
        var sb = new System.Text.StringBuilder(1 << 20);
        Frames(u, sb, 0, 20000, 8f, 25u);        // the whole ladder, 8..32 ms: mostly over budget
        u.SetScaleRange(0.50f, 0.77f);           // then the classic range, mid-run
        Frames(u, sb, 20000, 25000, 8f, 25u);
        u.SetScaleRange(0.35f, 1.00f);           // then the whole ladder again, in three load phases:
        Frames(u, sb, 25000, 30000, 3f, 17u);    //   spare time (3..19 ms): climbs and jumps
        Frames(u, sb, 30000, 36000, 14f, 21u);   //   load rises (14..34 ms): probes fail, steps down
        Frames(u, sb, 36000, 45000, 3f, 17u);    //   spare time again: climbs under the back-off
        // bursts: 400 light frames (a jump) then 400 heavy ones, inside the jump's proof window,
        // so failed jumps return to where they started
        for (int k = 0; k < 25; k++)
            Frames(u, sb, 45000 + k * 400, 45000 + (k + 1) * 400,
                   (k % 2 == 0) ? 3f : 20f, (k % 2 == 0) ? 17u : 20u);
        sb.Append("final ").Append(u.Rung).Append(' ').Append(u.OverFrames).Append(' ')
          .Append(u.GoodFrames).Append(' ').Append(u.UpWait).Append(' ')
          .Append(u.Probing ? 1 : 0).Append(' ').Append(u.ProbeFrom).Append('\n');
        System.Console.Write(sb);
    }
}
