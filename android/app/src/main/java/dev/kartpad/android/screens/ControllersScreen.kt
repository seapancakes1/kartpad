package dev.kartpad.android.screens

import android.content.Intent
import android.graphics.Canvas
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.os.SystemClock
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

// Controllers (the Mac's KartPadControllersScreen.inc.mm, as on iPhone): who plays with which
// controller, at a glance. Four player cards in the game's player colours, each with its Mii, a live
// drawing of the controller (it lights up as you press) and its battery; the controllers that aren't
// playing wait in a tray below. Press anything on a controller and its card bounces, so "which one is
// mine?" answers itself. A controller that isn't playing joins with A, and X makes a controller buzz
// and flash.
// Players change controllers by pressing on the controller they want, the way consoles do it:
// "Change controller" on a card (or A on an empty one) waits for A on the controller that should be
// that player; Player Order has everyone press A in turn, the first press becoming Player 1. Each
// card's menu also sets up buttons (ButtonSetupScreen), chooses a Mii or takes the controller out.
// Players are aurora's (KPRoster.move, stopPlaying). The touch screen is Player 1 while no controller
// is; it can't change player or stop. Android pairs controllers in its own Bluetooth settings, so
// Connect only says how.

/** Controllers, with the focus on a player's card (-1 for none); an empty player opens straight to choosing its controller. */
fun makeControllersScreen(overlay: KPOverlay, focusSlot: Int): KPScreen =
    ControllersScreen(overlay, focusSlot).also { it.assignOnOpen = focusSlot in 0..3 }

internal class ControllersScreen(overlay: KPOverlay, private val focusSlot: Int) : KPScreen(overlay) {
    // Choosing controllers by pressing on them: one player at a time, or everyone in order.
    private enum class Mode { Browsing, Assigning, Ordering }

    private val context = overlay.activity
    /** Opened on a player (HOME's strip, the reconnect card): straight to choosing its controller if it has none. */
    var assignOnOpen = false
    /** The reconnect card's Player 1: the touch screen standing in counts as no controller. */
    var assignOverTouch = false

    private val cards = ArrayList<KPButton>()
    private val chips = ArrayList<KPButton>()
    private lateinit var order: KPButton
    private lateinit var connect: KPButton
    private lateinit var done: KPButton
    // While controllers are being chosen by pressing: Done (everyone) and Cancel.
    private lateinit var finish: KPButton
    private lateinit var cancel: KPButton

    private var mode = Mode.Browsing
    private var target = 0                          // assigning: the player choosing a controller
    private val ordered = ArrayList<Int>()          // ordering: who has pressed (instances), in order
    private var before: Map<Int, Int> = emptyMap()  // ordering: who played as whom, for Cancel
    private var lastPress = 0L
    private var finishAt = 0L
    private var pulse = 0f
    // The press that ended choosing (or joined) isn't also a press on the screen.
    private var swallowUntil = 0L
    private var seating = 0L
    private var shownLook = 0L
    // Each controller's Mii (by instance; the touch screen is -1) until who plays as whom changes.
    private val miis = HashMap<Int, KPMiiInfo?>()

    override fun build() {
        solid = true
        title = "Controllers"
        order = button(RectF(), { c, r, state ->
            // Disabled (no pads): the whole pill fades, its word and icon too.
            val saved = if (!state.enabled) c.saveLayerAlpha(r.left - 4, r.top - 4, r.right + 4, r.bottom + 4, (.42f * 255).toInt())
                else c.save()
            KPFaces.pill(c, r, KPUIState(state.focused, state.pressed, true), KPStyle.Plain, KPUIGlyph.Order, "Player Order")
            c.restoreToCount(saved)
        }) { beginOrdering() }
        order.label = "Player Order"
        connect = button(RectF(), { c, r, state -> KPFaces.pill(c, r, state, KPStyle.Plain, KPUIGlyph.Plus, "Connect") }) {
            overlay.present(KPConnectScreen(overlay))
        }
        connect.label = "Connect a controller"
        done = button(RectF(), { c, r, state -> KPFaces.pill(c, r, state, KPStyle.Primary, KPUIGlyph.Check, "Done") }) { overlay.pop() }
        done.label = "Done"
        done.sound = KPUISound.Close
        finish = button(RectF(), { c, r, state -> KPFaces.pill(c, r, state, KPStyle.Primary, KPUIGlyph.Check, "Done") }) { endOrdering(true) }
        finish.label = "Done"
        finish.sound = null
        cancel = button(RectF(), { c, r, state -> KPFaces.pill(c, r, state, KPStyle.Plain, KPUIGlyph.Close, "Cancel") }) { cancelChoosing() }
        cancel.label = "Cancel"
        cancel.sound = null
        for (slot in 0 until 4) {
            val card = button(RectF(), { c, r, state -> drawCard(slot, c, r, state) }) { openCard(slot) }
            card.tag2 = slot
            card.radius = 20f
            card.focusScale = 1.025f
            card.label = KPFaces.playerName(slot)
            cards += card
        }
        // The tray shows four at most.
        for (index in 0 until 4) {
            val chip = button(RectF(), { c, r, state -> drawChip(index, c, r, state) }) { openChip(index) }
            chip.tag2 = index
            chip.radius = 16f
            chip.hidden = true
            chips += chip
        }
    }

