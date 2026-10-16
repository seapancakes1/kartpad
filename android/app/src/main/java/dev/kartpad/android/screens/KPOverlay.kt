package dev.kartpad.android.screens

import android.annotation.SuppressLint
import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PointF
import android.graphics.Rect
import android.graphics.RectF
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.provider.Settings
import android.view.Choreographer
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityNodeProvider
import android.widget.FrameLayout
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.round

// The screens' controller (the Mac's KPOverlayController): a stack of screens over the game, the focus
// and moving it, presses from controllers and keys, touches, toasts and the animations. One host view
// in SDL's layout, above the game's surface and the touch controls; it is never focusable, so SDL's
// surface keeps the gamepads' key events (SDL reads controllers there). While a screen is open the game
// holds still (onHoldWanted), except online.
@SuppressLint("ViewConstructor")
class KPHostView(activity: Activity, private val overlay: KPOverlay) : FrameLayout(activity) {
    init {
        isFocusable = false
        isFocusableInTouchMode = false
        setWillNotDraw(false)
        clipChildren = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        overlay.relayout()
    }

    override fun onApplyWindowInsets(insets: WindowInsets): WindowInsets {
        overlay.relayout()
        return super.onApplyWindowInsets(insets)
    }

    override fun onDraw(canvas: Canvas) = overlay.drawScreens(canvas)

    override fun dispatchDraw(canvas: Canvas) {
        super.dispatchDraw(canvas)
        overlay.drawToasts(canvas)
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean = overlay.touch(event)

    override fun getAccessibilityNodeProvider(): AccessibilityNodeProvider? =
        if (overlay.active) overlay.accessibility else null
}

class KPToast(
    val heading: String, var detail: String?, var stripe: Int, var icon: ((Canvas, RectF) -> Unit)?, var image: Bitmap?,
    var player: Int = -1, var mii: ByteArray? = null, var art: ((Canvas, RectF) -> Unit)? = null,
) {
    var owner: KPScreen? = null
    var owned = false
    var started = false
    var leaving = false
    var seconds = 3.4f
    var showing = 0
    val frame = RectF()
    var alpha = 0f
    var slide = 0f
}

class KPOverlay(val activity: Activity, private val parent: ViewGroup) {
    val host = KPHostView(activity, this)
    val stack = ArrayList<KPScreen>()
    val toasts = ArrayList<KPToast>()

    /** Pixels per design point, the whole view in design points, and the 1280×720 area inside the safe insets. */
    var scale = 1f
        private set
    var stageWidth = DesignWidth
        private set
    var stageHeight = DesignHeight
        private set
    val safe = RectF(0f, 0f, DesignWidth, DesignHeight)
    /** The smallest a control may be under a finger (44 dp), in design points. */
    val touchTarget get() = 44f * activity.resources.displayMetrics.density / scale

