package com.maba.upscalertest;

/**
 * Host-side parity runner: feeds the same deterministic trace as test_controller.c (trace mode)
 * through the Java controller and prints the identical format, so the outputs can be diffed.
 *
 * Build/run (JDK 11+):
 *   javac -d out src/com/maba/upscalertest/MabaController.java src/com/maba/upscalertest/Parity.java
 *   java -cp out com.maba.upscalertest.Parity > trace_java.txt
 *   diff trace_c.txt trace_java.txt
 */
public final class Parity {
    private static long lcgState = 12345L;

    private static float nextFrameMs() {
        lcgState = lcgState * 6364136223846793005L + 1442695040888963407L;
        int r = (int) (lcgState >>> 33);
        return 8f + (r % 25);
    }

    public static void main(String[] args) {
        MabaController u = new MabaController(MabaController.MODE_DYNAMIC, 60f);
        StringBuilder sb = new StringBuilder(1 << 20);
        for (int i = 0; i < 20000; i++) {
            float ms = (i % 500 == 499) ? 2000f : nextFrameMs();
            int rung = u.beginFrame(ms);
            int w = Math.max(2, Math.round(1541 * MabaController.rungScale(rung)));
            int h = Math.max(2, Math.round(720 * MabaController.rungScale(rung)));
            sb.append(i).append(' ').append(rung).append(' ').append(w).append(' ').append(h).append('\n');
        }
        sb.append("final ").append(u.rung).append(' ').append(u.overFrames).append(' ')
          .append(u.goodFrames).append(' ').append(u.upWait).append(' ')
          .append(u.probing ? 1 : 0).append('\n');
        System.out.print(sb);
    }
}