    override fun layoutDesign() {
        val s = safe
        val browsing = mode == Mode.Browsing
        // The buttons along the top: what the screen does, or (choosing by pressing) how to stop.
        order.hidden = !browsing
        connect.hidden = !browsing
        done.hidden = !browsing
        finish.hidden = mode != Mode.Ordering
        cancel.hidden = browsing
        val right = s.right - 56
        val y = s.top + 30
        place(done, RectF(right - 150, y, right, y + 60))
        place(connect, RectF(right - 366, y, right - 166, y + 60))
        place(order, RectF(right - 632, y, right - 382, y + 60))
        place(cancel, RectF(right - 170, y, right, y + 60))
        place(finish, RectF(right - 356, y, right - 186, y + 60))
        // While choosing by pressing, the cards and tray only show what's happening.
        for (card in cards) card.enabled = browsing
        order.enabled = KartPadPads.devices.isNotEmpty()
        val width = 278f
        val gap = 20f
        val x0 = s.left + (1280 - (4 * width + 3 * gap)) / 2
        for (card in cards) {
            val x = x0 + card.tag2 * (width + gap)
            place(card, RectF(x, s.top + 120, x + width, s.top + 516))
        }
        layoutChips()
    }

    // The tray: controllers connected but not playing.
    private fun resting(): List<KPPadDevice> = KartPadPads.devices.filter { it.slot !in 0..3 && !it.isTouch && !it.isKeyboard }

    private fun layoutChips() {
        val s = safe
        val resting = resting()
        val width = 262f
        val gap = 16f
        val x0 = s.left + (1280 - (4 * 278f + 3 * 20f)) / 2
        for (chip in chips) {
            val device = resting.getOrNull(chip.tag2)
            chip.hidden = device == null
            chip.tagObject = device?.instance
            chip.label = device?.let { "${it.name}, not playing" }
            chip.enabled = mode == Mode.Browsing
            val x = x0 + chip.tag2 * (width + gap)
            place(chip, RectF(x, s.top + 568, x + width, s.top + 644))
        }
    }

    private fun chipDevice(chip: KPButton): KPPadDevice? = (chip.tagObject as? Int)?.let { KartPadPads.device(it) }

    override fun initialFocus(): KPButton? = when (mode) {
        Mode.Assigning -> cancel
        Mode.Ordering -> finish
        Mode.Browsing -> if (focusSlot in 0..3) cards[focusSlot]
            else KartPadPads.lastActive?.slot?.takeIf { it in 0..3 }?.let { cards[it] } ?: cards.first()
    }

    // A control that went (a chip whose controller joined) hands the focus on.
    private fun refocus() {
        if (overlay.top !== this) return
        val focus = focus ?: return
        if (focus.hidden || !focus.enabled) overlay.focus(initialFocus(), false)
    }

    override fun willAppear() {
        KartPadPads.refresh(context)
        miis.clear()
        seating = seatingLook()
        layoutDesign()
    }

    override fun willDisappear() {
        if (mode == Mode.Ordering) endOrdering(false)
        else if (mode == Mode.Assigning) stopChoosing()
    }

    override fun didAppear() {
        if (!assignOnOpen) return
        assignOnOpen = false
        val device = KPRoster.deviceInSlot(focusSlot)
        if (focusSlot in 0..3 && (device == null || (assignOverTouch && device.isTouch))) beginAssigning(focusSlot)
    }

    override fun padsChanged() = rosterChanged()

    private fun rosterChanged() {
        seating = seatingLook()
        miis.clear()
        layoutDesign()
        refocus()
        invalidate()
    }

    private fun seatingLook(): Long {
        var look = KartPadPads.devices.size.toLong()
        for (device in KartPadPads.devices) look = look * 131 + device.instance * 8L + device.slot + 1
        return look
    }

    // What the cards and chips show (each controller, what it's pressing, its battery; the player
    // waiting, breathing), so a tick redraws only when that changed.
    private fun look(): Long {
        var look = 1125899906842597L
        fun mix(value: Long) { look = (look xor value) * 0x100000001b3L }
        for (device in KartPadPads.devices) {
            mix(device.instance.toLong())
            mix(device.slot.toLong())
            mix(device.buttons)
            for (axis in device.axes) mix((axis * 64).toInt().toLong())
            mix(((device.battery + 1).toLong() shl 2) or (if (device.charging) 2L else 0L))
        }
        mix(mode.ordinal.toLong())
        mix(target.toLong())
        mix(ordered.size.toLong())
        mix(if (finishAt > 0) 1L else 0L)
        if (mode != Mode.Browsing) mix((pulse * 40).toInt().toLong())
        return look
    }

    override fun tick() {
        val now = SystemClock.uptimeMillis()
        pulse = .5f + .5f * sin(now / 1000.0 * 6).toFloat()
        if (mode == Mode.Ordering && finishAt > 0 && now >= finishAt) endOrdering(true)
        else if (mode == Mode.Assigning && now - lastPress > 20_000) cancelChoosing()
        else if (mode == Mode.Ordering && now - lastPress > 60_000) endOrdering(ordered.isNotEmpty())
        if (seatingLook() != seating) rosterChanged()
        val look = look()
        if (look != shownLook) {
            shownLook = look
            invalidate()
        }
    }

    private fun viewFor(instance: Int): KPButton? {
        val device = KartPadPads.device(instance) ?: return null
        if (device.slot in 0..3) return cards[device.slot]
        return chips.firstOrNull { !it.hidden && it.tagObject == instance }
    }

    private fun bounce(instance: Int) {
        val view = viewFor(instance) ?: return
        view.springTo(1.06f)
        overlay.host.postDelayed({ view.springTo(if (view.focused) view.focusScale else 1f) }, 120)
    }

