package dev.kartpad.android.screens

import android.graphics.Canvas
import android.graphics.PointF
import android.graphics.RectF
import android.view.KeyEvent
import android.view.View
import kotlin.math.max
import kotlin.math.min
import kotlin.math.round

// KartPad's screens over the game, after the Mac's overlay kit (apple/macos/KartPadOverlay.inc.mm):
// each screen is laid out on one 1280×720 design canvas that scales with the view, like a console's
// menus. Controls are drawn, not Views: a screen keeps an ordered list of items (decoration and
// buttons) and draws them in that order, so ports of the Mac's screens keep their structure.

/** The Mii editor's sounds (runtime/include/kartpad/mii/editor_sounds.h), in its order. */
enum class KPUISound { Hover, Tick, Press, Tab, Same, Confirm, Left, Right, PageNext, PagePrevious, Key, Erase, Open, Close, Dialog, Saved, Reject, NewMii }

data class KPUIState(val focused: Boolean, val pressed: Boolean, val enabled: Boolean)

/** Something a screen draws at a design rect. Decoration takes no touches. */
open class KPItem(val screen: KPScreen) {
    val frame = RectF()
    var hidden = false
        set(value) { if (field != value) { field = value; screen.invalidate() } }
    var alpha = 1f
    /** Animated transforms about the centre (springs, wobbles). */
    var scale = 1f
    var rotation = 0f
    var dx = 0f
    var dy = 0f
    var paint: ((Canvas, RectF) -> Unit)? = null
    open fun draw(c: Canvas) { paint?.invoke(c, frame) }
    fun invalidate() = screen.invalidate()
}

/**
 * A Wii-style control: a face its block paints, the focus ring, a springy pop when it takes the focus.
 * frame is the face; the margin around it holds the focus glow.
 */
class KPButton(screen: KPScreen) : KPItem(screen) {
    var face: ((Canvas, RectF, KPUIState) -> Unit)? = null
    var activate: (() -> Unit)? = null
    /** Left and right change the control in place (a slider, a choice) rather than moving the focus. */
    var adjust: ((Int) -> Boolean)? = null
    /** A slider's track under a finger: called with the press (began) and each drag after it, in design points. */
    var slide: ((x: Float, y: Float, face: RectF, began: Boolean) -> Boolean)? = null
    var enabled = true
        set(value) { if (field != value) { field = value; invalidate() } }
    var focused = false
        internal set(value) {
            if (field == value) return
            field = value
            springTo(if (value) focusScale else 1f)
            invalidate()
        }
    var pressed = false
        set(value) {
            if (field == value) return
            field = value
            springTo(if (value) .97f else if (focused) focusScale else 1f)
            invalidate()
        }
    /** The last press that fired the action was a touch (not A from a pad or the keyboard). */
    var clicked = false
        private set
    var sound: KPUISound? = KPUISound.Press
    var margin = 8f
    var radius = 14f
    var focusScale = 1.04f
    var label: String? = null
    var tagObject: Any? = null
    var tag2 = 0
    /** The corner radius the face last drew with (0 before it has drawn). */
    internal var faceRadius = 0f
    internal var springTarget = 1f
    internal var springVelocity = 0f

    fun springTo(k: Float) {
        springTarget = k
        if (screen.overlay.reduceMotion) {
            scale = k
            springVelocity = 0f
        }
        screen.overlay.animating()
    }

    override fun draw(c: Canvas) {
        val state = KPUIState(focused, pressed, enabled)
        // The ring's corners follow the face's: those of the button face it draws, or the button's radius.
        val ring = if (faceRadius > 0) faceRadius else radius
        if (focused && enabled) KP.focusRing(c, frame, ring)
        KP.faceRadiusDrawn = -1f
        face?.invoke(c, frame, state)
        val drawn = if (KP.faceRadiusDrawn >= 0) KP.faceRadiusDrawn else radius
        KP.faceRadiusDrawn = -1f
        if (drawn != ring) {
            faceRadius = drawn
            if (focused) invalidate()
        }
    }

    fun fire(touch: Boolean = false) {
        val run = activate ?: return
        if (!enabled) return
        clicked = touch
        sound?.let { screen.overlay.play(it) }
        // Let this press finish before the action opens or closes a screen.
        screen.overlay.post(run)
    }

