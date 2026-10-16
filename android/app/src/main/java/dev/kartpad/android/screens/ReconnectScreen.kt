package dev.kartpad.android.screens

import android.graphics.Canvas
import android.graphics.RectF
import android.os.SystemClock
import kotlin.math.round

// A player's controller disconnecting mid-game holds the game still until it's back, as a console does
// (the Mac's KartPadReconnect.inc.mm): a card over the dimmed game with each player waiting, their Mii
// and controller, and it closes by itself once every one of them has a controller again, the same one
// reconnecting (aurora gives it its player back) or a controller that isn't playing pressing A.
// Controllers opens on the player; Continue (or B) carries on without them. Online the race can't
// wait, nor can the game while it starts, and another screen that's open shows the players already:
// there it's only the toast.

/** The card for a player whose controller (instance, -1 unknown) dropped out, or null when a toast says it instead. */
fun makeReconnectScreen(overlay: KPOverlay, player: Int, instance: Int): KPScreen? {
    if (player !in 0..3) return null
    val leaving = KartPadPads.device(instance) ?: KartPadPads.gone.firstOrNull { it.instance == instance }
    val top = overlay.top
    if (!ReconnectScreen.mayWait()) {
        ReconnectScreen.toastGone(overlay, player, leaving?.family ?: KPPadFamily.Generic, true)
        return null
    }
    // Another player while the card is up: they wait on it too.
    if (top is ReconnectScreen) {
        top.addPlayer(player, leaving)
        return null
    }
    if (overlay.active) {
        ReconnectScreen.toastGone(overlay, player, leaving?.family ?: KPPadFamily.Generic, true)
        return null
    }
    return ReconnectScreen(overlay).also { it.addPlayer(player, leaving) }
}

internal class ReconnectScreen(overlay: KPOverlay) : KPScreen(overlay) {
    private class Waiting(val player: Int, var name: String, var mii: ByteArray?, var family: KPPadFamily, var systemName: String?)

    private val waiting = ArrayList<Waiting>()   // players, in the order they dropped
    private val back = HashSet<Int>()
    private val tiles = ArrayList<KPItem>()
    private lateinit var controllers: KPButton
    private lateinit var carryOn: KPButton
    private var closeAt = 0L
    private var chimed = false
    // The A that took a player isn't also a press on Continue.
    private var swallowUntil = 0L

    companion object {
        /** The game can hold for a player: not online (the race can't wait) or while it starts. */
        fun mayWait(): Boolean {
            fun waits(hold: KartPadHostScreens.Hold) = hold != KartPadHostScreens.Hold.Online && hold != KartPadHostScreens.Hold.Starting
            return !KartPadHostScreens.gameOnline && !KartPadHostScreens.gameStarting &&
                waits(KartPadScreens.hold) && waits(KartPadHostScreens.hold)
        }

        fun toastGone(overlay: KPOverlay, player: Int, family: KPPadFamily, sound: Boolean) {
            val glyph = KPControllerArt.familyGlyph(family)
            overlay.toast("${KPFaces.playerName(player)}’s controller disconnected", null, KP.PlayerColors[player],
                icon = { c, r -> KPGlyphs.draw(c, glyph, r, KP.p.secondaryText) })
            if (sound) overlay.play(KPUISound.Close)
        }
    }

    private fun card(): RectF {
        val s = safe
        return RectF(s.left + 200, s.top + 120, s.left + 1080, s.top + 600)
    }

    override fun build() {
        solid = false
        title = "Controller disconnected"
        controllers = button(RectF(), { c, r, state -> KPFaces.pill(c, r, state, KPStyle.Plain, KPUIGlyph.Pad, "Controllers") }) {
            // On top, so this card is back underneath afterwards (and closes if everyone's back by then).
            val slot = waiting.firstOrNull { it.player !in back }?.player ?: -1
            val screen = ControllersScreen(overlay, slot)
            screen.assignOnOpen = slot >= 0
            screen.assignOverTouch = true
            overlay.present(screen)
        }
        controllers.label = "Controllers"
        carryOn = button(RectF(), { c, r, state -> KPFaces.pill(c, r, state, KPStyle.Primary, KPUIGlyph.Play, "Continue") }) { overlay.pop() }
        carryOn.label = "Continue"
        carryOn.sound = KPUISound.Close
    }

    override fun layoutDesign() {
        val card = card()
        // The waiting players, centred in a row.
        while (tiles.size < waiting.size) {
            val index = tiles.size
            tiles += decor(RectF()) { c, r -> drawTile(index, c, r) }
        }
        val width = 184f
        val gap = 18f
        val total = waiting.size * width + (waiting.size - 1) * gap
        var x = round(card.centerX() - total / 2)
        for (tile in tiles) {
            place(tile, RectF(x, card.top + 126, x + width, card.top + 362))
            x += width + gap
        }
        val bottom = card.bottom - 96
        place(carryOn, RectF(card.right - 260, bottom, card.right - 40, bottom + 64))
        place(controllers, RectF(card.right - 518, bottom, card.right - 278, bottom + 64))
    }

    override fun initialFocus(): KPButton = carryOn

    override fun willAppear() {
        // Once, not again on coming back from Controllers.
        if (!chimed) {
            chimed = true
            overlay.play(KPUISound.Dialog)
        }
        check()
    }

    /** A player whose controller dropped (leaving: the controller, when it's still known). */
    fun addPlayer(player: Int, leaving: KPPadDevice?) {
        val mii = leaving?.let { KPRoster.miiFor(overlay.activity, it) }
        val known = waiting.firstOrNull { it.player == player }
        if (known == null) {
            waiting += Waiting(player, leaving?.name ?: "Controller", mii, leaving?.family ?: KPPadFamily.Generic, leaving?.systemName)
        } else {
            back.remove(player)
            if (leaving != null) {
                known.name = leaving.name
                known.family = leaving.family
                known.systemName = leaving.systemName
            }
            if (mii != null) known.mii = mii
        }
        closeAt = 0
        relayout()
    }

