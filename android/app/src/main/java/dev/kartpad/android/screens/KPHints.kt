package dev.kartpad.android.screens

import android.graphics.Canvas
import android.graphics.Path
import android.graphics.RectF
import kotlin.math.ceil
import kotlin.math.max

// The button hints along the bottom of a screen ("Ⓐ Select  Ⓑ Back"), drawn as the controller in hand
// labels its buttons (after the Mac's apple/macos/KartPadHints.inc.mm): ✕ ○ □ △ on a PlayStation pad,
// the physical letters on a Switch pad (whose A is where an Xbox pad has B), A B 1 2 on a Wii Remote,
// and enter / esc keycaps on a keyboard. A remapped pad shows the buttons it now confirms and goes back
// with. The hints follow whichever controller was used last; worked by touch, they aren't drawn.

/** A hint: a button (null for plain text) and what it does; `also` is a second button shown with the first (L / R). */
data class KPHint(val button: KPPad?, val text: String, val also: KPPad? = null)

object KPHints {
    // No controller: an Xbox layout, the usual one.
    private val xbox = KPPadDevice(-3, -1, 0, 0, FloatArray(SDLAxis.Count), 0, 0, SDLType.XboxOne,
        intArrayOf(SDLLabel.A, SDLLabel.B, SDLLabel.X, SDLLabel.Y), false, false, false, "", "Xbox controller", KPPadFamily.Xbox)
    private val standard = KPPadFace(SDLButton.South, SDLButton.East, SDLButton.West, SDLButton.North)
    private val path = Path()
    private var shown: String? = null

    // Face buttons the Mac names by where they sit (KPButtonLabel), where SDL's labels don't know them:
    // a Wii Remote's B trigger is south, A east, 1 west and 2 north (with a Classic Controller attached
    // its own buttons take over); a GameCube controller's B sits west and X east; a Wii U Pro is
    // labelled as Nintendo's own pads are. Null: the pad's own labels (KPPadDevice.label).
    private fun placed(pad: KPPadDevice, native: Int): String? {
        if (native !in 0..3) return null
        val name = pad.systemName
        return when {
            name == "Nintendo Wii Remote" || name == "Nintendo Wii Remote with Nunchuk" -> arrayOf("B", "A", "1", "2")[native]
            pad.family == KPPadFamily.GameCube -> arrayOf("A", "X", "B", "Y")[native]
            name.contains("Wii U Pro Controller") -> arrayOf("B", "A", "Y", "X")[native]
            else -> null
        }
    }

    /**
     * What the device's button for a menu input is called: "A", "Cross", "LB", "enter". Null when it
     * has none (the keyboard has no X or Y for menus; a Wii Remote no shoulder buttons). No device: an
     * Xbox layout.
     */
    fun label(device: KPPadDevice?, button: KPPad): String? {
        val pad = device ?: xbox
        val face = if (device == null) standard else KartPadPads.faceFor(device)
        if (!pad.isKeyboard) when (button) {
            KPPad.Confirm -> placed(pad, face.a)?.let { return it }
            KPPad.Back -> placed(pad, face.b)?.let { return it }
            // X and Y in menus are the game's X and Y, unless confirm or back took them.
            KPPad.Undo -> if (face.x != face.a && face.x != face.b) placed(pad, face.x)?.let { return it }
            KPPad.Redo -> if (face.y != face.a && face.y != face.b) placed(pad, face.y)?.let { return it }
            // Start is Menu on any pad that isn't a PlayStation, Nintendo or GameCube one.
            KPPad.Start -> if (pad.family == KPPadFamily.Generic || pad.family == KPPadFamily.Touch) return "Menu"
            else -> {}
        }
        return pad.label(button, face)
    }

    fun isShape(label: String) = label == "Cross" || label == "Circle" || label == "Square" || label == "Triangle"

    /** The button in running text ("Press A to join", "Press ✕ to join"). */
    fun buttonWord(device: KPPadDevice?, button: KPPad): String {
        val word = label(device, button) ?: "A"
        return when (word) {
            "Cross" -> "✕"
            "Circle" -> "○"
            "Square" -> "□"
            "Triangle" -> "△"
            else -> word
        }
    }

    // A filled round badge with a letter or a PlayStation shape, a keycap for a word, arrows for left/right.
    fun badgeWidth(label: String, size: Float): Float {
        val round = Math.round(size * 1.4f).toFloat()
        if (label == "Left" || label == "Right") return Math.round(size * .9f).toFloat()
        if (label.length <= 1 || isShape(label)) return round
        return max(round, ceil(KP.textWidth(label, size * .78f, KPWeight.Semibold)) + size * .8f)
    }

