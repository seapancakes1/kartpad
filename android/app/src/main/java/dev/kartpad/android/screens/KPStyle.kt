package dev.kartpad.android.screens

import android.content.Context
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.text.TextUtils
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

// KartPad's Wii-style drawing kit on Android, after the Mac's apple/shared/KartPadStyle.h: the Mii
// Channel palette, silver button faces on a ledge, pinstripes, cards, switches and rounded type. The
// screens draw in design points (a 1280×720 canvas) on a Canvas already scaled to the view, y down as
// on the Mac. Colours are 0xRRGGBB; alpha is separate, as there. Main thread only.

data class KPPalette(
    val background: Int, val stripe: Int, val panel: Int, val panelStroke: Int, val well: Int,
    val buttonTop: Int, val buttonBottom: Int, val buttonStroke: Int, val tabTop: Int, val tabBottom: Int,
    val selectedTop: Int, val selectedBottom: Int, val accentTop: Int, val accentBottom: Int, val accentStroke: Int,
    val text: Int, val secondaryText: Int, val icon: Int, val switchOff: Int, val gloss: Float, val shadow: Float,
    val ledge: Int, val accentLedge: Int, val caution: Int, val cautionInk: Int, val danger: Int,
)

enum class KPStyle { Plain, Primary, Tab, Tile, Art, Round, Card }

enum class KPAlign { Left, Center, Right }

object KPWeight {
    const val Regular = 400
    const val Medium = 500
    const val Semibold = 600
    const val Bold = 700
    const val Heavy = 800
}

object KP {
    val Light = KPPalette(0xf2f4f5, 0xe8ecee, 0xfbfcfc, 0xc9d1d6, 0xe6ecef, 0xffffff, 0xdfe5e8, 0xb3bdc3, 0xfafbfc,
        0xd3dade, 0xebf8fe, 0xbde8fa, 0x5ccbf3, 0x1b9ad5, 0x1784bc, 0x3a4348, 0x6a747a, 0x5a646a, 0xc3cbd0, .9f, .20f,
        0xb0bbc1, 0x14709f, 0xf0a030, 0xc6731a, 0xd0342c)
    val Dark = KPPalette(0x15181b, 0x191d20, 0x22272b, 0x363d43, 0x191d21, 0x3c4349, 0x2a3035, 0x4c555c, 0x3f464c,
        0x2b3136, 0x1f4b5f, 0x163748, 0x4cc6f2, 0x168ac4, 0x63d0f5, 0xe6ebee, 0x9aa5ab, 0xc3cbd0, 0x4a535a, .13f, .55f,
        0x0c0e10, 0x0d5880, 0xf0a030, 0xf2a64a, 0xff6b5e)

    /** The palette drawing uses now. Follows the launcher's light/dark choice (KPOverlay sets it). */
    var p: KPPalette = Light

    val dark get() = p === Dark

    // Player colours in Nintendo's four-player order (red, blue, yellow, green); ink is the text on them.
    val PlayerColors = intArrayOf(0xe5484d, 0x2e7cf6, 0xf2b51e, 0x30b85c)
    val PlayerDarkColors = intArrayOf(0xb5303a, 0x1d5bc4, 0xc48a0c, 0x218a43)
    val PlayerInk = intArrayOf(0xffffff, 0xffffff, 0x3a2a00, 0xffffff)
    // The same colours for a controller's light, which looks washed out at the UI's values.
    val PlayerLights = intArrayOf(0xff0000, 0x0046ff, 0xffaa00, 0x00ff28)

    /** The corner radius of the first face drawn since this was set below zero (the focus ring follows it). */
    var faceRadiusDrawn = -1f

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val line = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val shaded = Paint(Paint.ANTI_ALIAS_FLAG)
    private val scratch = RectF()
    private val path = Path()

    fun argb(hex: Int, alpha: Float = 1f): Int =
        ((alpha.coerceIn(0f, 1f) * 255 + .5f).toInt() shl 24) or (hex and 0xffffff)

