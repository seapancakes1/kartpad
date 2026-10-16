package dev.kartpad.android.screens

import android.graphics.Canvas
import android.graphics.PointF
import android.graphics.RectF
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.round

// HOME (the Mac's KartPadHomeScreen.inc.mm): what ⋯, a controller's HOME button or Start held a
// second opens over the game, in the spirit of the Wii's HOME Menu. The game holds still underneath, a
// bar slides down from the top and the players' strip up from the bottom, and the big tiles in between
// do the everyday things: carry on, Miis, controllers. The volume has a row of its own; Settings sits in
// the top bar, with a waiting restart beside it, and the game that's playing, beside the title,
// switches to the other. Android, as iPhone, has no Quit or full screen here.
class HomeScreen(overlay: KPOverlay) : KPScreen(overlay) {
    private val context = overlay.activity
    private lateinit var topBar: KPItem
    private lateinit var bottomBar: KPItem
    private lateinit var resume: KPButton
    private lateinit var switchGame: KPButton
    private lateinit var miis: KPButton
    private lateinit var controllers: KPButton
    private lateinit var volume: KPButton
    private lateinit var settings: KPButton
    private lateinit var restart: KPButton
    private val slots = ArrayList<KPButton>()
    private var miiFaces: List<KPMiiInfo> = emptyList()
    private var shownVolume = 1f
    private var shownMute = false
    private var lastTick = 0L

    private val profile get() = KartPadScreens.host.gameProfile
    private val otherProfile get() = if (profile == "retro_rewind") "base" else "retro_rewind"
    private val canSwitch get() = KartPadScreens.host.dualGame

    companion object {
        const val RestartTitle = "Restart to Apply"
        fun volumeTrack(r: RectF) = RectF(r.left + 70, r.centerY() - 6, r.right - 90, r.centerY() + 6)
    }