    private fun celebrate(instance: Int) {
        KartPadPads.device(instance)?.let { KPRoster.identify(it) }
        overlay.play(KPUISound.Saved)
        overlay.post {
            val view = viewFor(instance)
            if (view != null) {
                overlay.wobble(view)
                view.springTo(1.1f)
                overlay.host.postDelayed({ view.springTo(if (view.focused) view.focusScale else 1f) }, 200)
            }
        }
    }

    // MARK: Choosing by pressing

    override val listening: Boolean get() = mode != Mode.Browsing

    private fun startListening() {
        lastPress = SystemClock.uptimeMillis()
        finishAt = 0
        layoutDesign()
        overlay.focus(initialFocus(), false)
        invalidate()
    }

    private fun stopChoosing() {
        mode = Mode.Browsing
        layoutDesign()
        invalidate()
    }

    /** One player: the next controller to press A becomes theirs. */
    fun beginAssigning(slot: Int) {
        mode = Mode.Assigning
        target = slot
        overlay.play(KPUISound.Open)
        startListening()
    }

    // Everyone: each controller to press A takes the next player, from Player 1.
    private fun beginOrdering() {
        before = KartPadPads.devices.associate { it.instance to it.slot }
        ordered.clear()
        mode = Mode.Ordering
        overlay.play(KPUISound.Open)
        startListening()
    }

    // Done: the order stands, and controllers that didn't press stop playing. Cancelled: everyone goes
    // back where they were.
    private fun endOrdering(keep: Boolean) {
        if (mode != Mode.Ordering) return
        if (keep && ordered.isNotEmpty()) {
            for (device in KartPadPads.devices.toList())
                if (device.slot in 0..3 && device.instance !in ordered) KPRoster.stopPlaying(device)
            overlay.play(KPUISound.Saved)
        } else {
            restore()
            overlay.play(KPUISound.Close)
        }
        val first = ordered.firstOrNull()?.let { KartPadPads.device(it)?.slot } ?: 0
        ordered.clear()
        stopChoosing()
        rosterChanged()
        if (overlay.top === this) overlay.focus(cards[first.coerceIn(0, 3)], false)
    }

    // Those that moved step out, then each takes its old player again (aurora swaps nobody that way).
    private fun restore() {
        val moved = KartPadPads.devices.filter { device -> before[device.instance]?.let { it != device.slot } == true }
        for (device in moved) if (device.slot in 0..3) KPRoster.stopPlaying(device)
        for (device in moved) {
            val slot = before[device.instance] ?: -1
            if (slot in 0..3) KartPadPads.device(device.instance)?.let { KPRoster.move(it, slot) }
        }
    }

    private fun cancelChoosing() {
        if (mode == Mode.Ordering) {
            endOrdering(false)
            return
        }
        val slot = target
        stopChoosing()
        overlay.play(KPUISound.Close)
        if (overlay.top === this) overlay.focus(cards[slot], false)
    }

    // Each controller's A, B and Start while choosing (the screens' reader keeps them meanwhile, so these
    // presses don't also move the focus). Two players pressing at once both count.
    override fun rawPress(device: KPPadDevice, pressed: Long) {
        if (mode == Mode.Browsing || device.isTouch || device.isKeyboard) return
        val face = KartPadPads.faceFor(device)
        fun has(button: Int) = button >= 0 && ((pressed shr button) and 1L) != 0L
        lastPress = SystemClock.uptimeMillis()
        if (has(face.b)) {
            swallowUntil = lastPress + 150
            cancelChoosing()
            return
        }
        if (mode == Mode.Assigning) {
            if (!has(face.a)) return
            val slot = target
            if (!KPRoster.move(device, slot)) {
                overlay.play(KPUISound.Reject)
                return
            }
            swallowUntil = lastPress + 150
            stopChoosing()
            rosterChanged()
            if (overlay.top === this) overlay.focus(cards[slot], false)
            celebrate(device.instance)
            return
        }
        if (has(SDLButton.Start)) {
            swallowUntil = lastPress + 150
            endOrdering(true)
            return
        }
        if (!has(face.a) || finishAt > 0) return
        if (device.instance in ordered) {
            viewFor(device.instance)?.let { overlay.wobble(it) }
            overlay.play(KPUISound.Same)
            return
        }
        val slot = ordered.size
        if (!KPRoster.move(device, slot)) {
            overlay.play(KPUISound.Reject)
            return
        }
        ordered += device.instance
        rosterChanged()
        celebrate(device.instance)
        // Everyone's in (every connected controller, or four players): a moment to see it, then done.
        if (ordered.size >= min(KartPadPads.devices.size, 4)) finishAt = SystemClock.uptimeMillis() + 1100
        invalidate()
    }

    // MARK: Input

    // Any press bounces that controller's card; a controller that isn't playing joins with A.
    override fun padActivity(device: KPPadDevice, pressed: Long) {
        if (mode != Mode.Browsing || device.isTouch || device.isKeyboard) return
        val a = KartPadPads.faceFor(device).a
        if (device.slot !in 0..3 && a >= 0 && ((pressed shr a) and 1L) != 0L) {
            swallowUntil = SystemClock.uptimeMillis() + 150
            join(device)
            return
        }
        bounce(device.instance)
    }

