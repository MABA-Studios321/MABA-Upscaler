package com.maba.upscalertest;

import android.app.Activity;
import android.graphics.Color;
import android.opengl.GLES30;
import android.opengl.GLSurfaceView;
import android.os.Bundle;
import android.util.Log;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.TextView;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.util.Locale;

import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.opengles.GL10;

/**
 * Test bed for the MABA Upscaler quality modes.
 *
 * Renders a procedural scene at a reduced resolution into a region of a fixed-size texture and
 * upscales it to the screen. Tap to switch mode: Dynamic (default), Ultra Quality, Quality,
 * Balanced, Performance, plain bilinear, and native resolution.
 *
 * At start-up it calibrates the scene's per-pixel cost and measures every mode off-screen, so
 * the display's 60 Hz cap does not apply. The Dynamic controller is a line-for-line port of
 * MabaUpdateDynamic() in maba_upscaler.h.
 *
 * Intent extras: "mode" (0-6), "anim" (0/1), "loadmul" (float, scales the calibrated scene cost).
 * Results are written to logcat with the tag MABA.
 */
public class MainActivity extends Activity implements GLSurfaceView.Renderer {
    private static final String TAG = "MABA";

    // Quality levels, as in maba_upscaler.h.
    private static final float[] LEVEL_SCALE = {0.50f, 0.59f, 0.59f, 0.67f, 0.77f};
    private static final boolean[] LEVEL_QUALITY = {false, false, true, true, true};
    private static final String[] LEVEL_NAMES = {
        "Performance (0.50, fast)", "Balanced-lite (0.59, fast)", "Balanced (0.59, quality)",
        "Quality (0.67, quality)", "Ultra Quality (0.77, quality)"
    };
    private static final int LEVEL_COUNT = 5;

    private static final int DYNAMIC = 0, BILINEAR = 5, NATIVE = 6, MODE_COUNT = 7;
    private static final String[] MODE_NAMES = {
        "Dynamic", "Ultra Quality", "Quality", "Balanced", "Performance",
        "Bilinear 0.59 (no MABA)", "Native resolution"
    };
    private static final int[] MODE_LEVEL = {2, 4, 3, 2, 0, 1, -1};

    // Dynamic controller tuning, as in maba_upscaler.h.
    private static final float TARGET_MS = 1000f / 60f;
    private static final float OVER_RATIO = 1.02f;
    private static final int DOWN_FRAMES = 20, UP_FRAMES = 180, UP_FRAMES_MAX = 3600, PROVEN_FRAMES = 300;

    private static final int FRAME_PASSES = 12;
    private static final double CALIBRATION_MS = 13.0;   // 0.59 + bilinear, before loadmul

    private TextView label;
    private volatile int mode = DYNAMIC;
    private volatile boolean modeChanged = true;
    private boolean anim = true;
    private float loadMul = 1f;

    private int progScene, progBlit, progFast, progQuality;
    private final int[] fbo = new int[2];   // 0 = scene (largest render size), 1 = output size
    private final int[] tex = new int[2];
    private final int[] vao = new int[1];
    private int outW, outH, texW, texH;
    private int load;
    private String glInfo = "";

    // Dynamic controller state.
    private int level = 2, overFrames, goodFrames, upWait = UP_FRAMES;
    private float avgMs;
    private boolean probing;