    /** A paint for drawing in one colour, for code that strokes or fills its own shapes (glyphs, art). */
    fun ink(hex: Int, alpha: Float = 1f, stroke: Float = 0f): Paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = argb(hex, alpha)
        if (stroke > 0) {
            style = Paint.Style.STROKE
            strokeWidth = stroke
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }
    }

    fun fill(c: Canvas, r: RectF, hex: Int, radius: Float = 0f, alpha: Float = 1f) {
        fill.color = argb(hex, alpha)
        if (radius > 0) c.drawRoundRect(r, radius, radius, fill) else c.drawRect(r, fill)
    }

    fun stroke(c: Canvas, r: RectF, hex: Int, width: Float = 1f, radius: Float = 0f, alpha: Float = 1f) {
        line.color = argb(hex, alpha)
        line.strokeWidth = width
        val round = max(0f, radius - width / 2)
        scratch.set(r.left + width / 2, r.top + width / 2, r.right - width / 2, r.bottom - width / 2)
        if (round > 0) c.drawRoundRect(scratch, round, round, line) else c.drawRect(scratch, line)
    }

    fun gradientFill(c: Canvas, r: RectF, radius: Float, top: Int, bottom: Int, alpha: Float = 1f) {
        shaded.style = Paint.Style.FILL
        shaded.shader = LinearGradient(0f, r.top, 0f, r.bottom, argb(top, alpha), argb(bottom, alpha), Shader.TileMode.CLAMP)
        if (radius > 0) c.drawRoundRect(r, radius, radius, shaded) else c.drawRect(r, shaded)
        shaded.shader = null
    }

    fun line(c: Canvas, x: Float, y: Float, x2: Float, y2: Float, paint: Paint) = c.drawLine(x, y, x2, y2, paint)

    /**
     * Wii channel face: a rounded rectangle on a solid ledge, a soft vertical gradient and a double rim
     * whose inner, white line fades out towards the bottom. Pressing drops the face onto its ledge.
     * Hovered lights the rim in Wii blue (a mouse on Android, as the Wii pointer). Art tiles stay light in
     * dark mode so black eyes and dark hair remain visible.
     */
    fun buttonFace(c: Canvas, r: RectF, styleIn: KPStyle, selected: Boolean, enabled: Boolean, pressed: Boolean,
                   hovered: Boolean = false) {
        val theme = p
        var style = styleIn
        if (style == KPStyle.Art) {
            p = Light
            style = KPStyle.Tile
        }
        val ledge = 3f
        val radius = when (style) { KPStyle.Card -> 14f; KPStyle.Round, KPStyle.Tile -> 10f; else -> 8f }
        if (faceRadiusDrawn < 0) faceRadiusDrawn = radius
        val body = RectF(r.left, r.top, r.right, r.bottom - ledge)
        val accent = style == KPStyle.Primary || (selected && style == KPStyle.Tab)
        val highlight = selected && !accent
        val saved = if (!enabled) c.saveLayerAlpha(r.left - 4, r.top - 4, r.right + 4, r.bottom + 4, (.42f * 255).toInt())
            else c.save()
        fill(c, RectF(body).apply { offset(0f, ledge) }, if (accent) p.accentLedge else if (highlight) p.accentStroke else p.ledge, radius)
        if (pressed) body.offset(0f, ledge - 1)
        var top = if (accent) p.accentTop else if (highlight) p.selectedTop else if (style == KPStyle.Tab) p.tabTop else p.buttonTop
        var bottom = if (accent) p.accentBottom else if (highlight) p.selectedBottom else if (style == KPStyle.Tab) p.tabBottom else p.buttonBottom
        if (pressed) top = bottom.also { bottom = top }
        gradientFill(c, body, radius, top, bottom)
        // The lit rim runs round the ledge too, so it is as thick at the bottom as on the other sides.
        val lit = hovered && enabled && !pressed && !highlight
        stroke(c, if (lit) r else body, if (accent || highlight) p.accentStroke else if (lit) p.accentTop else p.buttonStroke,
            if (highlight || lit) 2.5f else 1.25f, radius)
        if (!pressed) {
            val inset = if (highlight) 4.5f else 3.5f
            val gloss = RectF(body.left + inset, body.top + inset, body.right - inset, body.bottom - inset)
            val round = max(0f, radius - 3.5f)
            val alpha = p.gloss * (if (accent) .45f else 1f)
            shaded.style = Paint.Style.STROKE
            shaded.strokeWidth = 1f
            shaded.shader = LinearGradient(0f, gloss.top, 0f, gloss.bottom,
                intArrayOf(argb(0xffffff, alpha), argb(0xffffff, alpha), argb(0xffffff, 0f)), floatArrayOf(0f, .45f, .9f),
                Shader.TileMode.CLAMP)
            c.drawRoundRect(gloss, round, round, shaded)
            shaded.shader = null
        }
        c.restoreToCount(saved)
        p = theme
    }

    /** On/off indicator in the same rounded-rectangle language as the buttons. */
    fun switch(c: Canvas, track: RectF, on: Boolean) {
        fill(c, track, if (on) p.accentBottom else p.switchOff, 7f)
        stroke(c, track, if (on) p.accentLedge else p.buttonStroke, 1f, 7f)
        val d = track.height() - 6
        val x = if (on) track.right - d - 3 else track.left + 3
        val knob = RectF(x, track.top + 3, x + d, track.top + 3 + d)
        fill(c, RectF(knob).apply { offset(0f, 1.5f) }, 0x000000, 5f, .22f)
        gradientFill(c, knob, 5f, 0xffffff, 0xe3e8eb)
        stroke(c, knob, p.buttonStroke, 1f, 5f)
    }

    /** Pinstripes: a 1-point line every 4, the Mii Channel's background. */
    fun pinstripes(c: Canvas, r: RectF, stripe: Int) {
        line.color = argb(stripe)
        line.strokeWidth = 1f
        var y = r.top + 1.5f
        while (y < r.bottom) {
            c.drawLine(r.left, y, r.right, y, line)
            y += 4
        }
    }

    /** A panel card: soft drop shadow, the panel fill and a hairline rim. */
    fun card(c: Canvas, r: RectF, radius: Float = 18f) {
        fill(c, RectF(r).apply { offset(0f, 2f) }, 0x000000, radius, p.shadow * .6f)
        fill(c, r, p.panel, radius)
        stroke(c, r, p.panelStroke, 1f, radius)
    }

    /** Draws block with a soft shadow under what it draws (CGContextSetShadowWithColor). */
    fun shadowed(c: Canvas, dy: Float, blur: Float, alpha: Float, r: RectF, hex: Int, radius: Float) {
        shaded.style = Paint.Style.FILL
        shaded.color = argb(hex)
        shaded.setShadowLayer(blur, 0f, dy, argb(0x000000, alpha))
        c.drawRoundRect(r, radius, radius, shaded)
        shaded.clearShadowLayer()
    }

    /** The Wii-blue glow of a focused control around its face. */
    fun focusRing(c: Canvas, face: RectF, radius: Float) {
        line.color = argb(p.accentTop)
        line.strokeWidth = 4.5f
        line.setShadowLayer(10f, 0f, 0f, argb(p.accentTop, .85f))
        // It reaches a point under the face, so no seam shows between it and the face's lit rim.
        val ring = RectF(face.left - 3.5f + 2.25f, face.top - 3.5f + 2.25f, face.right + 3.5f - 2.25f, face.bottom + 3.5f - 2.25f)
        val round = max(0f, radius + 3.5f - 2.25f)
        c.drawRoundRect(ring, round, round, line)
        line.clearShadowLayer()
    }

    // MARK: Type

    private var fontSource: ((Int) -> Typeface)? = null
    private val typefaces = HashMap<Int, Typeface>()

    /** The bundled rounded face (assets/fonts/Nunito.ttf, a variable font), or the system font without it. */
    fun installFonts(context: Context) {
        if (fontSource != null) return
        val assets = context.applicationContext.assets
        val present = runCatching { assets.open("fonts/Nunito.ttf").close() }.isSuccess
        fontSource = { weight ->
            if (present) runCatching {
                Typeface.Builder(assets, "fonts/Nunito.ttf").setFontVariationSettings("'wght' $weight").build()
            }.getOrNull() ?: Typeface.create(Typeface.DEFAULT, weight, false)
            else Typeface.create(Typeface.DEFAULT, weight, false)
        }
    }

    fun typeface(weight: Int): Typeface = typefaces.getOrPut(weight) {
        fontSource?.invoke(weight) ?: Typeface.create(Typeface.DEFAULT, weight, false)
    }

    private val textPaint = TextPaint(Paint.ANTI_ALIAS_FLAG)

    fun textPaint(size: Float, hex: Int, weight: Int, alpha: Float = 1f): TextPaint = textPaint.apply {
        typeface = typeface(weight)
        textSize = size
        color = argb(hex, alpha)
        textAlign = Paint.Align.LEFT
    }

    // The Mac's lines: SF Pro Rounded puts the first baseline 0.952 of the size below the top of the
    // rect and spaces lines 1.193 apart. Drawing to the same metrics keeps every screen's layout.
    private const val Ascent = .952f
    private const val LineHeight = 1.193f

    private data class LayoutKey(val text: String, val width: Int, val size: Float, val weight: Int, val align: KPAlign, val lines: Int)
    private val layouts = object : LinkedHashMap<LayoutKey, StaticLayout>(64, .75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<LayoutKey, StaticLayout>?) = size > 384
    }

    /**
     * Text in a rect, from its top: wrapped when the rect has room for more than two lines and cut
     * short with an ellipsis otherwise, as the Mac's KPText.
     */
    fun text(c: Canvas, text: String, rect: RectF, size: Float, hex: Int, weight: Int = KPWeight.Regular,
             align: KPAlign = KPAlign.Center, alpha: Float = 1f) {
        if (text.isEmpty() || rect.width() <= 0) return
        val paint = textPaint(size, hex, weight, alpha)
        val metrics = paint.fontMetrics
        if (rect.height() <= size * 2.6f) {
            val shown = TextUtils.ellipsize(text, paint, rect.width(), TextUtils.TruncateAt.END).toString()
            val width = paint.measureText(shown)
            val x = when (align) {
                KPAlign.Left -> rect.left
                KPAlign.Center -> rect.left + (rect.width() - width) / 2
                KPAlign.Right -> rect.right - width
            }
            c.drawText(shown, x, rect.top + Ascent * size, paint)
            return
        }
        val lines = max(1, (rect.height() / (size * LineHeight)).toInt())
        val key = LayoutKey(text, rect.width().toInt(), size, weight, align, lines)
        val layout = layouts.getOrPut(key) {
            val natural = metrics.descent - metrics.ascent
            StaticLayout.Builder.obtain(text, 0, text.length, TextPaint(paint), rect.width().toInt())
                .setAlignment(when (align) {
                    KPAlign.Left -> Layout.Alignment.ALIGN_NORMAL
                    KPAlign.Center -> Layout.Alignment.ALIGN_CENTER
                    KPAlign.Right -> Layout.Alignment.ALIGN_OPPOSITE
                })
                .setIncludePad(false)
                .setLineSpacing(0f, size * LineHeight / natural)
                .setMaxLines(lines)
                .setEllipsize(TextUtils.TruncateAt.END)
                .build()
        }
        layout.paint.color = argb(hex, alpha)
        c.save()
        c.translate(rect.left, rect.top + Ascent * size + metrics.ascent)
        layout.draw(c)
        c.restore()
    }

    /** One line of text centred vertically in a face. */
    fun centeredText(c: Canvas, text: String, r: RectF, size: Float, hex: Int, weight: Int = KPWeight.Regular,
                     align: KPAlign = KPAlign.Center) =
        text(c, text, RectF(r.left, r.centerY() - size * .66f, r.right, r.centerY() - size * .66f + size * 1.5f), size, hex, weight, align)

    fun textWidth(text: String, size: Float, weight: Int): Float = textPaint(size, 0, weight).measureText(text)

    /** How tall wrapped text runs in a width (the Mac's boundingRectWithSize). */
    fun textHeight(text: String, width: Float, size: Float, weight: Int): Float {
        val paint = TextPaint(textPaint(size, 0, weight))
        val layout = StaticLayout.Builder.obtain(text, 0, text.length, paint, max(1, width.toInt())).setIncludePad(false).build()
        return layout.lineCount * size * LineHeight
    }

    /**
     * A short label (a button's letter, a player's number, a keycap's word) centred on its ink in r:
     * across by the glyphs' outlines, and up and down by them too when it has no lowercase; a word
     * centres its cap height (x-height when all lowercase), so keycaps share a baseline.
     */
    fun centredLabel(c: Canvas, text: String, r: RectF, size: Float, hex: Int, weight: Int) {
        val paint = textPaint(size, hex, weight)
        val ink = android.graphics.Rect()
        paint.getTextBounds(text, 0, text.length, ink)
        val lower = text.any { it.isLowerCase() }
        val upper = text.any { it.isUpperCase() }
        val baseline = when {
            !lower -> r.centerY() - ink.exactCenterY()
            upper -> r.centerY() + capHeight(paint) / 2
            else -> r.centerY() + xHeight(paint) / 2
        }
        c.drawText(text, r.centerX() - ink.exactCenterX(), baseline, paint)
    }

    private fun capHeight(paint: Paint): Float {
        val bounds = android.graphics.Rect()
        paint.getTextBounds("H", 0, 1, bounds)
        return -bounds.top.toFloat()
    }

    private fun xHeight(paint: Paint): Float {
        val bounds = android.graphics.Rect()
        paint.getTextBounds("x", 0, 1, bounds)
        return -bounds.top.toFloat()
    }

    // MARK: Arrows and control icons

    fun arrowHead(c: Canvas, tipX: Float, tipY: Float, angle: Float, length: Float, paint: Paint) {
        path.reset()
        path.moveTo(tipX, tipY)
        path.lineTo(tipX - length * cos(angle - .6f), tipY - length * sin(angle - .6f))
        path.lineTo(tipX - length * cos(angle + .6f), tipY - length * sin(angle + .6f))
        path.close()
        val style = paint.style
        paint.style = Paint.Style.FILL
        c.drawPath(path, paint)
        paint.style = style
    }

    fun arrow(c: Canvas, fromX: Float, fromY: Float, toX: Float, toY: Float, paint: Paint, width: Float = 3.4f) {
        val angle = kotlin.math.atan2(toY - fromY, toX - fromX)
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = width
        c.drawLine(fromX, fromY, toX - 4 * cos(angle), toY - 4 * sin(angle), paint)
        arrowHead(c, toX, toY, angle, 8f, paint)
    }

    /** Clockwise arc (y down) from start to end, radians, with a head at the end. */
    fun arcArrow(c: Canvas, cx: Float, cy: Float, radius: Float, start: Float, end: Float, paint: Paint, width: Float = 3.4f) {
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = width
        val oval = RectF(cx - radius, cy - radius, cx + radius, cy + radius)
        c.drawArc(oval, Math.toDegrees(start.toDouble()).toFloat(), Math.toDegrees((end - start).toDouble()).toFloat(), false, paint)
        val tip = end + .32f
        arrowHead(c, cx + radius * cos(tip), cy + radius * sin(tip), tip + (PI / 2).toFloat(), 9f, paint)
    }

    enum class Glyph { Move, Across, Size, Rotate, Spacing, Undo, More, Chevron, Turn, Front, None, Check }

    /** The editor's small control icons, on a 40-point grid (KPControlIcon). */
    fun controlIcon(c: Canvas, rect: RectF, kind: Glyph, direction: Int, hex: Int) {
        c.save()
        c.translate(rect.left, rect.top)
        c.scale(rect.width() / 40, rect.height() / 40)
        val ink = ink(hex)
        val stroke = ink(hex, stroke = 1f)
        fun mirror(flip: Boolean) {
            if (flip) {
                c.translate(40f, 0f)
                c.scale(-1f, 1f)
            }
        }
        fun dot(x: Float, y: Float, w: Float, h: Float) = c.drawOval(RectF(x, y, x + w, y + h), ink)
        when (kind) {
            Glyph.Move -> {
                dot(6f, 16f, 8f, 8f)
                arrow(c, 26f, if (direction < 0) 33f else 7f, 26f, if (direction < 0) 7f else 33f, stroke)
            }
            Glyph.Across -> {
                dot(16f, 5f, 8f, 8f)
                arrow(c, if (direction < 0) 34f else 6f, 28f, if (direction < 0) 6f else 34f, 28f, stroke)
            }
            Glyph.Size -> {
                val d = if (direction < 0) 3.5f else 5.5f
                dot(20 - d, 20 - d, d * 2, d * 2)
                for (x in intArrayOf(-1, 1)) for (y in intArrayOf(-1, 1)) {
                    val ix = 20 + x * 8.5f; val iy = 20 + y * 8.5f
                    val ox = 20 + x * 18f; val oy = 20 + y * 18f
                    if (direction < 0) arrow(c, ox, oy, ix, iy, stroke, 3f) else arrow(c, ix, iy, ox, oy, stroke, 3f)
                }
            }
            Glyph.Rotate -> {
                if (direction > 0) {
                    c.translate(0f, 40f)
                    c.scale(1f, -1f)
                }
                dot(15f, 21.5f, 10f, 10f)
                arcArrow(c, 20f, 26.5f, 14.5f, (PI * .93).toFloat(), (PI * 1.8).toFloat(), stroke, 4.2f)
            }
            Glyph.Spacing -> if (direction < 0) {
                dot(16f, 16f, 8f, 8f)
                arrow(c, 2f, 20f, 13f, 20f, stroke)
                arrow(c, 38f, 20f, 27f, 20f, stroke)
            } else {
                dot(2f, 16f, 8f, 8f)
                dot(30f, 16f, 8f, 8f)
                arrow(c, 17f, 20f, 11f, 20f, stroke)
                arrow(c, 23f, 20f, 29f, 20f, stroke)
            }
            Glyph.Undo -> {
                mirror(direction > 0)
                stroke.strokeWidth = 3.6f
                path.reset()
                path.moveTo(31f, 31f)
                path.cubicTo(32f, 19f, 25f, 14f, 15f, 14f)
                c.drawPath(path, stroke)
                arrowHead(c, 6f, 14f, PI.toFloat(), 11f, ink)
            }
            Glyph.More -> for (x in floatArrayOf(8f, 17f, 26f)) dot(x, 17f, 6f, 6f)
            Glyph.Chevron -> {
                mirror(direction < 0)
                stroke.strokeWidth = 4.4f
                path.reset()
                path.moveTo(15f, 8f); path.lineTo(27f, 20f); path.lineTo(15f, 32f)
                c.drawPath(path, stroke)
            }
            Glyph.Turn -> {
                mirror(direction < 0)
                dot(15.5f, 16.5f, 9f, 9f)
                arcArrow(c, 20f, 21f, 13f, (PI * .62).toFloat(), (PI * 2.02).toFloat(), stroke)
            }
            Glyph.Front -> {
                stroke.strokeWidth = 2.8f
                c.drawOval(RectF(10f, 7f, 30f, 32f), stroke)
                dot(14.5f, 16f, 3.4f, 3.4f)
                dot(22.1f, 16f, 3.4f, 3.4f)
                c.drawLine(16.5f, 25f, 23.5f, 25f, stroke)
            }
            Glyph.None -> {
                stroke.strokeWidth = 3f
                c.drawOval(RectF(8f, 8f, 32f, 32f), stroke)
                c.drawLine(12.5f, 27.5f, 27.5f, 12.5f, stroke)
            }
            Glyph.Check -> {
                stroke.strokeWidth = 4.5f
                path.reset()
                path.moveTo(9f, 21f); path.lineTo(17f, 29f); path.lineTo(31f, 12f)
                c.drawPath(path, stroke)
            }
        }
        c.restore()
    }

    // MARK: Sliders and loading dots (KartPadOverlay.inc.mm)

    /** The level (0 to 1, in hundredths) a point on a slider's track picks, or null off the track on a press. */
    fun sliderLevel(track: RectF, x: Float, began: Boolean): Float? {
        if (began && (x < track.left - 12 || x > track.right + 12)) return null
        return Math.round(((x - track.left) / track.width()).coerceIn(0f, 1f) * 100) / 100f
    }

    /** A slider: the track on its ledge, filled in Wii blue up to the level, the knob at its end; grey when dimmed. */
    fun slider(c: Canvas, track: RectF, level: Float, dimmed: Boolean = false) {
        fill(c, RectF(track).apply { offset(0f, -1f) }, p.ledge, 6f)
        fill(c, track, p.well, 6f)
        stroke(c, track, p.buttonStroke, 1f, 6f)
        val filled = track.width() * level
        val bar = RectF(track.left + 1, track.top + 1, track.left + filled - 1, track.bottom - 1)
        if (filled > 2 && dimmed) fill(c, bar, p.secondaryText, 5f, .45f)
        else if (filled > 2) gradientFill(c, bar, 5f, p.accentTop, p.accentBottom)
        val knob = RectF(track.left + filled - 11, track.centerY() - 11, track.left + filled + 11, track.centerY() + 11)
        fill(c, RectF(knob).apply { offset(0f, 1.5f) }, 0x000000, 11f, .22f)
        gradientFill(c, knob, 11f, 0xffffff, 0xe3e8eb)
        stroke(c, knob, p.buttonStroke, 1f, 11f)
    }

    /** Dots in the player colours bouncing in turn, Wii-loading style; phase runs from 0 to 1. */
    fun loadingDots(c: Canvas, x: Float, y: Float, phase: Float) {
        for (dot in 0 until 5) {
            val lift = max(0.0, sin(phase * 2 * PI - dot * .7)).toFloat() * 14
            val left = x + dot * 34
            c.drawOval(RectF(left, y - lift, left + 22, y - lift + 22), ink(PlayerColors[dot % 4]))
        }
    }

    fun clampIndex(value: Int, size: Int) = min(max(value, 0), size - 1)
}
