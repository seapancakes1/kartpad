package dev.kartpad.android.screens

import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Shader
import android.text.TextPaint
import android.view.KeyEvent
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

// Live drawings of controllers for the Controllers and button-setup screens, in the Wii's glossy
// white plastic (after the Mac's apple/macos/KartPadControllerArt.inc.mm). Each kind has its own
// silhouette (an Xbox controller's chunky grips, a PlayStation controller's touchpad and low sticks,
// a Pro Controller's round grips, a GameCube controller's big A, a Joy-Con pair, a Wii Remote held
// sideways or upright with a Nunchuk, a keyboard, a phone for the touch screen) and lights in the
// player's colour as they press. Buttons are drawn by position with plain letters; no maker's logos
// or symbols. Everything is in a 200 × 124 unit box scaled to fit; small drawings drop letters and
// keep lines at least a point wide. Main thread only.

class KPArtState(
    var buttons: Long = 0L,                       // SDL gamepad buttons held (bits)
    val axes: FloatArray = FloatArray(SDLAxis.Count),
    var highlight: Long = 0L,                     // buttons to pulse (the ones bound to an action being set up)
    var pulse: Float = 0f,                        // 0…1
    var accent: Int = 0x1b9ad5,                   // the player's colour
)

// Where each button sits, and how the body is shaped.
private enum class KPArtLayout { Offset, Symmetric, Nintendo, GameCube, JoyCon, WiiRemote, Keyboard }

// The plastic: shell, buttons at rest, recesses (stick wells) and the parts behind the shell
// (shoulders, triggers), for light and dark.
private class KPArtTones(
    val bodyTop: Int, val bodyBottom: Int, val outline: Int, val partTop: Int, val partBottom: Int, val partLine: Int,
    val letter: Int, val wellTop: Int, val wellBottom: Int, val backTop: Int, val backBottom: Int,
)

// How to draw at this size: the player's state, the scale, light or dark.
private class KPArtCtx(
    val c: Canvas,
    val state: KPArtState,
    val s: Float,          // points per art unit
    val dark: Boolean,
    val small: Boolean,    // a tray chip: silhouette and colour only
    val big: Boolean,      // button setup: every label and detail
    val tone: KPArtTones,
) {
    // A line `base` units wide, but never thinner than `minPoints` on screen.
    fun line(base: Float, minPoints: Float = .8f) = max(base, minPoints / s)
    // Letters only where they'll be readable.
    fun words(size: Float) = !small && size * s >= 4.4f
    fun held(button: Int) = button >= 0 && (state.buttons shr button) and 1L != 0L
    fun marked(button: Int) = button >= 0 && (state.highlight shr button) and 1L != 0L
    fun pull(axis: Int) = state.axes[axis].coerceIn(0f, 1f)
}

object KPControllerArt {
    /**
     * Whether a key (an Android KeyEvent keycode) is held now, for the keyboard's drawing (the Mac
     * reads SDL_GetKeyboardState). The activity sets it.
     */
    var keyDown: (Int) -> Boolean = { false }

    private val LightTones = KPArtTones(0xffffff, 0xe1e7ea, 0x97a4ab, 0xffffff, 0xe0e6e9, 0xa3afb6, 0x556168,
        0xc5ced3, 0xe9eef0, 0xf4f6f7, 0xd3dade)
    private val DarkTones = KPArtTones(0x5f6970, 0x3b4349, 0x0a0c0e, 0x7a858c, 0x4f585e, 0x1c2023, 0xf1f4f6,
        0x1b1f22, 0x353b40, 0x535c62, 0x363d42)

