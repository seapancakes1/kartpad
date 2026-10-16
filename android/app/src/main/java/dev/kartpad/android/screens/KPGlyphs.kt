package dev.kartpad.android.screens

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.tan

// Icons for KartPad's screens, drawn in code on a 40-unit grid in one ink, in the Mii editor's
// rounded line style (after the Mac's apple/macos/KartPadUIGlyphs.inc.mm). They're generic shapes
// (a house, a gamepad, a gear), never a console maker's logo.

// New glyphs go at the end: some code stores them as ints (the Mac's order, so an index is the same there).
enum class KPUIGlyph {
    Home, Play, Swap, Mii, Pad, Gear, Power, Speaker, SpeakerOff, Window, FullScreen, Plus, Keyboard,
    Restart, Find, Move, Close, Chevron, Back, WiiRemote, Bluetooth, Check, Buttons, Battery, Disc, Order, Search, Ghost, Export,
    Phone, Download, Folder, Picture, Game, Advanced
}

/**
 * A path that knows its current point, for CoreGraphics' arcs: by angle (CGPathAddArc with
 * clockwise false, radians, increasing angles turning clockwise with y down) and tangent to two
 * lines (CGPathAddArcToPoint, which Android's Path lacks).
 */
internal class KPPen(val path: Path = Path()) {
    var x = 0f
        private set
    var y = 0f
        private set
    private var startX = 0f
    private var startY = 0f
    private val oval = RectF()

    fun reset(): KPPen {
        path.reset()
        x = 0f; y = 0f; startX = 0f; startY = 0f
        return this
    }

    fun moveTo(x: Float, y: Float): KPPen {
        path.moveTo(x, y)
        this.x = x; this.y = y; startX = x; startY = y
        return this
    }

    fun lineTo(x: Float, y: Float): KPPen {
        path.lineTo(x, y)
        this.x = x; this.y = y
        return this
    }

    fun curveTo(c1x: Float, c1y: Float, c2x: Float, c2y: Float, x: Float, y: Float): KPPen {
        path.cubicTo(c1x, c1y, c2x, c2y, x, y)
        this.x = x; this.y = y
        return this
    }

    fun close(): KPPen {
        path.close()
        x = startX; y = startY
        return this
    }

    /** From start to end by increasing angle, joined to the current point by a line (or starting the path). */
    fun arc(cx: Float, cy: Float, radius: Float, start: Float, end: Float): KPPen {
        val turn = (2 * PI).toFloat()
        var sweep = end - start
        while (sweep < 0) sweep += turn
        if (sweep > turn) sweep = turn
        if (path.isEmpty) {
            startX = cx + radius * cos(start)
            startY = cy + radius * sin(start)
        }
        oval.set(cx - radius, cy - radius, cx + radius, cy + radius)
        path.arcTo(oval, Math.toDegrees(start.toDouble()).toFloat(), Math.toDegrees(sweep.toDouble()).toFloat(), false)
        x = cx + radius * cos(start + sweep)
        y = cy + radius * sin(start + sweep)
        return this
    }

    /** A line towards (x1, y1) that turns along a circle of the radius into the line on to (x2, y2). */
    fun arcTo(x1: Float, y1: Float, x2: Float, y2: Float, radius: Float): KPPen {
        val ax = x - x1; val ay = y - y1
        val bx = x2 - x1; val by = y2 - y1
        val la = hypot(ax, ay); val lb = hypot(bx, by)
        if (radius <= 0 || la < 1e-5f || lb < 1e-5f || abs(ax * by - ay * bx) < 1e-6f * la * lb) return lineTo(x1, y1)
        val ux = ax / la; val uy = ay / la
        val vx = bx / lb; val vy = by / lb
        val half = acos((ux * vx + uy * vy).coerceIn(-1f, 1f)) / 2
        val reach = radius / tan(half)
        val t1x = x1 + ux * reach; val t1y = y1 + uy * reach
        val t2x = x1 + vx * reach; val t2y = y1 + vy * reach
        val mx = ux + vx; val my = uy + vy
        val lm = hypot(mx, my)
        val centre = radius / sin(half)
        val cx = x1 + mx / lm * centre; val cy = y1 + my / lm * centre
        val start = atan2(t1y - cy, t1x - cx)
        var sweep = atan2(t2y - cy, t2x - cx) - start
        if (sweep > PI) sweep -= (2 * PI).toFloat()
        if (sweep < -PI) sweep += (2 * PI).toFloat()
        path.lineTo(t1x, t1y)
        oval.set(cx - radius, cy - radius, cx + radius, cy + radius)
        path.arcTo(oval, Math.toDegrees(start.toDouble()).toFloat(), Math.toDegrees(sweep.toDouble()).toFloat(), false)
        x = t2x; y = t2y
        return this
    }
}

