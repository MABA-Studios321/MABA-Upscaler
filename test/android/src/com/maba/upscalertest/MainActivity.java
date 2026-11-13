package com.maba.upscalertest;

import android.app.Activity;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.opengl.GLES30;
import android.opengl.GLSurfaceView;
import android.os.Build;
import android.os.Bundle;
import android.os.PowerManager;
import android.util.Log;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.SeekBar;
import android.widget.TextView;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.util.Locale;

import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.opengles.GL10;

/**
 * MABA Upscaler test bed - "MABA Core" 3D scene.
 *
 * Renders a real 3D scene (striped torus knot, thin emissive spokes, grid floor, orbiting
 * camera) at a reduced resolution and upscales it with MABA. Tap cycles modes; long-press
 * opens settings (sharpness, target fps). Modes: Dynamic, Ultra Quality, Quality, Balanced,
 * Performance, Bilinear, Native, and MABA-Upscaler 2 (Temporal) dynamic.
 *
 * Dynamic mode is driven by GPU timer queries when available (EXT_disjoint_timer_query), so it
 * sees headroom under vsync. The thermal API lowers the target to 30 fps when the device
 * throttles. At start-up every mode is benchmarked off-screen; results go to logcat tag MABA.
 *
 * Intent extras:
 *   mode (0-7), anim (0/1), loadmul (float)
 *   dump=1 pattern=N rung=R quality=0/1  -> render a reference pattern, write dump.ppm, exit
 */
public class MainActivity extends Activity implements GLSurfaceView.Renderer {
    private static final String TAG = "MABA";

    private static final int DYNAMIC = 0, BILINEAR = 5, NATIVE = 6, TEMPORAL = 7, MODE_COUNT = 8;
    private static final String[] MODE_NAMES = {
        "Dynamic", "Ultra Quality", "Quality", "Balanced", "Performance",
        "Bilinear 0.59 (no MABA)", "Native resolution", "MABA-Upscaler 2 (Temporal)"
    };
    private static final int[] MODE_RUNG = {10, 28, 18, 10, 0, 9, -1, 10};

    private static final int FRAME_PASSES = 12;
    private static final double CALIBRATION_MS = 13.0;

    private GLSurfaceView glView;
    private Object thermalListener;   // PowerManager.OnThermalStatusChangedListener on API 29+
    private TextView label;
    private LinearLayout settings;
    private SeekBar sharpBar;
    private Button targetBtn;
    private volatile int mode = DYNAMIC;
    private volatile boolean modeChanged = true;
    private boolean anim = true;
    private float loadMul = 1f;
    // Written on the UI thread, read on the GL thread.
    private volatile float sharpness = 0.5f;
    private volatile int userTargetFps = 60;
    private volatile int thermalStatus = 0;
    private volatile boolean targetChanged = true;

    // Dump mode (GPU vs CPU-reference comparison).
    private boolean dumpMode;
    private int dumpPattern, dumpRung, dumpQuality;

    private int progScene, progBg, progBlit, progFast, progQuality, progTemporal, progPattern;
    private final Scene3D scene = new Scene3D();
    private final GpuTimer gpuTimer = new GpuTimer();
    // The real C controller via JNI when the native lib is present; the parity-tested Java
    // port otherwise.
    private final DynController dyn = MabaNative.available()
        ? new MabaNativeController(MabaController.MODE_DYNAMIC, 60f)
        : new MabaController(MabaController.MODE_DYNAMIC, 60f);
    private final MabaTemporal temporal = new MabaTemporal();

    // Render targets. Scene color is single; depth and resolve ping-pong for temporal.
    private final int[] sceneFbo = new int[2];
    private final int[] depthTex = new int[2];
    private final int[] resolveFbo = new int[2];
    private final int[] resolveTex = new int[2];
    private int sceneTex, outFbo, outTex, outDepthTex;
    private final int[] vao = new int[1];
    private int outW, outH, texW, texH;
    private int load;
    private String glInfo = "";