    // On the focused empty card, else the first free player (the touch screen gives way).
    private fun join(device: KPPadDevice) {
        val players = KartPadPads.players()
        fun free(slot: Int) = players[slot].let { it == null || it.isTouch }
        val focused = focus
        var slot = if (focused != null && focused in cards && free(focused.tag2)) focused.tag2 else -1
        if (slot < 0) slot = (0 until 4).firstOrNull { free(it) } ?: -1
        if (slot < 0) {
            overlay.play(KPUISound.Reject)
            overlay.toast("All four players have a controller", "Use Change controller on a card to swap.",
                icon = { c, r -> KPGlyphs.draw(c, KPUIGlyph.Pad, r, KP.p.secondaryText) })
            return
        }
        if (!KPRoster.move(device, slot)) {
            overlay.play(KPUISound.Reject)
            return
        }
        rosterChanged()
        if (overlay.top === this) overlay.focus(cards[slot], false)
        celebrate(device.instance)
    }

    override fun handle(button: KPPad): Boolean {
        if (SystemClock.uptimeMillis() <= swallowUntil) {
            if (button == KPPad.Confirm || button == KPPad.Back || button == KPPad.Start) swallowUntil = 0
            return true
        }
        if (mode != Mode.Browsing) {
            if (button == KPPad.Back) {
                cancelChoosing()
                return true
            }
            return button == KPPad.Undo || button == KPPad.Redo
        }
        val focus = focus ?: return false
        val device = if (focus in cards) KPRoster.deviceInSlot(focus.tag2) else chipDevice(focus)
        // X: find it, as on HOME.
        if (button == KPPad.Undo && device != null && !device.isTouch) {
            KPRoster.identify(device)
            overlay.play(KPUISound.Confirm)
            viewFor(device.instance)?.let { overlay.wobble(it) }
            return true
        }
        return false
    }

    override fun back() {
        if (mode != Mode.Browsing) {
            cancelChoosing()
            return
        }
        super.back()
    }

    // MARK: Menus

    private fun miiFor(device: KPPadDevice): KPMiiInfo? {
        if (miis.containsKey(device.instance)) return miis[device.instance]
        val info = KPRoster.miiInfoFor(context, device)
        miis[device.instance] = info
        return info
    }

    private fun openCard(slot: Int) {
        if (mode != Mode.Browsing) return
        val device = KPRoster.deviceInSlot(slot)
        // An empty player takes whichever controller presses A next.
        if (device == null) {
            beginAssigning(slot)
            return
        }
        val mii = miiFor(device)
        val menu = KPMenuScreen(overlay)
        menu.heading = "${KPFaces.playerName(slot)} · ${mii?.name ?: device.name}"
        val miiTitle = if (mii != null) "Change Mii" else "Choose a Mii"
        // The touch screen can't change player or stop: its menu is the Mii and the touch layout.
        if (device.isTouch) {
            menu.add("Use a controller", "Press A on the controller for this player.", KPUIGlyph.Swap, run = { beginAssigning(slot) })
            menu.add(miiTitle, glyph = KPUIGlyph.Mii, run = { overlay.present(KPMiiPickerScreen(overlay, device)) })
            menu.add("Touch controls", "Layout, size and auto-accelerate.", KPUIGlyph.Buttons,
                run = { KartPadScreens.host.openSheet("touch_settings") })
            overlay.present(menu)
            return
        }
        val instance = device.instance
        menu.add("Change controller", glyph = KPUIGlyph.Swap, run = { beginAssigning(slot) })
        menu.add("Set up buttons", glyph = KPUIGlyph.Buttons, run = { overlay.present(ButtonSetupScreen(overlay, instance)) })
        menu.add(miiTitle, glyph = KPUIGlyph.Mii, run = { overlay.present(KPMiiPickerScreen(overlay, device)) })
        menu.add("Find", glyph = KPUIGlyph.Find, run = {
            KartPadPads.device(instance)?.let { KPRoster.identify(it) }
            viewFor(instance)?.let { overlay.wobble(it) }
        })
        menu.add("Stop playing", glyph = KPUIGlyph.Close, run = {
            KartPadPads.device(instance)?.let { KPRoster.stopPlaying(it) }
            rosterChanged()
            overlay.play(KPUISound.PagePrevious)
        })
        overlay.present(menu)
    }

    private fun openChip(index: Int) {
        if (mode != Mode.Browsing) return
        val device = chipDevice(chips[index]) ?: return
        val instance = device.instance
        val players = KartPadPads.players()
        val menu = KPMenuScreen(overlay)
        menu.heading = "Play with ${device.name}"
        for (slot in 0 until 4) {
            val occupant = players[slot]
            menu.add(KPFaces.playerName(slot), occupant?.let { "Instead of ${it.name}" }, run = {
                val now = KartPadPads.device(instance)
                if (now != null && KPRoster.move(now, slot)) {
                    rosterChanged()
                    overlay.focus(cards[slot], false)
                    celebrate(instance)
                } else {
                    overlay.play(KPUISound.Reject)
                }
            })
        }
        menu.add("Find", glyph = KPUIGlyph.Find, run = { KartPadPads.device(instance)?.let { KPRoster.identify(it) } })
        overlay.present(menu)
    }

    // MARK: Drawing