    val reduceMotion: Boolean get() = runCatching {
        Settings.Global.getFloat(activity.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }.getOrDefault(false)

    /** Worked by touch: the controller hints step aside until a controller (or key) is pressed again. */
    var touching = true
        set(value) { if (field != value) { field = value; invalidate() } }

    /** Plays one of the UI sounds (KartPadUISounds), set by the glue. */
    var soundPlayer: ((KPUISound) -> Unit)? = null
    /** A Mii's head as a Bitmap, or null while it renders (ready runs on the main thread once it's there). */
    var portraitProvider: ((ByteArray, () -> Unit) -> Bitmap?)? = null
    /** The game should hold (a screen that pauses it is open). */
    var onHoldWanted: ((Boolean) -> Unit)? = null
    /** The screens opened or all closed. */
    var onActiveChanged: ((Boolean) -> Unit)? = null
    /** A picture of the held game, drawn behind the scrim while the game's own surface may be gone. */
    var backdrop: Bitmap? = null
        set(value) { field = value; invalidate() }
    var showBackdrop = false
        set(value) { if (field != value) { field = value; invalidate() } }
    /** Called every frame while open (the controllers are read here). */
    var onFrame: ((Long) -> Unit)? = null

    val active get() = stack.isNotEmpty()
    val top: KPScreen? get() = stack.lastOrNull()

    private var scrimAlpha = 0f
    private var holdWanted = false
    private var padPressed: KPButton? = null
    private var keyPressed: KPButton? = null
    private var backKey = -1
    private var movedFrom: KPButton? = null
    private var movedTo: KPButton? = null
    private var movedDx = 0
    private var movedDy = 0
    private var movedColumn = Float.NaN
    private var touchButton: KPButton? = null
    private var sliding = false

    companion object {
        const val DesignWidth = 1280f
        const val DesignHeight = 720f
    }

    init {
        host.translationZ = 64 * activity.resources.displayMetrics.density
        host.visibility = View.GONE
    }

    fun post(run: () -> Unit) { host.post(run) }
    fun invalidate() = host.invalidate()
    fun play(sound: KPUISound) { soundPlayer?.invoke(sound) }

    private fun attach() {
        if (host.parent == null) {
            parent.addView(host, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        }
        host.bringToFront()
        host.visibility = View.VISIBLE
    }

    // MARK: Layout

    /** The insets the canvas keeps clear of (bars, the cutout), whether or not the bars are showing. */
    private fun safeInsets(): Rect {
        val insets = host.rootWindowInsets ?: return Rect()
        if (Build.VERSION.SDK_INT >= 30) {
            val i = insets.getInsetsIgnoringVisibility(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            return Rect(i.left, i.top, i.right, i.bottom)
        }
        @Suppress("DEPRECATION")
        val stable = Rect(insets.stableInsetLeft, insets.stableInsetTop, insets.stableInsetRight, insets.stableInsetBottom)
        insets.displayCutout?.let {
            stable.left = max(stable.left, it.safeInsetLeft)
            stable.top = max(stable.top, it.safeInsetTop)
            stable.right = max(stable.right, it.safeInsetRight)
            stable.bottom = max(stable.bottom, it.safeInsetBottom)
        }
        return stable
    }

    fun relayout() {
        val w = host.width.toFloat()
        val h = host.height.toFloat()
        if (w < 1 || h < 1) return
        val insets = safeInsets()
        val safeW = max(1f, w - insets.left - insets.right)
        val safeH = max(1f, h - insets.top - insets.bottom)
        scale = min(safeW / DesignWidth, safeH / DesignHeight)
        stageWidth = w / scale
        stageHeight = h / scale
        val left = (insets.left + (safeW - DesignWidth * scale) / 2) / scale
        val top = (insets.top + (safeH - DesignHeight * scale) / 2) / scale
        safe.set(round(left), round(top), round(left) + DesignWidth, round(top) + DesignHeight)
        for (screen in stack) screen.relayout()
        layoutToasts(false)
        invalidate()
    }

    fun placeViews(screen: KPScreen) {
        // Only the top screen's views: a view would draw over a question presented on its screen.
        val showing = screen === top && !screen.hidden
        for ((view, rect) in screen.views) {
            if (view.parent == null) host.addView(view)
            view.visibility = if (showing) View.VISIBLE else View.GONE
            val params = (view.layoutParams as? FrameLayout.LayoutParams)
                ?: FrameLayout.LayoutParams(0, 0)
            params.width = round(rect.width() * scale).toInt()
            params.height = round(rect.height() * scale).toInt()
            params.leftMargin = round(rect.left * scale).toInt()
            params.topMargin = round(rect.top * scale).toInt()
            view.layoutParams = params
        }
    }

    private fun removeViews(screen: KPScreen) {
        for (view in screen.views.keys) host.removeView(view)
        screen.views.clear()
    }

    // MARK: The stack

    fun present(screen: KPScreen) {
        val opening = !active
        attach()
        top?.let {
            it.willDisappear()
            it.hidden = !(screen.overPrevious && it.solid)
            placeViews(it)
        }
        stack += screen
        movedTo = null
        screen.relayout()
        screen.willAppear()
        dismissStaleToasts()
        layoutToasts(false)
        val focus = screen.focus?.takeIf { it.enabled && !it.hidden } ?: screen.initialFocus()
        screen.focus = null
        focus(focus, false)
        if (opening) {
            play(KPUISound.Open)
            onActiveChanged?.invoke(true)
        }
        fadeScrim(!screen.solid)
        updateHold()
        animateIn(screen)
        startFrames()
        screen.didAppear()
        sendAccessibilityChange()
    }

    fun pop() {
        val leaving = top ?: return
        if (stack.size == 1) {
            closeAll()
            return
        }
        removeScreen(leaving)
        play(KPUISound.Close)
        movedTo = null
        val back = top ?: return
        back.hidden = false
        back.relayout()
        back.willAppear()
        dismissStaleToasts()
        layoutToasts(false)
        fadeScrim(!back.solid)
        focus(back.focus?.takeIf { it.enabled && !it.hidden } ?: back.initialFocus(), false)
        updateHold()
        animateIn(back)
        back.didAppear()
        sendAccessibilityChange()
    }

    fun replaceTop(screen: KPScreen) {
        top?.let { removeScreen(it) }
        present(screen)
    }

    private fun removeScreen(screen: KPScreen) {
        screen.willDisappear()
        stack.remove(screen)
        removeViews(screen)
    }

    /** Back to the game: every screen closes and the game carries on once the buttons that closed it are let go. */
    fun closeAll() {
        if (!active) return
        // A screen with unsaved work asks first (the Mii editor); while its question is up, HOME waits for it.
        val asker = stack.lastOrNull { it.asksBeforeClosingAll() }
        if (asker != null) {
            if (asker === top) asker.askBeforeClosingAll()
            return
        }
        val closing = stack.toList()
        for (screen in closing.asReversed()) screen.willDisappear()
        stack.clear()
        play(KPUISound.Close)
        padPressed = null
        keyPressed = null
        touchButton = null
        updateHold()
        onActiveChanged?.invoke(false)
        val duration = if (reduceMotion) 100L else 160L
        val from = closing.map { it.alpha }
        val scrimFrom = scrimAlpha
        closingScreens = closing
        animate(duration, onFrame = { t ->
            closing.forEachIndexed { i, screen -> screen.alpha = from[i] * (1 - t) }
            scrimAlpha = scrimFrom * (1 - t)
        }) {
            closingScreens = emptyList()
            for (screen in closing) removeViews(screen)
            showBackdrop = false
            backdrop = null
            if (!active && toasts.isEmpty()) host.visibility = View.GONE
        }
        dismissStaleToasts()
        layoutToasts(true)
        sendAccessibilityChange()
    }

    private var closingScreens: List<KPScreen> = emptyList()

    private fun updateHold() {
        val wanted = stack.any { it.pausesGame }
        if (wanted == holdWanted) return
        holdWanted = wanted
        onHoldWanted?.invoke(wanted)
    }

    private fun fadeScrim(visible: Boolean) {
        val from = scrimAlpha
        val to = if (visible) 1f else 0f
        animate(if (reduceMotion) 120L else 200L, onFrame = { t -> scrimAlpha = from + (to - from) * t })
    }

    private fun animateIn(screen: KPScreen) {
        screen.alpha = 0f
        animate(if (reduceMotion) 120L else 180L, onFrame = { t -> screen.alpha = t })
    }

    // MARK: Focus and moving it

    fun focus(button: KPButton?, sound: Boolean) {
        val screen = top ?: return
        if (button === screen.focus) return
        screen.focus?.let {
            it.focused = false
            it.pressed = false
        }
        screen.focus = button
        button?.focused = true
        if (sound && button != null) play(KPUISound.Hover)
        if (button != null) sendAccessibilityFocus(button)
    }

    fun move(dx: Int, dy: Int) {
        val screen = top ?: return
        val controls = screen.focusables()
        val focus = screen.focus
        if (focus == null || focus !in controls) {
            focus(screen.initialFocus(), true)
            return
        }
        if (dx != 0 && focus.adjust?.invoke(dx) == true) return
        // Straight back the way it came returns to where it was. A run of moves up or down keeps to the
        // column it started in (sideways, to its row), so passing a wide control doesn't change columns.
        val continuing = focus === movedTo
        var next: KPButton? = null
        if (continuing && dx == -movedDx && dy == -movedDy && movedFrom in controls) next = movedFrom
        val column = if (continuing && (dx != 0) == (movedDx != 0)) movedColumn
            else if (dx != 0) focus.frame.centerY() else focus.frame.centerX()
        if (next == null) {
            val index = KPNavigation.nearest(controls.map { it.frame }, controls.indexOf(focus), dx, dy, column)
            next = controls.getOrNull(index)
        }
        if (next == null) return
        movedFrom = focus
        movedTo = next
        movedDx = dx
        movedDy = dy
        movedColumn = column
        focus(next, true)
    }

    /** A screen button from a controller (or key). down is false when it's let go; only A acts on release. */
    fun padPress(button: KPPad, down: Boolean) {
        val screen = top ?: return
        touching = false
        if (!down) {
            if (button != KPPad.Confirm) return
            val pressed = padPressed ?: return
            padPressed = null
            pressed.pressed = false
            if (pressed === screen.focus) pressed.fire()
            return
        }
        if (screen.handle(button)) return
        when (button) {
            KPPad.Up -> move(0, -1)
            KPPad.Down -> move(0, 1)
            KPPad.Left -> move(-1, 0)
            KPPad.Right -> move(1, 0)
            KPPad.Confirm -> {
                val focus = screen.focus
                if (focus != null && focus.enabled && focus.activate != null) {
                    focus.pressed = true
                    padPressed = focus
                } else if (focus == null) {
                    focus(screen.initialFocus(), true)
                }
            }
            KPPad.Back -> screen.back()
            KPPad.Start -> closeAll()
            else -> {}
        }
    }

    // MARK: Keys (keyboards, TV remotes, Back, and pads SDL doesn't read)

    /** True when the key was the screens'. Arrows move, Enter presses, Escape and Back go back, Tab changes page. */
    fun handleKey(event: KeyEvent): Boolean {
        val screen = top ?: return false
        if (event.isCtrlPressed || event.isMetaPressed) return false
        touching = false
        if (screen.takesKey(event)) return true
        val down = event.action == KeyEvent.ACTION_DOWN
        val button = when (event.keyCode) {
            KeyEvent.KEYCODE_DPAD_UP -> KPPad.Up
            KeyEvent.KEYCODE_DPAD_DOWN -> KPPad.Down
            KeyEvent.KEYCODE_DPAD_LEFT -> KPPad.Left
            KeyEvent.KEYCODE_DPAD_RIGHT -> KPPad.Right
            KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER, KeyEvent.KEYCODE_SPACE,
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_BUTTON_A -> KPPad.Confirm
            KeyEvent.KEYCODE_ESCAPE, KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_DEL, KeyEvent.KEYCODE_BUTTON_B -> KPPad.Back
            KeyEvent.KEYCODE_TAB -> if (event.isShiftPressed) KPPad.PreviousTab else KPPad.NextTab
            KeyEvent.KEYCODE_BUTTON_L1 -> KPPad.PreviousTab
            KeyEvent.KEYCODE_BUTTON_R1 -> KPPad.NextTab
            KeyEvent.KEYCODE_BUTTON_X -> KPPad.Undo
            KeyEvent.KEYCODE_BUTTON_Y -> KPPad.Redo
            KeyEvent.KEYCODE_BUTTON_START, KeyEvent.KEYCODE_MENU -> KPPad.Start
            else -> null
        } ?: return event.keyCode != KeyEvent.KEYCODE_VOLUME_UP && event.keyCode != KeyEvent.KEYCODE_VOLUME_DOWN &&
            event.keyCode != KeyEvent.KEYCODE_VOLUME_MUTE
        if (!down) {
            if (button == KPPad.Confirm) {
                val pressed = keyPressed
                keyPressed = null
                pressed?.pressed = false
                if (pressed != null && pressed === top?.focus) pressed.fire()
            } else if (button == KPPad.Back && backKey == event.keyCode) {
                backKey = -1
                padPress(KPPad.Back, true)
            }
            return true
        }
        when (button) {
            KPPad.Confirm -> {
                if (event.repeatCount > 0) return true
                if (screen.handle(button)) return true
                val focus = screen.focus
                if (focus != null && focus.enabled && focus.activate != null) {
                    focus.pressed = true
                    keyPressed = focus
                }
            }
            // Back acts when it comes up, so the key that opened HOME doesn't also close it.
            KPPad.Back -> if (event.repeatCount == 0) backKey = event.keyCode
            else -> padPress(button, true)
        }
        return true
    }

    // MARK: Touch

    fun touch(event: MotionEvent): Boolean {
        val screen = top ?: return false
        val x = event.x / scale
        val y = event.y / scale
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                touching = true
                val button = screen.buttonAt(x, y)
                touchButton = button
                sliding = false
                if (button == null) return true
                focus(button, false)
                val slide = button.slide
                if (slide != null && slide(x, y, button.frame, true)) {
                    sliding = true
                    return true
                }
                button.pressed = true
            }
            MotionEvent.ACTION_MOVE -> {
                val button = touchButton ?: return true
                if (sliding) {
                    button.slide?.invoke(x, y, button.frame, false)
                    return true
                }
                button.pressed = button.hit(x, y)
            }
            MotionEvent.ACTION_UP -> {
                val button = touchButton ?: return true
                touchButton = null
                if (sliding) {
                    sliding = false
                    KPSlide.saveNow()
                    return true
                }
                val fire = button.pressed && button.hit(x, y)
                button.pressed = false
                if (fire) button.fire(true)
            }
            MotionEvent.ACTION_CANCEL -> {
                touchButton?.pressed = false
                touchButton = null
                if (sliding) KPSlide.saveNow()
                sliding = false
            }
        }
        return true
    }

    // MARK: Drawing

    private val stripes = Paint().apply { strokeWidth = 1f }
    private var stripeLines = FloatArray(0)
    private var stripeHeight = -1f

    /** A solid screen's panel and pinstripes, across the whole view. */
    fun drawBackdrop(c: Canvas) {
        KP.fill(c, RectF(0f, 0f, stageWidth, stageHeight), KP.p.background)
        if (stripeHeight != stageHeight || stripeLines.size / 4 != (stageHeight / 4).toInt() + 1) {
            val count = (stageHeight / 4).toInt() + 1
            stripeLines = FloatArray(count * 4)
            for (i in 0 until count) {
                val y = 1.5f + i * 4
                stripeLines[i * 4] = 0f; stripeLines[i * 4 + 1] = y; stripeLines[i * 4 + 2] = 0f; stripeLines[i * 4 + 3] = y
            }
            stripeHeight = stageHeight
        }
        for (i in 0 until stripeLines.size / 4) stripeLines[i * 4 + 2] = stageWidth
        stripes.color = KP.argb(KP.p.stripe)
        c.drawLines(stripeLines, stripes)
    }

    fun drawScreens(c: Canvas) {
        KP.p = if (KPOverlayTheme.dark) KP.Dark else KP.Light
        val shown = stack.filter { !it.hidden } + closingScreens
        if (shown.isEmpty() && scrimAlpha <= 0f) return
        if (showBackdrop) backdrop?.let { c.drawBitmap(it, null, Rect(0, 0, host.width, host.height), null) }
        c.save()
        c.scale(scale, scale)
        if (scrimAlpha > 0f) KP.fill(c, RectF(0f, 0f, stageWidth, stageHeight), 0x000000, 0f, scrimAlpha * (if (KP.dark) .62f else .46f))
        for (screen in shown) {
            if (screen.alpha <= 0f) continue
            val saved = if (screen.alpha < 1f) c.saveLayerAlpha(0f, 0f, stageWidth, stageHeight, (screen.alpha * 255).toInt()) else c.save()
            screen.draw(c)
            c.restoreToCount(saved)
        }
        c.restore()
    }

    fun drawToasts(c: Canvas) {
        if (toasts.isEmpty()) return
        c.save()
        c.scale(scale, scale)
        for (toast in toasts) {
            if (!toast.started || toast.alpha <= 0f) continue
            val saved = c.saveLayerAlpha(toast.frame.left - 20, toast.frame.top - 20, toast.frame.right + 60, toast.frame.bottom + 20,
                (toast.alpha * 255).toInt())
            c.translate(toast.frame.left + toast.slide, toast.frame.top)
            KPToasts.draw(this, c, toast)
            c.restoreToCount(saved)
        }
        c.restore()
    }

    // MARK: Frames: animations, springs, ticks

    private class Anim(val start: Long, val duration: Long, val ease: (Float) -> Float, val frame: (Float) -> Unit, val end: (() -> Unit)?)
    private val anims = ArrayList<Anim>()
    private var framesRunning = false
    private var lastFrame = 0L
    private var lastTick = 0L

    private val frameCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            val now = SystemClock.uptimeMillis()
            val dt = if (lastFrame == 0L) 1 / 60f else min(.05f, (now - lastFrame) / 1000f)
            lastFrame = now
            var busy = active || toasts.isNotEmpty()
            if (active) onFrame?.invoke(now)
            if (anims.isNotEmpty()) {
                busy = true
                for (anim in anims.toList()) {
                    val t = if (anim.duration <= 0) 1f else ((now - anim.start).toFloat() / anim.duration).coerceIn(0f, 1f)
                    anim.frame(anim.ease(t))
                    if (t >= 1f) {
                        anims.remove(anim)
                        anim.end?.invoke()
                    }
                }
                invalidate()
            }
            if (stepSprings(dt)) {
                busy = true
                invalidate()
            }
            if (active && now - lastTick >= 33) {
                lastTick = now
                top?.tick()
            }
            if (busy) Choreographer.getInstance().postFrameCallback(this)
            else {
                framesRunning = false
                lastFrame = 0L
            }
        }
    }