object KPGlyphs {
    private val solid = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val outline = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val pen = KPPen()
    private val path get() = pen.path
    private val box = RectF()
    private val all = KPUIGlyph.entries

    private fun width(w: Float) { outline.strokeWidth = w }
    private fun glyphPath(c: Canvas, p: Path, fill: Boolean) = c.drawPath(p, if (fill) solid else outline)
    private fun rounded(c: Canvas, x: Float, y: Float, w: Float, h: Float, radius: Float, fill: Boolean) {
        box.set(x, y, x + w, y + h)
        c.drawRoundRect(box, radius, radius, if (fill) solid else outline)
    }
    private fun ring(c: Canvas, x: Float, y: Float, radius: Float) = c.drawCircle(x, y, radius, outline)
    private fun dot(c: Canvas, x: Float, y: Float, w: Float, h: Float) {
        box.set(x, y, x + w, y + h)
        c.drawOval(box, solid)
    }
    private fun line(c: Canvas, x: Float, y: Float, x2: Float, y2: Float) = c.drawLine(x, y, x2, y2, outline)
    // CGContextAddArc (increasing angle) and a stroke.
    private fun arc(c: Canvas, cx: Float, cy: Float, radius: Float, start: Float, end: Float) {
        pen.reset().arc(cx, cy, radius, start, end)
        c.drawPath(path, outline)
    }
    // An open arrowhead, drawn like the chevrons, with its tip at the point.
    private fun head(c: Canvas, tipX: Float, tipY: Float, angle: Float, arm: Float) {
        val quarter = (PI / 4).toFloat()
        pen.reset()
            .moveTo(tipX - arm * cos(angle - quarter), tipY - arm * sin(angle - quarter))
            .lineTo(tipX, tipY)
            .lineTo(tipX - arm * cos(angle + quarter), tipY - arm * sin(angle + quarter))
        c.drawPath(path, outline)
    }
    private fun arrow(c: Canvas, fromX: Float, fromY: Float, toX: Float, toY: Float, arm: Float) {
        line(c, fromX, fromY, toX, toY)
        head(c, toX, toY, atan2(toY - fromY, toX - fromX), arm)
    }
    private fun fillStroke(c: Canvas, p: Path) {
        c.drawPath(p, solid)
        c.drawPath(p, outline)
    }

    fun draw(c: Canvas, index: Int, rect: RectF, hex: Int) {
        draw(c, all.getOrNull(index) ?: return, rect, hex)
    }