    /** Where a finger lands counts within the face plus its margin, and never less than a 44 dp target. */
    fun hit(x: Float, y: Float): Boolean {
        if (hidden || !enabled) return false
        val target = screen.overlay.touchTarget
        val w = frame.width() + 2 * margin
        val h = frame.height() + 2 * margin
        val ex = max(margin, margin + (target - w) / 2)
        val ey = max(margin, margin + (target - h) / 2)
        return x >= frame.left - ex && x <= frame.right + ex && y >= frame.top - ey && y <= frame.bottom + ey
    }
}

open class KPScreen(val overlay: KPOverlay) {
    val items = ArrayList<KPItem>()
    var focus: KPButton? = null
    /** Pinstriped Mii Channel panel behind everything (the game hidden); otherwise the game shows dimmed. */
    var solid = false
    /** The game holds still while this screen is open. */
    var pausesGame = true
    var title: String? = null
    var alpha = 1f
    var hidden = false
    /** Native views placed on the canvas (the Mii preview, a name field), removed with the screen. */
    val views = LinkedHashMap<View, RectF>()
    private var built = false

    /** The 1280×720 design area, in design points (the screen covers the whole view). */
    val safe: RectF get() = overlay.safe
    /** The whole view in design points. */
    val width get() = overlay.stageWidth
    val height get() = overlay.stageHeight

    open fun build() {}
    open fun layoutDesign() {}
    fun relayout() {
        if (!built) {
            built = true
            build()
        }
        layoutDesign()
        overlay.placeViews(this)
        invalidate()
    }
    fun invalidate() = overlay.invalidate()

    fun place(item: KPItem, design: RectF) {
        item.frame.set(design)
        if (item !in items) items += item
    }
    fun place(item: KPItem, x: Float, y: Float, w: Float, h: Float) = place(item, RectF(x, y, x + w, y + h))

    fun button(design: RectF, face: (Canvas, RectF, KPUIState) -> Unit, action: (() -> Unit)?): KPButton {
        val button = KPButton(this)
        button.face = face
        button.activate = action
        place(button, design)
        return button
    }

    fun decor(design: RectF, paint: (Canvas, RectF) -> Unit): KPItem {
        val item = KPItem(this)
        item.paint = paint
        place(item, design)
        return item
    }

    fun remove(item: KPItem) {
        items.remove(item)
        if (focus === item) focus = null
    }

    /** A native view over the canvas at a design rect, kept in place as the screen lays out. */
    fun placeView(view: View, design: RectF) {
        views[view] = RectF(design)
        overlay.placeViews(this)
    }

    open fun focusables(): List<KPButton> =
        items.filterIsInstance<KPButton>().filter { !it.hidden && it.enabled && (it.activate != null || it.adjust != null) }

    open fun initialFocus(): KPButton? = focusables().firstOrNull()

    /** A press the screen handles itself; false leaves it to the navigator (moving, A, B). */
    open fun handle(button: KPPad): Boolean = false

    /** A key the screen wants as itself (a key being chosen for a button), before it is navigation. */
    open fun takesKey(event: KeyEvent): Boolean = false

    /** The right stick across, -1 to 1, over seconds since the last call (the Mii editor turns its Mii). */
    open fun turn(x: Float, seconds: Float) {}

    /**
     * While true, controllers don't move the focus: every pad's new presses (SDLButton bits) go to
     * rawPress instead ("Press A on the controller for Player 2", Player Order, button setup).
     */
    open val listening: Boolean get() = false
    open fun rawPress(device: KPPadDevice, pressed: Long) {}
    /** Any pad pressed something (the Controllers screen bounces that pad's card). */
    open fun padActivity(device: KPPadDevice, pressed: Long) {}
    /** Controllers connected or disconnected. */
    open fun padsChanged() {}

    open fun back() = overlay.pop()
    /**
     * A question, menu or name entry over a solid screen (the Miis screen, the editor) keeps that screen
     * showing under it, as the Mac's alerts sit on the Mii windows; over HOME it shows over the game, as there.
     */
    open val overPrevious: Boolean get() = false
    /** HOME or Start would close every screen: true when this one has something to ask first. */
    open fun asksBeforeClosingAll(): Boolean = false
    /** Asks it; the screen closes everything itself (overlay.closeAll) once the answer allows. */
    open fun askBeforeClosingAll() {}
    open fun willAppear() {}
    open fun didAppear() {}
    open fun willDisappear() {}
    /** 30 times a second while showing. */
    open fun tick() {}

