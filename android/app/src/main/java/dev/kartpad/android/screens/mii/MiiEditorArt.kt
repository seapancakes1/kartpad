package dev.kartpad.android.screens.mii

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import dev.kartpad.android.screens.KP
import dev.kartpad.android.screens.KPStyle

// The Mii editor's own vector art (apple/shared/KartPadMiiEditor.inc.mm KPIcon, KPMiiBodySlider):
// the category silhouettes on a 40-unit grid in one stroke weight, the Male and Female figures, the
// Create Mii stand-ins, and the height/weight gauge. Main thread only.
internal object MiiEditorArt {
    const val FEMALE = 10
    const val MALE = 11
    const val SCRATCH = 12
    const val LOOK_ALIKES = 13

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val line = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val clear = PorterDuffXfermode(PorterDuff.Mode.CLEAR)

    /** Categories 0–9 (EditorCategories order), then FEMALE, MALE, SCRATCH and LOOK_ALIKES. */
    fun icon(c: Canvas, category: Int, rect: RectF, ink: Int) {
        val color = KP.argb(ink)
        c.save()
        c.translate(rect.left, rect.top)
        c.scale(rect.width() / 40, rect.height() / 40)
        fill.color = color
        line.color = color
        line.strokeWidth = 2.8f
        val p = Path()
        fun oval(x: Float, y: Float, w: Float, h: Float) = c.drawOval(RectF(x, y, x + w, y + h), fill)
        fun rounded(x: Float, y: Float, w: Float, h: Float, r: Float, paint: Paint) = c.drawRoundRect(RectF(x, y, x + w, y + h), r, r, paint)
        fun seg(x: Float, y: Float, x2: Float, y2: Float) = c.drawLine(x, y, x2, y2, line)
        when (category) {
            0 -> { // Profile: an ID card with a bust and text lines.
                rounded(3f, 8f, 34f, 25f, 5f, line)
                oval(9f, 13f, 8f, 8f)
                p.moveTo(7f, 29.5f); p.cubicTo(7f, 21.5f, 19f, 21.5f, 19f, 29.5f); p.close(); c.drawPath(p, fill)
                line.strokeWidth = 2.6f
                seg(23f, 16f, 32f, 16f); seg(23f, 21f, 32f, 21f); seg(23f, 26f, 28f, 26f)
            }
            1 -> { // Body: a Mii beside a height gauge with end stops.
                oval(7.5f, 3f, 13f, 13f)
                p.moveTo(9f, 18f); p.lineTo(19f, 18f); p.quadTo(22f, 18f, 22.5f, 21f)
                p.lineTo(23.5f, 29f); p.lineTo(20f, 29f); p.lineTo(19.5f, 37f); p.lineTo(15.2f, 37f); p.lineTo(14f, 30.5f)
                p.lineTo(12.8f, 37f); p.lineTo(8.5f, 37f); p.lineTo(8f, 29f); p.lineTo(4.5f, 29f); p.lineTo(5.5f, 21f)
                p.quadTo(6f, 18f, 9f, 18f); p.close(); c.drawPath(p, fill)
                line.strokeWidth = 2.6f
                seg(32f, 7f, 32f, 33f); seg(28f, 3.5f, 36f, 3.5f); seg(28f, 36.5f, 36f, 36.5f)
                p.reset(); p.moveTo(32f, 4.5f); p.lineTo(28.5f, 9.5f); p.lineTo(35.5f, 9.5f); p.close(); c.drawPath(p, fill)
                p.reset(); p.moveTo(32f, 35.5f); p.lineTo(28.5f, 30.5f); p.lineTo(35.5f, 30.5f); p.close(); c.drawPath(p, fill)
            }
            FEMALE, MALE -> {
                // Male and female Miis in Mii Channel proportions: a large round head over a short body, mitten
                // arms and stubby legs; female wears an A-line dress. The arms are cut out of the body so they read apart.
                val female = category == FEMALE
                val arm = if (female) 4f else 4.4f
                val layer = c.saveLayer(0f, 0f, 40f, 40f, null)
                oval(12f, 1f, 16f, 15.5f)
                if (female) {
                    p.moveTo(16.5f, 17.5f); p.lineTo(23.5f, 17.5f); p.quadTo(26f, 17.5f, 26.6f, 20f); p.lineTo(29.2f, 29.5f)
                    p.quadTo(29.8f, 32f, 27.2f, 32f); p.lineTo(12.8f, 32f); p.quadTo(10.2f, 32f, 10.8f, 29.5f)
                    p.lineTo(13.4f, 20f); p.quadTo(14f, 17.5f, 16.5f, 17.5f); p.close(); c.drawPath(p, fill)
                    for (x in floatArrayOf(15.4f, 20.8f)) rounded(x, 30f, 3.8f, 8f, 1.8f, fill)
                } else {
                    rounded(13.5f, 17.5f, 13f, 12.5f, 4f, fill)
                    for (x in floatArrayOf(14.2f, 20.9f)) rounded(x, 27f, 4.9f, 11f, 2.4f, fill)
                }
                val inner = if (female) 13.2f else 12.4f
                val outer = if (female) 10f else 9.4f
                val top = if (female) 20.5f else 20f
                val bottom = if (female) 27.5f else 28f
                line.xfermode = clear
                line.strokeWidth = arm + 2.4f
                seg(inner, top, outer, bottom); seg(40 - inner, top, 40 - outer, bottom)
                line.xfermode = null
                line.strokeWidth = arm
                seg(inner, top, outer, bottom); seg(40 - inner, top, 40 - outer, bottom)
                c.restoreToCount(layer)
            }
            SCRATCH -> { // Start from scratch, when portraits can't render: a plain face with a plus.
                icon(c, 2, RectF(0f, 4f, 34f, 38f), ink)
                line.strokeWidth = 3f
                seg(34f, 2f, 34f, 12f); seg(29f, 7f, 39f, 7f)
            }
            LOOK_ALIKES -> { // Look-alikes, when portraits can't render: three faces.
                val layer = c.saveLayer(0f, 0f, 40f, 40f, null)
                icon(c, 2, RectF(0f, 9f, 19f, 28f), ink)
                icon(c, 2, RectF(21f, 9f, 40f, 28f), ink)
                fill.xfermode = clear
                oval(9f, 5f, 22f, 30f)
                fill.xfermode = null
                icon(c, 2, RectF(8f, 6f, 32f, 34f), ink)
                c.restoreToCount(layer)
            }
            2 -> { // Face: a jaw outline with simple features.
                p.moveTo(20f, 4f); p.cubicTo(29f, 4f, 34f, 10f, 34f, 18f); p.cubicTo(34f, 27f, 27f, 36f, 20f, 36f)
                p.cubicTo(13f, 36f, 6f, 27f, 6f, 18f); p.cubicTo(6f, 10f, 11f, 4f, 20f, 4f); p.close(); c.drawPath(p, line)
                oval(13f, 16f, 3.6f, 3.6f); oval(23.4f, 16f, 3.6f, 3.6f)
                line.strokeWidth = 2.4f
                p.reset(); p.moveTo(15f, 26f); p.quadTo(20f, 30f, 25f, 26f); c.drawPath(p, line)
            }
            3 -> { // Hair: a filled cap with a fringe over the face outline.
                p.moveTo(5f, 21f); p.cubicTo(4f, 9f, 12f, 3f, 20f, 3f); p.cubicTo(28f, 3f, 36f, 9f, 35f, 21f)
                p.lineTo(31f, 15f); p.lineTo(27f, 18f); p.lineTo(24f, 12f); p.lineTo(19f, 17f); p.lineTo(14f, 12f)
                p.lineTo(10f, 17f); p.close(); c.drawPath(p, fill)
                p.reset(); p.moveTo(7.5f, 22f); p.cubicTo(8f, 31f, 14f, 37f, 20f, 37f); p.cubicTo(26f, 37f, 32f, 31f, 32.5f, 22f)
                c.drawPath(p, line)
            }
            4 -> for (side in 0..1) { // Eyebrows: tapered brows, a fine outer tip swelling to a blunt inner end.
                c.save()
                if (side == 1) {
                    c.translate(40f, 0f)
                    c.scale(-1f, 1f)
                }
                p.reset(); p.moveTo(1.5f, 19f); p.cubicTo(7f, 15f, 13.5f, 15f, 17.5f, 18.5f)
                p.cubicTo(19.2f, 20f, 19f, 24f, 16.8f, 24f); p.cubicTo(12f, 22.5f, 6.5f, 20.8f, 1.5f, 19f); p.close()
                c.drawPath(p, fill)
                c.restore()
            }
            5 -> { // Eyes: almonds with pupils.
                line.strokeWidth = 2.4f
                for (x in floatArrayOf(2f, 22f)) {
                    p.reset(); p.moveTo(x, 20f); p.quadTo(x + 8, 9f, x + 16, 20f); p.quadTo(x + 8, 31f, x, 20f); p.close()
                    c.drawPath(p, line)
                    oval(x + 4.5f, 16.5f, 7f, 7f)
                }
            }
            6 -> { // Nose: side profile with a nostril.
                line.strokeWidth = 3.2f
                p.moveTo(15f, 5f); p.cubicTo(18f, 14f, 26f, 19f, 29.5f, 25.5f); p.cubicTo(31f, 29f, 28.5f, 31.5f, 25f, 31f)
                p.cubicTo(23f, 34f, 18.5f, 34f, 15.5f, 31.5f); c.drawPath(p, line)
                line.strokeWidth = 2.4f
                p.reset(); p.moveTo(19f, 28f); p.quadTo(21.5f, 25.5f, 24f, 28f); c.drawPath(p, line)
            }
            7 -> { // Mouth: full lips, a cupid's-bow upper lip over a slimmer lower lip, parted by a straight line.
                p.moveTo(3f, 22f); p.cubicTo(4f, 15f, 9.5f, 10f, 14.5f, 10f); p.cubicTo(17f, 10f, 18.5f, 11.5f, 20f, 13.5f)
                p.cubicTo(21.5f, 11.5f, 23f, 10f, 25.5f, 10f); p.cubicTo(30.5f, 10f, 36f, 15f, 37f, 22f); p.close(); c.drawPath(p, fill)
                p.reset(); p.moveTo(3.5f, 25f); p.lineTo(36.5f, 25f); p.cubicTo(35f, 30.5f, 28.5f, 33f, 20f, 33f)
                p.cubicTo(11.5f, 33f, 5f, 30.5f, 3.5f, 25f); p.close(); c.drawPath(p, fill)
            }
            8 -> { // Facial hair: a curled mustache.
                p.moveTo(20f, 17f); p.cubicTo(15f, 10f, 8f, 12f, 7f, 18f); p.cubicTo(6f, 21f, 3f, 21f, 2f, 19f)
                p.cubicTo(2f, 26f, 10f, 29f, 16f, 25.5f); p.quadTo(19f, 23.5f, 20f, 22f); p.quadTo(21f, 23.5f, 24f, 25.5f)
                p.cubicTo(30f, 29f, 38f, 26f, 38f, 19f); p.cubicTo(37f, 21f, 34f, 21f, 33f, 18f); p.cubicTo(32f, 12f, 25f, 10f, 20f, 17f)
                p.close(); c.drawPath(p, fill)
            }
            9 -> { // Glasses: lenses, bridge and arms.
                for (x in floatArrayOf(2.5f, 22.5f)) rounded(x, 13f, 15f, 13f, 5.5f, line)
                p.moveTo(17.5f, 18f); p.quadTo(20f, 15f, 22.5f, 18f); c.drawPath(p, line)
                seg(2.5f, 16f, 1.5f, 12.5f); seg(37.5f, 16f, 38.5f, 12.5f)
            }
        }
        c.restore()
    }

