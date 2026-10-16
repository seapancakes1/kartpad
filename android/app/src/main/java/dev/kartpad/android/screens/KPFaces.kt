package dev.kartpad.android.screens

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.RectF
import kotlin.math.min

// Faces the screens share (the Mac's KartPadHomeScreen.inc.mm "Faces shared by the screens").
object KPFaces {
    private val image = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)

    fun playerName(slot: Int) = "Player ${slot + 1}"
    fun gameTitle(profile: String) = if (profile == "retro_rewind") "Retro Rewind" else "Mario Kart Wii"

    /** A tile's icon square, centred (the Miis tile puts its faces there instead). */
    fun tileIconRect(r: RectF, dy: Float): RectF {
        val icon = min(78f, r.height() * .34f)
        val top = r.top + r.height() * .19f + dy
        return RectF(r.centerX() - icon / 2, top, r.centerX() + icon / 2, top + icon)
    }

    /** A tile: a big icon, a title and a line under it; titles in a row line up with or without a line. */
    fun tile(c: Canvas, r: RectF, state: KPUIState, primary: Boolean, glyph: KPUIGlyph?, title: String, detail: String?, iconInk: Int = 0) {
        KP.buttonFace(c, r, if (primary) KPStyle.Primary else KPStyle.Card, false, state.enabled, state.pressed, state.focused)
        val dy = if (state.pressed) 2f else 0f
        val ink = if (primary) 0xffffff else KP.p.text
        val sub = if (primary) 0xeaf7fd else KP.p.secondaryText
        if (glyph != null) KPGlyphs.draw(c, glyph, tileIconRect(r, dy), if (iconInk != 0) iconInk else if (primary) 0xffffff else KP.p.accentBottom)
        val titleY = r.top + r.height() * .61f + dy
        KP.text(c, title, RectF(r.left + 10, titleY, r.right - 10, titleY + 34), 26f, ink, KPWeight.Semibold)
        if (!detail.isNullOrEmpty())
            KP.text(c, detail, RectF(r.left + 12, titleY + 36, r.right - 12, titleY + 60), 17f, sub, KPWeight.Medium)
    }

    /** A pill button: an icon and a word. */
    fun pill(c: Canvas, r: RectF, state: KPUIState, style: KPStyle, glyph: KPUIGlyph, title: String?, tint: Int = 0) {
        KP.buttonFace(c, r, style, false, state.enabled, state.pressed, state.focused)
        val dy = if (state.pressed) 2f else 0f
        val ink = if (style == KPStyle.Primary) 0xffffff else if (tint != 0) tint else KP.p.text
        val iconSize = min(30f, r.height() - 26)
        val text = if (!title.isNullOrEmpty()) KP.textWidth(title, 21f, KPWeight.Semibold) else 0f
        val width = iconSize + if (!title.isNullOrEmpty()) 10 + text else 0f
        val x = r.centerX() - width / 2
        KPGlyphs.draw(c, glyph, RectF(x, r.centerY() - iconSize / 2 - 1 + dy, x + iconSize, r.centerY() + iconSize / 2 - 1 + dy),
            if (style == KPStyle.Primary) 0xffffff else if (tint != 0) tint else KP.p.accentBottom)
        if (!title.isNullOrEmpty())
            KP.text(c, title, RectF(x + iconSize + 10, r.centerY() - 15 + dy, x + iconSize + 14 + text, r.centerY() + 15 + dy), 21f, ink,
                KPWeight.Semibold, KPAlign.Left)
    }

    /** A Mii face in a well, or a silhouette in the player's colour while there's none (faint for a player without a controller). */
    fun miiWell(c: Canvas, well: RectF, portrait: Bitmap?, color: Int, empty: Boolean) {
        KP.fill(c, well, if (empty) KP.p.well else KP.Light.well, well.width() * .22f)
        if (portrait != null) {
            val inset = well.width() * .06f
            c.drawBitmap(portrait, null, RectF(well.left + inset, well.top + inset, well.right - inset, well.bottom - inset), image)
        } else {
            val s = well.width()
            KP.fill(c, RectF(well.centerX() - s * .19f, well.top + s * .16f, well.centerX() + s * .19f, well.top + s * .58f), color,
                s * .19f, if (empty) .18f else .5f)
            KP.fill(c, RectF(well.centerX() - s * .31f, well.top + s * .63f, well.centerX() + s * .31f, well.top + s * .93f), color,
                s * .12f, if (empty) .12f else .36f)
        }
    }

    /** A player's number in their colour. */
    fun playerBadge(c: Canvas, r: RectF, slot: Int, dim: Boolean) {
        c.drawOval(r, KP.ink(KP.PlayerColors[slot], if (dim) .35f else 1f))
        c.drawOval(RectF(r.left + .75f, r.top + .75f, r.right - .75f, r.bottom - .75f), KP.ink(KP.PlayerDarkColors[slot], if (dim) .3f else .9f, 1.5f))
        KP.centredLabel(c, "${slot + 1}", r, r.height() * .56f, if (dim) KP.p.secondaryText else KP.PlayerInk[slot], KPWeight.Heavy)
    }

    fun battery(c: Canvas, r: RectF, device: KPPadDevice) {
        if (device.isKeyboard || device.isTouch || device.battery < 0) return
        val ink = if (device.battery <= 15 && !device.charging) 0xd0342c else KP.p.secondaryText
        KPGlyphs.draw(c, KPUIGlyph.Battery, r, ink, device.battery / 100f)
    }

    /** A controller's small icon. */
    fun deviceGlyph(device: KPPadDevice): KPUIGlyph = if (device.isKeyboard) KPUIGlyph.Keyboard else KPControllerArt.familyGlyph(device.family)

    /** The empty player's dashed outline. */
    fun dashedOutline(c: Canvas, r: RectF, radius: Float) {
        val paint = KP.ink(KP.p.buttonStroke, 1f, 1.5f)
        paint.pathEffect = DashPathEffect(floatArrayOf(6f, 5f), 0f)
        c.drawRoundRect(RectF(r.left + 1.75f, r.top + 1.75f, r.right - 1.75f, r.bottom - 1.75f), radius - .75f, radius - .75f, paint)
    }

    /** A Mii's portrait for a controller, asking for it (and redrawing) when it isn't rendered yet. */
    fun portraitFor(screen: KPScreen, device: KPPadDevice): Bitmap? {
        val mii = KPRoster.miiFor(screen.overlay.activity, device) ?: return null
        return KPMiiSource.portrait(mii) { screen.invalidate() }
    }
}