    private fun startFrames() {
        if (framesRunning) return
        framesRunning = true
        Choreographer.getInstance().postFrameCallback(frameCallback)
    }

    /** Something started moving (a spring); keep the frames coming. */
    fun animating() = startFrames()

    fun animate(duration: Long, ease: (Float) -> Float = ::easeOut, onFrame: (Float) -> Unit, end: (() -> Unit)? = null) {
        anims += Anim(SystemClock.uptimeMillis(), duration, ease, onFrame, end)
        startFrames()
    }

    // Scales about the centre with a spring (damping 15, stiffness 320, as on the Mac).
    private fun stepSprings(dt: Float): Boolean {
        var moving = false
        val screens = stack + closingScreens
        for (screen in screens) for (item in screen.items) {
            val button = item as? KPButton ?: continue
            if (button.scale == button.springTarget && button.springVelocity == 0f) continue
            var remaining = dt
            while (remaining > 0) {
                val step = min(remaining, .004f)
                val acceleration = -320 * (button.scale - button.springTarget) - 15 * button.springVelocity
                button.springVelocity += acceleration * step
                button.scale += button.springVelocity * step
                remaining -= step
            }
            if (abs(button.scale - button.springTarget) < .0005f && abs(button.springVelocity) < .001f) {
                button.scale = button.springTarget
                button.springVelocity = 0f
            } else moving = true
        }
        return moving
    }

