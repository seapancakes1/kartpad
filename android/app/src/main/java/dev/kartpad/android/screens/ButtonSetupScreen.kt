package dev.kartpad.android.screens

import android.graphics.Canvas
import android.graphics.RectF
import android.os.SystemClock
import dev.kartpad.android.KartPadControllerMapping
import kotlin.math.max
import kotlin.math.sin

// Button setup (the Mac's KPRemapScreen): which controller button does each of the game's actions.
// Android has one set for every controller (KartPadControllerMapping: the twelve buttons the game
// reads, each on a physical button or trigger), so this changes that set. A on an action waits for
// the next button or trigger on the controller; the action that had it takes the old one. Reset goes
// back to the standard buttons. Changes save by themselves and apply at once. Sticks and Start stay
// as they are.
class ButtonSetupScreen(overlay: KPOverlay, private val instance: Int = -1) : KPScreen(overlay) {
    private val context = overlay.activity
    private val rows = ArrayList<KPButton>()
    private lateinit var reset: KPButton
    private lateinit var done: KPButton
    private lateinit var art: KPItem
    private var mapping = IntArray(12) { it }
    private var capturing = -1              // action index, -1 when not listening
    private var captureFrom = -1            // the pad listened to; -1 for any
    private var captureStarted = 0L
    private val clear = HashSet<Int>()      // pads that have let everything go since listening began
    private var status: String? = null
    // The press that was taken isn't also a press on the screen.
    private var swallowUntil = 0L

    private val titles get() = KartPadControllerMapping.gameButtonNames

    companion object {
        // The physical buttons (KartPadControllerMapping's order) in SDL's numbering; the triggers are axes.
        private val Native = intArrayOf(SDLButton.South, SDLButton.East, SDLButton.West, SDLButton.North, SDLButton.LeftShoulder,
            SDLButton.RightShoulder, SDLButton.DpadUp, SDLButton.DpadDown, SDLButton.DpadLeft, SDLButton.DpadRight, -1, -1)
        private val NativeMask = Native.filter { it >= 0 }.fold(0L) { mask, button -> mask or (1L shl button) }
        private const val LeftTrigger = 10
        private const val RightTrigger = 11
    }

    // The controller the drawing and the button names are for: the one being set up, else the one in hand.
    private fun device(): KPPadDevice? = KartPadPads.device(instance) ?: KartPadPads.hintDevice()

    // A physical button as the controller in hand labels it.
    private fun buttonName(physical: Int): String {
        val device = device() ?: return KartPadControllerMapping.physicalButtonNames.getOrElse(physical) { "—" }
        val family = device.family
        val ps = family == KPPadFamily.PlayStation
        val nintendo = family == KPPadFamily.Switch || family == KPPadFamily.JoyCon
        return when (physical) {
            in 0..3 -> when (device.labels.getOrElse(physical) { SDLLabel.Unknown }) {
                SDLLabel.A -> "A"
                SDLLabel.B -> "B"
                SDLLabel.X -> "X"
                SDLLabel.Y -> "Y"
                SDLLabel.Cross -> "Cross"
                SDLLabel.Circle -> "Circle"
                SDLLabel.Square -> "Square"
                SDLLabel.Triangle -> "Triangle"
                else -> when {
                    ps -> arrayOf("Cross", "Circle", "Square", "Triangle")[physical]
                    nintendo -> arrayOf("B", "A", "Y", "X")[physical]
                    family == KPPadFamily.GameCube -> arrayOf("A", "X", "B", "Y")[physical]
                    else -> arrayOf("A", "B", "X", "Y")[physical]
                }
            }
            4 -> if (ps) "L1" else if (nintendo) "L" else "LB"
            5 -> if (ps) "R1" else if (nintendo) "R" else "RB"
            6 -> "D-pad up"
            7 -> "D-pad down"
            8 -> "D-pad left"
            9 -> "D-pad right"
            LeftTrigger -> if (ps) "L2" else if (nintendo) "ZL" else if (family == KPPadFamily.GameCube) "L" else "LT"
            RightTrigger -> if (ps) "R2" else if (nintendo) "ZR" else if (family == KPPadFamily.GameCube) "R" else "RT"
            else -> "—"
        }
    }