    override fun build() {
        title = "HOME"
        topBar = decor(RectF()) { c, r -> drawTopBar(c, r) }
        bottomBar = decor(RectF()) { c, r -> drawBottomBar(c, r) }

        // Blue only while it has the focus, so it never looks focused beside the tile that is.
        resume = button(RectF(), { c, r, state -> KPFaces.tile(c, r, state, state.focused, KPUIGlyph.Play, "Resume", null) }) {
            overlay.closeAll()
        }
        resume.label = "Resume"
        resume.sound = KPUISound.Confirm

        // The other game: switching is rare, so it's a small pill beside the title, naming the game playing.
        switchGame = button(RectF(), { c, r, state -> KPFaces.pill(c, r, state, KPStyle.Plain, KPUIGlyph.Swap, KPFaces.gameTitle(profile)) }) {
            askToSwitch()
        }
        switchGame.label = "Switch to ${KPFaces.gameTitle(otherProfile)}"
        switchGame.hidden = !canSwitch

        // The Miis tile shows up to three of the Miis, overlapping, where the other tiles have their icon.
        miis = button(RectF(), { c, r, state -> drawMiisTile(c, r, state) }) {
            KartPadScreens.screens["miis"]?.let { overlay.present(it(overlay)) }
        }
        miis.label = "Miis"

        controllers = button(RectF(), { c, r, state -> KPFaces.tile(c, r, state, false, KPUIGlyph.Pad, "Controllers", null) }) {
            KartPadScreens.controllersFor?.let { overlay.present(it(overlay, -1)) }
        }
        controllers.label = "Controllers"

        // Volume: left and right change it in steps, A turns the sound off and on, a finger drags it along the track.
        volume = button(RectF(), { c, r, state ->
            KP.buttonFace(c, r, KPStyle.Plain, false, state.enabled, state.pressed, state.focused)
            KPGlyphs.draw(c, if (shownMute) KPUIGlyph.SpeakerOff else KPUIGlyph.Speaker,
                RectF(r.left + 20, r.centerY() - 17, r.left + 54, r.centerY() + 17), if (shownMute) KP.p.secondaryText else KP.p.accentBottom, shownVolume)
            KP.slider(c, volumeTrack(r), shownVolume, shownMute)  // muted keeps its level, greyed, for turning back on
            KP.text(c, if (shownMute) "Off" else "${Math.round(shownVolume * 100)}%", RectF(r.right - 80, r.centerY() - 14, r.right - 16, r.centerY() + 14),
                20f, KP.p.text, KPWeight.Semibold, KPAlign.Right)
        }) {
            KPSlide.saveNow()
            shownMute = !shownMute
            KPVolume.set(context, shownVolume, shownMute)
            invalidate()
        }
        volume.label = "Volume"
        volume.sound = KPUISound.Confirm
        volume.adjust = { direction ->
            val next = (shownVolume + direction * .05f).coerceIn(0f, 1f)
            if (next == shownVolume && !shownMute) {
                overlay.play(KPUISound.Same)
            } else {
                KPSlide.saveNow()
                shownVolume = next
                shownMute = false
                KPVolume.set(context, next, false)
                overlay.play(if (direction < 0) KPUISound.Left else KPUISound.Right)
                invalidate()
            }
            true
        }
        volume.slide = slide@{ x, _, face, began ->
            val next = KP.sliderLevel(volumeTrack(face), x, began) ?: return@slide false
            if (next == shownVolume && !shownMute) return@slide true
            if (floor(next * 20) != floor(shownVolume * 20) || shownMute) overlay.play(KPUISound.Tick)
            shownVolume = next
            shownMute = false
            KPSlide.saveSoon { KPVolume.set(context, next, false) }
            invalidate()
            true
        }

        settings = button(RectF(), { c, r, state ->
            KP.buttonFace(c, r, KPStyle.Round, false, state.enabled, state.pressed, state.focused)
            val ix = r.width() * .22f
            val iy = r.height() * .22f + 1
            KPGlyphs.draw(c, KPUIGlyph.Gear, RectF(r.left + ix, r.top + iy, r.right - ix, r.bottom - iy), KP.p.accentBottom)
        }) { KartPadScreens.screens["settings"]?.let { overlay.present(it(overlay)) } }
        settings.label = "Settings"
        settings.radius = 12f

        restart = button(RectF(), { c, r, state ->
            KP.buttonFace(c, r, KPStyle.Plain, false, state.enabled, state.pressed, state.focused)
            val dy = if (state.pressed) 2f else 0f
            KP.fill(c, RectF(r.left + 2, r.top + dy + 2, r.right - 2, r.bottom - 3 + dy - 2), KP.p.caution, 6f, .22f)
            KPGlyphs.draw(c, KPUIGlyph.Restart, RectF(r.left + 16, r.centerY() - 14 + dy, r.left + 42, r.centerY() + 12 + dy), KP.p.cautionInk)
            KP.text(c, RestartTitle, RectF(r.left + 50, r.centerY() - 13 + dy, r.right - 8, r.centerY() + 13 + dy), 19f, KP.p.text,
                KPWeight.Semibold, KPAlign.Left)
        }) { askToRestart() }
        restart.label = RestartTitle

        for (slot in 0 until 4) {
            val button = button(RectF(), { c, r, state -> drawSlot(slot, c, r, state) }) {
                KartPadScreens.controllersFor?.let { overlay.present(it(overlay, slot)) }
            }
            button.tag2 = slot
            button.radius = 16f
            button.focusScale = 1.03f
            button.label = "${KPFaces.playerName(slot)} slot"
            slots += button
        }
    }

    override fun layoutDesign() {
        val s = safe
        val topHeight = s.top + 98
        val bottomTop = s.top + 538
        place(topBar, RectF(0f, 0f, width, topHeight + 14))
        place(bottomBar, RectF(0f, bottomTop - 14, width, height))

        // The top bar, from the right: Settings and a waiting restart; on the left, after the title, the game switch.
        val waiting = KPRestart.waiting(context)
        restart.hidden = !waiting
        var right = s.right - 52
        place(settings, RectF(right - 62, s.top + 20, right, s.top + 82))
        right -= 62 + 14
        if (canSwitch) {
            // Sized to the game's name (a 24-point icon at this height), centred on the house (y 49).
            val w = ceil(24 + 10 + KP.textWidth(KPFaces.gameTitle(profile), 21f, KPWeight.Semibold) + 40)
            place(switchGame, RectF(s.left + 252, s.top + 24, s.left + 252 + w, s.top + 74))
        }
        val restartWidth = ceil(50 + KP.textWidth(RestartTitle, 19f, KPWeight.Semibold) + 24)
        place(restart, RectF(right - restartWidth, s.top + 22, right, s.top + 80))

        val gap = 22f
        val top = s.top + 140
        val tileHeight = 230f
        val wide = 420f
        val narrow = 360f
        var x = round(s.left + (s.width() - wide - narrow * 2 - gap * 2) / 2)
        place(resume, RectF(x, top, x + wide, top + tileHeight))
        x += wide + gap
        place(miis, RectF(x, top, x + narrow, top + tileHeight))
        x += narrow + gap
        place(controllers, RectF(x, top, x + narrow, top + tileHeight))

        // The volume, alone on its row. Toasts go in the gap under it (toastSpots).
        val vx = round(s.left + (s.width() - 820) / 2)
        place(volume, RectF(vx, s.top + 388, vx + 820, s.top + 462))

        val slotWidth = 282f
        val slotGap = 16f
        val slotTop = s.top + 584
        for (button in slots) {
            val left = s.left + 52 + button.tag2 * (slotWidth + slotGap)
            place(button, RectF(left, slotTop, left + slotWidth, slotTop + 104))
        }
    }

