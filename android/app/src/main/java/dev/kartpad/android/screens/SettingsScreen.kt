package dev.kartpad.android.screens

import android.graphics.Canvas
import android.graphics.RectF
import android.os.SystemClock
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// Settings, as a screen over the game (the Mac's KartPadSettingsScreen.inc.mm): five plain-word
// categories down the side (Picture, Sound, Controls, Game, Advanced) and big rows a controller can
// work. A flips a switch or opens a row; left and right step a choice or a level in place. Left from a
// switch (or a choice already at its first step) goes back to the categories, as B does before it
// leaves. LB and RB change category. The rows (SettingsRows) are Android's own settings, applied at
// once; a change that needs a restart says so on its row, and HOME offers the restart.
class SettingsScreen(overlay: KPOverlay, initialCategory: Int = 0) : KPScreen(overlay) {
    private val context = overlay.activity
    private val names = SettingsRows.categoryNames
    var category = initialCategory.coerceIn(0, names.size - 1)
        private set
    private var first = 0  // the top row showing
    private val tabs = ArrayList<KPButton>()
    private val rowButtons = ArrayList<KPButton>()
    private lateinit var done: KPButton
    private lateinit var gauge: KPButton
    private var rows: List<List<KPSettingRow>> = emptyList()
    // The category's rows as they show now (Music and Game sounds only while adjusted).
    private var showing: List<KPSettingRow> = emptyList()
    // A level row being dragged shows slidingLevel until it's saved (KPSlide.saveSoon).
    private var sliding: KPSettingRow? = null
    private var slidingLevel = 0f
    private var gaugeGrab = -1f  // where in the scroll gauge's thumb the finger holds it
    // Restart marks and action values, read when the rows change and twice a second (Android's sheets
    // change things under the screen), not at every frame.
    private val marks = HashMap<KPSettingRow, Boolean>()
    private val values = HashMap<KPSettingRow, String?>()
    private var lastRead = 0L
    // The control last drawn with the focus, which it goes back to when the gauge is touched.
    private var lastFocus: KPButton? = null

    companion object {
        const val VisibleRows = 7

        // Where a level row draws its track (unpressed), for the drawing and the finger alike.
        fun sliderTrack(r: RectF): RectF {
            val right = r.right - 20
            val mid = r.centerY() - 1.5f
            return RectF(right - 300, mid - 6, right - 300 + 230, mid + 6)
        }

        // Where a choice row draws its box of arrows and value (unpressed).
        fun choiceBox(r: RectF): RectF {
            val right = r.right - 20
            val mid = r.centerY() - 1.5f
            return RectF(right - 300, mid - 20, right, mid + 20)
        }
    }

    private fun levelOf(row: KPSettingRow) = if (row === sliding) slidingLevel else row.level()