    override fun build() {
        solid = true
        title = "Buttons"
        mapping = KartPadControllerMapping.load(context)
        for (i in titles.indices) {
            val row = button(RectF(), { c, r, state -> drawRow(i, c, r, state) }) { listen(i) }
            row.tag2 = i
            row.radius = 10f
            row.margin = 5f
            row.focusScale = 1.01f
            row.label = titles[i]
            rows += row
        }
        reset = button(RectF(), { c, r, state -> KPFaces.pill(c, r, state, KPStyle.Plain, KPUIGlyph.Restart, "Reset") }) { askToReset() }
        reset.label = "Reset"
        done = button(RectF(), { c, r, state -> KPFaces.pill(c, r, state, KPStyle.Primary, KPUIGlyph.Check, "Done") }) { overlay.pop() }
        done.label = "Done"
        done.sound = KPUISound.Saved
        art = decor(RectF()) { c, r -> drawArt(c, r) }
    }

    override fun layoutDesign() {
        val s = safe
        for (row in rows) {
            val top = s.top + 118 + row.tag2 * 46
            place(row, RectF(s.left + 52, top, s.left + 652, top + 42))
        }
        place(art, RectF(s.left + 690, s.top + 150, s.left + 1230, s.top + 480))
        place(reset, RectF(s.left + 690, s.top + 590, s.left + 980, s.top + 650))
        place(done, RectF(s.right - 222, s.top + 590, s.right - 52, s.top + 650))
    }

    override fun initialFocus(): KPButton? = rows.firstOrNull()

    override fun willAppear() {
        mapping = KartPadControllerMapping.load(context)
    }

    // MARK: Listening

    override val listening: Boolean get() = capturing >= 0

    private fun listen(action: Int) {
        capturing = action
        captureFrom = KartPadPads.device(instance)?.instance ?: -1
        captureStarted = SystemClock.uptimeMillis()
        clear.clear()
        status = null
        overlay.play(KPUISound.Open)
        invalidate()
    }

    private fun stopListening(status: String?, sound: KPUISound) {
        capturing = -1
        this.status = status
        overlay.play(sound)
        invalidate()
    }

    private fun listenedTo(): List<KPPadDevice> = KartPadPads.devices.filter { captureFrom < 0 || it.instance == captureFrom }

    override fun tick() {
        invalidate()  // the drawing follows the controller, the buttons bound to the action in focus pulse
        if (capturing < 0) return
        if (SystemClock.uptimeMillis() - captureStarted > 8000) {
            stopListening("Nothing changed.", KPUISound.Close)
            return
        }
        if (captureFrom >= 0 && KartPadPads.device(captureFrom) == null) {
            stopListening("The controller disconnected.", KPUISound.Reject)
            return
        }
        // Wait for everything to be let go, then take the next button (rawPress) or trigger.
        for (pad in listenedTo()) {
            val left = pad.axes[SDLAxis.LeftTrigger]
            val right = pad.axes[SDLAxis.RightTrigger]
            if (pad.instance !in clear) {
                if ((pad.buttons and NativeMask) == 0L && left < .06f && right < .06f) clear += pad.instance
                continue
            }
            if (left > .61f) {
                bind(LeftTrigger)
                return
            }
            if (right > .61f) {
                bind(RightTrigger)
                return
            }
        }
    }

    override fun rawPress(device: KPPadDevice, pressed: Long) {
        if (capturing < 0 || device.instance !in clear) return
        if (captureFrom >= 0 && device.instance != captureFrom) return
        val physical = Native.indexOfFirst { it >= 0 && ((pressed shr it) and 1L) != 0L }
        if (physical < 0) return
        swallowUntil = SystemClock.uptimeMillis() + 150
        bind(physical)
    }

    private fun bind(physical: Int) {
        val action = capturing
        if (action < 0) return
        mapping = KartPadControllerMapping.assign(context, action, physical)
        applyMapping()
        stopListening("${titles[action]} is now ${buttonName(physical)}.", KPUISound.Saved)
    }

    private fun applyMapping() {
        KartPadPads.mapping = mapping.copyOf()
        KartPadScreens.host.applyControllerMapping()
    }

    override fun handle(button: KPPad): Boolean {
        if (SystemClock.uptimeMillis() <= swallowUntil) return true
        if (capturing < 0) return false
        // Keys while listening (the pads are being listened to): Back stops.
        if (button == KPPad.Back) stopListening("Nothing changed.", KPUISound.Close)
        return true
    }