    override fun initialFocus(): KPButton = resume

    // Between the volume and the players, in the middle.
    override fun toastSpots() = listOf(PointF(round(safe.centerX() - KPToasts.Width / 2), safe.top + 462))

    override fun willAppear() {
        shownVolume = KPVolume.level(context)
        shownMute = KPVolume.muted(context)
        miiFaces = KPMiiSource.list(context).take(3)
        KPMiiSource.refresh(context) {
            miiFaces = KPMiiSource.list(context).take(3)
            invalidate()
        }
        KartPadPads.refresh(context)
        layoutDesign()
    }

    override fun didAppear() {
        if (overlay.reduceMotion) return
        // The bars slide in from the edges and the tiles pop up, staggered, as the Wii's HOME Menu does.
        val topSlide = -topBar.frame.height()
        val bottomSlide = bottomBar.frame.height()
        val fromTop = listOf(topBar, switchGame, settings, restart)
        val fromBottom = listOf(bottomBar) + slots
        for (item in fromTop) item.dy = topSlide
        for (item in fromBottom) item.dy = bottomSlide
        overlay.animate(420, ::springOut, onFrame = { t ->
            for (item in fromTop) item.dy = topSlide * (1 - t)
            for (item in fromBottom) item.dy = bottomSlide * (1 - t)
        }) { (fromTop + fromBottom).forEach { it.dy = 0f } }
        var delay = 40L
        for (tile in listOf(resume, miis, controllers)) {
            tile.alpha = 0f
            tile.dy = 24f
            val start = delay
            overlay.post {
                overlay.host.postDelayed({
                    overlay.animate(300, ::springOut, onFrame = { t ->
                        tile.alpha = t.coerceIn(0f, 1f)
                        tile.dy = 24 * (1 - t)
                    }) { tile.alpha = 1f; tile.dy = 0f }
                }, start)
            }
            delay += 35
        }
    }

    override fun willDisappear() = KPSlide.saveNow()

    override fun padsChanged() = invalidate()

    override fun tick() {
        val now = android.os.SystemClock.uptimeMillis()
        if (now - lastTick < 250) return
        lastTick = now
        invalidate()
        if (restart.hidden == KPRestart.waiting(context)) layoutDesign()
    }

    // X on a player identifies their controller (it buzzes and flashes), as it does on Controllers.
    override fun handle(button: KPPad): Boolean {
        val focus = focus
        if (button == KPPad.Undo && focus != null && focus in slots) {
            val device = KPRoster.deviceInSlot(focus.tag2)
            if (device != null && !device.isTouch) {
                KPRoster.identify(device)
                overlay.play(KPUISound.Confirm)
                overlay.wobble(focus)
                focus.springTo(1.08f)
                overlay.host.postDelayed({ focus.springTo(if (focus.focused) focus.focusScale else 1f) }, 180)
            } else {
                overlay.play(KPUISound.Reject)
            }
            return true
        }
        return false
    }

    override fun back() = overlay.closeAll()

    // MARK: Drawing