    /** hole is the colour of the letter or shape on a round badge (the panel behind, by default). */
    fun drawBadge(c: Canvas, label: String, r: RectF, size: Float, hex: Int, hole: Int? = null) {
        val ink = KP.ink(hex)
        if (label == "Left" || label == "Right") {
            val left = label == "Left"
            val h = size * .62f
            val w = size * .5f
            val x = r.centerX() + (if (left) w / 2 else -w / 2)
            val y = r.centerY()
            path.reset()
            path.moveTo(x, y - h / 2)
            path.lineTo(x + (if (left) -w else w), y)
            path.lineTo(x, y + h / 2)
            path.close()
            c.drawPath(path, ink)
            return
        }
        val holeInk = hole ?: KP.p.panel
        if (label.length <= 1 || isShape(label)) {
            c.drawOval(r, ink)
            val line = KP.ink(holeInk, stroke = max(1.5f, size * .11f))
            val inner = RectF(r).apply { inset(r.width() * .3f, r.height() * .3f) }
            when (label) {
                "Cross" -> {
                    c.drawLine(inner.left, inner.top, inner.right, inner.bottom, line)
                    c.drawLine(inner.right, inner.top, inner.left, inner.bottom, line)
                }
                "Circle" -> c.drawOval(inner, line)
                "Square" -> c.drawRect(inner.left + .5f, inner.top + .5f, inner.right - .5f, inner.bottom - .5f, line)
                "Triangle" -> {
                    val t = RectF(inner).apply { offset(0f, -inner.height() * .06f) }
                    path.reset()
                    path.moveTo(t.centerX(), t.top)
                    path.lineTo(t.right, t.bottom)
                    path.lineTo(t.left, t.bottom)
                    path.close()
                    c.drawPath(path, line)
                }
                else -> KP.centredLabel(c, label, r, size * .8f, holeInk, KPWeight.Bold)
            }
            return
        }
        KP.stroke(c, r, hex, 1.5f, size * .36f)
        KP.centredLabel(c, label, r, size * .78f, hex, KPWeight.Semibold)
    }

    /**
     * Draws the hints in one line in r, from the side align says. Hints the device has no button for are
     * left out; one with no button is plain text. No device: the hint device (KartPadPads.hintDevice);
     * no ink: the secondary text colour.
     */
    fun draw(c: Canvas, r: RectF, hints: List<KPHint>, size: Float, align: KPAlign, device: KPPadDevice? = null, ink: Int? = null) {
        if (KartPadPads.touching) return  // worked by touch: no controller to show buttons for
        val pad = device ?: KartPadPads.hintDevice()
        val hex = ink ?: KP.p.secondaryText
        class Piece(val first: String?, val second: String?, val text: String, val width: Float)
        val pieces = ArrayList<Piece>()
        val gap = size * .4f
        val badge = Math.round(size * 1.4f).toFloat()
        var total = 0f
        for (hint in hints) {
            val first = hint.button?.let { label(pad, it) }
            var second = hint.also?.let { label(pad, it) }
            if (hint.button != null && first == null) continue
            if (second == first) second = null  // the keyboard's tab does both
            var width = ceil(KP.textWidth(hint.text, size, KPWeight.Medium))
            if (first != null) width += badgeWidth(first, size) + gap
            if (second != null) width += badgeWidth(second, size) + size * .25f
            total += width + (if (pieces.isEmpty()) 0f else size * 1.6f)
            pieces += Piece(first, second, hint.text, width)
        }
        var x = when (align) {
            KPAlign.Right -> r.right - total
            KPAlign.Center -> r.centerX() - total / 2
            KPAlign.Left -> r.left
        }
        val mid = r.centerY()
        for (piece in pieces) {
            val badges = arrayOf(piece.first, piece.second)
            for (i in 0..1) {
                val badgeLabel = badges[i] ?: continue
                val w = badgeWidth(badgeLabel, size)
                drawBadge(c, badgeLabel, RectF(x, mid - badge / 2, x + w, mid + badge / 2), size, hex)
                x += w + (if (i == 0 && piece.second != null) size * .25f else gap)
            }
            KP.text(c, piece.text, RectF(x, mid - size * .66f, r.right, mid - size * .66f + size * 1.4f), size, hex, KPWeight.Medium,
                KPAlign.Left)
            x += ceil(KP.textWidth(piece.text, size, KPWeight.Medium)) + size * 1.6f
        }
    }

    /**
     * For the roster to call when the last-used controller changes (the Mac's KPHintDeviceChanged): true
     * when that changes the buttons the hints show (for the hint device or the join device), so screens
     * should redraw.
     */
    fun deviceChanged(): Boolean {
        val device = KartPadPads.hintDevice()
        val join = KartPadPads.joinDevice()
        val now = KPPad.entries.joinToString(" ") { "${label(device, it) ?: "-"} ${label(join, it) ?: "-"}" }
        if (now == shown) return false
        shown = now
        return true
    }
}