    /** A little side-to-side wobble about the centre: a card saying hello. Nothing with Reduce Motion. */
    fun wobble(item: KPItem) {
        if (reduceMotion) return
        val frames = floatArrayOf(0f, .05f, -.045f, .03f, -.015f, 0f)
        animate(550, ::easeInOut, onFrame = { t ->
            val at = t * (frames.size - 1)
            val i = min(frames.size - 2, at.toInt())
            item.rotation = frames[i] + (frames[i + 1] - frames[i]) * (at - i)
        }) { item.rotation = 0f }
    }

    // MARK: Toasts

    /**
     * Toasts come in front of the game and any screen, and never take the focus or a touch. A toast raised
     * on a screen goes when that screen goes.
     */
    fun toast(heading: String, detail: String? = null, stripe: Int = 0, icon: ((Canvas, RectF) -> Unit)? = null,
              image: Bitmap? = null, seconds: Float = 3.4f) {
        val toast = KPToast(heading, detail, stripe, icon, image)
        toast.owner = top
        toast.owned = top != null
        show(toast, seconds)
    }

    fun toastController(heading: String, detail: String?, player: Int, mii: ByteArray?, icon: ((Canvas, RectF) -> Unit)?,
                        art: (Canvas, RectF) -> Unit) {
        show(KPToast(heading, detail, 0, icon, null, player, mii, art), 3.4f)
    }