    private fun drawTopBar(c: Canvas, frame: RectF) {
        val s = safe
        val barHeight = frame.height() - 14
        val dark = KP.dark
        KP.shadowed(c, 4f, 12f, .3f, RectF(0f, frame.top, frame.width(), frame.top + barHeight), if (dark) 0x23292d else 0xe6edf1, 0f)
        KP.gradientFill(c, RectF(0f, frame.top, frame.width(), frame.top + barHeight), 0f, if (dark) 0x353c42 else 0xffffff, if (dark) 0x23292d else 0xe6edf1)
        KP.pinstripes(c, RectF(0f, frame.top, frame.width(), frame.top + barHeight - 4), if (dark) 0x2b3136 else 0xeef2f4)
        KP.fill(c, RectF(0f, frame.top + barHeight - 4, frame.width(), frame.top + barHeight), KP.p.accentBottom)
        KP.fill(c, RectF(0f, frame.top + barHeight - 4, frame.width(), frame.top + barHeight - 2.5f), KP.p.accentTop, 0f, .8f)
        KPGlyphs.draw(c, KPUIGlyph.Home, RectF(s.left + 52, frame.top + s.top + 26, s.left + 98, frame.top + s.top + 72), KP.p.accentBottom)
        // Beside the title, what's playing (the game switch shows it, where there is one).
        val playing = if (KartPadScreens.hold != KartPadHostScreens.Hold.Online && !canSwitch) KPFaces.gameTitle(profile) else null
        KP.text(c, "HOME", RectF(s.left + 110, frame.top + s.top + 26, s.left + 310, frame.top + s.top + 76), 38f, KP.p.text, KPWeight.Heavy, KPAlign.Left)
        if (playing != null)
            KP.text(c, playing, RectF(s.left + 260, frame.top + s.top + 37, s.left + 720, frame.top + s.top + 65), 20f, KP.p.secondaryText,
                KPWeight.Medium, KPAlign.Left)
    }

    private fun drawBottomBar(c: Canvas, frame: RectF) {
        val s = safe
        val dark = KP.dark
        val bar = RectF(0f, frame.top + 14, frame.width(), frame.bottom)
        KP.shadowed(c, -4f, 12f, .3f, bar, if (dark) 0x23292d else 0xe6edf1, 0f)
        KP.gradientFill(c, bar, 0f, if (dark) 0x23292d else 0xe6edf1, if (dark) 0x353c42 else 0xffffff)
        KP.pinstripes(c, RectF(0f, frame.top + 18, frame.width(), frame.bottom), if (dark) 0x2b3136 else 0xeef2f4)
        KP.fill(c, RectF(0f, frame.top + 14, frame.width(), frame.top + 18), KP.p.accentBottom)
        KP.fill(c, RectF(0f, frame.top + 16.5f, frame.width(), frame.top + 18), KP.p.accentTop, 0f, .8f)
        val y = s.top + 552
        KP.text(c, "Players", RectF(s.left + 56, y, s.left + 356, y + 26), 18f, KP.p.secondaryText, KPWeight.Semibold, KPAlign.Left)
        // Which buttons do what, for the controller in hand.
        KPHints.draw(c, RectF(s.left + 1280 - 52 - 760, y, s.left + 1280 - 52, y + 26),
            listOf(KPHint(KPPad.Confirm, "Select"), KPHint(KPPad.Undo, "Find"), KPHint(KPPad.Back, "Close")), 16f, KPAlign.Right)
    }

    private fun drawMiisTile(c: Canvas, r: RectF, state: KPUIState) {
        val faces = miiFaces
        KPFaces.tile(c, r, state, false, if (faces.isEmpty()) KPUIGlyph.Mii else null, "Miis", null)
        if (faces.isEmpty()) return
        val icon = KPFaces.tileIconRect(r, if (state.pressed) 2f else 0f)
        val size = icon.width()
        val overlap = round(size * .3f)
        val total = size + (faces.size - 1) * (size - overlap)
        var x = r.centerX() - total / 2
        for (mii in faces) {
            val well = RectF(x, icon.top, x + size, icon.top + size)
            KP.fill(c, RectF(well.left - 3, well.top - 3, well.right + 3, well.bottom + 3), KP.p.panel, size * .25f)
            KPFaces.miiWell(c, well, KPMiiSource.portrait(mii.record) { invalidate() }, KPMiiSource.favoriteHex(mii.favoriteColor), false)
            x += size - overlap
        }
    }

