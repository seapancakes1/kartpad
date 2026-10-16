package dev.kartpad.android.screens.mii

import android.content.Context
import android.database.ContentObserver
import android.graphics.Bitmap
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.provider.Settings
import android.util.AttributeSet
import android.util.Log
import android.view.Choreographer
import android.view.MotionEvent
import android.view.TextureView
import android.view.View
import android.view.ViewOutlineProvider
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.abs

/**
 * The Mii editor's 3D preview (apple/shared/KartPadMiiPreview.inc.mm): the imported head and
 * body drawn by kartpad_mii_preview_gl.cpp on this view's own GL thread and EGL context. Drag or
 * [turnBy] to turn it. While [animated] the body plays its idle loop, the face blinks and smiles
 * and the head sways; with animations off in system settings (Reduce Motion) only blink and smile
 * remain. It renders continuously only while animating and visible, otherwise on demand. Without
 * GLES 3 it shows the Mii's portrait instead. Main thread API.
 */
class MiiPreviewView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) :
    TextureView(context, attrs), TextureView.SurfaceTextureListener {

    companion object {
        /** Apple's turn buttons step by 0.35 radians. */
        const val BUTTON_TURN_DEGREES = 20.05f
        private const val TAG = "KartPadMiiPreview"
        private const val BODY_MISSING = "Body missing. Import your game data again."
        private const val UNAVAILABLE = "Preview unavailable."
        // Drags turn 0.015 radians per point, as on Apple.
        private const val DRAG_RADIANS_PER_DP = .015f
    }

    /** Why the preview can't show the Mii as it should (game files, body or GPU), or null. */
    var status: String? = null
        private set

    /** Called on the main thread when [status] changes. */
    var onStatus: ((String?) -> Unit)? = null

    /** Idle animation; on by default. Off drops blink and smile too. */
    var animated = true
        set(value) { field = value; configure() }

    /** The opaque colour behind the Mii (the editor's preview well). */
    var wellColor = 0xffecf1f1.toInt()
        set(value) { field = value or 0xff000000.toInt(); configure(); drawFallback() }

    var cornerRadius = 12 * resources.displayMetrics.density
        set(value) { field = value; invalidateOutline() }

    private val main = Handler(Looper.getMainLooper())
    private var record: ByteArray? = null
    private var fullBody = false
    private var reduceMotion = false
    private var shown = false
    @Volatile private var attached = false
    private var lastX = 0f
    private var dragged = false

    // A scene built on the Mii worker, waiting for the GL thread. Only the current revision is kept.
    private val revision = AtomicLong()
    private val sceneLock = Any()
    private var pendingScene = 0L
    private var hasPending = false

    // Render thread. [gl] is read from the Mii worker.
    @Volatile private var gl: Handler? = null
    private var thread: HandlerThread? = null
    private var fallback = false
    private var portrait: Bitmap? = null

    private data class State(
        val animated: Boolean, val reduceMotion: Boolean, val visible: Boolean, val fullBody: Boolean, val color: Int,
    ) {
        val continuous get() = animated && visible
    }
    @Volatile private var state = State(true, false, false, false, wellColor)
    @Volatile private var savedYaw = 0f

    // GL thread only.
    private class Egl(val display: EGLDisplay, val context: EGLContext, val surface: EGLSurface)
    private var egl: Egl? = null
    private var renderer = 0L
    private var hasScene = false
    private var surfaceWidth = 0
    private var surfaceHeight = 0
    private var frameScheduled = false
    private var texture: SurfaceTexture? = null
    private var choreographer: Choreographer? = null
    private val frame = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            frameScheduled = false
            render()
            if (state.continuous && hasScene) schedule()
        }
    }

    private val motion = object : ContentObserver(main) {
        override fun onChange(selfChange: Boolean) = readReduceMotion()
    }

    init {
        surfaceTextureListener = this
        isOpaque = true
        contentDescription = "Mii preview"
        outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) =
                outline.setRoundRect(0, 0, view.width, view.height, cornerRadius)
        }
        clipToOutline = true
    }

    /** Shows [record] (74 bytes). Scenes build off the main thread; a newer call wins. */
    fun setMii(record: ByteArray) {
        if (record.size != MiiNative.MII_SIZE) return
        this.record = record.copyOf()
        if (fallback) requestPortrait() else buildScene()
    }

    /** Full body (Profile, Body) or the head (face categories). */
    fun setFraming(head: Boolean) {
        if (fullBody == !head) return
        fullBody = !head
        configure()
    }

    /** Turn buttons and the like; pauses the head sway for a moment. */
    fun turnBy(degrees: Float) = turn(Math.toRadians(degrees.toDouble()).toFloat())

    /** The face-front button: straight to the front. */
    fun faceFront() = onGl({ savedYaw = 0f }) {
        MiiNative.nativePreviewFaceFront(it, false)
        schedule()
    }

    /** Opening a face category: eases back to the front while animating (snaps with Reduce Motion). */
    fun easeToFront() = onGl({ if (animated) savedYaw = 0f }) {
        MiiNative.nativePreviewFaceFront(it, true)
        schedule()
    }

    /** Picking a feature or colour: the Mii smiles for a second while animating. */
    fun smile() = onGl({}) {
        MiiNative.nativePreviewReact(it)
        schedule()
    }

    private fun turn(radians: Float) = onGl({ savedYaw += radians }) {
        MiiNative.nativePreviewTurn(it, radians)
        schedule()
    }

    // Runs [action] with the renderer on the GL thread, or [offline] when there is none.
    private fun onGl(offline: () -> Unit, action: (Long) -> Unit) {
        val handler = gl
        if (handler == null) { offline(); return }
        handler.post { if (renderer != 0L) action(renderer) else offline() }
    }

    private fun configure() {
        val next = State(animated, reduceMotion, shown, fullBody, wellColor)
        state = next
        gl?.post { applyState() }
    }

    private fun report(value: String?) {
        if (value == status) return
        status = value
        onStatus?.invoke(value)
    }

    private fun buildScene() {
        val mii = record ?: return
        val current = revision.incrementAndGet()
        if (!MiiNative.available) { useFallback(); return }
        val files = MiiImages.gameFiles(context)
        MiiImages.execute {
            if (revision.get() != current) return@execute
            var scene = 0L
            var problem: String? = null
            try {
                scene = MiiNative.nativeBuildScene(files.faces.path, files.bodies.path, mii)
                if (!MiiNative.nativeSceneHasBody(scene)) problem = BODY_MISSING
            } catch (error: Throwable) {
                problem = error.message ?: UNAVAILABLE
            }
            synchronized(sceneLock) {
                // Detached: the next surface builds again.
                if (revision.get() != current || !attached) {
                    if (scene != 0L) MiiNative.nativeReleaseScene(scene)
                    return@execute
                }
                if (pendingScene != 0L) MiiNative.nativeReleaseScene(pendingScene)
                pendingScene = scene
                hasPending = true
            }
            gl?.post { installPending() }
            main.post { if (revision.get() == current && !fallback) report(problem) }
        }
    }

    // GL thread.
    private fun installPending() {
        if (renderer == 0L) return
        val scene = synchronized(sceneLock) {
            if (!hasPending) return
            hasPending = false
            pendingScene.also { pendingScene = 0L }
        }
        hasScene = MiiNative.nativePreviewSetScene(renderer, scene)
        schedule()
    }

    private fun applyState() {
        if (renderer == 0L) return
        val s = state
        MiiNative.nativePreviewConfigure(renderer, s.animated, s.reduceMotion, s.visible, s.fullBody, s.color)
        schedule()
    }

    private fun schedule() {
        if (renderer == 0L || frameScheduled) return
        frameScheduled = true
        choreographer?.postFrameCallback(frame)
    }

    private fun render() {
        val egl = egl ?: return
        if (renderer == 0L) return
        MiiNative.nativePreviewDraw(renderer, surfaceWidth, surfaceHeight)
        if (!EGL14.eglSwapBuffers(egl.display, egl.surface) && EGL14.eglGetError() == EGL14.EGL_CONTEXT_LOST) {
            val surface = texture ?: return
            stopGl()
            startGl(surface)
        }
    }

    private fun startGl(surface: SurfaceTexture) {
        texture = surface
        val created = createEgl(surface)
        val next = if (created != null) runCatching { MiiNative.nativePreviewCreate() }.getOrDefault(0L) else 0L
        if (next == 0L) {
            Log.w(TAG, "GLES 3 preview unavailable; showing the portrait")
            created?.let(::destroyEgl)
            main.post { useFallback() }
            return
        }
        egl = created
        renderer = next
        hasScene = false
        choreographer = Choreographer.getInstance()
        MiiNative.nativePreviewSetYaw(renderer, savedYaw)
        applyState()
        // The last renderer took its scene with it: build one again unless one is waiting.
        if (synchronized(sceneLock) { hasPending }) installPending() else main.post { buildScene() }
    }

    private fun stopGl() {
        choreographer?.removeFrameCallback(frame)
        frameScheduled = false
        if (renderer != 0L) {
            savedYaw = MiiNative.nativePreviewYaw(renderer)
            MiiNative.nativePreviewDestroy(renderer)
            renderer = 0L
        }
        hasScene = false
        egl?.let(::destroyEgl)
        egl = null
    }

    private fun createEgl(surface: SurfaceTexture): Egl? {
        val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val version = IntArray(2)
        if (display == EGL14.EGL_NO_DISPLAY || !EGL14.eglInitialize(display, version, 0, version, 1)) return null
        val config = chooseConfig(display) ?: return null
        val context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE), 0)
        if (context == null || context == EGL14.EGL_NO_CONTEXT) return null
        val window = EGL14.eglCreateWindowSurface(display, config, surface, intArrayOf(EGL14.EGL_NONE), 0)
        if (window == null || window == EGL14.EGL_NO_SURFACE) {
            EGL14.eglDestroyContext(display, context)
            return null
        }
        val result = Egl(display, context, window)
        if (!EGL14.eglMakeCurrent(display, window, window, context)) {
            destroyEgl(result)
            return null
        }
        return result
    }

    // RGBA8 with depth, 4x multisampled like the Metal view where the device offers it.
    private fun chooseConfig(display: EGLDisplay): EGLConfig? {
        for ((depth, samples) in listOf(24 to 4, 24 to 0, 16 to 0)) {
            val attributes = intArrayOf(
                EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_DEPTH_SIZE, depth,
                EGL14.EGL_SAMPLE_BUFFERS, if (samples > 0) 1 else 0, EGL14.EGL_SAMPLES, samples,
                EGL14.EGL_NONE,
            )
            val configs = arrayOfNulls<EGLConfig>(1)
            val count = IntArray(1)
            if (EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0) && count[0] > 0) return configs[0]
        }
        return null
    }

    // Never eglTerminate: the display is shared with the game's renderer.
    private fun destroyEgl(value: Egl) {
        EGL14.eglMakeCurrent(value.display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        EGL14.eglDestroySurface(value.display, value.surface)
        EGL14.eglDestroyContext(value.display, value.context)
        EGL14.eglReleaseThread()
    }

    override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
        if (fallback) { drawFallback(); return }
        val started = HandlerThread("KartPadMiiPreview").also { it.start() }
        val handler = Handler(started.looper)
        thread = started
        gl = handler
        handler.post {
            surfaceWidth = width
            surfaceHeight = height
            startGl(surface)
        }
    }

    override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {
        if (fallback) { drawFallback(); return }
        gl?.post {
            surfaceWidth = width
            surfaceHeight = height
            schedule()
        }
    }

    // Synchronous: the GL objects and EGL surface go before the SurfaceTexture is released.
    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
        val handler = gl ?: return true
        gl = null
        val done = CountDownLatch(1)
        handler.post {
            stopGl()
            texture = null
            done.countDown()
        }
        if (!done.await(2, TimeUnit.SECONDS)) Log.w(TAG, "Preview teardown timed out")
        thread?.quitSafely()
        thread = null
        return true
    }

    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit

    // No GLES 3 (or no native renderer in this build): the portrait, drawn into the surface.
    private fun useFallback() {
        if (fallback) return
        fallback = true
        thread?.quitSafely()
        thread = null
        gl = null
        report(UNAVAILABLE)
        requestPortrait()
    }

    private fun requestPortrait() {
        val mii = record
        if (mii == null || !MiiNative.available) { drawFallback(); return }
        MiiImages.requestPortrait(context, mii) ready@{ image ->
            if (record?.contentEquals(mii) != true) return@ready
            portrait = image
            drawFallback()
        }
    }

    private fun drawFallback() {
        if (!fallback || !isAvailable) return
        val canvas = lockCanvas() ?: return
        try {
            canvas.drawColor(wellColor)
            portrait?.let { image ->
                val scale = minOf(canvas.width * .88f / image.width, canvas.height * .88f / image.height)
                val w = image.width * scale
                val h = image.height * scale
                val target = RectF((canvas.width - w) / 2, (canvas.height - h) / 2, (canvas.width + w) / 2, (canvas.height + h) / 2)
                canvas.drawBitmap(image, null, target, Paint(Paint.FILTER_BITMAP_FLAG))
            }
        } finally {
            unlockCanvasAndPost(canvas)
        }
    }

    private fun readReduceMotion() {
        val scale = runCatching {
            Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f)
        }.getOrDefault(1f)
        if (reduceMotion == (scale == 0f)) return
        reduceMotion = scale == 0f
        configure()
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        attached = true
        context.contentResolver.registerContentObserver(
            Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE), false, motion)
        readReduceMotion()
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        attached = false
        context.contentResolver.unregisterContentObserver(motion)
        synchronized(sceneLock) {
            if (pendingScene != 0L) MiiNative.nativeReleaseScene(pendingScene)
            pendingScene = 0L
            hasPending = false
        }
    }

    // Visible on screen, in a started activity.
    override fun onVisibilityAggregated(isVisible: Boolean) {
        super.onVisibilityAggregated(isVisible)
        if (shown == isVisible) return
        shown = isVisible
        configure()
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                lastX = event.x
                dragged = false
                parent?.requestDisallowInterceptTouchEvent(true)
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = event.x - lastX
                if (dragged || abs(dx) > 2 * resources.displayMetrics.density) {
                    dragged = true
                    lastX = event.x
                    turn(dx / resources.displayMetrics.density * DRAG_RADIANS_PER_DP)
                }
            }
            MotionEvent.ACTION_UP -> if (!dragged) performClick()
        }
        return true
    }

    override fun performClick(): Boolean = super.performClick()
}