    private fun show(toast: KPToast, seconds: Float) {
        attach()
        toast.seconds = seconds
        // The same toast again renews the one already up rather than stacking a copy.
        for (shown in toasts) {
            if (shown.leaving || shown.player != toast.player || shown.owner !== toast.owner || shown.owned != toast.owned ||
                shown.heading != toast.heading || (shown.detail ?: "") != (toast.detail ?: "")) continue
            shown.stripe = toast.stripe
            shown.icon = toast.icon
            shown.image = toast.image
            shown.mii = toast.mii
            shown.art = toast.art
            shown.seconds = seconds
            invalidate()
            if (shown.started) time(shown)
            return
        }
        toasts += toast
        while (toasts.size > 4) toasts.removeAt(0)
        layoutToasts(true)
        startFrames()
    }

    private fun start(toast: KPToast) {
        toast.started = true
        toast.alpha = 0f
        toast.slide = if (reduceMotion) 0f else 40f
        animate(280, { t -> overshoot(t) }, onFrame = { t ->
            toast.alpha = t.coerceIn(0f, 1f)
            toast.slide = (if (reduceMotion) 0f else 40f) * (1 - t)
        })
        time(toast)
    }

    private fun time(toast: KPToast) {
        val showing = ++toast.showing
        host.postDelayed({ if (toast.showing == showing) dismissToast(toast) }, (toast.seconds * 1000).toLong())
    }