    override fun drawDesign(c: Canvas) {
        super.drawDesign(c)
        val s = safe
        KP.text(c, "Controllers", RectF(s.left + 56, s.top + 26, s.left + 656, s.top + 76), 38f, KP.p.text, KPWeight.Bold, KPAlign.Left)
        val press = KPHints.buttonWord(KartPadPads.joinDevice(), KPPad.Confirm)
        var subtitle = "Press a button to find your card."
        var hints = listOf(KPHint(KPPad.Confirm, "Options"), KPHint(KPPad.Undo, "Find"), KPHint(KPPad.Back, "Back"))
        var ink = KP.p.secondaryText
        if (mode == Mode.Assigning) {
            subtitle = "Press $press on the controller for ${KPFaces.playerName(target)}."
            hints = listOf(KPHint(KPPad.Back, "Cancel"))
            ink = KP.p.accentBottom
        } else if (mode == Mode.Ordering) {
            val next = ordered.size
            subtitle = when {
                next == 0 -> "Everyone press $press in turn. The first is Player 1."
                next < 4 && finishAt == 0L -> "Next: ${KPFaces.playerName(next)}"
                else -> "Everyone’s in"
            }
            hints = listOf(KPHint(KPPad.Start, "Done"), KPHint(KPPad.Back, "Cancel"))
            ink = KP.p.accentBottom
        }
        KP.text(c, subtitle, RectF(s.left + 58, s.top + 78, s.left + 698, s.top + 104), 18f, ink, KPWeight.Medium, KPAlign.Left)
        if (resting().isNotEmpty())
            KP.text(c, "Not playing", RectF(s.left + 58, s.top + 536, s.left + 858, s.top + 562), 18f, KP.p.secondaryText,
                KPWeight.Semibold, KPAlign.Left)
        KPHints.draw(c, RectF(s.left + 56, s.top + 670, s.left + 1224, s.top + 696), hints, 16f, KPAlign.Right)
    }

    private fun drawCard(slot: Int, c: Canvas, r: RectF, state: KPUIState) {
        // Choosing by pressing: the player being chosen waits for A; while ordering, so do those after.
        if (mode == Mode.Assigning && slot == target) {
            drawWaiting(slot, c, r, true)
            return
        }
        if (mode == Mode.Ordering && slot >= ordered.size) {
            drawWaiting(slot, c, r, slot == ordered.size && finishAt == 0L)
            return
        }
        // The others step back meanwhile.
        val saved = if (mode == Mode.Assigning) c.saveLayerAlpha(r.left - 12, r.top - 12, r.right + 12, r.bottom + 12, (.45f * 255).toInt())
            else c.save()
        drawPlayer(slot, KPRoster.deviceInSlot(slot), c, r, state)
        c.restoreToCount(saved)
    }

    // A player waiting for a controller while choosing by pressing: the one being chosen pulses.
    private fun drawWaiting(slot: Int, c: Canvas, r: RectF, next: Boolean) {
        val color = KP.PlayerColors[slot]
        KP.fill(c, r, KP.p.panel, 20f, if (next) .95f else .5f)
        KPPlayerCards.dashed(c, RectF(r.left + 1, r.top + 1, r.right - 1, r.bottom - 1), if (next) color else KP.p.buttonStroke,
            if (next) 3f else 2.2f, 19f)
        KPPlayerCards.cap(c, r, r.top, slot, !next)
        KP.text(c, KPFaces.playerName(slot), RectF(r.left + 22, r.top + 13, r.left + 222, r.top + 45), 24f,
            if (next) KP.PlayerInk[slot] else KP.p.secondaryText, KPWeight.Heavy, KPAlign.Left)
        if (!next) return
        // A big A button, breathing.
        val size = 92 + 10 * pulse
        val button = RectF(r.centerX() - size / 2, r.top + 160 - size / 2, r.centerX() + size / 2, r.top + 160 + size / 2)
        c.drawOval(RectF(button.left - 14, button.top - 14, button.right + 14, button.bottom + 14), KP.ink(color, .25f + .2f * pulse))
        c.drawOval(button, KP.ink(color))
        // Labelled as the pad in hand labels it (✕ on a PlayStation pad).
        val join = KartPadPads.joinDevice()
        val label = KPHints.label(join, KPPad.Confirm) ?: "A"
        if (KPHints.isShape(label)) {
            val inset = size * .12f
            KPHints.drawBadge(c, label, RectF(button.left + inset, button.top + inset, button.right - inset, button.bottom - inset),
                size * .55f, color, KP.PlayerInk[slot])
        } else {
            KP.centredLabel(c, label, button, if (label.length <= 2) size * .5f else size * .24f, KP.PlayerInk[slot], KPWeight.Heavy)
        }
        // Which controller is in the subtitle above.
        KP.text(c, "Press ${KPHints.buttonWord(join, KPPad.Confirm)}", RectF(r.left + 10, r.top + 236, r.right - 10, r.top + 268), 24f, KP.p.text,
            KPWeight.Bold)
    }

