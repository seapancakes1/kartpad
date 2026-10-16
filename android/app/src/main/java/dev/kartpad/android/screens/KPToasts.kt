package dev.kartpad.android.screens

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF

// A toast's card (the Mac's KPToastView), drawn in its own design points: 420 × 92.
object KPToasts {
    const val Width = 420f
    const val Height = 92f
    private val image = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)

    fun draw(overlay: KPOverlay, c: Canvas, toast: KPToast) {
        val card = RectF(6f, 4f, Width - 6, Height - 8)
        KP.shadowed(c, 4f, 14f, .28f, card, KP.p.panel, 18f)
        val art = toast.art
        if (art != null) {
            drawController(overlay, c, toast, card, art)
            return
        }
        KP.stroke(c, card, KP.p.panelStroke, 1f, 18f)
        // The player's colour runs down the leading edge.
        if (toast.stripe != 0) {
            c.save()
            c.clipPath(Path().apply { addRoundRect(card, 18f, 18f, Path.Direction.CW) })
            KP.fill(c, RectF(card.left, card.top, card.left + 8, card.bottom), toast.stripe)
            c.restore()
        }
        val well = RectF(card.left + 22, card.top + (card.height() - 52) / 2, card.left + 74, card.top + (card.height() - 52) / 2 + 52)
        val bitmap = toast.image
        val icon = toast.icon
        if (bitmap != null) {
            KP.fill(c, well, KP.Light.well, 14f)
            c.drawBitmap(bitmap, null, RectF(well.left + 3, well.top + 3, well.right - 3, well.bottom - 3), image)
        } else if (icon != null) {
            KP.fill(c, well, KP.p.well, 14f)
            icon(c, RectF(well.left + 9, well.top + 9, well.right - 9, well.bottom - 9))
        }
        val x = well.right + 16
        val w = card.right - x - 18
        val detail = toast.detail
        if (!detail.isNullOrEmpty()) {
            KP.text(c, toast.heading, RectF(x, card.top + 17, x + w, card.top + 43), 19f, KP.p.text, KPWeight.Semibold, KPAlign.Left)
            KP.text(c, detail, RectF(x, card.top + 44, x + w, card.top + 66), 15f, KP.p.secondaryText, KPWeight.Regular, KPAlign.Left)
        } else {
            KP.text(c, toast.heading, RectF(x, card.centerY() - 13, x + w, card.centerY() + 13), 19f, KP.p.text, KPWeight.Semibold, KPAlign.Left)
        }
    }

    // The player's colour fills the leading end, with their Mii's head on it (their number without one);
    // a controller still without a player gets a grey end and its icon. The controller sits at the trailing end.
    private fun drawController(overlay: KPOverlay, c: Canvas, toast: KPToast, card: RectF, art: (Canvas, RectF) -> Unit) {
        val player = toast.player
        val band = RectF(card.left, card.top, card.left + 84, card.bottom)
        c.save()
        c.clipPath(Path().apply { addRoundRect(card, 18f, 18f, Path.Direction.CW) })
        if (player in 0..3) {
            KP.gradientFill(c, band, 0f, KP.PlayerColors[player], KP.PlayerDarkColors[player])
            KP.fill(c, RectF(band.left, band.top, band.right, band.top + 1.5f), 0xffffff, 0f, .35f)
        } else {
            KP.fill(c, band, KP.p.well)
        }
        c.restore()
        KP.stroke(c, card, KP.p.panelStroke, 1f, 18f)
        // The portrait may still be rendering: the toast redraws once it's ready.
        val mii = toast.mii
        val portrait = if (player >= 0 && mii != null) overlay.portraitProvider?.invoke(mii) { overlay.invalidate() } else null
        if (portrait != null) {
            val head = RectF(band.centerX() - 34, band.centerY() - 34, band.centerX() + 34, band.centerY() + 34)
            image.setShadowLayer(6f, 0f, 2f, KP.argb(0x000000, .3f))
            c.drawBitmap(portrait, null, head, image)
            image.clearShadowLayer()
        } else if (player in 0..3) {
            KP.centredLabel(c, "${player + 1}", band, 50f, KP.PlayerInk[player], KPWeight.Heavy)
        } else {
            toast.icon?.invoke(c, RectF(band.centerX() - 18, band.centerY() - 18, band.centerX() + 18, band.centerY() + 18))
        }
        val drawing = RectF(card.right - 18 - 88, card.top + 10, card.right - 18, card.bottom - 10)
        art(c, drawing)
        val x = band.right + 18
        val w = drawing.left - 12 - x
        KP.text(c, toast.heading, RectF(x, card.top + 14, x + w, card.top + 44), 23f, KP.p.text, KPWeight.Bold, KPAlign.Left)
        toast.detail?.let { KP.text(c, it, RectF(x, card.top + 46, x + w, card.top + 68), 15f, KP.p.secondaryText, KPWeight.Medium, KPAlign.Left) }
    }
}