    private fun dismissToast(toast: KPToast) {
        if (toast.leaving || toast !in toasts) return
        toast.leaving = true
        val from = toast.alpha
        animate(if (toast.started) 250L else 0L, onFrame = { t -> toast.alpha = from * (1 - t) }) {
            toasts.remove(toast)
            layoutToasts(true)
            if (!active && toasts.isEmpty()) host.visibility = View.GONE
        }
    }

    /** Takes away the toasts raised on screen (and any whose screen has gone or isn't on top). */
    fun dismissToastsFrom(screen: KPScreen?) {
        for (toast in toasts.toList())
            if (toast.owned && (toast.owner == null || toast.owner === screen || toast.owner !== top)) dismissToast(toast)
    }

    private fun dismissStaleToasts() = dismissToastsFrom(null)

    private fun layoutToasts(animated: Boolean) {
        val width = KPToasts.Width
        val height = KPToasts.Height
        val screen = top
        val starts = ArrayList<Pair<PointF, Int>>()
        val controls = ArrayList<RectF>()
        if (screen == null) {
            starts += PointF(stageWidth - width - 18, 18f) to 1
        } else {
            for (spot in screen.toastSpots()) starts += spot to if (spot.y + height / 2 > safe.centerY()) -1 else 1
            val mid = round(safe.centerX() - width / 2)
            starts += PointF(mid, safe.top + 6) to 1
            starts += PointF(mid, safe.top + 588) to -1
            starts += PointF(safe.right - width - 18, safe.top + 112) to 1
            for (item in screen.items) {
                val button = item as? KPButton ?: continue
                if (button.hidden) continue
                // The face and a little room round it (the Mac's frame less margin - 3).
                controls += RectF(button.frame.left - 3, button.frame.top - 3, button.frame.right + 3, button.frame.bottom + 3)
            }
        }
        fun card(p: PointF) = RectF(p.x + 6, p.y + 4, p.x + width - 6, p.y + height - 8)
        fun place(start: Pair<PointF, Int>, i: Int) = PointF(start.first.x, start.first.y + start.second * i * (height - 4))
        fun fits(start: Pair<PointF, Int>, count: Int): Boolean {
            for (i in 0 until count) {
                val r = card(place(start, i))
                if (r.top < 0 || r.bottom > stageHeight) return false
                if (controls.any { RectF.intersects(it, r) }) return false
            }
            return true
        }
        val shown = toasts.filter { !it.leaving }
        if (shown.isEmpty() || starts.isEmpty()) return
        val start = starts.firstOrNull { fits(it, shown.size) } ?: starts.firstOrNull { fits(it, 1) } ?: starts.first()
        shown.forEachIndexed { i, toast ->
            val at = place(start, i)
            val target = RectF(at.x, at.y, at.x + width, at.y + height)
            if (!toast.started) {
                toast.frame.set(target)
                start(toast)
            } else if (animated) {
                val from = RectF(toast.frame)
                animate(250, onFrame = { t ->
                    toast.frame.set(from.left + (target.left - from.left) * t, from.top + (target.top - from.top) * t,
                        from.right + (target.right - from.right) * t, from.bottom + (target.bottom - from.bottom) * t)
                })
            } else toast.frame.set(target)
        }
        invalidate()
    }