    // A player: their Mii in a ring of their colour with their number on it, the Mii's name (or the
    // player's) with the battery, and the controller. A player without one keeps the layout, faded.
    private fun drawSlot(slot: Int, c: Canvas, r: RectF, state: KPUIState) {
        val device = KPRoster.deviceInSlot(slot)
        val empty = device == null
        val color = KP.PlayerColors[slot]
        val dy = if (state.pressed && !empty) 2f else 0f
        if (empty) {
            KP.fill(c, r, KP.p.panel, 16f, .4f)
            KPFaces.dashedOutline(c, r, 16f)
            if (state.focused) KP.stroke(c, r, KP.p.accentTop, 2.5f, 16f)
        } else {
            KP.buttonFace(c, r, KPStyle.Card, false, true, state.pressed, state.focused)
        }
        val well = RectF(r.left + 18, r.top + 15 + dy, r.left + 88, r.top + 85 + dy)
        KP.stroke(c, RectF(well.left - 4, well.top - 4, well.right + 4, well.bottom + 4), color, 2.5f, well.width() * .22f + 4, if (empty) .3f else 1f)
        KPFaces.miiWell(c, well, if (device == null) null else KPFaces.portraitFor(this, device), color, empty)
        // The number sits on the ring's corner, outlined so it stands off the Mii.
        val badge = RectF(well.right - 16, well.bottom - 16, well.right + 10, well.bottom + 10)
        if (!empty) c.drawOval(RectF(badge.left - 2.5f, badge.top - 2.5f, badge.right + 2.5f, badge.bottom + 2.5f), KP.ink(KP.p.buttonTop))
        KPFaces.playerBadge(c, badge, slot, empty)
        val x = well.right + 20
        val w = r.right - 16 - x
        if (device == null) {
            KP.text(c, "No controller", RectF(x, r.centerY() - 13, x + w, r.centerY() + 13), 18f, KP.p.secondaryText, KPWeight.Semibold, KPAlign.Left)
            return
        }
        val mii = KPRoster.miiInfoFor(context, device)
        val battery = !device.isKeyboard && !device.isTouch && device.battery >= 0
        KP.text(c, mii?.name ?: KPFaces.playerName(slot), RectF(x, r.top + 20 + dy, x + w - (if (battery) 40 else 0), r.top + 48 + dy), 20f,
            KP.p.text, KPWeight.Semibold, KPAlign.Left)
        if (battery) KPFaces.battery(c, RectF(r.right - 48, r.top + 22 + dy, r.right - 16, r.top + 46 + dy), device)
        KPGlyphs.draw(c, KPFaces.deviceGlyph(device), RectF(x, r.top + 54 + dy, x + 22, r.top + 76 + dy), KP.p.secondaryText)
        KP.text(c, device.name, RectF(x + 28, r.top + 56 + dy, x + w, r.top + 78 + dy), 15f, KP.p.secondaryText, KPWeight.Medium, KPAlign.Left)
    }

    // MARK: Actions

    private fun askToSwitch() {
        val other = otherProfile
        KPAsk.warning(overlay, "Switch to ${KPFaces.gameTitle(other)}?", "Unsaved progress will be lost.", listOf("Switch", "Cancel"), 0, -1) { choice ->
            if (choice == 0) KartPadScreens.host.restart(other)
        }
    }

    private fun askToRestart() {
        KPAsk.warning(overlay, "Restart KartPad?", "Unsaved progress will be lost.", listOf("Restart", "Later"), 0, -1) { choice ->
            if (choice == 0) KartPadScreens.host.restart(null)
        }
    }
}

/** A spring settling from 0 to 1 with a small overshoot (damping about 18, stiffness 220). */
fun springOut(t: Float): Float {
    val omega = 14.8f
    val zeta = .6f
    val damped = omega * kotlin.math.sqrt(1 - zeta * zeta)
    val time = t * .42f
    return 1 - kotlin.math.exp(-zeta * omega * time) * (kotlin.math.cos(damped * time) + zeta * omega / damped * kotlin.math.sin(damped * time))
}

/** Questions over the current screen (the Mac's KPAsk / KPAskWarning). */
object KPAsk {
    fun ask(overlay: KPOverlay, heading: String, message: String, choices: List<String>, primary: Int, destructive: Int, done: (Int) -> Unit) =
        show(overlay, heading, message, false, choices, primary, destructive, done)

    fun warning(overlay: KPOverlay, heading: String, message: String, choices: List<String>, primary: Int, destructive: Int, done: (Int) -> Unit) =
        show(overlay, heading, message, true, choices, primary, destructive, done)

    private fun show(overlay: KPOverlay, heading: String, message: String, warning: Boolean, choices: List<String>, primary: Int,
                     destructive: Int, done: (Int) -> Unit) {
        val dialog = KPDialogScreen(overlay)
        dialog.heading = heading
        dialog.message = message
        dialog.warning = warning
        dialog.choices = choices
        dialog.primary = primary
        dialog.destructive = destructive
        dialog.done = done
        dialog.solid = false
        overlay.present(dialog)
    }
}