    private fun drawPlayer(slot: Int, device: KPPadDevice?, c: Canvas, r: RectF, state: KPUIState) {
        val color = KP.PlayerColors[slot]
        val dy = if (state.pressed) 2f else 0f
        if (device == null) {
            KP.fill(c, r, KP.p.panel, 20f, .6f)
            KPPlayerCards.dashed(c, RectF(r.left + 1, r.top + 1, r.right - 1, r.bottom - 1), KP.p.buttonStroke, 2.2f, 19f)
        } else {
            KP.buttonFace(c, r, KPStyle.Card, false, true, state.pressed, state.focused)
        }
        // The player's colour cap, with the number and the controller's lights.
        KPPlayerCards.cap(c, RectF(r.left, r.top + dy, r.right, r.bottom - 3 + dy), r.top + dy, slot, device == null)
        val ink = if (device != null) KP.PlayerInk[slot] else KP.p.secondaryText
        KP.text(c, KPFaces.playerName(slot), RectF(r.left + 22, r.top + 13 + dy, r.left + 192, r.top + 45 + dy), 24f, ink, KPWeight.Heavy,
            KPAlign.Left)
        for (pip in 0 until 4) {
            val x = r.right - 22 - (4 - pip) * 17 + 4
            // The player's own light: lit with a controller, dim without one.
            KP.fill(c, RectF(x, r.top + 23 + dy, x + 12, r.top + 35 + dy), if (pip == slot) 0x8fe9ff else 0x000000, 3f,
                if (pip == slot) (if (device != null) 1f else .4f) else .2f)
        }
        if (device == null) {
            KPGlyphs.draw(c, KPUIGlyph.Plus, RectF(r.centerX() - 34, r.top + 112 + dy, r.centerX() + 34, r.top + 180 + dy), KP.p.buttonStroke)
            KP.text(c, "No controller", RectF(r.left + 10, r.top + 206 + dy, r.right - 10, r.top + 236 + dy), 22f, KP.p.secondaryText,
                KPWeight.Semibold)
            KP.text(c, "Press ${KPHints.buttonWord(KartPadPads.joinDevice(), KPPad.Confirm)} to join",
                RectF(r.left + 26, r.top + 242 + dy, r.right - 26, r.top + 272 + dy), 16f, KP.p.secondaryText, KPWeight.Regular)
            return
        }
        val mii = miiFor(device)
        val portrait = mii?.let { KPMiiSource.portrait(it.record) { invalidate() } }
        KPFaces.miiWell(c, RectF(r.centerX() - 58, r.top + 72 + dy, r.centerX() + 58, r.top + 188 + dy), portrait, color, false)
        if (mii != null)
            KP.text(c, mii.name, RectF(r.left + 12, r.top + 194 + dy, r.right - 12, r.top + 224 + dy), 21f, KP.p.text, KPWeight.Semibold)
        // The controller, live.
        KPControllerArt.draw(c, RectF(r.left + 20, r.top + 232 + dy, r.right - 20, r.top + 348 + dy), device.family,
            KPControllerArt.stateFor(device, color), device.systemName)
        KP.text(c, device.name, RectF(r.left + 20, r.top + 356 + dy, r.right - 60, r.top + 380 + dy), 16f, KP.p.secondaryText,
            KPWeight.Medium, KPAlign.Left)
        KPFaces.battery(c, RectF(r.right - 56, r.top + 354 + dy, r.right - 22, r.top + 380 + dy), device)
    }

    private fun drawChip(index: Int, c: Canvas, r: RectF, state: KPUIState) {
        val device = chipDevice(chips[index]) ?: return
        KP.buttonFace(c, r, KPStyle.Plain, false, true, state.pressed, state.focused)
        val dy = if (state.pressed) 2f else 0f
        KPControllerArt.draw(c, RectF(r.left + 10, r.top + 8 + dy, r.left + 102, r.bottom - 11 + dy), device.family,
            KPControllerArt.stateFor(device, KP.p.accentBottom), device.systemName)
        KP.text(c, device.name, RectF(r.left + 110, r.top + 12 + dy, r.right - 10, r.top + 38 + dy), 18f, KP.p.text, KPWeight.Semibold,
            KPAlign.Left)
        KP.text(c, "Press ${KPHints.buttonWord(device, KPPad.Confirm)} to join", RectF(r.left + 110, r.top + 40 + dy, r.right - 40, r.top + 62 + dy),
            15f, KP.p.secondaryText, KPWeight.Regular, KPAlign.Left)
        KPFaces.battery(c, RectF(r.right - 44, r.top + 38 + dy, r.right - 14, r.top + 62 + dy), device)
    }
}

/** What the player cards share with the reconnect card. */
internal object KPPlayerCards {
    /** A dashed rounded outline (an empty player). */
    fun dashed(c: Canvas, r: RectF, hex: Int, width: Float, radius: Float) {
        val paint = KP.ink(hex, 1f, width)
        paint.strokeCap = Paint.Cap.BUTT
        paint.pathEffect = DashPathEffect(floatArrayOf(9f, 7f), 0f)
        val round = max(0f, radius - width / 2)
        c.drawRoundRect(RectF(r.left + width / 2, r.top + width / 2, r.right - width / 2, r.bottom - width / 2), round, round, paint)
    }

    /** The player's colour across the top of a card clipped to clip; faded under the panel for a player without a controller. */
    fun cap(c: Canvas, clip: RectF, top: Float, slot: Int, dim: Boolean, height: Float = 58f) {
        c.save()
        c.clipPath(Path().apply { addRoundRect(clip, 20f, 20f, Path.Direction.CW) })
        val band = RectF(clip.left, top, clip.right, top + height)
        KP.gradientFill(c, band, 0f, KP.PlayerColors[slot], KP.PlayerDarkColors[slot])
        if (dim) KP.fill(c, band, KP.p.panel, 0f, .55f)
        c.restore()
    }
}

// MARK: Choosing a Mii

// A Mii labels a controller so players can tell them apart; it doesn't change who races. Tile one of
// the first page is "No Mii"; LB and RB (or the arrows by the page number) turn the pages.
private class KPMiiPickerScreen(overlay: KPOverlay, private val device: KPPadDevice) : KPScreen(overlay) {
    private val context = overlay.activity
    private var records: List<KPMiiInfo> = emptyList()
    private val tiles = ArrayList<KPButton>()
    private lateinit var cancel: KPButton
    private lateinit var previous: KPButton
    private lateinit var next: KPButton
    private var page = 0

    companion object {
        const val Columns = 6
        const val Rows = 3
        const val PerPage = Columns * Rows
    }

    private val pages get() = max(1, (records.size + 1 + PerPage - 1) / PerPage)
    private fun recordAt(tile: Int): KPMiiInfo? = records.getOrNull(page * PerPage + tile - 1)
    private fun pageText() = "Page ${page + 1} of $pages"