    // MARK: Accessibility (TalkBack): the top screen's controls as virtual views

    // Android throws when an event is sent with accessibility off, so only while a service listens.
    private val accessibilityOn: Boolean
        get() = activity.getSystemService(android.view.accessibility.AccessibilityManager::class.java)?.isEnabled == true

    private fun sendAccessibilityChange() {
        if (accessibilityOn && host.isAttachedToWindow) host.sendAccessibilityEvent(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED)
    }

    private fun sendAccessibilityFocus(button: KPButton) {
        val index = top?.focusables()?.indexOf(button) ?: -1
        if (index < 0 || !accessibilityOn || !host.isAttachedToWindow) return
        val event = AccessibilityEvent.obtain(AccessibilityEvent.TYPE_VIEW_FOCUSED)
        event.setSource(host, index + 1)
        event.packageName = activity.packageName
        event.className = android.widget.Button::class.java.name
        button.label?.let { event.text.add(it) }
        host.parent?.requestSendAccessibilityEvent(host, event)
    }

    val accessibility = object : AccessibilityNodeProvider() {
        override fun createAccessibilityNodeInfo(virtualViewId: Int): AccessibilityNodeInfo? {
            val controls = top?.focusables() ?: emptyList()
            if (virtualViewId == View.NO_ID) {
                val info = AccessibilityNodeInfo.obtain(host)
                host.onInitializeAccessibilityNodeInfo(info)
                for (i in controls.indices) info.addChild(host, i + 1)
                return info
            }
            val button = controls.getOrNull(virtualViewId - 1) ?: return null
            val info = AccessibilityNodeInfo.obtain(host, virtualViewId)
            info.setParent(host)
            info.packageName = activity.packageName
            info.className = android.widget.Button::class.java.name
            info.text = button.label ?: ""
            info.isEnabled = button.enabled
            info.isClickable = true
            info.isFocusable = true
            info.isFocused = button.focused
            info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_CLICK)
            val location = IntArray(2)
            host.getLocationOnScreen(location)
            val r = button.frame
            info.setBoundsInScreen(Rect((r.left * scale).toInt() + location[0], (r.top * scale).toInt() + location[1],
                (r.right * scale).toInt() + location[0], (r.bottom * scale).toInt() + location[1]))
            return info
        }