    override fun padsChanged() = check()

    override fun tick() {
        // The game couldn't hold after all (it's online, or starting): the toast says it instead.
        if (!mayWait() && overlay.top === this) {
            val gone = waiting.filter { it.player !in back }
            overlay.pop()
            for (each in gone) toastGone(overlay, each.player, each.family, false)
            return
        }
        check()
        if (closeAt > 0 && SystemClock.uptimeMillis() >= closeAt && overlay.top === this) overlay.pop()
    }

    // Who's back: a player with a controller again (not the touch screen standing in for Player 1).
    private fun check() {
        var changed = false
        for (each in waiting) {
            val device = KPRoster.deviceInSlot(each.player)
            if (device != null && !device.isTouch) {
                if (back.add(each.player)) {
                    changed = true
                    KPRoster.identify(device)
                }
            } else if (back.remove(each.player)) {
                changed = true
            }
        }
        if (!changed) return
        val everyone = back.size == waiting.size
        overlay.play(if (everyone) KPUISound.Saved else KPUISound.Confirm)
        // A moment to see it, then back to the game.
        closeAt = if (everyone) SystemClock.uptimeMillis() + 900 else 0
        invalidate()
    }

    // A with a controller that isn't playing takes the first player still waiting.
    override fun padActivity(device: KPPadDevice, pressed: Long) {
        if (device.isTouch || device.isKeyboard || device.slot in 0..3) return
        val a = KartPadPads.faceFor(device).a
        if (a < 0 || ((pressed shr a) and 1L) == 0L) return
        val each = waiting.firstOrNull { it.player !in back } ?: return
        if (!KPRoster.move(device, each.player)) return
        swallowUntil = SystemClock.uptimeMillis() + 150
        check()
    }

    override fun handle(button: KPPad): Boolean {
        if (button == KPPad.Confirm && SystemClock.uptimeMillis() <= swallowUntil) {
            swallowUntil = 0
            return true
        }
        return false
    }

    override fun drawDesign(c: Canvas) {
        KP.fill(c, RectF(0f, 0f, width, height), 0x000000, 0f, .35f)
        val card = card()
        KP.shadowed(c, 10f, 30f, .35f, card, KP.p.panel, 28f)
        KP.stroke(c, card, KP.p.panelStroke, 1.5f, 28f)
        val count = waiting.size
        val everyone = count > 0 && back.size == count
        val heading = when {
            everyone -> if (count == 1) "Controller reconnected" else "Controllers reconnected"
            count == 1 -> "${KPFaces.playerName(waiting[0].player)}’s controller disconnected"
            else -> "Controllers disconnected"
        }
        KP.text(c, heading, RectF(card.left + 40, card.top + 30, card.right - 40, card.top + 74), 31f, KP.p.text, KPWeight.Bold, KPAlign.Left)
        if (everyone) return
        val press = KPHints.buttonWord(KartPadPads.joinDevice(), KPPad.Confirm)
        val message = if (count - back.size > 1) "Reconnect them, or press $press on another controller."
            else "Reconnect it, or press $press on another controller."
        KP.text(c, message, RectF(card.left + 40, card.top + 82, card.right - 40, card.top + 110), 21f, KP.p.secondaryText, KPWeight.Regular,
            KPAlign.Left)
    }

    private fun drawTile(index: Int, c: Canvas, r: RectF) {
        val each = waiting.getOrNull(index) ?: return
        val player = each.player
        val isBack = player in back
        val color = KP.PlayerColors[player]
        KP.fill(c, r, KP.p.well, 20f, .7f)
        KP.stroke(c, RectF(r.left + 1, r.top + 1, r.right - 1, r.bottom - 1), if (isBack) color else KP.p.buttonStroke, if (isBack) 3f else 2f, 19f)
        KPPlayerCards.cap(c, r, r.top, player, false, 46f)
        KP.text(c, KPFaces.playerName(player), RectF(r.left + 16, r.top + 9, r.right - 16, r.top + 37), 21f, KP.PlayerInk[player], KPWeight.Heavy,
            KPAlign.Left)
        val portrait = each.mii?.let { mii -> KPMiiSource.portrait(mii) { invalidate() } }
        val saved = if (!isBack) c.saveLayerAlpha(r.left, r.top, r.right, r.bottom, (.55f * 255).toInt()) else c.save()
        KPFaces.miiWell(c, RectF(r.centerX() - 36, r.top + 54, r.centerX() + 36, r.top + 126), portrait, color, false)
        // The controller they had.
        KPControllerArt.draw(c, RectF(r.left + 16, r.top + 132, r.right - 16, r.top + 180), each.family, KPArtState(accent = color), each.systemName)
        c.restoreToCount(saved)
        KP.text(c, each.name, RectF(r.left + 10, r.top + 184, r.right - 10, r.top + 206), 15f, KP.p.secondaryText, KPWeight.Medium)
        if (isBack) {
            KPGlyphs.draw(c, KPUIGlyph.Check, RectF(r.centerX() - 38, r.top + 206, r.centerX() - 12, r.top + 232), color)
            KP.text(c, "Back", RectF(r.centerX() - 8, r.top + 206, r.centerX() + 52, r.top + 232), 19f, KP.p.text, KPWeight.Bold, KPAlign.Left)
        } else {
            KP.text(c, "Waiting…", RectF(r.left + 10, r.top + 206, r.right - 10, r.top + 232), 19f, KP.p.accentBottom, KPWeight.Semibold)
        }
    }
}