    override fun build() {
        solid = true
        title = "Choose a Mii"
        records = KPMiiSource.list(context)
        for (i in 0 until PerPage) {
            val tile = button(RectF(), { c, r, state -> drawTile(i, c, r, state) }) { choose(i) }
            tile.tag2 = i
            tile.radius = 16f
            tiles += tile
        }
        cancel = button(RectF(), { c, r, state -> KPFaces.pill(c, r, state, KPStyle.Plain, KPUIGlyph.Close, "Cancel") }) { overlay.pop() }
        cancel.label = "Cancel"
        cancel.sound = KPUISound.Close
        previous = button(RectF(), { c, r, state -> drawTurn(c, r, state, KPUIGlyph.Back) }) { turn(-1) }
        previous.label = "Previous page"
        previous.sound = null
        previous.radius = 12f
        next = button(RectF(), { c, r, state -> drawTurn(c, r, state, KPUIGlyph.Chevron) }) { turn(1) }
        next.label = "Next page"
        next.sound = null
        next.radius = 12f
    }

    override fun layoutDesign() {
        val s = safe
        val w = 176f
        val h = 160f
        val gap = 16f
        val x0 = s.left + (1280 - (Columns * w + (Columns - 1) * gap)) / 2
        place(cancel, RectF(s.right - 226, s.top + 30, s.right - 56, s.top + 90))
        for (tile in tiles) {
            val i = tile.tag2
            tile.hidden = page * PerPage + i > records.size
            tile.label = if (page == 0 && i == 0) "No Mii" else recordAt(i)?.name
            val x = x0 + (i % Columns) * (w + gap)
            val y = s.top + 124 + (i / Columns) * (h + gap)
            place(tile, RectF(x, y, x + w, y + h))
        }
        val paged = pages > 1
        previous.hidden = !paged
        next.hidden = !paged
        val text = ceil(KP.textWidth(pageText(), 16f, KPWeight.Medium))
        place(previous, RectF(s.left + 56, s.top + 658, s.left + 100, s.top + 702))
        place(next, RectF(s.left + 124 + text, s.top + 658, s.left + 168 + text, s.top + 702))
        if (overlay.top === this) focus?.let { if (it.hidden) overlay.focus(initialFocus(), false) }
    }

    override fun initialFocus(): KPButton? {
        val current = KPRoster.miiInfoFor(context, device)
        if (page == 0 && current != null) {
            val index = records.indexOfFirst { it.createId == current.createId } + 1
            if (index in 1 until PerPage) return tiles[index]
        }
        return tiles.firstOrNull { !it.hidden }
    }

    private fun turn(direction: Int): Boolean {
        val to = page + direction
        if (to < 0 || to >= pages) {
            overlay.play(KPUISound.Reject)
            return false
        }
        page = to
        overlay.play(if (direction > 0) KPUISound.PageNext else KPUISound.PagePrevious)
        layoutDesign()
        invalidate()
        return true
    }

    override fun handle(button: KPPad): Boolean {
        if (button != KPPad.NextTab && button != KPPad.PreviousTab) return false
        if (turn(if (button == KPPad.NextTab) 1 else -1)) overlay.focus(tiles.first(), false)
        return true
    }

    private fun choose(i: Int) {
        val record = if (page == 0 && i == 0) null else recordAt(i)
        KPRoster.setMii(context, device, record)
        overlay.play(if (record != null) KPUISound.NewMii else KPUISound.PagePrevious)
        overlay.pop()
    }

    private fun drawTurn(c: Canvas, r: RectF, state: KPUIState, glyph: KPUIGlyph) {
        KP.buttonFace(c, r, KPStyle.Round, false, state.enabled, state.pressed, state.focused)
        val dy = if (state.pressed) 2f else 0f
        KPGlyphs.draw(c, glyph, RectF(r.left + 10, r.top + 8 + dy, r.right - 10, r.bottom - 12 + dy), KP.p.accentBottom)
    }

    private fun drawTile(i: Int, c: Canvas, r: RectF, state: KPUIState) {
        KP.buttonFace(c, r, KPStyle.Tile, false, true, state.pressed, state.focused)
        val dy = if (state.pressed) 2f else 0f
        val well = RectF(r.centerX() - 50, r.top + 12 + dy, r.centerX() + 50, r.top + 112 + dy)
        val name = RectF(r.left + 6, r.top + 118 + dy, r.right - 6, r.top + 144 + dy)
        if (page == 0 && i == 0) {
            KP.fill(c, well, KP.Light.well, 22f)
            KPGlyphs.draw(c, KPUIGlyph.Close, RectF(well.left + 30, well.top + 30, well.right - 30, well.bottom - 30), KP.p.buttonStroke)
            KP.text(c, "No Mii", name, 18f, KP.p.secondaryText, KPWeight.Semibold)
            return
        }
        val record = recordAt(i) ?: return
        KPFaces.miiWell(c, well, KPMiiSource.portrait(record.record) { invalidate() }, KPMiiSource.favoriteHex(record.favoriteColor), false)
        KP.text(c, record.name, name, 18f, KP.p.text, KPWeight.Semibold)
    }