        override fun performAction(virtualViewId: Int, action: Int, arguments: Bundle?): Boolean {
            val button = top?.focusables()?.getOrNull(virtualViewId - 1) ?: return false
            return when (action) {
                AccessibilityNodeInfo.ACTION_CLICK -> {
                    focus(button, false)
                    button.fire()
                    true
                }
                else -> false
            }
        }
    }
}

/** Light or dark, as the launcher's theme switch chose it (SharedPreferences kartpad_launcher/dark_mode). */
object KPOverlayTheme {
    var dark = true
}

/**
 * A slider dragged with a finger saves its level once the drag rests a moment, or is let go, rather than
 * at every step; anything else that saves the same setting saves the waiting level first.
 */
object KPSlide {
    private var save: (() -> Unit)? = null
    private var saves = 0
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

    fun saveNow() {
        val pending = save
        save = null
        pending?.invoke()
    }

    fun saveSoon(block: () -> Unit) {
        save = block
        val mine = ++saves
        handler.postDelayed({ if (mine == saves) saveNow() }, 300)
    }
}

fun easeOut(t: Float) = 1 - (1 - t) * (1 - t)
fun easeInOut(t: Float) = if (t < .5f) 2 * t * t else 1 - 2 * (1 - t) * (1 - t)
/** CAMediaTimingFunction(0.2, 1.3, 0.4, 1): a small overshoot. */
fun overshoot(t: Float): Float {
    // Cubic Bézier with control points (0.2, 1.3) and (0.4, 1), solved for x by bisection.
    fun bezier(a: Float, b: Float, s: Float) = 3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s
    var lo = 0f
    var hi = 1f
    repeat(20) {
        val mid = (lo + hi) / 2
        if (bezier(.2f, .4f, mid) < t) lo = mid else hi = mid
    }
    return bezier(1.3f, 1f, (lo + hi) / 2)
}