    private int frame;
    private boolean benchDone;
    private String benchText = "benchmark pending...";
    private long startNanos, lastNanos, fpsNanos;
    private int fpsFrames;
    private double fps;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        mode = Math.max(0, Math.min(MODE_COUNT - 1, getIntent().getIntExtra("mode", DYNAMIC)));
        anim = getIntent().getIntExtra("anim", 1) != 0;
        loadMul = getIntent().getFloatExtra("loadmul", 1f);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        GLSurfaceView view = new GLSurfaceView(this);
        view.setEGLContextClientVersion(3);
        view.setRenderer(this);
        view.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                mode = (mode + 1) % MODE_COUNT;
                modeChanged = true;
            }
        });

        label = new TextView(this);
        label.setTextColor(Color.WHITE);
        label.setTextSize(10f);
        label.setShadowLayer(3f, 1f, 1f, Color.BLACK);
        label.setPadding(16, 8, 16, 8);

        FrameLayout root = new FrameLayout(this);
        root.addView(view);
        root.addView(label, new FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT));
        setContentView(root);
        view.setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN
            | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
    }

    // ---------------------------------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------------------------------

    private String asset(String name) {
        try (InputStream in = getAssets().open(name)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            return out.toString("UTF-8");
        } catch (Exception e) {
            throw new RuntimeException("missing asset " + name, e);
        }
    }

    private int shader(int type, String src, String name) {
        int s = GLES30.glCreateShader(type);
        GLES30.glShaderSource(s, src);
        GLES30.glCompileShader(s);
        int[] ok = new int[1];
        GLES30.glGetShaderiv(s, GLES30.GL_COMPILE_STATUS, ok, 0);
        if (ok[0] == 0) {
            Log.e(TAG, "compile failed: " + name + "\n" + GLES30.glGetShaderInfoLog(s));
            GLES30.glDeleteShader(s);
            return 0;
        }
        return s;
    }

    private int program(String header, String vert, String frag, String name) {
        int vs = shader(GLES30.GL_VERTEX_SHADER, header + vert, name + ".vert");
        int fs = shader(GLES30.GL_FRAGMENT_SHADER, header + frag, name + ".frag");
        if (vs == 0 || fs == 0) return 0;
        int p = GLES30.glCreateProgram();
        GLES30.glAttachShader(p, vs);
        GLES30.glAttachShader(p, fs);
        GLES30.glLinkProgram(p);
        int[] ok = new int[1];
        GLES30.glGetProgramiv(p, GLES30.GL_LINK_STATUS, ok, 0);
        if (ok[0] == 0) {
            Log.e(TAG, "link failed: " + name + "\n" + GLES30.glGetProgramInfoLog(p));
            return 0;
        }
        GLES30.glUseProgram(p);
        GLES30.glUniform1i(GLES30.glGetUniformLocation(p, "uMabaInput"), 0);
        return p;
    }

    @Override
    public void onSurfaceCreated(GL10 unused, EGLConfig config) {
        String version = GLES30.glGetString(GLES30.GL_VERSION);
        boolean es31 = version != null && (version.contains("ES 3.1") || version.contains("ES 3.2"));
        glInfo = GLES30.glGetString(GLES30.GL_RENDERER) + " | " + version;
        Log.i(TAG, "GL: " + glInfo);

        String vert = asset("maba_upscaler.vert.glsl");
        String maba = asset("maba_upscaler.frag.glsl");
        String h30 = "#version 300 es\n";
        String h31 = "#version 310 es\n";

        progScene = program(h30, vert, asset("scene.frag.glsl"), "scene");
        progBlit = program(h30, vert, asset("blit.frag.glsl"), "blit");
        if (es31) {
            progFast = program(h31 + "#define MABA_GATHER 1\n", vert, maba, "maba-fast");
            progQuality = program(h31 + "#define MABA_GATHER 1\n#define MABA_QUALITY 1\n",
                vert, maba, "maba-quality");
        }
        // OpenGL ES 3.0 devices use the gather-free build for every level.
        if (progFast == 0) progFast = program(h30 + "#define MABA_GATHER 0\n", vert, maba, "maba-es30");
        if (progQuality == 0) progQuality = progFast;

        GLES30.glGenVertexArrays(1, vao, 0);
        GLES30.glDisable(GLES30.GL_DEPTH_TEST);
        GLES30.glDisable(GLES30.GL_BLEND);
        startNanos = System.nanoTime();
    }

    private void target(int i, int w, int h) {
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, tex[i]);
        GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8, w, h, 0,
            GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, null);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE);
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fbo[i]);
        GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0,
            GLES30.GL_TEXTURE_2D, tex[i], 0);
    }

    @Override
    public void onSurfaceChanged(GL10 unused, int width, int height) {
        outW = width;
        outH = height;
        // Allocated once at the largest level; lower levels render into a region of it.
        texW = Math.round(width * LEVEL_SCALE[LEVEL_COUNT - 1]);
        texH = Math.round(height * LEVEL_SCALE[LEVEL_COUNT - 1]);
        Log.i(TAG, "output " + outW + "x" + outH + ", scene texture " + texW + "x" + texH);
        if (tex[0] == 0) {
            GLES30.glGenTextures(2, tex, 0);
            GLES30.glGenFramebuffers(2, fbo, 0);
        }
        target(0, texW, texH);
        target(1, outW, outH);
    }

    // ---------------------------------------------------------------------------------------
    // Drawing
    // ---------------------------------------------------------------------------------------

    private void pass(int program, int srcTex, int dstFbo, int w, int h) {
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, dstFbo);
        GLES30.glViewport(0, 0, w, h);
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT);
        GLES30.glUseProgram(program);
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0);
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, srcTex);
        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3);
    }

    private void drawScene(int dstFbo, int w, int h, float time) {
        GLES30.glUseProgram(progScene);
        GLES30.glUniform2f(GLES30.glGetUniformLocation(progScene, "uRes"), w, h);
        GLES30.glUniform1f(GLES30.glGetUniformLocation(progScene, "uTime"), time);
        GLES30.glUniform1i(GLES30.glGetUniformLocation(progScene, "uLoad"), load);
        pass(progScene, 0, dstFbo, w, h);
    }

    /** Scene at the level's scale into a region of the scene texture, then the upscale. */
    private void drawUpscaled(int lvl, boolean bilinear, int dstFbo, float time) {
        int w = Math.max(2, Math.round(outW * LEVEL_SCALE[lvl]));
        int h = Math.max(2, Math.round(outH * LEVEL_SCALE[lvl]));
        drawScene(fbo[0], w, h, time);
        int p = bilinear ? progBlit : (LEVEL_QUALITY[lvl] ? progQuality : progFast);
        GLES30.glUseProgram(p);
        GLES30.glUniform4f(GLES30.glGetUniformLocation(p, "uMabaInputSize"), w, h, 1f / texW, 1f / texH);
        GLES30.glUniform4f(GLES30.glGetUniformLocation(p, "uMabaParams"), 0.5f, 0f, 0f, 0f);
        pass(p, tex[0], dstFbo, outW, outH);
    }

    private void drawMode(int m, int lvl, int dstFbo, float time) {
        if (m == NATIVE) drawScene(dstFbo, outW, outH, time);
        else drawUpscaled(lvl, m == BILINEAR, dstFbo, time);
    }

    // ---------------------------------------------------------------------------------------
    // Dynamic controller (port of MabaUpdateDynamic in maba_upscaler.h)
    // ---------------------------------------------------------------------------------------

    private void resetDynamic() {
        level = 2;
        avgMs = 0f;
        overFrames = 0;
        goodFrames = 0;
        upWait = UP_FRAMES;
        probing = false;
    }

    private void updateDynamic(float frameMs) {
        if (frameMs <= 0f || frameMs > 1000f) return;
        avgMs = avgMs <= 0f ? frameMs : avgMs + (frameMs - avgMs) * 0.1f;
        int before = level;
        if (avgMs > TARGET_MS * OVER_RATIO) {
            goodFrames = 0;
            if (++overFrames >= DOWN_FRAMES && level > 0) {
                level--;
                overFrames = 0;
                avgMs = TARGET_MS;
                if (probing) {
                    upWait = Math.min(upWait * 2, UP_FRAMES_MAX);
                    probing = false;
                }
            }
        } else {
            overFrames = 0;
            goodFrames++;
            if (probing && goodFrames >= PROVEN_FRAMES) {
                probing = false;
                upWait = Math.max(UP_FRAMES, upWait / 2);
            }
            if (!probing && goodFrames >= upWait && level < LEVEL_COUNT - 1) {
                level++;
                goodFrames = 0;
                probing = true;
            }
        }
        if (level != before) {
            Log.i(TAG, String.format(Locale.US, "DYNAMIC %s -> %s (next step-up wait %d frames)",
                LEVEL_NAMES[before], LEVEL_NAMES[level], upWait));
        }
    }

    // ---------------------------------------------------------------------------------------
    // Off-screen benchmark
    // ---------------------------------------------------------------------------------------

    private double benchFrame(int m, int lvl) {
        for (int i = 0; i < 3; i++) drawMode(m, lvl, fbo[1], 20f);
        GLES30.glFinish();
        long t = System.nanoTime();
        for (int i = 0; i < FRAME_PASSES; i++) {
            drawMode(m, lvl, fbo[1], 20f);
            GLES30.glFinish();
        }
        return (System.nanoTime() - t) / 1e6 / FRAME_PASSES;
    }

    private void runBenchmark() {
        // Calibrate the scene's per-pixel cost so 0.59 + bilinear takes CALIBRATION_MS.
        load = 0;
        double t0 = benchFrame(BILINEAR, 1);
        load = 64;
        double t64 = benchFrame(BILINEAR, 1);
        double perUnit = Math.max(1e-4, (t64 - t0) / 64.0);
        load = (int) Math.max(0, Math.min(4000, Math.round((CALIBRATION_MS - t0) / perUnit * loadMul)));
        Log.i(TAG, String.format(Locale.US, "calibration: load=%d (loadmul %.2f)", load, loadMul));

        int[] modes = {NATIVE, 1, 2, 3, DYNAMIC, 4, BILINEAR};   // DYNAMIC slot = level 1
        int[] levels = {-1, 4, 3, 2, 1, 0, 1};
        String[] names = {"Native resolution", LEVEL_NAMES[4], LEVEL_NAMES[3], LEVEL_NAMES[2],
                          LEVEL_NAMES[1], LEVEL_NAMES[0], "Bilinear 0.59 (no MABA)"};
        double[] ms = new double[modes.length];
        for (int round = 0; round < 2; round++) {
            for (int i = 0; i < modes.length; i++) {
                double t = benchFrame(modes[i], levels[i]);
                if (round == 0 || t < ms[i]) ms[i] = t;
            }
        }
        StringBuilder sb = new StringBuilder(
            String.format(Locale.US, "Off-screen, uncapped, scene load %d:", load));
        for (int i = 0; i < modes.length; i++) {
            String line = String.format(Locale.US, "%s: %.1f fps (%.1f ms, %+.0f%% vs native)",
                names[i], 1000.0 / ms[i], ms[i], (ms[0] / ms[i] - 1.0) * 100.0);
            Log.i(TAG, "FRAME " + line);
            sb.append("\n  ").append(line);
        }
        benchText = sb.toString();
    }

    @Override
    public void onDrawFrame(GL10 unused) {
        GLES30.glBindVertexArray(vao[0]);
        frame++;
        if (!benchDone && frame == 90) {
            runBenchmark();
            benchDone = true;
            modeChanged = true;
        }

        long now = System.nanoTime();
        float frameMs = (now - lastNanos) / 1e6f;
        lastNanos = now;
        int m = mode;
        if (modeChanged) {
            modeChanged = false;
            resetDynamic();
            fpsFrames = 0;
        } else if (m == DYNAMIC && benchDone) {
            updateDynamic(frameMs);
        }
        int lvl = m == DYNAMIC ? level : MODE_LEVEL[m];
        drawMode(m, lvl, 0, anim ? (now - startNanos) / 1e9f : 20f);

        if (fpsFrames == 0) fpsNanos = now;
        fpsFrames++;
        if (fpsFrames > 120) {
            fps = (fpsFrames - 1) * 1e9 / (now - fpsNanos);
            Log.i(TAG, String.format(Locale.US, "ONSCREEN %s%s = %.1f fps", MODE_NAMES[m],
                m == DYNAMIC ? " [" + LEVEL_NAMES[lvl] + "]" : "", fps));
            fpsFrames = 0;
        }
        if (frame % 30 == 0) {
            final String text = String.format(Locale.US,
                "%s%s   |   %.0f fps on screen (60 Hz cap)   |   output %dx%d   |   tap to switch\n%s\n%s",
                MODE_NAMES[m], m == DYNAMIC ? "  ->  now " + LEVEL_NAMES[lvl] : "",
                fps, outW, outH, benchText, glInfo);
            runOnUiThread(new Runnable() {
                @Override public void run() { label.setText(text); }
            });
        }
    }
}