    /** Where this screen's toasts may go first (top-left corners, design points), before the usual places. */
    open fun toastSpots(): List<PointF> = emptyList()

    /** Behind the items. */
    open fun drawDesign(c: Canvas) {
        if (solid) overlay.drawBackdrop(c)
    }

    /** In front of the items. */
    open fun drawOver(c: Canvas) {}

    fun draw(c: Canvas) {
        drawDesign(c)
        for (item in items) {
            if (item.hidden || item.alpha <= 0f) continue
            val transformed = item.scale != 1f || item.rotation != 0f || item.dx != 0f || item.dy != 0f
            val saved = if (item.alpha < 1f) {
                val m = (item as? KPButton)?.margin ?: 0f
                c.saveLayerAlpha(item.frame.left - m - 12, item.frame.top - m - 12, item.frame.right + m + 12,
                    item.frame.bottom + m + 12, (item.alpha * 255).toInt())
            } else c.save()
            if (transformed) {
                c.translate(item.dx, item.dy)
                c.rotate(Math.toDegrees(item.rotation.toDouble()).toFloat(), item.frame.centerX(), item.frame.centerY())
                c.scale(item.scale, item.scale, item.frame.centerX(), item.frame.centerY())
            }
            item.draw(c)
            c.restoreToCount(saved)
        }
        drawOver(c)
    }

    /** The topmost enabled control under a design point. */
    fun buttonAt(x: Float, y: Float): KPButton? =
        items.asReversed().firstOrNull { it is KPButton && it.hit(x, y) } as KPButton?
}

/** A Wii-style question over whatever is showing: a heading, a message and two or three big buttons; B picks the last. */
class KPDialogScreen(overlay: KPOverlay) : KPScreen(overlay) {
    override val overPrevious get() = true
    var heading = ""
    var message = ""
    var choices: List<String> = emptyList()
    var primary = 0
    var destructive = -1
    var warning = false
    var done: ((Int) -> Unit)? = null

    private fun card(): RectF {
        val s = safe
        val text = kotlin.math.ceil(KP.textHeight(message, 680f, 21f, KPWeight.Regular))
        val height = min(560f, 92 + text + 40 + 104)
        val top = round(s.top + (720 - height) / 2)
        return RectF(s.left + 260, top, s.left + 260 + 760, top + height)
    }

    override fun build() {
        for (i in choices.indices) {
            val button = button(RectF(), { c, r, state ->
                val isPrimary = i == primary
                KP.buttonFace(c, r, if (isPrimary) KPStyle.Primary else KPStyle.Plain, false, state.enabled, state.pressed, state.focused)
                val ink = if (isPrimary) 0xffffff else if (i == destructive) KP.p.danger else KP.p.text
                KP.text(c, choices[i], RectF(r.left, r.centerY() - 16, r.right, r.centerY() + 16), 23f, ink, KPWeight.Semibold)
            }) {
                val finish = done
                overlay.pop()
                finish?.invoke(i)
            }
            button.tag2 = i
            button.label = choices[i]
            button.sound = if (i == choices.size - 1) KPUISound.Close else KPUISound.Confirm
        }
    }

    override fun layoutDesign() {
        val card = card()
        val count = choices.size
        val gap = 20f
        val width = (card.width() - 64 - gap * (count - 1)) / count
        for (button in items.filterIsInstance<KPButton>()) {
            val x = card.left + 32 + button.tag2 * (width + gap)
            place(button, RectF(x, card.bottom - 104, x + width, card.bottom - 32))
        }
    }

    override fun initialFocus(): KPButton? = focusables().firstOrNull { it.tag2 == primary } ?: super.initialFocus()
    override fun willAppear() = overlay.play(KPUISound.Dialog)
    override fun back() {
        val finish = done
        overlay.pop()
        finish?.invoke(choices.size - 1)
    }

    override fun drawDesign(c: Canvas) {
        KP.fill(c, RectF(0f, 0f, width, height), 0x000000, 0f, .35f)
        val card = card()
        KP.shadowed(c, 10f, 30f, .35f, card, KP.p.panel, 28f)
        KP.stroke(c, card, KP.p.panelStroke, 1.5f, 28f)
        KP.text(c, heading, RectF(card.left + 40, card.top + 30, card.right - 40, card.top + 74), 31f, KP.p.text, KPWeight.Bold, KPAlign.Left)
        KP.text(c, message, RectF(card.left + 40, card.top + 92, card.right - 40, card.bottom - 104), 21f,
            if (warning) KP.p.danger else KP.p.secondaryText, if (warning) KPWeight.Medium else KPWeight.Regular, KPAlign.Left)
    }
}