    override fun drawDesign(c: Canvas) {
        super.drawDesign(c)
        val s = safe
        KP.text(c, "Choose a Mii", RectF(s.left + 56, s.top + 26, s.left + 656, s.top + 76), 36f, KP.p.text, KPWeight.Bold, KPAlign.Left)
        val who = if (device.slot in 0..3) "${KPFaces.playerName(device.slot)} · ${device.name}" else device.name
        KP.text(c, who, RectF(s.left + 58, s.top + 76, s.left + 758, s.top + 102), 18f, KP.p.secondaryText, KPWeight.Medium, KPAlign.Left)
        val hints = ArrayList<KPHint>()
        hints += KPHint(KPPad.Confirm, "Choose")
        if (pages > 1) {
            hints += KPHint(KPPad.PreviousTab, "Turn page", KPPad.NextTab)
            KP.text(c, pageText(), RectF(s.left + 112, s.top + 670, s.left + 512, s.top + 696), 16f, KP.p.secondaryText, KPWeight.Medium,
                KPAlign.Left)
        }
        hints += KPHint(KPPad.Back, "Cancel")
        KPHints.draw(c, RectF(s.left + 56, s.top + 670, s.left + 1224, s.top + 696), hints, 16f, KPAlign.Right)
        if (records.isEmpty())
            KP.text(c, "No Miis yet. Make one in HOME › Miis.", RectF(s.left + 56, s.top + 320, s.left + 1224, s.top + 350), 20f,
                KP.p.secondaryText, KPWeight.Medium)
    }
}

// MARK: Connecting a controller

// Android pairs controllers in its own Bluetooth settings (the iPhone's KartPadScreensConnect.inc.mm):
// the page says how to put each kind in pairing mode and opens those settings, and closes by itself
// once a new controller shows up.
private class KPConnectScreen(overlay: KPOverlay) : KPScreen(overlay) {
    private class PairMode(val brand: String, val how: String, val family: KPPadFamily)

    private val modes = listOf(
        PairMode("PlayStation", "Hold Create (or Share) and PS until the light flashes.", KPPadFamily.PlayStation),
        PairMode("Xbox", "Hold the pair button until the Xbox button flashes fast.", KPPadFamily.Xbox),
        PairMode("Switch", "Hold the sync button (on a Joy‑Con, the rail) until the lights run.", KPPadFamily.Switch),
        PairMode("Others", "Usually: hold the pair button. Controllers that plug in work too.", KPPadFamily.Generic),
    )
    private lateinit var settings: KPButton
    private lateinit var done: KPButton
    private var before: Set<Int> = emptySet()

    override fun build() {
        solid = true
        title = "Connect a Controller"
        before = KartPadPads.devices.map { it.instance }.toSet()
        settings = button(RectF(), { c, r, state -> KPFaces.pill(c, r, state, KPStyle.Plain, KPUIGlyph.Bluetooth, "Bluetooth Settings") }) {
            openBluetoothSettings()
        }
        settings.label = "Bluetooth Settings"
        done = button(RectF(), { c, r, state -> KPFaces.pill(c, r, state, KPStyle.Primary, KPUIGlyph.Check, "Done") }) { overlay.pop() }
        done.label = "Done"
        done.sound = KPUISound.Close
    }

    override fun layoutDesign() {
        val s = safe
        val doneX = s.right - 56 - 170
        place(done, RectF(doneX, s.top + 590, doneX + 170, s.top + 654))
        place(settings, RectF(doneX - 306, s.top + 590, doneX - 16, s.top + 654))
    }

    override fun initialFocus(): KPButton = done

    private fun openBluetoothSettings() {
        val activity = overlay.activity
        try {
            activity.startActivity(Intent(android.provider.Settings.ACTION_BLUETOOTH_SETTINGS))
        } catch (e: Exception) {
            try {
                activity.startActivity(Intent(android.provider.Settings.ACTION_SETTINGS))
            } catch (e: Exception) {
                overlay.play(KPUISound.Reject)
            }
        }
    }

    // A controller that wasn't here before: it's connected, so the page has done its job.
    private fun check() {
        if (overlay.top !== this) return
        if (KartPadPads.devices.any { !it.isTouch && it.instance !in before }) overlay.pop()
    }

    override fun padsChanged() = check()
    override fun tick() = check()

    override fun drawDesign(c: Canvas) {
        super.drawDesign(c)
        val s = safe
        KP.text(c, "Connect a Controller", RectF(s.left + 56, s.top + 26, s.left + 856, s.top + 76), 38f, KP.p.text, KPWeight.Bold,
            KPAlign.Left)
        KP.text(c, "Put it in pairing mode, then choose it in Bluetooth Settings.", RectF(s.left + 58, s.top + 80, s.left + 1058, s.top + 106),
            19f, KP.p.secondaryText, KPWeight.Medium, KPAlign.Left)
        val w = 280f
        val gap = 16f
        val x0 = s.left + (1280 - (4 * w + 3 * gap)) / 2
        modes.forEachIndexed { i, mode ->
            val left = x0 + i * (w + gap)
            val card = RectF(left, s.top + 150, left + w, s.top + 550)
            KP.buttonFace(c, card, KPStyle.Card, false, true, false, false)
            KPControllerArt.draw(c, RectF(card.left + 24, card.top + 26, card.right - 24, card.top + 156), mode.family,
                KPArtState(accent = KP.p.accentBottom))
            KP.text(c, mode.brand, RectF(card.left + 16, card.top + 184, card.right - 16, card.top + 216), 24f, KP.p.text, KPWeight.Semibold)
            KP.text(c, mode.how, RectF(card.left + 24, card.top + 230, card.right - 24, card.top + 380), 18f, KP.p.secondaryText,
                KPWeight.Regular)
        }
        KPHints.draw(c, RectF(s.left + 56, s.top + 670, s.left + 1224, s.top + 696), listOf(KPHint(KPPad.Back, "Back")), 16f, KPAlign.Right)
    }
}
