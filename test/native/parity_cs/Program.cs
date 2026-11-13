// Host parity runner: same deterministic trace as test_controller.c, through the Unity C#
// controller. Output format matches the C trace so the two can be diffed.
// Run: dotnet run --project test/native/parity_cs > trace_cs.txt
using Maba;

class Program
{
    static ulong lcg = 12345UL;

    static float NextFrameMs()
    {
        lcg = lcg * 6364136223846793005UL + 1442695040888963407UL;
        uint r = (uint)(lcg >> 33);
        return 8f + (r % 25u);
    }

    static void Main()
    {
        var u = new MabaController(MabaController.ModeDynamic, 60f);
        var sb = new System.Text.StringBuilder(1 << 20);
        for (int i = 0; i < 20000; i++)
        {
            float ms = (i % 500 == 499) ? 2000f : NextFrameMs();
            int rung = u.BeginFrame(ms);
            int w = System.Math.Max(2, (int)System.Math.Round(1541 * MabaController.RungScale(rung), System.MidpointRounding.AwayFromZero));
            int h = System.Math.Max(2, (int)System.Math.Round(720 * MabaController.RungScale(rung), System.MidpointRounding.AwayFromZero));
            sb.Append(i).Append(' ').Append(rung).Append(' ').Append(w).Append(' ').Append(h).Append('\n');
        }
        sb.Append("final ").Append(u.Rung).Append(' ').Append(u.OverFrames).Append(' ')
          .Append(u.GoodFrames).Append(' ').Append(u.UpWait).Append(' ')
          .Append(u.Probing ? 1 : 0).Append('\n');
        System.Console.Write(sb);
    }
}