class KPMenuItem(val title: String, val detail: String?, val glyph: KPUIGlyph?, val enabled: Boolean, val run: (() -> Unit)?)

/** A short Wii-style menu over the current screen: a heading and a column of big choices with icons. A picks, B closes. */
class KPMenuScreen(overlay: KPOverlay) : KPScreen(overlay) {
    override val overPrevious get() = true
    var heading = ""
    var message: String? = null
    /** The choice in effect, focused first and marked with chosenGlyph; -1 for none. */
    var chosen = -1
    var chosenGlyph: KPUIGlyph? = null
    private val entries = ArrayList<KPMenuItem>()

    fun add(title: String, detail: String? = null, glyph: KPUIGlyph? = null, enabled: Boolean = true, run: (() -> Unit)?) {
        entries += KPMenuItem(title, detail, glyph, enabled, run)
    }

    private fun card(): RectF {
        val s = safe
        val height = 96 + (if (message.isNullOrEmpty()) 0 else 40) + 76f * entries.size + 18
        val top = round(s.top + (720 - height) / 2)
        return RectF(s.left + 340, top, s.left + 940, top + height)
    }

    override fun build() {
        entries.forEachIndexed { i, item ->
            val button = button(RectF(), { c, r, state ->
                KP.buttonFace(c, r, KPStyle.Plain, false, state.enabled, state.pressed, state.focused)
                val dy = if (state.pressed) 2f else 0f
                val x = if (item.glyph != null) r.left + 66 else r.left + 24
                item.glyph?.let { KPGlyphs.draw(c, it, RectF(r.left + 20, r.centerY() - 17 + dy, r.left + 52, r.centerY() + 15 + dy), KP.p.accentBottom) }
                if (!item.detail.isNullOrEmpty()) {
                    KP.text(c, item.title, RectF(x, r.top + 9 + dy, r.right - 16, r.top + 37 + dy), 21f, KP.p.text, KPWeight.Semibold, KPAlign.Left)
                    KP.text(c, item.detail, RectF(x, r.top + 36 + dy, r.right - 16, r.top + 58 + dy), 15f, KP.p.secondaryText, KPWeight.Regular, KPAlign.Left)
                } else {
                    KP.text(c, item.title, RectF(x, r.centerY() - 15 + dy, r.right - 16, r.centerY() + 15 + dy), 21f, KP.p.text, KPWeight.Semibold, KPAlign.Left)
                }
                val mark = chosenGlyph
                if (i == chosen && mark != null)
                    KPGlyphs.draw(c, mark, RectF(r.right - 50, r.centerY() - 15 + dy, r.right - 20, r.centerY() + 15 + dy), KP.p.accentBottom)
            }) {
                overlay.pop()
                item.run?.invoke()
            }
            button.tag2 = i
            button.enabled = item.enabled
            button.label = item.title
            button.sound = KPUISound.Confirm
        }
    }

    override fun initialFocus(): KPButton? = focusables().firstOrNull { it.tag2 == chosen && it.enabled } ?: super.initialFocus()

    override fun layoutDesign() {
        val card = card()
        val top = card.top + 96 + (if (message.isNullOrEmpty()) 0 else 40)
        for (button in items.filterIsInstance<KPButton>())
            place(button, RectF(card.left + 28, top + button.tag2 * 76, card.right - 28, top + button.tag2 * 76 + 66))
    }

    override fun willAppear() = overlay.play(KPUISound.Dialog)

    override fun drawDesign(c: Canvas) {
        KP.fill(c, RectF(0f, 0f, width, height), 0x000000, 0f, .35f)
        val card = card()
        KP.shadowed(c, 10f, 30f, .35f, card, KP.p.panel, 28f)
        KP.stroke(c, card, KP.p.panelStroke, 1.5f, 28f)
        KP.text(c, heading, RectF(card.left + 34, card.top + 28, card.right - 34, card.top + 72), 29f, KP.p.text, KPWeight.Bold, KPAlign.Left)
        message?.takeIf { it.isNotEmpty() }?.let {
            KP.text(c, it, RectF(card.left + 34, card.top + 80, card.right - 34, card.top + 130), 18f, KP.p.secondaryText, KPWeight.Regular, KPAlign.Left)
        }
    }
}