    private int frame, slot, lastRung = -1;
    private float probeMs;
    private int probeCountdown = 60;
    private final Mat4 prevVP = Mat4.identity();   // previous frame's UNJITTERED view-projection
    private boolean havePrevVP;
    private boolean benchDone;
    private String benchText = "benchmark pending...";
    private long startNanos, lastNanos, fpsNanos;
    private int fpsFrames;
    private double fps;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        SharedPreferences prefs = getPreferences(MODE_PRIVATE);
        mode = Math.max(0, Math.min(MODE_COUNT - 1, getIntent().getIntExtra("mode", prefs.getInt("mode", DYNAMIC))));
        anim = getIntent().getIntExtra("anim", 1) != 0;
        loadMul = getIntent().getFloatExtra("loadmul", 1f);
        sharpness = prefs.getFloat("sharpness", 0.5f);
        userTargetFps = prefs.getInt("targetFps", 60);
        dumpMode = getIntent().getIntExtra("dump", 0) == 1;
        dumpPattern = getIntent().getIntExtra("pattern", 0);
        dumpRung = getIntent().getIntExtra("rung", 10);
        dumpQuality = getIntent().getIntExtra("quality", 0);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        GLSurfaceView view = new GLSurfaceView(this);
        glView = view;
        view.setEGLContextClientVersion(3);
        view.setRenderer(this);
        view.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                mode = (mode + 1) % MODE_COUNT;
                modeChanged = true;
                getPreferences(MODE_PRIVATE).edit().putInt("mode", mode).apply();
            }
        });
        view.setOnLongClickListener(new View.OnLongClickListener() {
            @Override public boolean onLongClick(View v) {
                settings.setVisibility(settings.getVisibility() == View.VISIBLE ? View.GONE : View.VISIBLE);
                return true;
            }
        });

        label = new TextView(this);
        label.setTextColor(Color.WHITE);
        label.setTextSize(10f);
        label.setShadowLayer(3f, 1f, 1f, Color.BLACK);
        label.setPadding(16, 8, 16, 8);

        settings = buildSettingsPanel();

        FrameLayout root = new FrameLayout(this);
        root.addView(view);
        root.addView(label, new FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT));
        FrameLayout.LayoutParams sp = new FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT);
        sp.gravity = android.view.Gravity.BOTTOM | android.view.Gravity.CENTER_HORIZONTAL;
        sp.bottomMargin = 24;
        root.addView(settings, sp);
        setContentView(root);
        view.setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN
            | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);

        if (Build.VERSION.SDK_INT >= 29) {
            PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
            PowerManager.OnThermalStatusChangedListener l = new PowerManager.OnThermalStatusChangedListener() {
                @Override public void onThermalStatusChanged(int status) {
                    thermalStatus = status;
                    applyTargetFps();
                    Log.i(TAG, "THERMAL status=" + status + " target=" + effectiveTargetFps() + "fps");
                }
            };
            pm.addThermalStatusListener(getMainExecutor(), l);
            thermalListener = l;
        }
    }

    // GLSurfaceView must be told about the activity lifecycle, or its render thread keeps
    // drawing (and draining the battery) while the app is in the background.
    @Override
    protected void onPause() {
        super.onPause();
        if (glView != null) glView.onPause();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (glView != null) glView.onResume();
    }

    @Override
    protected void onDestroy() {
        if (Build.VERSION.SDK_INT >= 29 && thermalListener != null) {
            PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
            pm.removeThermalStatusListener((PowerManager.OnThermalStatusChangedListener) thermalListener);
            thermalListener = null;
        }
        super.onDestroy();
    }

    private int effectiveTargetFps() {
        return thermalStatus >= 2 ? Math.min(userTargetFps, 30) : userTargetFps;
    }

    /** UI / thermal thread: the controller itself is only ever touched on the GL thread. */
    private void applyTargetFps() {
        targetChanged = true;
    }

    private LinearLayout buildSettingsPanel() {
        LinearLayout panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setBackgroundColor(0xE0202024);
        panel.setPadding(28, 20, 28, 20);
        panel.setVisibility(View.GONE);

        TextView title = new TextView(this);
        title.setText("MABA settings");
        title.setTextColor(Color.WHITE);
        title.setTextSize(13f);
        panel.addView(title);

        TextView sharpLabel = new TextView(this);
        sharpLabel.setTextColor(0xFFCCCCCC);
        sharpLabel.setTextSize(11f);
        sharpLabel.setText("Sharpness");
        panel.addView(sharpLabel);

        sharpBar = new SeekBar(this);
        sharpBar.setMax(100);
        sharpBar.setProgress(Math.round(sharpness * 100));
        sharpBar.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onProgressChanged(SeekBar s, int p, boolean user) {
                sharpness = p / 100f;
                getPreferences(MODE_PRIVATE).edit().putFloat("sharpness", sharpness).apply();
            }
            @Override public void onStartTrackingTouch(SeekBar s) {}
            @Override public void onStopTrackingTouch(SeekBar s) {}
        });
        panel.addView(sharpBar, new LinearLayout.LayoutParams(420, LinearLayout.LayoutParams.WRAP_CONTENT));

        targetBtn = new Button(this);
        targetBtn.setTextSize(11f);
        targetBtn.setText("Target: " + userTargetFps + " fps");
        targetBtn.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                userTargetFps = userTargetFps == 60 ? 30 : 60;
                targetBtn.setText("Target: " + userTargetFps + " fps");
                getPreferences(MODE_PRIVATE).edit().putInt("targetFps", userTargetFps).apply();
                applyTargetFps();
            }
        });
        panel.addView(targetBtn);

        Button close = new Button(this);
        close.setTextSize(11f);
        close.setText("Close");
        close.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { settings.setVisibility(View.GONE); }
        });
        panel.addView(close);
        return panel;
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
        if (vs == 0 || fs == 0) {
            if (vs != 0) GLES30.glDeleteShader(vs);
            if (fs != 0) GLES30.glDeleteShader(fs);
            return 0;
        }
        int p = GLES30.glCreateProgram();
        GLES30.glAttachShader(p, vs);
        GLES30.glAttachShader(p, fs);
        GLES30.glLinkProgram(p);
        int[] ok = new int[1];
        GLES30.glGetProgramiv(p, GLES30.GL_LINK_STATUS, ok, 0);
        // The program keeps what it needs; the shader objects can go either way.
        GLES30.glDeleteShader(vs);
        GLES30.glDeleteShader(fs);
        if (ok[0] == 0) {
            Log.e(TAG, "link failed: " + name + "\n" + GLES30.glGetProgramInfoLog(p));
            GLES30.glDeleteProgram(p);
            return 0;
        }
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

        // A new EGL context invalidates every GL object from the old one.
        progFast = progQuality = progTemporal = 0;
        sceneTex = 0;

        progScene = program(h30, asset("scene3d.vert.glsl"), asset("scene3d.frag.glsl"), "scene3d");
        progBg = program(h30, vert, asset("bg.frag.glsl"), "bg");
        progBlit = program(h30, vert, asset("blit.frag.glsl"), "blit");
        progPattern = program(h30, vert, asset("pattern.frag.glsl"), "pattern");
        if (es31) {
            progFast = program(h31 + "#define MABA_GATHER 1\n", vert, maba, "maba-fast");
            progQuality = program(h31 + "#define MABA_GATHER 1\n#define MABA_QUALITY 1\n#define MABA_HIGHP 1\n",
                vert, maba, "maba-quality");
        }
        if (progFast == 0) progFast = program(h30 + "#define MABA_GATHER 0\n", vert, maba, "maba-es30");
        if (progQuality == 0) progQuality = progFast;
        progTemporal = program(h30, vert, asset("maba_temporal.frag.glsl"), "maba-temporal");
        if (progTemporal == 0) Log.e(TAG, "temporal unavailable; mode 7 falls back to Dynamic");

        GLES30.glGenVertexArrays(1, vao, 0);
        GLES30.glDisable(GLES30.GL_DEPTH_TEST);
        GLES30.glDisable(GLES30.GL_BLEND);
        scene.init();
        gpuTimer.init();
        Log.i(TAG, "GPU timer: " + (gpuTimer.supported ? "EXT_disjoint_timer_query" : "unsupported"));
        // A new context also follows every resume from the background: keep the animation
        // clock running (no camera jump), and restart frame timing so neither the fps counter
        // nor the Dynamic controller sees the paused time as one giant frame.
        if (startNanos == 0) startNanos = System.nanoTime();
        lastNanos = 0;
        fpsFrames = 0;
        fps = 0;
        targetChanged = true;
    }

    private int colorTarget(int w, int h) {
        int[] tex = new int[1];
        GLES30.glGenTextures(1, tex, 0);
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, tex[0]);
        GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8, w, h, 0,
            GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, null);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE);
        return tex[0];
    }

    private int depthTarget(int w, int h) {
        int[] tex = new int[1];
        GLES30.glGenTextures(1, tex, 0);
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, tex[0]);
        GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, 0x81A6 /* DEPTH_COMPONENT24 */, w, h, 0,
            GLES30.GL_DEPTH_COMPONENT, GLES30.GL_UNSIGNED_INT, null);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_NEAREST);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_NEAREST);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE);
        return tex[0];
    }

    private int fboWith(int colorTex, int depthTex) {
        int[] fbo = new int[1];
        GLES30.glGenFramebuffers(1, fbo, 0);
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fbo[0]);
        GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0,
            GLES30.GL_TEXTURE_2D, colorTex, 0);
        if (depthTex != 0) {
            GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_DEPTH_ATTACHMENT,
                GLES30.GL_TEXTURE_2D, depthTex, 0);
        }
        int status = GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER);
        if (status != GLES30.GL_FRAMEBUFFER_COMPLETE) Log.e(TAG, "FBO incomplete: " + status);
        return fbo[0];
    }

    @Override
    public void onSurfaceChanged(GL10 unused, int width, int height) {
        // The surface can change size more than once; drop the previous targets first.
        if (sceneTex != 0) {
            GLES30.glDeleteFramebuffers(2, sceneFbo, 0);
            GLES30.glDeleteFramebuffers(2, resolveFbo, 0);
            GLES30.glDeleteFramebuffers(1, new int[]{outFbo}, 0);
            GLES30.glDeleteTextures(2, depthTex, 0);
            GLES30.glDeleteTextures(2, resolveTex, 0);
            GLES30.glDeleteTextures(3, new int[]{sceneTex, outTex, outDepthTex}, 0);
        }
        outW = width;
        outH = height;
        if (dyn instanceof MabaNativeController) ((MabaNativeController) dyn).setOutSize(width, height);
        texW = Math.round(width * MabaController.rungScale(MabaController.RUNG_MAX));
        texH = Math.round(height * MabaController.rungScale(MabaController.RUNG_MAX));
        Log.i(TAG, "output " + outW + "x" + outH + ", scene texture " + texW + "x" + texH);

        sceneTex = colorTarget(texW, texH);
        for (int i = 0; i < 2; i++) {
            depthTex[i] = depthTarget(texW, texH);
            sceneFbo[i] = fboWith(sceneTex, depthTex[i]);
            resolveTex[i] = colorTarget(texW, texH);
            resolveFbo[i] = fboWith(resolveTex[i], 0);
        }
        // The off-screen output needs its own depth buffer: the Native benchmark renders the 3D
        // scene straight into it, and without one the depth test silently does nothing.
        outTex = colorTarget(outW, outH);
        outDepthTex = depthTarget(outW, outH);
        outFbo = fboWith(outTex, outDepthTex);
        temporal.reset();
        havePrevVP = false;
        lastRung = -1;
    }

    // ---------------------------------------------------------------------------------------
    // Drawing
    // ---------------------------------------------------------------------------------------

    private void fullscreenPass(int prog, int dstFbo, int w, int h) {
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, dstFbo);
        GLES30.glViewport(0, 0, w, h);
        GLES30.glUseProgram(prog);
        GLES30.glBindVertexArray(vao[0]);
        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3);
    }

    /** Camera eye: slow orbit with a gentle dolly in/out and height drift. */
    private static float[] cameraEye(float time) {
        float ang = time * 0.12f + 0.6f;
        // Stays well inside the pillar circle (Scene3D.PILLAR_R minus the plinth size).
        float radius = 4.6f + 0.6f * (float) Math.sin(time * 0.19f);
        float height = 1.0f + 0.55f * (float) Math.sin(time * 0.15f + 1.0f);
        return new float[]{radius * (float) Math.sin(ang), height, radius * (float) Math.cos(ang)};
    }

    private Mat4 cameraVP(float time, int rw, int rh, float jx, float jy) {
        float[] e = cameraEye(time);
        Mat4 view = Mat4.lookAt(e[0], e[1], e[2], 0, 0.05f, 0);
        Mat4 proj = Mat4.perspective(48f * (float) Math.PI / 180f, (float) rw / rh, 0.1f, 40f);
        if (jx != 0f || jy != 0f) proj.applyJitter(jx, jy, rw, rh);
        return Mat4.mul(proj, view);
    }

    /** Background + 3D scene into the scene FBO at region size. */
    private void drawScene3D(int dstFbo, int rw, int rh, float time, Mat4 vp) {
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, dstFbo);
        GLES30.glViewport(0, 0, rw, rh);
        GLES30.glDepthMask(true);
        GLES30.glClear(GLES30.GL_DEPTH_BUFFER_BIT);
        GLES30.glDisable(GLES30.GL_DEPTH_TEST);
        fullscreenPass(progBg, dstFbo, rw, rh);

        GLES30.glEnable(GLES30.GL_DEPTH_TEST);
        GLES30.glDepthFunc(GLES30.GL_LEQUAL);
        GLES30.glUseProgram(progScene);
        GLES30.glUniformMatrix4fv(GLES30.glGetUniformLocation(progScene, "uVP"), 1, false, vp.m, 0);
        float[] eye = cameraEye(time);
        GLES30.glUniform3f(GLES30.glGetUniformLocation(progScene, "uCamPos"), eye[0], eye[1], eye[2]);
        GLES30.glUniform1f(GLES30.glGetUniformLocation(progScene, "uTime"), time);
        GLES30.glUniform1i(GLES30.glGetUniformLocation(progScene, "uLoad"), load);
        scene.draw(progScene, time);
        GLES30.glDisable(GLES30.GL_DEPTH_TEST);
    }

    private void upscale(int srcTex, int prog, int dstFbo, int rw, int rh) {
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, dstFbo);
        GLES30.glViewport(0, 0, outW, outH);
        GLES30.glUseProgram(prog);
        GLES30.glUniform4f(GLES30.glGetUniformLocation(prog, "uMabaInputSize"), rw, rh, 1f / texW, 1f / texH);
        GLES30.glUniform4f(GLES30.glGetUniformLocation(prog, "uMabaParams"), sharpness, 0, 0, 0);
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0);
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, srcTex);
        GLES30.glUniform1i(GLES30.glGetUniformLocation(prog, "uMabaInput"), 0);
        GLES30.glBindVertexArray(vao[0]);
        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3);
    }

    /** Temporal resolve at region size; writes resolveTex[slot]. */
    private void temporalResolve(int rw, int rh, Mat4 invVP, float reset) {
        int prev = 1 - slot;
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, resolveFbo[slot]);
        GLES30.glViewport(0, 0, rw, rh);
        GLES30.glUseProgram(progTemporal);
        int p = progTemporal;
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0);
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, sceneTex);
        GLES30.glUniform1i(GLES30.glGetUniformLocation(p, "uMabaInput"), 0);
        GLES30.glActiveTexture(GLES30.GL_TEXTURE1);
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, resolveTex[prev]);
        GLES30.glUniform1i(GLES30.glGetUniformLocation(p, "uMabaHistory"), 1);
        GLES30.glActiveTexture(GLES30.GL_TEXTURE2);
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, depthTex[slot]);
        GLES30.glUniform1i(GLES30.glGetUniformLocation(p, "uMabaDepth"), 2);
        GLES30.glActiveTexture(GLES30.GL_TEXTURE3);
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, depthTex[prev]);
        GLES30.glUniform1i(GLES30.glGetUniformLocation(p, "uMabaPrevDepth"), 3);
        GLES30.glUniformMatrix4fv(GLES30.glGetUniformLocation(p, "uMabaInvViewProj"), 1, false, invVP.m, 0);
        GLES30.glUniformMatrix4fv(GLES30.glGetUniformLocation(p, "uMabaPrevViewProj"), 1, false, prevVP.m, 0);
        float[] params = temporal.uniforms(new float[]{0, 0, reset, 0});
        GLES30.glUniform4f(GLES30.glGetUniformLocation(p, "uMabaTemporalParams"),
            params[0], params[1], params[2], params[3]);
        GLES30.glUniform2f(GLES30.glGetUniformLocation(p, "uMabaTexel"), 1f / texW, 1f / texH);
        GLES30.glUniform2f(GLES30.glGetUniformLocation(p, "uMabaRegion"), rw, rh);
        GLES30.glBindVertexArray(vao[0]);
        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3);
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0);
    }

    /** One full frame of the given mode into dstFbo. Returns the rung used. */
    private int drawMode(int m, int rung, int dstFbo, float time) {
        if (m == NATIVE) {
            Mat4 vp = cameraVP(time, outW, outH, 0, 0);
            drawScene3D(dstFbo, outW, outH, time, vp);
            return -1;
        }
        int rw = Math.max(2, Math.round(outW * MabaController.rungScale(rung)));
        int rh = Math.max(2, Math.round(outH * MabaController.rungScale(rung)));
        boolean temporalMode = m == TEMPORAL && progTemporal != 0;

        if (temporalMode) {
            if (rung != lastRung) { temporal.reset(); havePrevVP = false; }
            lastRung = rung;
            float[] jf = temporal.beginFrame();
            Mat4 jittered = cameraVP(time, rw, rh, jf[0], jf[1]);
            Mat4 plain = cameraVP(time, rw, rh, 0, 0);
            Mat4 inv = plain.invert();
            if (inv == null) inv = Mat4.identity();
            float reset = (jf[2] > 0.5f || !havePrevVP) ? 1f : 0f;
            drawScene3D(sceneFbo[slot], rw, rh, time, jittered);
            temporalResolve(rw, rh, inv, reset);
            // History is reprojected with the UNJITTERED matrix: it holds the accumulated,
            // jitter-free image, so a jittered matrix would blur it a little every frame.
            System.arraycopy(plain.m, 0, prevVP.m, 0, 16);
            havePrevVP = true;
            int prog = MabaController.rungQuality(rung) ? progQuality : progFast;
            upscale(resolveTex[slot], prog, dstFbo, rw, rh);
            slot = 1 - slot;
        } else {
            Mat4 vp = cameraVP(time, rw, rh, 0, 0);
            drawScene3D(sceneFbo[0], rw, rh, time, vp);
            int prog = m == BILINEAR ? progBlit
                : (MabaController.rungQuality(rung) ? progQuality : progFast);
            upscale(sceneTex, prog, dstFbo, rw, rh);
        }
        return rung;
    }

    // ---------------------------------------------------------------------------------------
    // Off-screen benchmark
    // ---------------------------------------------------------------------------------------

    // The start-up benchmark runs as one small slice per displayed frame (a single off-screen
    // frame, timed with glFinish), so the screen keeps animating instead of freezing for the
    // several seconds the whole benchmark takes.
    private static final int BENCH_START_FRAME = 30;
    private static final int BENCH_WARMUP = 3;
    private static final int[] BENCH_MODES = {NATIVE, 1, 2, 3, DYNAMIC, 4, BILINEAR, TEMPORAL};
    private static final int[] BENCH_RUNGS = {-1, 28, 18, 10, 9, 0, 9, 10};
    private static final String[] BENCH_NAMES = {"Native resolution", "Ultra Quality 0.77",
        "Quality 0.67", "Balanced 0.59", "Balanced-lite 0.59 fast", "Performance 0.50",
        "Bilinear 0.59 (no MABA)", "MABA-Upscaler 2 (Temporal) 0.59"};
    private final double[] benchMs = new double[BENCH_MODES.length];
    private int benchJob, benchStep;
    private double benchAcc, benchT0;

    /** Jobs: 0-1 load calibration, then two rounds over every mode (best of the two kept). */
    private static int benchJobCount() { return 2 + 2 * BENCH_MODES.length; }

    private void benchSlice() {
        int job = benchJob;
        int m, rung, idx = -1;
        if (job < 2) {
            m = BILINEAR;
            rung = 9;
            load = job == 0 ? 0 : 64;
        } else {
            idx = (job - 2) % BENCH_MODES.length;
            m = BENCH_MODES[idx];
            rung = BENCH_RUNGS[idx];
            if (m == TEMPORAL && progTemporal == 0) {
                benchMs[idx] = Double.NaN;
                nextBenchJob();
                return;
            }
            if (benchStep == 0) { temporal.reset(); havePrevVP = false; }
        }

        if (benchStep < BENCH_WARMUP) {
            drawMode(m, rung, outFbo, 20f);
        } else {
            GLES30.glFinish();
            long t = System.nanoTime();
            drawMode(m, rung, outFbo, 20f);
            GLES30.glFinish();
            benchAcc += (System.nanoTime() - t) / 1e6;
        }
        if (++benchStep < BENCH_WARMUP + FRAME_PASSES) return;

        double ms = benchAcc / FRAME_PASSES;
        if (job == 0) {
            benchT0 = ms;
        } else if (job == 1) {
            double perUnit = Math.max(1e-4, (ms - benchT0) / 64.0);
            load = (int) Math.max(0, Math.min(4000, Math.round((CALIBRATION_MS - benchT0) / perUnit * loadMul)));
            Log.i(TAG, String.format(Locale.US, "calibration: load=%d (loadmul %.2f)", load, loadMul));
        } else if (job - 2 < BENCH_MODES.length || ms < benchMs[idx]) {
            benchMs[idx] = ms;
        }
        nextBenchJob();
    }

    private void nextBenchJob() {
        benchJob++;
        benchStep = 0;
        benchAcc = 0;
        benchText = String.format(Locale.US, "benchmarking... %d%%", benchJob * 100 / benchJobCount());
        if (benchJob < benchJobCount()) return;

        StringBuilder sb = new StringBuilder(
            String.format(Locale.US, "Off-screen, uncapped, scene load %d:", load));
        for (int i = 0; i < BENCH_MODES.length; i++) {
            if (Double.isNaN(benchMs[i])) continue;
            String line = String.format(Locale.US, "%s: %.1f fps (%.1f ms, %+.0f%% vs native)",
                BENCH_NAMES[i], 1000.0 / benchMs[i], benchMs[i], (benchMs[0] / benchMs[i] - 1.0) * 100.0);
            Log.i(TAG, "FRAME " + line);
            sb.append("\n  ").append(line);
        }
        benchText = sb.toString();
        temporal.reset();
        havePrevVP = false;
        benchDone = true;
        modeChanged = true;
    }

    // ---------------------------------------------------------------------------------------
    // Dump mode: reference pattern -> PPM for host comparison against the CPU golden reference
    // ---------------------------------------------------------------------------------------

    private void runDump() {
        int rw = Math.max(2, Math.round(outW * MabaController.rungScale(dumpRung)));
        int rh = Math.max(2, Math.round(outH * MabaController.rungScale(dumpRung)));
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, sceneFbo[0]);
        GLES30.glViewport(0, 0, rw, rh);
        GLES30.glDisable(GLES30.GL_DEPTH_TEST);
        GLES30.glUseProgram(progPattern);
        GLES30.glUniform1i(GLES30.glGetUniformLocation(progPattern, "uPattern"), dumpPattern);
        GLES30.glUniform2f(GLES30.glGetUniformLocation(progPattern, "uRes"), rw, rh);
        GLES30.glBindVertexArray(vao[0]);
        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3);
        int prog = dumpQuality != 0 ? progQuality : progFast;
        upscale(sceneTex, prog, 0, rw, rh);
        GLES30.glFinish();

        ByteBuffer buf = ByteBuffer.allocateDirect(outW * outH * 4);
        GLES30.glReadPixels(0, 0, outW, outH, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, buf);
        File f = new File(getExternalFilesDir(null), "dump.ppm");
        try (FileOutputStream out = new FileOutputStream(f)) {
            out.write(("P6\n" + outW + " " + outH + "\n255\n").getBytes("UTF-8"));
            byte[] row = new byte[outW * 3];
            for (int y = outH - 1; y >= 0; y--) {   // GL readback is bottom-up
                for (int x = 0; x < outW; x++) {
                    int i = (y * outW + x) * 4;
                    row[x * 3] = buf.get(i);
                    row[x * 3 + 1] = buf.get(i + 1);
                    row[x * 3 + 2] = buf.get(i + 2);
                }
                out.write(row);
            }
            Log.i(TAG, "DUMP " + f.getAbsolutePath() + " pattern=" + dumpPattern
                + " rung=" + dumpRung + " quality=" + dumpQuality);
        } catch (Exception e) {
            Log.e(TAG, "dump failed", e);
        }
        runOnUiThread(new Runnable() { @Override public void run() { finish(); } });
    }

    // ---------------------------------------------------------------------------------------
    // Frame loop
    // ---------------------------------------------------------------------------------------

    @Override
    public void onDrawFrame(GL10 unused) {
        GLES30.glBindVertexArray(vao[0]);
        frame++;
        if (dumpMode) {
            if (frame == 2) runDump();
            return;
        }
        if (!benchDone && frame >= BENCH_START_FRAME) benchSlice();

        long now = System.nanoTime();
        // 0 on the first frame after (re)start: the controller ignores non-positive samples.
        float frameMs = lastNanos == 0 ? 0f : (now - lastNanos) / 1e6f;
        lastNanos = now;
        int m = mode;
        if (m == TEMPORAL && progTemporal == 0) m = DYNAMIC;
        if (targetChanged) {
            targetChanged = false;
            dyn.setTargetFps(effectiveTargetFps());
        }
        boolean modeChangedThisFrame = modeChanged;
        if (modeChanged) {
            modeChanged = false;
            dyn.setMode(MabaController.MODE_DYNAMIC);
            dyn.setTargetFps(effectiveTargetFps());
            if (benchDone) {   // while benchmarking, the temporal history belongs to the benchmark
                temporal.reset();
                havePrevVP = false;
                lastRung = -1;
            }
            fpsFrames = 0;
            fps = 0;            // show "--" until the new mode has its own measurement
            probeMs = 0;
            probeCountdown = 60;
        }
        int rung = (m == DYNAMIC || m == TEMPORAL) ? dyn.rung() : MODE_RUNG[m];
        boolean probeNow = false;
        if (!modeChangedThisFrame && (m == DYNAMIC || m == TEMPORAL) && benchDone) {
            float sample;
            // Some Mali drivers latch timestamps at frame granularity, so the query just echoes
            // the present-to-present interval. Trust it only when it shows headroom that
            // present-to-present cannot see.
            boolean timerTrusted = gpuTimer.usable() && gpuTimer.gpuMs < frameMs - 1.0f;
            if (timerTrusted) {
                sample = gpuTimer.gpuMs;                 // real per-frame GPU timing
            } else {
                // Every 120 frames, time THIS frame's real work with glFinish (no extra frames
                // are drawn, so there is no visible hitch). Between probes a real overrun is
                // visible present-to-present; otherwise hold the last probe estimate.
                if (--probeCountdown <= 0) {
                    probeCountdown = 120;
                    probeNow = true;
                }
                sample = frameMs > 18f ? frameMs : (probeMs > 0 ? probeMs : frameMs);
            }
            dyn.updateDynamic(sample);
            rung = dyn.rung();
        }

        // While the benchmark is still running it owns the temporal history, so show the
        // spatial path in the meantime.
        int drawM = m, drawRung = rung;
        if (!benchDone && m == TEMPORAL) { drawM = 3; drawRung = 10; }

        float animTime = anim ? (now - startNanos) / 1e9f : 20f;
        gpuTimer.begin();
        if (probeNow) {
            // Time this frame's real work on the off-screen target: drawing into the window
            // would also time Android's wait for a free swap buffer (one vsync), hiding all GPU
            // headroom. Then copy the finished frame to the window, so it is still shown and
            // nothing is drawn twice.
            GLES30.glFinish();
            long probeStart = System.nanoTime();
            drawMode(drawM, drawRung, outFbo, animTime);
            GLES30.glFinish();
            probeMs = (System.nanoTime() - probeStart) / 1e6f;
            GLES30.glBindFramebuffer(GLES30.GL_READ_FRAMEBUFFER, outFbo);
            GLES30.glBindFramebuffer(GLES30.GL_DRAW_FRAMEBUFFER, 0);
            GLES30.glBlitFramebuffer(0, 0, outW, outH, 0, 0, outW, outH,
                GLES30.GL_COLOR_BUFFER_BIT, GLES30.GL_NEAREST);
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0);
            Log.i(TAG, String.format(Locale.US, "PROBE gpu %.1f ms at %s", probeMs, rungName(rung)));
        } else {
            drawMode(drawM, drawRung, 0, animTime);
        }
        gpuTimer.end();

        if (fpsFrames == 0) fpsNanos = now;
        fpsFrames++;
        if (fpsFrames > 120) {
            fps = (fpsFrames - 1) * 1e9 / (now - fpsNanos);
            Log.i(TAG, String.format(Locale.US, "ONSCREEN %s%s = %.1f fps (%s)", MODE_NAMES[m],
                (m == DYNAMIC || m == TEMPORAL) ? " [" + rungName(rung) + "]" : "", fps, gpuText()));
            fpsFrames = 0;
        }
        if (frame % 30 == 0) {
            final String text = String.format(Locale.US,
                "%s%s   |   %s fps   |   %s   |   thermal %d   |   tap: mode, hold: settings\n%s\n%s",
                MODE_NAMES[m], (m == DYNAMIC || m == TEMPORAL) ? "  ->  " + rungName(rung) : "",
                fps > 0 ? String.format(Locale.US, "%.0f", fps) : "--",
                gpuText(), thermalStatus, benchText, glInfo);
            runOnUiThread(new Runnable() {
                @Override public void run() { label.setText(text); }
            });
        }
    }

    /** GPU time for the overlay: the timer query if it really measures, else the probe. */
    private String gpuText() {
        if (gpuTimer.usable()) return String.format(Locale.US, "gpu %.1f ms", gpuTimer.gpuMs);
        if (probeMs > 0) return String.format(Locale.US, "gpu ~%.1f ms (probe)", probeMs);
        return "gpu n/a";
    }

    private static String rungName(int rung) {
        if (rung < 0) return "native";
        return String.format(Locale.US, "%.2f %s", MabaController.rungScale(rung),
            MabaController.rungQuality(rung) ? "quality" : "fast");
    }
}