    private fun askToReset() {
        KPAsk.ask(overlay, "Reset the Buttons?", "Every controller goes back to the standard buttons.", listOf("Reset", "Cancel"), 1, 0) { choice ->
            if (choice == 0) {
                mapping = KartPadControllerMapping.reset(context)
                applyMapping()
                status = "Back to the standard buttons."
                overlay.play(KPUISound.PagePrevious)
                invalidate()
            }
        }
    }

    override fun back() {
        if (capturing >= 0) {
            stopListening("Nothing changed.", KPUISound.Close)
            return
        }
        super.back()
    }

    // Closed or covered while listening: stop, or the pads stay quiet for it.
    override fun willDisappear() {
        if (capturing < 0) return
        capturing = -1
        status = null
    }

    // MARK: Drawing

    private fun drawRow(i: Int, c: Canvas, r: RectF, state: KPUIState) {
        val live = capturing == i
        KP.buttonFace(c, r, KPStyle.Plain, live, state.enabled, state.pressed, state.focused)
        val dy = if (state.pressed) 2f else 0f
        KP.text(c, titles[i], RectF(r.left + 18, r.centerY() - 13 + dy, r.left + 318, r.centerY() + 13 + dy), 18f, KP.p.text,
            KPWeight.Semibold, KPAlign.Left)
        val chip = if (live) "Press…" else buttonName(mapping.getOrElse(i) { i })
        val w = max(64f, KP.textWidth(chip, 16f, KPWeight.Bold) + 26)
        val pill = RectF(r.right - 14 - w, r.centerY() - 15 + dy, r.right - 14, r.centerY() + 13 + dy)
        KP.fill(c, pill, if (live) KP.p.accentBottom else KP.p.well, 14f)
        KP.stroke(c, pill, if (live) KP.p.accentLedge else KP.p.buttonStroke, 1f, 14f)
        KP.text(c, chip, RectF(pill.left, pill.top + 4, pill.right, pill.top + 26), 16f, if (live) 0xffffff else KP.p.text, KPWeight.Bold)
    }

    private fun drawArt(c: Canvas, r: RectF) {
        val device = device()
        val accent = device?.slot?.takeIf { it in 0..3 }?.let { KP.PlayerColors[it] } ?: KP.p.accentBottom
        val state = KPControllerArt.stateFor(device, accent)
        // The button bound to the action in focus pulses.
        val focus = focus
        if (capturing < 0 && focus != null && focus in rows) {
            val native = Native.getOrElse(mapping.getOrElse(focus.tag2) { -1 }) { -1 }
            if (native >= 0) state.highlight = 1L shl native
            state.pulse = .5f + .5f * sin(SystemClock.uptimeMillis() / 1000.0 * 5).toFloat()
        }
        KPControllerArt.draw(c, r, device?.family ?: KPPadFamily.Generic, state, device?.systemName)
    }

    override fun drawDesign(c: Canvas) {
        super.drawDesign(c)
        val s = safe
        KP.text(c, "Buttons", RectF(s.left + 56, s.top + 26, s.left + 456, s.top + 76), 36f, KP.p.text, KPWeight.Bold, KPAlign.Left)
        KP.text(c, "For every controller", RectF(s.left + 58, s.top + 76, s.left + 758, s.top + 102), 18f, KP.p.secondaryText,
            KPWeight.Medium, KPAlign.Left)
        val line = RectF(s.left + 690, s.top + 500, s.left + 1230, s.top + 556)
        val status = status
        if (capturing >= 0) {
            val left = max(0L, 8 - (SystemClock.uptimeMillis() - captureStarted) / 1000)
            KP.text(c, "Press a button for ${titles[capturing]} ($left)", line, 20f, KP.p.accentBottom, KPWeight.Semibold)
        } else if (status != null) {
            KP.text(c, status, line, 20f, KP.p.secondaryText, KPWeight.Semibold)
        } else {
            KPHints.draw(c, RectF(line.left, line.top, line.right, line.top + 28),
                listOf(KPHint(KPPad.Confirm, "Change"), KPHint(KPPad.Back, "Back")), 18f, KPAlign.Center, device())
        }
    }
}