    override fun build() {
        solid = true
        title = "Settings"
        rows = SettingsRows.categories(context, overlay).map { it.second }
        showing = shownRows()
        for (i in names.indices) {
            val icon = SettingsRows.categoryGlyphs[i]
            val name = names[i]
            val tab = button(RectF(), { c, r, state ->
                val chosen = category == i
                KP.buttonFace(c, r, KPStyle.Tab, chosen, true, state.pressed, state.focused)
                val dy = if (state.pressed) 2f else 0f
                val ink = if (chosen) 0xffffff else KP.p.text
                KPGlyphs.draw(c, icon, RectF(r.left + 20, r.centerY() - 16 + dy, r.left + 52, r.centerY() + 16 + dy),
                    if (chosen) 0xffffff else KP.p.accentBottom)
                KP.text(c, name, RectF(r.left + 66, r.centerY() - 15 + dy, r.right - 10, r.centerY() + 15 + dy), 22f, ink,
                    KPWeight.Semibold, KPAlign.Left)
            }, null)
            // A from a pad goes into the category's rows; a touch just shows them.
            tab.activate = { showCategory(i, !tab.clicked) }
            tab.tag2 = i
            tab.radius = 12f
            tab.label = name
            tab.sound = KPUISound.Tab
            tabs += remembered(tab)
        }
        for (i in 0 until VisibleRows) {
            val row = button(RectF(), { c, r, state -> drawRow(i, c, r, state) }) { pressRow(i) }
            row.tag2 = i
            row.radius = 12f
            row.margin = 6f
            row.focusScale = 1.012f
            row.adjust = { direction -> adjustRow(i, direction) }
            row.slide = { x, y, face, began -> slideRow(i, x, y, face, began) }
            rowButtons += remembered(row)
        }
        done = remembered(button(RectF(), { c, r, state -> KPFaces.pill(c, r, state, KPStyle.Primary, KPUIGlyph.Check, "Done") }) {
            overlay.pop()
        })
        done.label = "Done"
        done.sound = KPUISound.Close
        // The scroll gauge for long categories: a finger drags its thumb, or takes it to where the track
        // is touched. It never has the focus (no action), and goes last so it wins a touch at its edge.
        gauge = button(RectF(), { c, _, _ ->
            KP.fill(c, gaugeTrack(), KP.p.buttonStroke, 4f, .45f)
            KP.fill(c, gaugeThumb(), KP.p.accentBottom, 4f)
        }, null)
        gauge.margin = 14f
        gauge.focusScale = 1f
        gauge.sound = null
        gauge.slide = { _, y, _, began ->
            if (began) {
                overlay.focus(lastFocus?.takeIf { !it.hidden && it.enabled } ?: tabs[category], false)
                val thumb = gaugeThumb()
                gaugeGrab = if (y >= thumb.top && y <= thumb.bottom) y - thumb.top else thumb.height() / 2
            }
            dragGauge(y)
            true
        }
    }

    // Notes which control draws with the focus, for the gauge to give it back.
    private fun remembered(button: KPButton): KPButton {
        val face = button.face
        button.face = { c, r, state ->
            if (state.focused) lastFocus = button
            face?.invoke(c, r, state)
        }
        return button
    }

    private fun shownRows(): List<KPSettingRow> =
        rows.getOrElse(category) { emptyList() }.filter { row -> runCatching { row.shown?.invoke() != false }.getOrDefault(true) }

    private fun rowAt(visible: Int): KPSettingRow? = showing.getOrNull(first + visible)

    override fun layoutDesign() {
        val s = safe
        for (tab in tabs) place(tab, s.left + 52, s.top + 118 + tab.tag2 * 78, 250f, 66f)
        for (row in rowButtons) {
            val setting = rowAt(row.tag2)
            row.hidden = setting == null
            row.label = setting?.title
            place(row, s.left + 336, s.top + 112 + row.tag2 * 78, 880f, 70f)
        }
        place(done, s.right - 52 - 150, s.top + 26, 150f, 58f)
        place(gauge, gaugeTrack())
        gauge.hidden = showing.size <= VisibleRows
        invalidate()  // the scroll gauge follows first
    }

    override fun initialFocus(): KPButton? = tabs.getOrNull(category)

    private fun showCategory(index: Int, focusRows: Boolean) {
        if (index != category) {
            KPSlide.saveNow()
            category = index
            first = 0
            showing = shownRows()
            readRows()
            layoutDesign()
            overlay.dismissToastsFrom(this)  // a toast about the last category's rows
        }
        if (focusRows) overlay.focus(rowButtons.first(), false)
        invalidate()
    }

    // After a change: rows that come and go (Music and Game sounds), the marks and values.
    private fun refreshRows() {
        val now = shownRows()
        if (now != showing) {
            showing = now
            first = first.coerceIn(0, max(0, showing.size - VisibleRows))
            layoutDesign()
            // A row that went takes the focus up to the last one left.
            val focus = focus
            if (focus != null && focus in rowButtons && focus.hidden)
                overlay.focus(rowButtons.lastOrNull { !it.hidden } ?: tabs[category], false)
        }
        readRows()
        invalidate()
    }

    // Reads the showing rows' restart marks and values; true when any changed.
    private fun readRows(): Boolean {
        var changed = false
        for (row in showing) {
            val mark = runCatching { row.restart?.invoke() }.getOrNull() == true
            val value = runCatching { row.value?.invoke() }.getOrNull()
            if (marks[row] != mark || values[row] != value) changed = true
            marks[row] = mark
            values[row] = value
        }
        lastRead = SystemClock.uptimeMillis()
        return changed
    }