    private val Pi = PI.toFloat()

    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val washPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val clearFill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        xfermode = PorterDuffXfermode(PorterDuff.Mode.CLEAR)
    }
    private val clearStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
        xfermode = PorterDuffXfermode(PorterDuff.Mode.CLEAR)
    }
    private val outlinePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val labelPaint = TextPaint(Paint.ANTI_ALIAS_FLAG)
    private val capHeights = HashMap<Int, Float>()

    private fun layoutFor(family: KPPadFamily) = when (family) {
        KPPadFamily.PlayStation -> KPArtLayout.Symmetric
        KPPadFamily.Switch -> KPArtLayout.Nintendo
        KPPadFamily.GameCube -> KPArtLayout.GameCube
        KPPadFamily.JoyCon -> KPArtLayout.JoyCon
        KPPadFamily.WiiRemote -> KPArtLayout.WiiRemote
        KPPadFamily.Keyboard -> KPArtLayout.Keyboard
        else -> KPArtLayout.Offset
    }

    private fun mix(a: Int, b: Int, t: Float): Int {
        var out = 0
        for (shift in intArrayOf(16, 8, 0))
            out = out or (Math.round(((a shr shift) and 255) * (1 - t) + ((b shr shift) and 255) * t) shl shift)
        return out
    }

    private fun luminance(rgb: Int): Float {
        fun channel(shift: Int): Double {
            val v = ((rgb shr shift) and 255) / 255.0
            return if (v <= .04045) v / 12.92 else ((v + .055) / 1.055).pow(2.4)
        }
        return (.2126 * channel(16) + .7152 * channel(8) + .0722 * channel(0)).toFloat()
    }

    // Letters on a lit part: dark on light colours (Player 3's yellow, Player 4's green), white on the rest.
    private fun inkOn(fill: Int) = if (luminance(fill) > .3f) mix(fill, 0x000000, .8f) else 0xffffff

    // The player's number from their colour (-1 for the UI blue).
    private fun playerOf(accent: Int) = KP.PlayerColors.indexOf(accent)

    // MARK: Shapes

    private fun rect(x: Float, y: Float, w: Float, h: Float) = RectF(x, y, x + w, y + h)

    private fun boundsOf(p: Path) = RectF().also { p.computeBounds(it, true) }

    private fun circle(x: Float, y: Float, r: Float) =
        Path().apply { addOval(RectF(x - r, y - r, x + r, y + r), Path.Direction.CW) }

    private fun round(r: RectF, radius: Float): Path {
        val corner = max(0f, min(radius, min(r.width(), r.height()) / 2 - .01f))
        return Path().apply { addRoundRect(r, corner, corner, Path.Direction.CW) }
    }

    // A closed polygon (x, y pairs) with each corner rounded by its own radius.
    private fun polygon(v: FloatArray, radii: FloatArray): Path {
        val count = v.size / 2
        val pen = KPPen()
        pen.moveTo((v[0] + v[2 * count - 2]) / 2, (v[1] + v[2 * count - 1]) / 2)
        for (i in 0 until count) {
            val next = (i + 1) % count
            pen.arcTo(v[2 * i], v[2 * i + 1], (v[2 * i] + v[2 * next]) / 2, (v[2 * i + 1] + v[2 * next + 1]) / 2, radii[i])
        }
        pen.close()
        return pen.path
    }

    private fun octagonPath(x: Float, y: Float, r: Float): Path {
        val v = FloatArray(16)
        val radii = FloatArray(8)
        for (i in 0 until 8) {
            v[2 * i] = x + r * cos(Pi / 8 + i * Pi / 4)
            v[2 * i + 1] = y + r * sin(Pi / 8 + i * Pi / 4)
            radii[i] = r * .18f
        }
        return polygon(v, radii)
    }

    // A body symmetric about x = axis: the right half from the top centre clockwise to the bottom
    // centre as curves (control, control, end: six numbers each), mirrored for the left.
    private fun mirrored(topX: Float, topY: Float, k: FloatArray, axis: Float = 100f): Path {
        val p = Path()
        p.moveTo(topX, topY)
        val count = k.size / 6
        for (i in 0 until count) p.cubicTo(k[6 * i], k[6 * i + 1], k[6 * i + 2], k[6 * i + 3], k[6 * i + 4], k[6 * i + 5])
        for (i in count - 1 downTo 0) {
            val startX = if (i > 0) k[6 * i - 2] else topX
            val startY = if (i > 0) k[6 * i - 1] else topY
            p.cubicTo(2 * axis - k[6 * i + 2], k[6 * i + 3], 2 * axis - k[6 * i], k[6 * i + 1], 2 * axis - startX, startY)
        }
        p.close()
        return p
    }

    // A line's outline as a shape (CGPathCreateCopyByStrokingPath), stroked large and scaled back so its
    // curves are as fine as the drawing's.
    private fun outline(src: Path, width: Float): Path {
        val up = 16f
        val big = Path(src)
        val m = Matrix()
        m.setScale(up, up)
        big.transform(m)
        outlinePaint.strokeWidth = width * up
        val out = Path()
        outlinePaint.getFillPath(big, out)
        m.setScale(1 / up, 1 / up)
        out.transform(m)
        return out
    }

    // MARK: Painting

    private fun fill(c: Canvas, p: Path, hex: Int, alpha: Float = 1f) {
        fillPaint.color = KP.argb(hex, alpha)
        c.drawPath(p, fillPaint)
    }

    private fun stroke(c: Canvas, p: Path, hex: Int, width: Float, alpha: Float = 1f) {
        strokePaint.color = KP.argb(hex, alpha)
        strokePaint.strokeWidth = width
        c.drawPath(p, strokePaint)
    }

    // A vertical gradient across a box, between fractions `from` and `to` of its height, inside the
    // current clip.
    private fun wash(c: Canvas, box: RectF, top: Int, bottom: Int, topAlpha: Float = 1f, bottomAlpha: Float = 1f,
                     from: Float = 0f, to: Float = 1f) {
        washPaint.shader = LinearGradient(0f, box.top + box.height() * from, 0f, box.top + box.height() * to,
            KP.argb(top, topAlpha), KP.argb(bottom, bottomAlpha), Shader.TileMode.CLAMP)
        c.drawPaint(washPaint)
        washPaint.shader = null
    }

    // Three colours down a box, `middle` at fraction `at` of its height, inside the current clip.
    private fun wash3(c: Canvas, box: RectF, top: Int, middle: Int, bottom: Int, at: Float) {
        washPaint.shader = LinearGradient(0f, box.top, 0f, box.bottom, intArrayOf(KP.argb(top), KP.argb(middle), KP.argb(bottom)),
            floatArrayOf(0f, at, 1f), Shader.TileMode.CLAMP)
        c.drawPaint(washPaint)
        washPaint.shader = null
    }

    // The same, filling a path.
    private fun gradient(c: Canvas, p: Path, top: Int, bottom: Int, topAlpha: Float = 1f, bottomAlpha: Float = 1f,
                         from: Float = 0f, to: Float = 1f) {
        val box = boundsOf(p)
        washPaint.shader = LinearGradient(0f, box.top + box.height() * from, 0f, box.top + box.height() * to,
            KP.argb(top, topAlpha), KP.argb(bottom, bottomAlpha), Shader.TileMode.CLAMP)
        c.drawPath(p, washPaint)
        washPaint.shader = null
    }

    // A band just inside a shape's top edge, fading out down its sides (in steps, or at once when
    // `steps` is 1): light on a raised part, shade in a recess. Drawn inside a clip to the shape.
    private fun rim(c: Canvas, p: Path, width: Float, hex: Int, alpha: Float, steps: Int = 1) {
        val box = boundsOf(p)
        for (step in 0 until steps) {
            val reach = if (steps == 1) .45f else .56f * (step + 1) / steps
            c.save()
            c.clipRect(box.left - width, box.top - width, box.right + width, box.top + box.height() * reach)
            c.translate(0f, width / 2)
            stroke(c, p, hex, width, alpha / steps)
            c.restore()
        }
    }

    // A surface: a gradient with a rim along its top, in one clip.
    private fun surface(c: Canvas, p: Path, top: Int, bottom: Int, rimWidth: Float = 0f, rimAlpha: Float = 0f, rimInk: Int = 0xffffff) {
        c.save()
        c.clipPath(p)
        wash(c, boundsOf(p), top, bottom)
        if (rimAlpha > 0) rim(c, p, rimWidth, rimInk, rimAlpha)
        c.restore()
    }

    // A shadow under a shape, soft (widening translucent bands, so it scales with the drawing) or a
    // plain contact shadow for small parts.
    private fun drop(a: KPArtCtx, p: Path, drop: Float, strength: Float = 1f, soft: Boolean = true) {
        a.c.save()
        a.c.translate(0f, drop)
        val k = strength * (if (a.dark) 2.4f else 1f)
        // Bands round the edge rather than a fill, since the shape covers the middle.
        if (soft) {
            for (i in 1..3) stroke(a.c, p, 0x000000, drop * 1.2f * i, .045f * k)
        } else {
            fill(a.c, p, 0x000000, .12f * k)
        }
        a.c.restore()
    }

    // The ring around a part being set up: a crisp line in the player's colour, a small gap off the
    // part, with a soft glow that breathes with the pulse.
    private fun mark(a: KPArtCtx, shape: Path) {
        val c = a.c
        val pulse = a.state.pulse.coerceIn(0f, 1f)
        val gap = a.line(1.1f, 1.1f) + .7f * pulse
        val ring = a.line(1.25f, 1.4f)
        val glow = a.line(1.2f, 1.1f)
        val ink = if (!a.dark && luminance(a.state.accent) > .3f) mix(a.state.accent, 0x000000, .15f) else a.state.accent
        val saved = c.save()
        val reach = 2 * (gap + ring + glow * 3)
        val bounds = boundsOf(shape).apply { inset(-reach, -reach) }
        c.clipRect(bounds)
        c.saveLayer(bounds, null)
        for (i in 3 downTo 1) stroke(c, shape, a.state.accent, 2 * (gap + ring + glow * i), .05f + .09f * pulse)
        stroke(c, shape, ink, 2 * (gap + ring))
        clearStroke.strokeWidth = 2 * gap
        c.drawPath(shape, clearStroke)
        c.drawPath(shape, clearFill)
        c.restoreToCount(saved)
    }

    // Capitals centred on a point. Drawn at the size they show, so the type's metrics hold when tiny.
    private fun artLabel(a: KPArtCtx, text: String, x: Float, y: Float, size: Float, ink: Int, weight: Int = KPWeight.Bold) {
        val k = a.s
        val paint = labelPaint
        paint.typeface = KP.typeface(weight)
        paint.textSize = size * k
        paint.color = KP.argb(ink)
        paint.textAlign = Paint.Align.LEFT
        val cap = capHeight(weight) * size * k
        a.c.save()
        a.c.scale(1 / k, 1 / k)
        a.c.drawText(text, x * k - paint.measureText(text) / 2, y * k + cap / 2, paint)
        a.c.restore()
    }

    // Cap height as a fraction of the size, measured large (getTextBounds is in whole pixels).
    private fun capHeight(weight: Int): Float = capHeights.getOrPut(weight) {
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = KP.typeface(weight)
            textSize = 200f
        }
        val bounds = Rect()
        paint.getTextBounds("H", 0, 1, bounds)
        -bounds.top / 200f
    }

    // MARK: The shell and its parts

    // The shell: a soft shadow, white plastic shading to silver, a gloss over the top, shade inside the
    // lower edge and a fine outline. Dark mode is graphite with a light rim so it stands off the card.
    private fun shell(a: KPArtCtx, body: Path, shadow: Boolean = true) {
        val c = a.c
        if (shadow) drop(a, body, 2f)
        val box = boundsOf(body)
        c.save()
        c.clipPath(body)
        // White plastic shading to silver, with a gloss over the top part.
        wash3(c, box, mix(a.tone.bodyTop, 0xffffff, if (a.dark) .12f else .8f), mix(a.tone.bodyTop, a.tone.bodyBottom, .45f),
            a.tone.bodyBottom, .45f)
        // Shade inside the lower edge: the wider bands start lower down the sides, so it fades in.
        val widths = floatArrayOf(6f, 3.8f, 1.8f)
        val starts = floatArrayOf(.72f, .6f, .48f)
        for (i in 0 until 3) {
            c.save()
            c.clipRect(rect(box.left - 4, box.top + box.height() * starts[i], box.width() + 8, box.height()))
            c.translate(0f, -a.line(widths[i]) / 2)
            stroke(c, body, 0x000000, a.line(widths[i]), if (a.dark) .1f else .03f)
            c.restore()
        }
        rim(c, body, a.line(2f, 1.2f), 0xffffff, if (a.dark) .45f else 1f, 3)
        c.restore()
        stroke(c, body, a.tone.outline, a.line(1.2f, 1f), if (a.dark) .85f else 1f)
    }

    // One button of any shape: raised silver at rest, lit with the player's colour while held, ringed
    // while it's one being set up. Its label takes dark or light ink to suit the fill.
    private fun part(a: KPArtCtx, button: Int, shape: Path, label: String? = null, size: Float = 0f, atX: Float = 0f, atY: Float = 0f) {
        val c = a.c
        val held = a.held(button)
        val accent = a.state.accent
        if (a.marked(button)) mark(a, shape)
        if (!held) {
            c.save()
            c.translate(0f, a.line(.9f, .6f))
            fill(c, shape, 0x000000, if (a.dark) .45f else .15f)
            c.restore()
        }
        surface(c, shape, if (held) mix(accent, 0xffffff, .2f) else a.tone.partTop, if (held) mix(accent, 0x000000, .08f) else a.tone.partBottom,
            a.line(1f, .8f), if (a.small) 0f else if (held) .45f else if (a.dark) .3f else .9f)
        stroke(c, shape, if (held) mix(accent, 0x000000, .35f) else a.tone.partLine, a.line(.8f, .75f))
        if (!label.isNullOrEmpty() && a.words(size)) artLabel(a, label, atX, atY, size, if (held) inkOn(accent) else a.tone.letter)
    }

    private fun button(a: KPArtCtx, button: Int, x: Float, y: Float, radius: Float, label: String? = null) =
        part(a, button, circle(x, y, radius), label, radius * 1.12f, x, y)

    private fun pill(a: KPArtCtx, button: Int, r: RectF) = part(a, button, round(r, min(r.width(), r.height()) / 2))

    // A − or + drawn as bars (readable smaller than text).
    private fun sign(a: KPArtCtx, button: Int, x: Float, y: Float, size: Float, plus: Boolean) {
        if (a.small) return
        fillPaint.color = KP.argb(if (a.held(button)) inkOn(a.state.accent) else a.tone.letter)
        val w = max(size * .26f, .9f / a.s)
        a.c.drawRect(x - size / 2, y - w / 2, x + size / 2, y + w / 2, fillPaint)
        if (plus) a.c.drawRect(x - w / 2, y - size / 2, x + w / 2, y + size / 2, fillPaint)
    }

    // A small arrowhead pointing up, right, down or left (0…3).
    private fun arrowhead(c: Canvas, x: Float, y: Float, size: Float, direction: Int, ink: Int, alpha: Float) {
        val angle = direction * Pi / 2
        val cs = cos(angle)
        val sn = sin(angle)
        val px = floatArrayOf(0f, size * .62f, -size * .62f)
        val py = floatArrayOf(-size * .6f, size * .4f, size * .4f)
        val p = Path()
        for (i in 0 until 3) {
            val vx = x + px[i] * cs - py[i] * sn
            val vy = y + px[i] * sn + py[i] * cs
            if (i == 0) p.moveTo(vx, vy) else p.lineTo(vx, vy)
        }
        p.close()
        fill(c, p, ink, alpha)
    }

    // Four face buttons around a point, labelled by position (south, east, west, north).
    private fun face(a: KPArtCtx, x: Float, y: Float, spread: Float, radius: Float, south: String?, east: String?, west: String?,
                     north: String?) {
        button(a, SDLButton.North, x, y - spread, radius, north)
        button(a, SDLButton.West, x - spread, y, radius, west)
        button(a, SDLButton.East, x + spread, y, radius, east)
        button(a, SDLButton.South, x, y + spread, radius, south)
    }

    // A stick: a recessed well (round, or the GameCube's octagon) and a cap that follows the stick,
    // ringed in the player's colour as it leans and filled with it while clicked.
    private fun stick(a: KPArtCtx, click: Int, axisX: Int, x: Float, y: Float, radius: Float, octagon: Boolean = false,
                      capScale: Float = .72f) {
        val c = a.c
        val accent = a.state.accent
        val well = if (octagon) octagonPath(x, y, radius) else circle(x, y, radius)
        if (a.marked(click)) mark(a, well)
        surface(c, well, a.tone.wellTop, a.tone.wellBottom, a.line(2.2f, 1f), if (a.dark) .4f else .16f, 0x000000)
        stroke(c, well, a.tone.partLine, a.line(.8f, .75f))
        val sx = a.state.axes[axisX].coerceIn(-1f, 1f)
        val sy = a.state.axes[axisX + 1].coerceIn(-1f, 1f)
        val lean = min(1f, hypot(sx, sy))
        val cap = radius * capScale
        val cx = x + sx * radius * .36f
        val cy = y + sy * radius * .36f
        val top = circle(cx, cy, cap)
        val dish = circle(cx, cy, cap * .68f)
        val held = a.held(click)
        c.save()
        c.translate(0f, a.line(1.2f, .6f))
        fill(c, top, 0x000000, if (a.dark) .5f else .2f)
        c.restore()
        surface(c, top, if (held) mix(accent, 0xffffff, .2f) else a.tone.partTop, if (held) mix(accent, 0x000000, .08f) else a.tone.partBottom,
            a.line(1f, .8f), if (a.small) 0f else if (held) .45f else if (a.dark) .3f else .9f)
        // The dish is concave: dark at the top, light at the bottom. Leaning only tints it faintly; the
        // full colour is for a click.
        var dishTop = if (held) mix(accent, 0x000000, .15f) else a.tone.partBottom
        var dishBottom = if (held) mix(accent, 0xffffff, .25f) else a.tone.partTop
        val leaning = !held && lean > .05f
        if (leaning) {
            dishTop = mix(dishTop, accent, .18f * lean)
            dishBottom = mix(dishBottom, accent, .12f * lean)
        }
        gradient(c, dish, dishTop, dishBottom)
        if (!a.small) stroke(c, dish, if (held) mix(accent, 0x000000, .3f) else a.tone.partLine, a.line(.6f, .5f), .6f)
        stroke(c, top, if (held) mix(accent, 0x000000, .35f) else a.tone.partLine, a.line(.8f, .75f))
        // Leaning rings the cap in the player's colour, stronger the further it goes.
        if (leaning) stroke(c, top, accent, a.line(1.4f, 1.1f), .35f + .65f * lean)
    }

    private val DpadButtons = intArrayOf(SDLButton.DpadUp, SDLButton.DpadRight, SDLButton.DpadDown, SDLButton.DpadLeft)

    // A D-pad cross; each arm lights on its own. `turn` quarter-turns it clockwise for a controller
    // held sideways, so the arm that lights is the one under the player's thumb.
    private fun dpad(a: KPArtCtx, x: Float, y: Float, size: Float, turn: Int = 0) {
        val c = a.c
        val h = size / 2
        val w = size * .17f
        val v = floatArrayOf(x - w, y - h, x + w, y - h, x + w, y - w, x + h, y - w, x + h, y + w, x + w, y + w,
            x + w, y + h, x - w, y + h, x - w, y + w, x - h, y + w, x - h, y - w, x - w, y - w)
        val o = w * .5f
        val i = w * .35f
        val cross = polygon(v, floatArrayOf(o, o, i, o, o, i, o, o, i, o, o, i))
        // Arms in screen order: up, right, down, left.
        val arms = arrayOf(rect(x - w, y - h, 2 * w, h - w * .4f), rect(x + w * .4f, y - w, h - w * .4f, 2 * w),
            rect(x - w, y + w * .4f, 2 * w, h - w * .4f), rect(x - h, y - w, h - w * .4f, 2 * w))
        val button = IntArray(4) { arm -> DpadButtons[(arm - turn + 8) % 4] }
        for (arm in 0 until 4) if (a.marked(button[arm])) mark(a, round(arms[arm], o))
        c.save()
        c.translate(0f, a.line(1f, .6f))
        fill(c, cross, 0x000000, if (a.dark) .45f else .16f)
        c.restore()
        c.save()
        c.clipPath(cross)
        wash(c, boundsOf(cross), a.tone.partTop, a.tone.partBottom)
        for (arm in 0 until 4) if (a.held(button[arm])) {
            c.save()
            c.clipRect(arms[arm])
            wash(c, arms[arm], mix(a.state.accent, 0xffffff, .2f), mix(a.state.accent, 0x000000, .08f))
            c.restore()
        }
        if (!a.small) rim(c, cross, a.line(1f, .8f), 0xffffff, if (a.dark) .3f else .9f)
        c.restore()
        if (!a.small) {
            // A dimple in the middle, and arrowheads on the big drawing.
            gradient(c, circle(x, y, w * .55f), a.tone.partBottom, a.tone.partTop)
            if (a.big) for (arm in 0 until 4) {
                val d = h - w * .75f
                val tx = x + d * (if (arm == 1) 1 else if (arm == 3) -1 else 0)
                val ty = y + d * (if (arm == 2) 1 else if (arm == 0) -1 else 0)
                val held = a.held(button[arm])
                arrowhead(c, tx, ty, w * .55f, arm, if (held) inkOn(a.state.accent) else a.tone.letter, if (held) .9f else .4f)
            }
        }
        stroke(c, cross, a.tone.partLine, a.line(.8f, .75f))
    }

    // The PlayStation controller's D-pad: four separate pads pointing in.
    private fun arrowPads(a: KPArtCtx, x: Float, y: Float, size: Float) {
        val h = size / 2
        val w = size * .18f
        val gap = size * .07f
        for (arm in 0 until 4) {
            val angle = arm * Pi / 2
            val cs = cos(angle)
            val sn = sin(angle)
            val px = floatArrayOf(-w, w, w, 0f, -w)
            val py = floatArrayOf(-h, -h, -gap - w, -gap, -gap - w)
            val v = FloatArray(10)
            for (i in 0 until 5) {
                v[2 * i] = x + px[i] * cs - py[i] * sn
                v[2 * i + 1] = y + px[i] * sn + py[i] * cs
            }
            val shape = polygon(v, floatArrayOf(w * .45f, w * .45f, w * .3f, w * .25f, w * .3f))
            part(a, DpadButtons[arm], shape)
            if (a.big) {
                val held = a.held(DpadButtons[arm])
                val ty = -h + w * .95f
                arrowhead(a.c, x - ty * sn, y + ty * cs, w * .55f, arm, if (held) inkOn(a.state.accent) else a.tone.letter, if (held) .9f else .4f)
            }
        }
    }

    // A trigger: an analog pad that fills from its base up as it's pulled. `show` is how much of it
    // peeks out past whatever sits in front; its label changes ink where the fill passes under it.
    private fun triggerPart(a: KPArtCtx, axis: Int, r: RectF, radius: Float, show: Float, label: String?, labelShift: Float = 0f) {
        val c = a.c
        val shape = round(r, radius)
        val accent = a.state.accent
        drop(a, shape, 1.2f, .8f, false)
        val pull = a.pull(axis)
        val level = rect(r.left, r.top + show * (1 - pull), r.width(), r.height())
        c.save()
        c.clipPath(shape)
        wash(c, r, a.tone.backTop, a.tone.backBottom, 1f, 1f, 0f, show / r.height())
        if (pull > .01f) {
            c.save()
            c.clipRect(level)
            wash(c, level, mix(accent, 0xffffff, .15f), mix(accent, 0x000000, .1f))
            c.restore()
        }
        if (!a.small) rim(c, shape, a.line(1f, .8f), 0xffffff, if (a.dark) .3f else .9f)
        c.restore()
        stroke(c, shape, a.tone.partLine, a.line(.8f, .75f))
        val size = min(6f, show * .62f)
        if (!label.isNullOrEmpty() && a.words(size) && (a.big || label.length == 1)) {
            val x = r.centerX() + labelShift
            val y = r.top + show / 2 + .3f
            artLabel(a, label, x, y, size, a.tone.letter)
            if (pull > .01f) {
                c.save()
                c.clipRect(level)
                artLabel(a, label, x, y, size, inkOn(accent))
                c.restore()
            }
        }
    }

    // Shoulder buttons with their triggers behind, peeking above the shell (drawn before it). The left
    // pair is given and the right mirrors it, both tilted to follow the shoulders. `show` is how much
    // of a shoulder button clears the shell.
    private fun shoulders(a: KPArtCtx, bumper: RectF, trigger: RectF, tilt: Float, show: Float, bumperLeft: String, bumperRight: String,
                          triggerLeft: String, triggerRight: String, leftBumper: Boolean = true) {
        val c = a.c
        for (side in 0 until 2) {
            val right = side == 1
            val b = if (right) RectF(200 - bumper.right, bumper.top, 200 - bumper.left, bumper.bottom) else bumper
            val t = if (right) RectF(200 - trigger.right, trigger.top, 200 - trigger.left, trigger.bottom) else trigger
            val button = if (right) SDLButton.RightShoulder else SDLButton.LeftShoulder
            c.save()
            c.translate(b.centerX(), b.centerY())
            c.rotate(Math.toDegrees((if (right) -tilt else tilt).toDouble()).toFloat())
            c.translate(-b.centerX(), -b.centerY())
            triggerPart(a, if (right) SDLAxis.RightTrigger else SDLAxis.LeftTrigger, t, min(t.width(), t.height()) * .45f, b.top - t.top,
                if (right) triggerRight else triggerLeft)
            // The GameCube controller has Z on the right only; a left one (newer models' ZL) shows only while
            // it's pressed or being set up.
            if (right || leftBumper || a.held(button) || a.marked(button)) {
                val size = min(6f, show * .66f)
                part(a, button, round(b, b.height() * .42f), if (right) bumperRight else bumperLeft, size, b.centerX(), b.top + show / 2 + .4f)
            }
            c.restore()
        }
    }

    // MARK: Controllers

    private val XboxRight = floatArrayOf(116f, 25f, 131f, 20f, 145f, 21f, 160f, 22f, 172f, 26f, 177f, 34f, 184f, 45f, 187f, 59f, 188f, 74f,
        190f, 88f, 189f, 100f, 183f, 107f, 177f, 114f, 167f, 117f, 157f, 116f, 147f, 115f, 140f, 109f, 135f, 104f,
        127f, 100f, 113f, 100f, 100f, 100f)

    // Xbox: a chunky body with deep grips and a heavy lower half, the left stick high and the right one
    // low, a round guide button high in the middle with two small buttons below it and share under those.
    private fun xbox(a: KPArtCtx) {
        shoulders(a, rect(30f, 13f, 46f, 17f), rect(36f, 2f, 34f, 21f), -.1f, 8.5f, "LB", "RB", "LT", "RT")
        shell(a, mirrored(100f, 25f, XboxRight))
        stick(a, SDLButton.LeftStick, SDLAxis.LeftX, 55f, 50f, 13.5f)
        dpad(a, 80f, 80f, 24f)
        stick(a, SDLButton.RightStick, SDLAxis.RightX, 121f, 80f, 13f)
        face(a, 146f, 50f, 12.5f, 7.2f, "A", "B", "X", "Y")
        button(a, SDLButton.Guide, 100f, 34f, 6.8f)
        if (!a.small)
            stroke(a.c, circle(100f, 34f, 4.2f), if (a.held(SDLButton.Guide)) inkOn(a.state.accent) else a.tone.partLine, a.line(.7f, .5f), .6f)
        button(a, SDLButton.Back, 87f, 50f, 3.8f)
        button(a, SDLButton.Start, 113f, 50f, 3.8f)
        pill(a, SDLButton.Misc1, rect(96.5f, 57.5f, 7f, 4f))
    }

    private val PlayStationRight = floatArrayOf(118f, 27f, 132f, 23f, 147f, 24f, 163f, 25f, 176f, 28f, 182f, 37f, 191f, 54f, 198f, 82f, 197f, 101f,
        196f, 113f, 189f, 119f, 180f, 118f, 169f, 117f, 158f, 106.5f, 152f, 98f, 144f, 93.5f, 120f, 93f, 100f, 93f)

    // PlayStation: long grips, a wide touchpad across the top with the light bar glowing in the
    // player's colour beside it, four separate D-pad pads, and both sticks low in the middle.
    private fun playStation(a: KPArtCtx) {
        val c = a.c
        shoulders(a, rect(28f, 15f, 46f, 17f), rect(33f, 2f, 36f, 22f), -.08f, 8.5f, "L1", "R1", "L2", "R2")
        shell(a, mirrored(100f, 27f, PlayStationRight))
        val pad = rect(75f, 29f, 50f, 28f)
        for (x in floatArrayOf(pad.left - 4.6f, pad.right + 2.2f)) {
            val bar = round(rect(x, pad.top + 3, 2.4f, pad.height() - 7), 1.2f)
            stroke(c, bar, a.state.accent, a.line(2.4f, 1.2f), if (a.dark) .35f else .22f)
            fill(c, bar, mix(a.state.accent, 0xffffff, if (a.dark) .1f else .15f))
        }
        part(a, SDLButton.Touchpad, round(pad, 6f))
        pill(a, SDLButton.Back, rect(64f, 28f, 4.6f, 8.5f))
        pill(a, SDLButton.Start, rect(131.4f, 28f, 4.6f, 8.5f))
        arrowPads(a, 50f, 51f, 28f)
        face(a, 150f, 51f, 12.5f, 7.2f, null, null, null, null)
        stick(a, SDLButton.LeftStick, SDLAxis.LeftX, 76f, 78f, 12.5f)
        stick(a, SDLButton.RightStick, SDLAxis.RightX, 124f, 78f, 12.5f)
        button(a, SDLButton.Guide, 100f, 73f, 4.6f)
        pill(a, SDLButton.Misc1, rect(96.5f, 81.5f, 7f, 3.2f))
    }

    private val ProRight = floatArrayOf(120f, 28f, 136f, 26f, 150f, 27f, 166f, 28f, 177f, 31f, 181f, 38f, 186f, 46f, 188f, 55f, 190f, 64f,
        192f, 77f, 198f, 90f, 197f, 101f, 196f, 114f, 186f, 120f, 176f, 118f, 164f, 116f, 155f, 108.5f, 149f, 100f,
        142f, 90f, 121f, 86f, 100f, 86f)

    // Pro Controller: wide, with round grips splayed outward, offset sticks, − and + up top with
    // capture and home below.
    private fun pro(a: KPArtCtx) {
        shoulders(a, rect(28f, 17f, 48f, 17f), rect(34f, 4f, 36f, 22f), -.06f, 9.5f, "L", "R", "ZL", "ZR")
        shell(a, mirrored(100f, 28f, ProRight))
        stick(a, SDLButton.LeftStick, SDLAxis.LeftX, 52f, 51f, 13f)
        dpad(a, 79f, 72f, 22f)
        stick(a, SDLButton.RightStick, SDLAxis.RightX, 121f, 72f, 12f)
        face(a, 149f, 51f, 12f, 7f, "B", "A", "Y", "X")
        button(a, SDLButton.Back, 85f, 38f, 3.6f)
        sign(a, SDLButton.Back, 85f, 38f, 3.5f, false)
        button(a, SDLButton.Start, 115f, 38f, 3.6f)
        sign(a, SDLButton.Start, 115f, 38f, 3.5f, true)
        part(a, SDLButton.Misc1, round(rect(85f, 47f, 7f, 7f), 1.9f))
        button(a, SDLButton.Guide, 111.5f, 50.5f, 4.2f)
        if (!a.small) {
            stroke(a.c, circle(88.5f, 50.5f, 1.8f), if (a.held(SDLButton.Misc1)) inkOn(a.state.accent) else a.tone.partLine, a.line(.6f, .5f), .8f)
            stroke(a.c, circle(111.5f, 50.5f, 2.3f), if (a.held(SDLButton.Guide)) inkOn(a.state.accent) else a.tone.partLine, a.line(.6f, .5f), .8f)
        }
    }

    private val GenericRight = floatArrayOf(118f, 37f, 132f, 35f, 146f, 36f, 166f, 37f, 180f, 50f, 180f, 68f, 180f, 87f, 168f, 100f, 153f, 100f,
        134f, 100f, 118f, 94f, 100f, 94f)

    // Any other controller: a smaller, plain friendly pad with round ends, a D-pad, four face buttons,
    // two small sticks and small shoulder buttons.
    private fun generic(a: KPArtCtx) {
        shoulders(a, rect(38f, 29f, 36f, 13f), rect(43f, 21f, 26f, 14f), -.06f, 7f, "LB", "RB", "LT", "RT")
        shell(a, mirrored(100f, 37f, GenericRight))
        dpad(a, 54f, 67f, 23f)
        face(a, 146f, 67f, 11f, 6.4f, "A", "B", "X", "Y")
        stick(a, SDLButton.LeftStick, SDLAxis.LeftX, 85f, 83f, 8.5f)
        stick(a, SDLButton.RightStick, SDLAxis.RightX, 115f, 83f, 8.5f)
        pill(a, SDLButton.Back, rect(85f, 53f, 9f, 4f))
        pill(a, SDLButton.Start, rect(106f, 53f, 9f, 4f))
        button(a, SDLButton.Guide, 100f, 66f, 4f)
    }

    // A GameCube kidney button: a short thick arc around A.
    private fun kidney(a: KPArtCtx, button: Int, x: Float, y: Float, radius: Float, from: Float, to: Float, width: Float, label: String) {
        val arc = KPPen().arc(x, y, radius, from, to).path
        val mid = (from + to) / 2
        part(a, button, outline(arc, width), label, width * .78f, x + radius * cos(mid), y + radius * sin(mid))
    }

    private val GameCubeRight = floatArrayOf(114f, 37f, 126f, 25f, 141f, 24f, 164f, 22f, 184f, 30f, 187f, 47f, 190f, 62f, 193f, 78f, 190f, 90f,
        187f, 104f, 178f, 117f, 165f, 116f, 153f, 115f, 148f, 108f, 147f, 100f, 144f, 93f, 122f, 89f, 100f, 89f)

    // GameCube: round handles, the stick in an octagon high on the left, a small D-pad below, a big A
    // with B low to its left and X and Y curving round it, the C-stick, big L and R triggers and Z.
    private fun gameCube(a: KPArtCtx) {
        shoulders(a, rect(40f, 15f, 30f, 13f), rect(24f, 3f, 50f, 27f), -.2f, 7f, "ZL", "Z", "L", "R", false)
        shell(a, mirrored(100f, 37f, GameCubeRight))
        stick(a, SDLButton.LeftStick, SDLAxis.LeftX, 49f, 52f, 15f, true)
        dpad(a, 72f, 80f, 17f)
        stick(a, SDLButton.RightStick, SDLAxis.RightX, 131f, 80.5f, 9.2f, true, .6f)
        button(a, SDLButton.Start, 100f, 56f, 3.8f)
        kidney(a, SDLButton.East, 152f, 51f, 20f, -.95f, .35f, 8.4f, "X")
        kidney(a, SDLButton.North, 152f, 51f, 20f, -2.7f, -1.75f, 8.4f, "Y")
        button(a, SDLButton.West, 133.5f, 62f, 6.2f, "B")
        button(a, SDLButton.South, 152f, 51f, 11.5f, "A")
    }

    // The Joy-Con shoulders: bands hugging each half's outer top corner (centre `corner`, radius 21),
    // the trigger (ZL, ZR) behind the button (L, R).
    private fun joyConShoulders(a: KPArtCtx) {
        val c = a.c
        val cornerX = 67f
        val cornerY = 36.5f
        val bumper = 24.6f
        val trigger = 31f
        val shown = 28.2f
        for (side in 0 until 2) {
            val right = side == 1
            val flip = Matrix()
            if (right) flip.setValues(floatArrayOf(-1f, 0f, 200f, 0f, 1f, 0f, 0f, 0f, 1f))
            fun flipX(x: Float) = if (right) 200 - x else x
            fun band(radius: Float, from: Float, width: Float): Path {
                val spine = KPPen().arc(cornerX, cornerY, radius, from, 1.5f * Pi).lineTo(80f, cornerY - radius).path
                spine.transform(flip)
                return outline(spine, width)
            }
            // The trigger fills outward from the shell as it's pulled.
            val back = band(trigger, 1.13f * Pi, 6.8f)
            val pull = a.pull(if (right) SDLAxis.RightTrigger else SDLAxis.LeftTrigger)
            val reach = shown + (trigger + 3.4f - shown) * pull
            val level = Path().apply {
                addRoundRect(rect(cornerX - reach, cornerY - reach, 2 * reach + 40, 2 * reach), reach - .01f, reach - .01f, Path.Direction.CW)
                transform(flip)
            }
            drop(a, back, 1.2f, .8f, false)
            c.save()
            c.clipPath(back)
            wash(c, boundsOf(back), a.tone.backTop, a.tone.backBottom)
            if (pull > .01f) gradient(c, level, mix(a.state.accent, 0xffffff, .15f), mix(a.state.accent, 0x000000, .1f))
            if (!a.small) rim(c, back, a.line(1f, .8f), 0xffffff, if (a.dark) .3f else .9f)
            c.restore()
            stroke(c, back, a.tone.partLine, a.line(.8f, .75f))
            val name = if (right) "ZR" else "ZL"
            if (a.big) {
                val x = flipX(76f)
                val y = cornerY - (shown + trigger + 3.4f) / 2
                artLabel(a, name, x, y, 4.6f, a.tone.letter)
                if (pull > .01f) {
                    c.save()
                    c.clipPath(level)
                    artLabel(a, name, x, y, 4.6f, inkOn(a.state.accent))
                    c.restore()
                }
            }
            val front = band(bumper, 1.1f * Pi, 7.2f)
            val at = (21 + bumper + 3.6f) / 2
            part(a, if (right) SDLButton.RightShoulder else SDLButton.LeftShoulder, front, if (!a.big) null else if (right) "R" else "L",
                5.4f, flipX(cornerX + at * cos(1.27f * Pi)), cornerY + at * sin(1.27f * Pi))
        }
    }

    // Joy-Con pair: two halves, each flat along its rail and rounded outside; the left with its stick
    // above four direction buttons, the right with its face buttons above the stick.
    private fun joyCon(a: KPArtCtx) {
        val c = a.c
        joyConShoulders(a)
        for (side in 0 until 2) {
            val inner = if (side == 1) 106f else 94f
            val outer = if (side == 1) 154f else 46f
            val half = polygon(floatArrayOf(inner, 15.5f, outer, 15.5f, outer, 117f, inner, 117f), floatArrayOf(2.5f, 21f, 21f, 2.5f))
            shell(a, half)
            // The rail, a darker strip down the inside edge.
            c.save()
            c.clipPath(half)
            val rail = Path().apply { addRect(rect(if (side == 1) inner else inner - 3.2f, 15.5f, 3.2f, 101.5f), Path.Direction.CW) }
            gradient(c, rail, if (a.dark) 0x2b3136 else 0xd3dade, if (a.dark) 0x23282c else 0xc2cbd0)
            c.restore()
            stroke(c, half, a.tone.outline, a.line(1.2f, 1f), if (a.dark) .85f else 1f)
        }
        stick(a, SDLButton.LeftStick, SDLAxis.LeftX, 69f, 42f, 12.5f)
        for (arm in 0 until 4) {
            val x = 69 + 10.5f * (if (arm == 1) 1 else if (arm == 3) -1 else 0)
            val y = 81 + 10.5f * (if (arm == 2) 1 else if (arm == 0) -1 else 0)
            button(a, DpadButtons[arm], x, y, 5.4f)
            if (!a.small) arrowhead(c, x, y, 3.2f, arm, if (a.held(DpadButtons[arm])) inkOn(a.state.accent) else a.tone.letter, .55f)
        }
        face(a, 131f, 42f, 10.5f, 5.6f, "B", "A", "Y", "X")
        stick(a, SDLButton.RightStick, SDLAxis.RightX, 131f, 81f, 12.5f)
        button(a, SDLButton.Back, 85f, 23.5f, 3.3f)
        sign(a, SDLButton.Back, 85f, 23.5f, 3.4f, false)
        button(a, SDLButton.Start, 115f, 23.5f, 3.3f)
        sign(a, SDLButton.Start, 115f, 23.5f, 3.4f, true)
        part(a, SDLButton.Misc1, round(rect(80f, 99f, 7f, 7f), 1.8f))
        button(a, SDLButton.Guide, 117f, 102.5f, 4.2f)
    }

    // The Wii Remote's four player lights; the player's own lit in their colour, or all four softly
    // while it isn't playing.
    private fun lights(a: KPArtCtx, firstX: Float, firstY: Float, stepX: Float, stepY: Float, w: Float, h: Float) {
        val player = playerOf(a.state.accent)
        for (i in 0 until 4) {
            val led = round(rect(firstX + stepX * i - w / 2, firstY + stepY * i - h / 2, w, h), min(w, h) / 2)
            val lit = player < 0 || player == i
            val ink = if (player < 0) 0x5ccbf3 else a.state.accent
            if (lit) stroke(a.c, led, ink, a.line(2.2f, 1f), .3f)
            fill(a.c, led, if (lit) ink else if (a.dark) 0x2a3035 else 0xcfd7db)
            stroke(a.c, led, if (lit) mix(ink, 0x000000, .3f) else a.tone.partLine, a.line(.5f, .4f), .7f)
        }
    }

    // Speaker holes: a little ring of dots.
    private fun speaker(a: KPArtCtx, x: Float, y: Float, r: Float) {
        if (a.small) return
        fillPaint.color = KP.argb(if (a.dark) 0x1d2124 else 0x9aa6ad, .8f)
        a.c.drawOval(RectF(x - .75f, y - .75f, x + .75f, y + .75f), fillPaint)
        for (i in 0 until 6) {
            val dx = x + r * cos(i * Pi / 3)
            val dy = y + r * sin(i * Pi / 3)
            a.c.drawOval(RectF(dx - .7f, dy - .7f, dx + .7f, dy + .7f), fillPaint)
        }
    }

    // The dark window over the pointer's sensor at one end.
    private fun window(a: KPArtCtx, body: Path, r: RectF) {
        a.c.save()
        a.c.clipPath(body)
        val window = Path().apply { addRect(r, Path.Direction.CW) }
        gradient(a.c, window, if (a.dark) 0x2a3035 else 0x6b767d, if (a.dark) 0x15181b else 0x3d464c)
        gradient(a.c, window, 0xffffff, 0xffffff, if (a.dark) .14f else .35f, 0f, 0f, .55f)
        a.c.restore()
    }

    // Wii Remote held sideways, as for racing: the pointer end on the left, the D-pad under the left
    // thumb, A, − HOME + in a column, 1 and 2 on the right, the player lights at the far end, B peeking
    // out underneath and the wrist strap. SDL names the D-pad as for the remote held upright (pointer
    // end up) and doesn't turn it for sideways play, so the cross is turned a quarter: the arm under the
    // player's thumb that SDL calls left points down here, up points left, and so on.
    private fun wiiRemote(a: KPArtCtx) {
        val c = a.c
        val face = rect(4f, 25f, 192f, 56f)
        val y = face.centerY()
        if (!a.small) {
            val strap = Path().apply {
                moveTo(186f, 84f)
                cubicTo(182f, 99f, 173f, 114f, 182f, 118f)
                cubicTo(191f, 122f, 197f, 104f, 192f, 84f)
            }
            stroke(c, strap, a.tone.outline, a.line(2.6f, 1.6f), if (a.dark) .9f else .8f)
            stroke(c, strap, if (a.dark) 0x6a747b else 0xdfe5e8, a.line(1.4f, .8f))
            part(a, -1, round(rect(181.2f, 98f, 7f, 6f), 2f))
        }
        part(a, SDLButton.South, round(rect(66f, 78f, 28f, 23f), 8f), if (a.big) "B" else null, 5.6f, 80f, 95.6f)
        // The remote's side, under its face, gives it depth.
        val side = round(RectF(face).apply { offset(0f, 7f) }, 19f)
        val top = round(face, 19f)
        drop(a, side, 2f)
        gradient(c, side, if (a.dark) 0x3d454b else 0xdde3e6, if (a.dark) 0x2a3035 else 0xc4cdd2)
        stroke(c, side, a.tone.outline, a.line(1.2f, 1f), if (a.dark) .85f else 1f)
        shell(a, top, false)
        window(a, top, rect(face.left, face.top, 9f, face.height()))
        stroke(c, top, a.tone.outline, a.line(1.2f, 1f), if (a.dark) .85f else 1f)
        button(a, -1, 24f, y + 16, 3f)
        dpad(a, 45f, y, 33f, 3)
        button(a, SDLButton.East, 83f, y, 11f, "A")
        button(a, SDLButton.Start, 110f, y - 14.5f, 4f)
        sign(a, SDLButton.Start, 110f, y - 14.5f, 3.8f, true)
        button(a, SDLButton.Guide, 110f, y, 4.8f)
        button(a, SDLButton.Back, 110f, y + 14.5f, 4f)
        sign(a, SDLButton.Back, 110f, y + 14.5f, 3.8f, false)
        speaker(a, 127f, y, 3.4f)
        button(a, SDLButton.West, 147f, y, 8.2f, "1")
        button(a, SDLButton.North, 168.5f, y, 8.2f, "2")
        lights(a, 185.5f, y + 12.6f, 0f, -8.4f, 3.2f, 4.6f)
    }

    private val Egg = floatArrayOf(88f, 21.5f, 98f, 35f, 97f, 50f, 96f, 65f, 86f, 78f, 82f, 94f, 79f, 105f, 76f, 110f, 70f, 110f)

    // Wii Remote upright with a Nunchuk on its cord: the Nunchuk's egg shape with its stick, C and Z
    // peeking over the top; the remote beside it as it's held for pointing, its D-pad as SDL names it.
    private fun nunchukPair(a: KPArtCtx) {
        val c = a.c
        val x = 138f
        val cord = Path().apply {
            moveTo(70f, 108f)
            cubicTo(70f, 124f, x - 4, 124f, x, 113f)
        }
        stroke(c, cord, a.tone.outline, a.line(2.8f, 1.6f), if (a.dark) .9f else .8f)
        stroke(c, cord, if (a.dark) 0x6a747b else 0xe3e8eb, a.line(1.5f, .8f))
        // Nunchuk.
        triggerPart(a, SDLAxis.LeftTrigger, rect(48f, 12.5f, 44f, 18f), 8f, 9f, "Z", 13f)
        button(a, SDLButton.LeftShoulder, 70f, 12f, 5.2f, "C")
        shell(a, mirrored(70f, 21.5f, Egg, 70f))
        stick(a, SDLButton.LeftStick, SDLAxis.LeftX, 70f, 49.5f, 14.5f)
        // Remote, with B on its back peeking out the side.
        part(a, SDLButton.South, round(rect(150f, 46f, 11f, 17f), 4.5f))
        val face = rect(x - 17, 5f, 34f, 109f)
        val remote = round(face, 13f)
        shell(a, remote)
        window(a, remote, rect(face.left, face.top, face.width(), 8f))
        stroke(c, remote, a.tone.outline, a.line(1.2f, 1f), if (a.dark) .85f else 1f)
        button(a, -1, x - 9, 17.5f, 2.4f)
        dpad(a, x, 31f, 22f)
        button(a, SDLButton.East, x, 53.5f, 8.4f, "A")
        button(a, SDLButton.Back, x - 9.5f, 72f, 3f)
        sign(a, SDLButton.Back, x - 9.5f, 72f, 3f, false)
        button(a, SDLButton.Guide, x, 72f, 3.6f)
        button(a, SDLButton.Start, x + 9.5f, 72f, 3f)
        sign(a, SDLButton.Start, x + 9.5f, 72f, 3f, true)
        speaker(a, x, 81f, 2.6f)
        button(a, SDLButton.West, x, 91f, 5.4f, "1")
        button(a, SDLButton.North, x, 102.5f, 5.4f, "2")
        lights(a, x - 7.5f, 109.5f, 5f, 0f, 3f, 1.8f)
    }

    private class KPArtKey(val code: Int, val x: Float, val y: Float, val w: Float, val label: String, val game: Boolean)

    // The keys, at a 16-unit pitch, 14 square; the Mac's SDL scancodes as Android keycodes.
    private val Keys: Array<KPArtKey> by lazy {
        val p = 16f
        val k = 14f
        fun col(n: Int, indent: Float) = 10 + indent + n * p
        arrayOf(
            KPArtKey(KeyEvent.KEYCODE_Q, col(0, 0f), 28f, k, "Q", true), KPArtKey(KeyEvent.KEYCODE_W, col(1, 0f), 28f, k, "W", true),
            KPArtKey(KeyEvent.KEYCODE_E, col(2, 0f), 28f, k, "E", true), KPArtKey(KeyEvent.KEYCODE_R, col(3, 0f), 28f, k, "R", false),
            KPArtKey(KeyEvent.KEYCODE_T, col(4, 0f), 28f, k, "T", false), KPArtKey(KeyEvent.KEYCODE_Y, col(5, 0f), 28f, k, "Y", false),
            KPArtKey(KeyEvent.KEYCODE_U, col(6, 0f), 28f, k, "U", true), KPArtKey(KeyEvent.KEYCODE_I, col(7, 0f), 28f, k, "I", true),
            KPArtKey(KeyEvent.KEYCODE_O, col(8, 0f), 28f, k, "O", false), KPArtKey(KeyEvent.KEYCODE_P, col(9, 0f), 28f, k, "P", false),
            KPArtKey(KeyEvent.KEYCODE_DEL, col(10, 0f), 28f, 20f, "⌫", true),
            KPArtKey(KeyEvent.KEYCODE_A, col(0, 4f), 44f, k, "A", true), KPArtKey(KeyEvent.KEYCODE_S, col(1, 4f), 44f, k, "S", true),
            KPArtKey(KeyEvent.KEYCODE_D, col(2, 4f), 44f, k, "D", true), KPArtKey(KeyEvent.KEYCODE_F, col(3, 4f), 44f, k, "F", false),
            KPArtKey(KeyEvent.KEYCODE_G, col(4, 4f), 44f, k, "G", false), KPArtKey(KeyEvent.KEYCODE_H, col(5, 4f), 44f, k, "H", false),
            KPArtKey(KeyEvent.KEYCODE_J, col(6, 4f), 44f, k, "J", true), KPArtKey(KeyEvent.KEYCODE_K, col(7, 4f), 44f, k, "K", true),
            KPArtKey(KeyEvent.KEYCODE_L, col(8, 4f), 44f, k, "L", true), KPArtKey(KeyEvent.KEYCODE_ENTER, col(9, 4f), 44f, 26f, "⏎", true),
            KPArtKey(KeyEvent.KEYCODE_SHIFT_LEFT, col(0, 0f), 60f, 22f, "⇧", true), KPArtKey(KeyEvent.KEYCODE_Z, col(0, 24f), 60f, k, "Z", false),
            KPArtKey(KeyEvent.KEYCODE_X, col(1, 24f), 60f, k, "X", false), KPArtKey(KeyEvent.KEYCODE_C, col(2, 24f), 60f, k, "C", false),
            KPArtKey(KeyEvent.KEYCODE_V, col(3, 24f), 60f, k, "V", false), KPArtKey(KeyEvent.KEYCODE_B, col(4, 24f), 60f, k, "B", false),
            KPArtKey(KeyEvent.KEYCODE_N, col(5, 24f), 60f, k, "N", false), KPArtKey(KeyEvent.KEYCODE_M, col(6, 24f), 60f, k, "M", true),
            KPArtKey(KeyEvent.KEYCODE_DPAD_UP, col(9, 4f), 60f, k, "↑", true),
            KPArtKey(KeyEvent.KEYCODE_CTRL_LEFT, col(0, 0f), 76f, k, "⌃", true), KPArtKey(KeyEvent.KEYCODE_ALT_LEFT, col(1, 0f), 76f, k, "⌥", true),
            KPArtKey(KeyEvent.KEYCODE_META_LEFT, col(2, 0f), 76f, k, "⌘", false), KPArtKey(KeyEvent.KEYCODE_SPACE, col(3, 0f), 76f, 5 * p - 2, "", true),
            KPArtKey(KeyEvent.KEYCODE_DPAD_LEFT, col(8, 4f), 76f, k, "←", true), KPArtKey(KeyEvent.KEYCODE_DPAD_DOWN, col(9, 4f), 76f, k, "↓", true),
            KPArtKey(KeyEvent.KEYCODE_DPAD_RIGHT, col(10, 4f), 76f, k, "→", true),
        )
    }

    // A small keyboard with the keys the game uses lit as they're pressed; the rest stay quiet.
    private fun keyboard(a: KPArtCtx) {
        val c = a.c
        shell(a, round(rect(4f, 20f, 192f, 86f), 11f))
        val k = 14f
        for (key in Keys) {
            val r = rect(key.x, key.y, key.w, k)
            val held = keyDown(key.code)
            val cap = round(r, 3f)
            if (!held) {
                c.save()
                c.translate(0f, a.line(.9f, .6f))
                fill(c, cap, 0x000000, if (a.dark) .45f else .14f)
                c.restore()
            }
            val top = if (held) mix(a.state.accent, 0xffffff, .2f) else if (key.game) a.tone.partTop else if (a.dark) 0x4a535a else 0xf1f4f5
            val bottom = if (held) mix(a.state.accent, 0x000000, .08f) else if (key.game) a.tone.partBottom else if (a.dark) 0x3c444a else 0xe4e9ec
            surface(c, cap, top, bottom, a.line(1f, .8f), if (a.small) 0f else if (held) .45f else if (a.dark) .25f else .9f)
            stroke(c, cap, if (held) mix(a.state.accent, 0x000000, .35f) else if (key.game) a.tone.partLine else mix(a.tone.partLine, a.tone.bodyBottom, .45f),
                a.line(.8f, .6f))
            if (key.label.isNotEmpty() && a.words(7.5f))
                artLabel(a, key.label, r.centerX(), r.centerY(), 7.5f,
                    if (held) inkOn(a.state.accent) else if (key.game) a.tone.letter else mix(a.tone.letter, a.tone.partBottom, .6f))
        }
    }

    // The touch screen's drawing, a phone in landscape playing through its controller page (the Mac's
    // KPDrawPhoneArt): a handset with the stick and buttons on it.
    private fun phone(c: Canvas, r: RectF, accent: Int) {
        val w = min(r.width(), r.height() * 2.1f)
        val h = w / 2.1f
        val body = rect(r.centerX() - w / 2, r.centerY() - h / 2, w, h)
        KP.fill(c, body, 0x1d2027, h * .18f)
        val screen = RectF(body).apply { inset(h * .07f, h * .07f) }
        KP.fill(c, screen, 0x2a2f39, h * .12f)
        val u = screen.height()
        fun dot(x: Float, y: Float, d: Float, hex: Int, alpha: Float) {
            fillPaint.color = KP.argb(hex, alpha)
            c.drawOval(RectF(x, y, x + d, y + d), fillPaint)
        }
        dot(screen.left + u * .22f, screen.top + u * .28f, u * .5f, 0xffffff, .18f)
        dot(screen.left + u * .37f, screen.top + u * .43f, u * .2f, accent, 1f)
        dot(screen.right - u * .55f, screen.top + u * .42f, u * .42f, accent, 1f)
        dot(screen.right - u * .95f, screen.top + u * .5f, u * .3f, 0xffffff, .35f)
        dot(screen.right - u * .45f, screen.top + u * .1f, u * .24f, 0xffffff, .35f)
    }

    fun draw(c: Canvas, r: RectF, family: KPPadFamily, state: KPArtState, systemName: String? = null) {
        val s = min(r.width() / 200, r.height() / 124)
        if (!(s > 0)) return
        // The touch screen: the handset with the controller page on it.
        if (family == KPPadFamily.Touch) {
            phone(c, RectF(r.left + r.width() * .03f, r.top + r.height() * .14f, r.right - r.width() * .03f, r.bottom - r.height() * .14f),
                state.accent)
            return
        }
        val dark = KP.dark
        c.save()
        c.translate(r.left + (r.width() - 200 * s) / 2, r.top + (r.height() - 124 * s) / 2)
        c.scale(s, s)
        val a = KPArtCtx(c, state, s, dark, s < .6f, s >= 1.6f, if (dark) DarkTones else LightTones)
        when (layoutFor(family)) {
            KPArtLayout.Keyboard -> keyboard(a)
            KPArtLayout.WiiRemote -> if (systemName?.contains("Nunchuk") == true) nunchukPair(a) else wiiRemote(a)
            KPArtLayout.JoyCon -> joyCon(a)
            KPArtLayout.GameCube -> gameCube(a)
            KPArtLayout.Symmetric -> playStation(a)
            KPArtLayout.Nintendo -> pro(a)
            KPArtLayout.Offset -> if (family == KPPadFamily.Generic) generic(a) else xbox(a)
        }
        c.restore()
    }

    fun stateFor(device: KPPadDevice?, accent: Int): KPArtState {
        val state = KPArtState(accent = accent)
        if (device == null) return state
        if (!device.isKeyboard) {
            state.buttons = device.buttons
            for (axis in 0 until min(SDLAxis.Count, device.axes.size)) state.axes[axis] = device.axes[axis]
        }
        return state
    }

    /** The small icon for a kind of controller, where there's no room for its drawing (toasts, HOME). */
    fun familyGlyph(family: KPPadFamily): KPUIGlyph = when (family) {
        KPPadFamily.Keyboard -> KPUIGlyph.Keyboard
        KPPadFamily.WiiRemote -> KPUIGlyph.WiiRemote
        KPPadFamily.Touch -> KPUIGlyph.Phone
        else -> KPUIGlyph.Pad
    }
}