    /** Where the gauge's track runs in its frame. */
    fun gaugeTrack(frame: RectF) = RectF(frame.left + 62, frame.centerY() - 9, frame.right - 62, frame.centerY() + 9)

    /** The value (0–127) a point on the track picks. */
    fun gaugeValue(frame: RectF, x: Float): Int {
        val t = gaugeTrack(frame)
        return Math.round(((x - t.left) / t.width()).coerceIn(0f, 1f) * 127)
    }

    /**
     * Height (field 5) or weight: a recessed track with notches, a Wii-blue fill and a ledged handle, with
     * small and large Mii silhouettes at the ends (short/tall for height, thin/wide for weight).
     */
    fun gauge(c: Canvas, frame: RectF, value: Int, height: Boolean, dragging: Boolean) {
        val t = gaugeTrack(frame)
        val mid = t.centerY()
        val small = if (height) RectF(frame.left + 10, mid - 10, frame.left + 49, mid + 19)
            else RectF(frame.left + 16, mid - 20, frame.left + 45, mid + 19)
        val large = if (height) RectF(frame.right - 49, mid - 25, frame.right - 10, mid + 27)
            else RectF(frame.right - 57, mid - 20, frame.right - 5, mid + 19)
        icon(c, MALE, small, KP.p.icon)
        icon(c, MALE, large, KP.p.icon)
        KP.fill(c, RectF(t).apply { offset(0f, -1f) }, KP.p.ledge, 9f)
        KP.fill(c, t, KP.p.well, 9f)
        KP.stroke(c, t, KP.p.buttonStroke, 1f, 9f)
        val x = t.left + value / 127f * t.width()
        if (x > t.left + 2) KP.gradientFill(c, RectF(t.left + 2, t.top + 2, x, t.bottom - 2), 7f, KP.p.accentTop, KP.p.accentBottom)
        line.color = KP.argb(KP.p.buttonStroke)
        line.strokeWidth = 2f
        line.xfermode = null
        for (i in 0..8) {
            val tx = t.left + t.width() * i / 8
            c.drawLine(tx, t.bottom + 6.5f, tx, t.bottom + if (i % 4 != 0) 12f else 16f, line)
        }
        val knob = RectF(x - 18, mid - 25, x + 18, mid + 25)
        KP.buttonFace(c, knob, KPStyle.Plain, dragging, true, dragging)
        val gy = mid - 2 + if (dragging) 2 else 0
        for (i in -1..1) c.drawLine(x + i * 6, gy - 8, x + i * 6, gy + 8, line)
    }
}