    override fun willAppear() {
        KartPadPads.refresh(context)
        refreshRows()
    }

    override fun willDisappear() = KPSlide.saveNow()

    override fun padsChanged() {
        readRows()
        invalidate()
    }

    override fun tick() {
        val now = SystemClock.uptimeMillis()
        if (now - lastRead < 500) return
        if (shownRows() != showing) refreshRows()
        else {
            readRows()
            invalidate()  // switches and choices a sheet changed
        }
    }

    override fun handle(button: KPPad): Boolean {
        val focus = focus
        val row = focus?.takeIf { it in rowButtons }
        val tab = focus?.takeIf { it in tabs }
        if (row != null && button == KPPad.Back) {
            overlay.play(KPUISound.Close)
            overlay.focus(tabs[category], false)
            return true
        }
        if (button == KPPad.NextTab || button == KPPad.PreviousTab) {
            val next = (category + if (button == KPPad.NextTab) 1 else -1).coerceIn(0, tabs.size - 1)
            if (next == category) {
                overlay.play(KPUISound.Same)
                return true
            }
            overlay.play(KPUISound.Tab)
            showCategory(next, row != null)
            if (tab != null) overlay.focus(tabs[next], false)
            return true
        }
        // Up and down walk the rows, scrolling through long categories.
        if (row != null && (button == KPPad.Up || button == KPPad.Down)) {
            val next = first + row.tag2 + if (button == KPPad.Down) 1 else -1
            if (next < 0) {
                overlay.focus(done, true)
                return true
            }
            if (next >= showing.size) {
                overlay.play(KPUISound.Same)
                return true
            }
            if (next < first) first = next
            if (next >= first + VisibleRows) first = next - VisibleRows + 1
            layoutDesign()
            overlay.focus(rowButtons[next - first], true)
            return true
        }
        // From a tab, Right goes to its rows. From a row, Left steps a choice or level down, and goes back to
        // the tab from a switch, a button row, or a choice already at its first step.
        if (tab != null && button == KPPad.Right) {
            if (tab.tag2 != category) showCategory(tab.tag2, false)
            overlay.focus(rowButtons.first(), true)
            return true
        }
        if (tab != null && (button == KPPad.Up || button == KPPad.Down)) {
            val next = tab.tag2 + if (button == KPPad.Down) 1 else -1
            if (next < 0 || next >= tabs.size) {
                if (next < 0) overlay.focus(done, true)
                return true
            }
            showCategory(next, false)
            overlay.focus(tabs[next], true)
            return true
        }
        if (row != null && button == KPPad.Left) {
            val setting = rowAt(row.tag2)
            val atStart = setting != null && ((setting.kind == KPRowKind.Choice && setting.index() <= 0) ||
                (setting.kind == KPRowKind.Slider && levelOf(setting) <= .001f))
            if (setting == null || setting.kind == KPRowKind.Action || setting.kind == KPRowKind.Switch || atStart)
                overlay.focus(tabs[category], true)
            else adjustRow(row.tag2, -1)
            return true
        }
        if (focus === done && button == KPPad.Down) {
            overlay.focus(tabs[category], true)
            return true
        }
        return false
    }

    // The scroll gauge, and the part of it the showing rows take.
    private fun gaugeTrack(): RectF {
        val s = safe
        return RectF(s.right - 31, s.top + 118, s.right - 23, s.top + 118 + VisibleRows * 78 - 14)
    }

    private fun gaugeThumb(): RectF {
        val track = gaugeTrack()
        val count = max(1, showing.size).toFloat()
        val top = track.top + track.height() * first / count
        return RectF(track.left, top, track.right, top + track.height() * min(1f, VisibleRows / count))
    }

    private fun dragGauge(y: Float) {
        val track = gaugeTrack()
        val count = showing.size
        val next = Math.round((y - gaugeGrab - track.top) / track.height() * count).coerceIn(0, max(0, count - VisibleRows))
        if (next == first) return
        first = next
        layoutDesign()
    }