    /** level is 0…1 for Speaker and Battery. */
    fun draw(c: Canvas, glyph: KPUIGlyph, rect: RectF, hex: Int, level: Float = 1f) {
        val pi = PI.toFloat()
        c.save()
        c.translate(rect.left, rect.top)
        c.scale(rect.width() / 40, rect.height() / 40)
        solid.color = KP.argb(hex)
        outline.color = KP.argb(hex)
        width(3.4f)
        when (glyph) {
            KPUIGlyph.Home -> {
                // A house with a door: the HOME button's mark.
                pen.reset().moveTo(4f, 20f).lineTo(20f, 5f).lineTo(36f, 20f)
                glyphPath(c, path, false)
                pen.reset().moveTo(9f, 17f).lineTo(9f, 35f).lineTo(17f, 35f).lineTo(17f, 25f).lineTo(23f, 25f)
                    .lineTo(23f, 35f).lineTo(31f, 35f).lineTo(31f, 17f)
                glyphPath(c, path, false)
            }
            KPUIGlyph.Play -> {
                pen.reset().moveTo(13f, 7f).lineTo(33f, 20f).lineTo(13f, 33f).close()
                width(4f)
                fillStroke(c, path)
            }
            KPUIGlyph.Swap -> {
                // Two arrows passing each other: change one thing for another.
                width(4f)
                arrow(c, 6f, 12.5f, 32f, 12.5f, 7.5f)
                arrow(c, 34f, 27.5f, 8f, 27.5f, 7.5f)
            }
            KPUIGlyph.Mii -> {
                // A round head on shoulders.
                dot(c, 12f, 3f, 16f, 17f)
                pen.reset().moveTo(6f, 36f).curveTo(6f, 26.8f, 12.6f, 23f, 20f, 23f).curveTo(27.4f, 23f, 34f, 26.8f, 34f, 36f).close()
                width(2f)
                fillStroke(c, path)
            }
            KPUIGlyph.Pad -> {
                // A two-grip gamepad with a D-pad and two face buttons.
                pen.reset().moveTo(11f, 11f).lineTo(29f, 11f)
                    .curveTo(35f, 11f, 37f, 16f, 38f, 22f)
                    .curveTo(39.5f, 30f, 37f, 33f, 34f, 33f)
                    .curveTo(31f, 33f, 29f, 29f, 26f, 26f)
                    .lineTo(14f, 26f)
                    .curveTo(11f, 29f, 9f, 33f, 6f, 33f)
                    .curveTo(3f, 33f, .5f, 30f, 2f, 22f)
                    .curveTo(3f, 16f, 5f, 11f, 11f, 11f)
                    .close()
                width(3f)
                glyphPath(c, path, false)
                width(2.6f)
                line(c, 8f, 18.5f, 14f, 18.5f)
                line(c, 11f, 15.5f, 11f, 21.5f)
                dot(c, 26.5f, 14f, 4f, 4f)
                dot(c, 30.5f, 18.5f, 4f, 4f)
            }
            KPUIGlyph.Gear -> {
                // Six chunky teeth round a hole: Settings.
                val step = pi / 3
                pen.reset()
                for (i in 0 until 6) {
                    val a = -pi / 2 + i * step
                    pen.arc(20f, 20f, 12f, a - step / 2, a - .29f)
                    pen.arc(20f, 20f, 17f, a - .19f, a + .19f)
                    pen.arc(20f, 20f, 12f, a + .29f, a + step / 2)
                }
                pen.close()
                glyphPath(c, path, false)
                ring(c, 20f, 20f, 4.6f)
            }
            KPUIGlyph.Power -> {
                arc(c, 20f, 21f, 13f, -pi / 2 + .75f, -pi / 2 - .75f + 2 * pi)
                line(c, 20f, 4f, 20f, 19f)
            }
            KPUIGlyph.Speaker, KPUIGlyph.SpeakerOff -> {
                pen.reset().moveTo(5f, 15.5f).lineTo(11.5f, 15.5f).lineTo(19.5f, 8.5f).lineTo(19.5f, 31.5f)
                    .lineTo(11.5f, 24.5f).lineTo(5f, 24.5f).close()
                width(2.4f)
                fillStroke(c, path)
                width(3.4f)
                if (glyph == KPUIGlyph.SpeakerOff) {
                    line(c, 25.5f, 15f, 35.5f, 25f)
                    line(c, 35.5f, 15f, 25.5f, 25f)
                } else {
                    if (level > .05f) arc(c, 20f, 20f, 7f, -.8f, .8f)
                    if (level > .5f) arc(c, 20f, 20f, 13f, -.85f, .85f)
                }
            }
            KPUIGlyph.Window -> {
                // A window with a solid title bar.
                width(3.2f)
                box.set(5f, 8f, 35f, 32f)
                pen.reset()
                path.addRoundRect(box, 5f, 5f, Path.Direction.CW)
                c.save()
                c.clipPath(path)
                c.drawRect(5f, 8f, 35f, 15f, solid)
                c.restore()
                glyphPath(c, path, false)
            }
            KPUIGlyph.FullScreen -> {
                // Four rounded corners pointing out.
                for (x in 0..1) for (y in 0..1) {
                    val cx = if (x == 1) 34f else 6f
                    val cy = if (y == 1) 33f else 7f
                    val sx = if (x == 1) -1f else 1f
                    val sy = if (y == 1) -1f else 1f
                    pen.reset().moveTo(cx, cy + sy * 9.5f).arcTo(cx, cy, cx + sx * 9.5f, cy, 4f).lineTo(cx + sx * 9.5f, cy)
                    c.drawPath(path, outline)
                }
            }
            KPUIGlyph.Plus -> {
                width(4.2f)
                line(c, 20f, 7f, 20f, 33f)
                line(c, 7f, 20f, 33f, 20f)
            }
            KPUIGlyph.Keyboard -> {
                // Two rows of round keys over a space bar.
                width(3.2f)
                rounded(c, 3.5f, 9f, 33f, 22f, 5f, false)
                for (row in 0 until 2) for (col in 0 until 4) dot(c, 9.2f + col * 6, 13.2f + row * 5.2f, 3.6f, 3.6f)
                width(3f)
                line(c, 14f, 25.8f, 26f, 25.8f)
            }
            KPUIGlyph.Restart -> {
                // A clockwise circle arrow, open at the top right.
                width(3.6f)
                arc(c, 20f, 21.3f, 12.5f, -pi / 5, pi * 1.5f)
                head(c, 20.8f, 8.8f, .06f, 7f)
            }
            KPUIGlyph.Find -> {
                // A remote with its light on, buzzing: "this one is me".
                width(3.2f)
                rounded(c, 14f, 7f, 12f, 26f, 5f, false)
                dot(c, 18.1f, 11.1f, 3.8f, 3.8f)
                width(3f)
                for (side in floatArrayOf(0f, pi)) {
                    arc(c, 20f, 20f, 12.8f, side - .48f, side + .48f)
                    arc(c, 20f, 20f, 18f, side - .42f, side + .42f)
                }
            }
            KPUIGlyph.Move -> {
                // Arrows out four ways.
                width(3.6f)
                line(c, 20f, 5.5f, 20f, 34.5f)
                line(c, 5.5f, 20f, 34.5f, 20f)
                for (i in 0 until 4) {
                    val a = i * pi / 2
                    head(c, 20 + 15 * cos(a), 20 + 15 * sin(a), a, 5.5f)
                }
            }
            KPUIGlyph.Close -> {
                width(4f)
                line(c, 10f, 10f, 30f, 30f)
                line(c, 30f, 10f, 10f, 30f)
            }
            KPUIGlyph.Chevron -> {
                width(4.2f)
                pen.reset().moveTo(15f, 8f).lineTo(27f, 20f).lineTo(15f, 32f)
                c.drawPath(path, outline)
            }
            KPUIGlyph.Back -> {
                width(4.2f)
                pen.reset().moveTo(25f, 8f).lineTo(13f, 20f).lineTo(25f, 32f)
                c.drawPath(path, outline)
            }
            KPUIGlyph.WiiRemote -> {
                // A remote held upright: D-pad, A, then 1 and 2.
                width(3.2f)
                rounded(c, 13.5f, 2.5f, 13f, 35f, 6f, false)
                width(2.6f)
                line(c, 17f, 10.5f, 23f, 10.5f)
                line(c, 20f, 7.5f, 20f, 13.5f)
                dot(c, 17.4f, 17.4f, 5.2f, 5.2f)
                dot(c, 18.4f, 26f, 3.2f, 3.2f)
                dot(c, 18.4f, 31f, 3.2f, 3.2f)
            }
            KPUIGlyph.Bluetooth -> {
                width(3.2f)
                pen.reset().moveTo(12f, 13f).lineTo(28f, 27f).lineTo(20f, 34f).lineTo(20f, 6f).lineTo(28f, 13f).lineTo(12f, 27f)
                c.drawPath(path, outline)
            }
            KPUIGlyph.Check -> {
                width(4.5f)
                pen.reset().moveTo(8f, 21f).lineTo(17f, 30f).lineTo(32f, 11f)
                c.drawPath(path, outline)
            }
            KPUIGlyph.Buttons -> {
                // Four face buttons in a diamond: "set up buttons".
                for ((x, y) in arrayOf(20f to 9f, 31f to 20f, 20f to 31f, 9f to 20f)) {
                    box.set(x - 5, y - 5, x + 5, y + 5)
                    c.drawOval(box, outline)
                }
                dot(c, 15f, 26f, 10f, 10f)
            }
            KPUIGlyph.Battery -> {
                width(3f)
                rounded(c, 3f, 11.5f, 31f, 17f, 5f, false)
                rounded(c, 35f, 16f, 3.2f, 8f, 1.6f, true)
                val fill = level.coerceIn(0f, 1f) * 24
                if (fill > 0) rounded(c, 6.5f, 15f, fill, 10f, min(2f, fill / 2), true)
            }
            KPUIGlyph.Disc -> {
                // A game disc in front of another: switch game. The back one stops short of the front one.
                arc(c, 24f, 16f, 11.5f, 4.025f, 6.971f)
                ring(c, 16f, 24f, 11.5f)
                width(3.2f)
                ring(c, 16f, 24f, 3.3f)
            }
            KPUIGlyph.Order -> {
                // A numbered list: players take their places in turn.
                width(3f)
                pen.reset().moveTo(4.5f, 8.1f).lineTo(8.5f, 4.5f).lineTo(8.5f, 15f)
                c.drawPath(path, outline)
                dot(c, 6f, 18.5f, 5f, 5f)
                dot(c, 6f, 29.5f, 5f, 5f)
                width(3.4f)
                line(c, 16f, 9.5f, 35f, 9.5f)
                line(c, 16f, 21f, 35f, 21f)
                line(c, 16f, 32f, 35f, 32f)
            }
            KPUIGlyph.Ghost -> {
                // A ghost with a wavy hem: Time Trial ghosts.
                pen.reset().moveTo(8f, 34f).lineTo(8f, 19f).arc(20f, 19f, 12f, pi, 0f).lineTo(32f, 34f).lineTo(28f, 30.5f)
                    .lineTo(24f, 34f).lineTo(20f, 30.5f).lineTo(16f, 34f).lineTo(12f, 30.5f).close()
                glyphPath(c, path, false)
                dot(c, 12.6f, 15.5f, 5f, 6f)
                dot(c, 22.4f, 15.5f, 5f, 6f)
            }
            KPUIGlyph.Export -> {
                // An arrow out of a tray: save a copy somewhere else.
                pen.reset().moveTo(8f, 22f).lineTo(8f, 34f).lineTo(32f, 34f).lineTo(32f, 22f)
                glyphPath(c, path, false)
                arrow(c, 20f, 27f, 20f, 5f, 7f)
            }
            KPUIGlyph.Search -> {
                // A magnifying glass: look for something.
                width(3.6f)
                ring(c, 17.5f, 17.5f, 10f)
                width(4.4f)
                line(c, 25.2f, 25.2f, 33f, 33f)
            }
            KPUIGlyph.Phone -> {
                // A phone held upright: wider than a remote, with a notch and a home bar.
                width(3.2f)
                rounded(c, 10.5f, 3.5f, 19f, 33f, 5f, false)
                rounded(c, 16.5f, 7f, 7f, 2.6f, 1.3f, true)
                width(2.8f)
                line(c, 16.5f, 31.5f, 23.5f, 31.5f)
            }
            KPUIGlyph.Download -> {
                // An arrow down into a tray: bring a copy here. Export's opposite.
                pen.reset().moveTo(8f, 22f).lineTo(8f, 34f).lineTo(32f, 34f).lineTo(32f, 22f)
                glyphPath(c, path, false)
                arrow(c, 20f, 5f, 20f, 27f, 7f)
            }
            KPUIGlyph.Folder -> {
                // A folder with a tab: choose a folder or a file.
                width(3.2f)
                pen.reset().moveTo(4f, 20f).arcTo(4f, 8f, 15f, 8f, 3f).lineTo(15f, 8f).lineTo(19f, 12f)
                    .arcTo(36f, 12f, 36f, 33f, 3f).arcTo(36f, 33f, 4f, 33f, 3f).arcTo(4f, 33f, 4f, 8f, 3f).close()
                glyphPath(c, path, false)
                line(c, 4f, 18f, 36f, 18f)
            }
            KPUIGlyph.Picture -> {
                // A landscape photo: hills and a sun in a frame.
                width(3.2f)
                val frame = Path().apply { addRoundRect(RectF(4f, 7f, 36f, 33f), 5f, 5f, Path.Direction.CW) }
                c.save()
                c.clipPath(frame)
                pen.reset().moveTo(4f, 33f).lineTo(4f, 30f).lineTo(15f, 19f).lineTo(22.5f, 26.5f).lineTo(27f, 22f)
                    .lineTo(36f, 31f).lineTo(36f, 33f).close()
                glyphPath(c, path, true)
                c.restore()
                glyphPath(c, frame, false)
                dot(c, 24f, 11.5f, 6f, 6f)
            }
            KPUIGlyph.Game -> {
                // A steering wheel: the game's own settings.
                ring(c, 20f, 20f, 15f)
                line(c, 5.5f, 19f, 34.5f, 19f)
                line(c, 20f, 21f, 20f, 34.5f)
                dot(c, 14.5f, 14f, 11f, 11f)
            }
            KPUIGlyph.Advanced -> {
                // Three sliders set at different points: fine-tuning.
                width(3f)
                for ((x, y) in arrayOf(12f to 9f, 27f to 20f, 17f to 31f)) {
                    line(c, 4.5f, y, x - 5.5f, y)
                    line(c, x + 5.5f, y, 35.5f, y)
                    ring(c, x, y, 3.8f)
                }
            }
        }
        c.restore()
    }
}