    private fun adjustRow(visible: Int, direction: Int): Boolean {
        val row = rowAt(visible) ?: return false
        KPSlide.saveNow()
        when (row.kind) {
            KPRowKind.Switch, KPRowKind.Action -> return false  // only A flips a switch
            KPRowKind.Choice -> {
                val next = row.index() + direction
                if (next < 0 || next >= row.choices.size) return true
                row.setIndex(next)
                overlay.play(if (direction < 0) KPUISound.Left else KPUISound.Right)
            }
            KPRowKind.Slider -> {
                val now = row.level()
                val next = (now + direction * .05f).coerceIn(0f, 1f)
                if (next == now) {
                    overlay.play(KPUISound.Same)
                    return true
                }
                row.setLevel(next)
                overlay.play(KPUISound.Tick)
            }
        }
        refreshRows()
        return true
    }

    // A level row's track follows the finger; the level is saved once the drag rests or ends.
    private fun slideRow(visible: Int, x: Float, y: Float, face: RectF, began: Boolean): Boolean {
        val row = rowAt(visible) ?: return false
        // A touch on a choice's arrow steps it; anywhere else on the row is a press as before.
        if (row.kind == KPRowKind.Choice) {
            if (!began) return true
            val box = choiceBox(face)
            box.inset(-8f, -10f)
            if (!box.contains(x, y)) return false
            if (x < box.left + 60) return adjustRow(visible, -1)
            if (x > box.right - 60) return adjustRow(visible, 1)
            return false
        }
        if (row.kind != KPRowKind.Slider) return false
        val next = KP.sliderLevel(sliderTrack(face), x, began) ?: return false
        val now = levelOf(row)
        if (abs(next - now) < .005f) return true
        if (floor(next * 20) != floor(now * 20)) overlay.play(KPUISound.Tick)
        sliding = row
        slidingLevel = next
        KPSlide.saveSoon {
            row.setLevel(next)
            if (sliding === row && slidingLevel == next) sliding = null
            refreshRows()
        }
        invalidate()
        return true
    }

    private fun pressRow(visible: Int) {
        val row = rowAt(visible) ?: return
        KPSlide.saveNow()
        when (row.kind) {
            KPRowKind.Switch -> row.setOn(!row.on())
            KPRowKind.Choice -> if (row.choices.isNotEmpty()) row.setIndex((row.index() + 1) % row.choices.size)
            KPRowKind.Slider -> row.setLevel(if (row.level() > .01f) 0f else 1f)
            KPRowKind.Action -> row.run?.invoke()
        }
        refreshRows()
    }

    // MARK: Drawing

    private fun drawRow(visible: Int, c: Canvas, r: RectF, state: KPUIState) {
        val row = rowAt(visible) ?: return
        KP.buttonFace(c, r, KPStyle.Plain, false, true, state.pressed, state.focused)
        val dy = if (state.pressed) 2f else 0f
        val controlWidth = when (row.kind) {
            KPRowKind.Switch -> 90f
            KPRowKind.Action -> 220f
            else -> 300f
        }
        val textRight = r.left + 22 + r.width() - controlWidth - 60
        val detail = row.detail
        if (!detail.isNullOrEmpty()) {
            KP.text(c, row.title, RectF(r.left + 22, r.top + 9 + dy, textRight, r.top + 37 + dy), 21f, KP.p.text, KPWeight.Semibold, KPAlign.Left)
            KP.text(c, detail, RectF(r.left + 22, r.top + 37 + dy, textRight, r.top + 59 + dy), 15f, KP.p.secondaryText, KPWeight.Regular,
                KPAlign.Left)
        } else {
            KP.text(c, row.title, RectF(r.left + 22, r.centerY() - 16 + dy, textRight, r.centerY() + 14 + dy), 21f, KP.p.text,
                KPWeight.Semibold, KPAlign.Left)
        }
        val right = r.right - 20
        val mid = r.centerY() - 1.5f + dy
        if (marks[row] == true) {
            val badge = HomeScreen.RestartTitle
            val width = KP.textWidth(badge, 14f, KPWeight.Bold)
            val left = right - controlWidth - width - 40
            val pill = RectF(left, mid - 13, left + width + 22, mid + 13)
            KP.fill(c, pill, 0xf0a030, 13f, .25f)
            KP.text(c, badge, RectF(pill.left, pill.top + 4, pill.right, pill.top + 24), 14f, if (KP.dark) 0xffd28a else 0x8a4b00,
                KPWeight.Bold)
        }
        when (row.kind) {
            KPRowKind.Switch -> KP.switch(c, RectF(right - 72, mid - 17, right, mid + 17), row.on())
            KPRowKind.Choice -> {
                val index = row.index()
                val box = choiceBox(r)
                box.offset(0f, dy)
                KP.fill(c, box, KP.p.well, 20f)
                KP.stroke(c, box, KP.p.buttonStroke, 1f, 20f)
                val canLeft = index > 0
                val canRight = index + 1 < row.choices.size
                KPGlyphs.draw(c, KPUIGlyph.Back, RectF(box.left + 8, mid - 12, box.left + 32, mid + 12),
                    if (canLeft) KP.p.accentBottom else KP.p.buttonStroke)
                KPGlyphs.draw(c, KPUIGlyph.Chevron, RectF(box.right - 32, mid - 12, box.right - 8, mid + 12),
                    if (canRight) KP.p.accentBottom else KP.p.buttonStroke)
                val value = row.choices.getOrNull(index) ?: "—"
                // 18 points, a little smaller for a long choice ("Fill Screen (Experimental)") so it isn't cut short.
                var size = 18f
                while (size > 14f && KP.textWidth(value, size, KPWeight.Semibold) > box.width() - 68) size -= 1f
                val top = mid - 13 + (18 - size) / 2
                KP.text(c, value, RectF(box.left + 34, top, box.right - 34, top + 26), size, KP.p.text, KPWeight.Semibold)
            }
            KPRowKind.Slider -> {
                val level = levelOf(row)
                // With Sound off the levels keep their place, greyed, as HOME's volume does.
                val silenced = row.soundLevel && KPVolume.muted(context)
                val track = sliderTrack(r)
                track.offset(0f, dy)
                KP.slider(c, track, level, silenced)
                KP.text(c, "${(level * 100).roundToInt()}%", RectF(right - 62, mid - 13, right, mid + 13), 18f,
                    if (silenced) KP.p.secondaryText else KP.p.text, KPWeight.Semibold, KPAlign.Right)
            }
            KPRowKind.Action -> {
                val value = values[row]
                if (!value.isNullOrEmpty())
                    KP.text(c, value, RectF(right - controlWidth, mid - 13, right - 36, mid + 13), 17f, KP.p.secondaryText,
                        KPWeight.Medium, KPAlign.Right)
                if (row.inPlace) KPGlyphs.draw(c, KPUIGlyph.Find, RectF(right - 32, mid - 16, right, mid + 16), KP.p.accentBottom)
                else KPGlyphs.draw(c, KPUIGlyph.Chevron, RectF(right - 28, mid - 14, right, mid + 14), KP.p.accentBottom)
            }
        }
    }

    override fun drawDesign(c: Canvas) {
        super.drawDesign(c)
        val s = safe
        KPGlyphs.draw(c, KPUIGlyph.Gear, RectF(s.left + 52, s.top + 30, s.left + 94, s.top + 72), KP.p.accentBottom)
        KP.text(c, "Settings", RectF(s.left + 106, s.top + 26, s.left + 506, s.top + 76), 36f, KP.p.text, KPWeight.Bold, KPAlign.Left)
        KPHints.draw(c, RectF(s.left + 52, s.top + 672, s.left + 1228, s.top + 698),
            listOf(KPHint(KPPad.Confirm, "Select"), KPHint(KPPad.Left, "Adjust", KPPad.Right),
                KPHint(KPPad.PreviousTab, "Category", KPPad.NextTab), KPHint(KPPad.Back, "Back")), 16f, KPAlign.Right)
    }
}
