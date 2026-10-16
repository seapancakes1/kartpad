package dev.kartpad.android.screens.mii

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.KeyEvent
import dev.kartpad.android.KartPadMiiChanges
import dev.kartpad.android.screens.KP
import dev.kartpad.android.screens.KPAlign
import dev.kartpad.android.screens.KPAsk
import dev.kartpad.android.screens.KPButton
import dev.kartpad.android.screens.KPFaces
import dev.kartpad.android.screens.KPHint
import dev.kartpad.android.screens.KPHints
import dev.kartpad.android.screens.KPMenuScreen
import dev.kartpad.android.screens.KPMiiSource
import dev.kartpad.android.screens.KPNavigation
import dev.kartpad.android.screens.KPOverlay
import dev.kartpad.android.screens.KPPad
import dev.kartpad.android.screens.KPScreen
import dev.kartpad.android.screens.KPStyle
import dev.kartpad.android.screens.KPUIGlyph
import dev.kartpad.android.screens.KPUISound
import dev.kartpad.android.screens.KPUIState
import dev.kartpad.android.screens.KPWeight
import dev.kartpad.android.screens.KartPadScreens
import java.io.File
import java.util.concurrent.Executors
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.round

// The Miis screen (apple/shared/KartPadMiiBrowser.inc.mm, as the Mac hosts it among KartPad's screens):
// every Mii as a portrait tile beside the selected Mii's details, actions and licenses, on the Mii
// Channel's pinstripes. Every change waits in KartPadMiiChanges' queue for the next launch; the banner
// names the latest, counts what is waiting and restarts. The changes run on one background thread and
// the screen reloads and selects the Mii a change concerns, as the Mac does. A controller moves the
// focus (moving onto a Mii selects it), A on a Mii opens it in the editor, B and Start are Done.

private typealias Mii = KartPadMiiChanges.Mii
private typealias License = KartPadMiiChanges.License

class MiisScreen(overlay: KPOverlay) : KPScreen(overlay) {
    private val context: Context = overlay.activity
    private val files: File get() = context.filesDir

    private var snapshot: KartPadMiiChanges.Snapshot? = null
    // Waiting changes while the Miis can't be shown (Upcoming counts its own).
    private var waitingUnshown = 0
    private var selectedSlot = -1
    private var busy = false
    private var opened = false
    private var loaded = false
    private var lastReload = 0L
    // Why portraits can't be drawn (no imported archive), once the worker has said.
    private var portraitReason: String? = null
    private var problemShown: String? = null

    private lateinit var done: KPButton
    private lateinit var importButton: KPButton
    private lateinit var restart: KPButton
    private lateinit var discard: KPButton
    private lateinit var edit: KPButton
    private lateinit var use: KPButton
    private lateinit var actions: List<KPButton>
    private lateinit var gridGauge: KPButton
    private lateinit var licenseGauge: KPButton
    private var tiles: List<KPButton> = emptyList()
    private var orphanRows: List<KPButton> = emptyList()
    private var licenseRows: List<KPButton> = emptyList()
    private val grid = MiiList()
    private val licenseList = MiiList()
    private var grab = 0f
    // A run of moves up or down a list keeps to the column it started in, as the screens' own moves do.
    private var listMovedTo: KPButton? = null
    private var listColumn = Float.NaN

    // Laid out in layoutDesign, drawn in drawDesign.
    private var bannerText: String? = null
    private val banner = RectF()
    private val bannerTextRect = RectF()
    private val gridCard = RectF()
    private val detailCard = RectF()
    private val gridNote = RectF()
    private val portraitRect = RectF()
    private val nameRect = RectF()
    private val infoRect = RectF()
    private val chipRect = RectF()
    private val colorRect = RectF()
    private val problemRect = RectF()
    private val licensesRect = RectF()
    private val saveProblemRect = RectF()
    private val detailNoteRect = RectF()
    private var detailNote: String? = null

    companion object {
        private const val MaxMiis = 100
        private const val Columns = 5
        private const val TileGap = 12f
        private const val NameRoom = 30f
        private const val OrphanNote = "The game shows these as Player. Choose a Mii to repair one; its progress and friend code are kept."
        private val ColorNames = listOf("Red", "Orange", "Yellow", "Light green", "Green", "Blue", "Light blue", "Pink", "Purple",
            "Brown", "White", "Black")
        // Changes, reads and file copies, one at a time and never on the main thread.
        private val worker = Executors.newSingleThreadExecutor { task -> Thread(task, "KartPadMiis").apply { isDaemon = true } }
        private val main = Handler(Looper.getMainLooper())
        private val image = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)

        fun fileName(name: String): String {
            val clean = name.replace('/', '-').replace(':', '-').replace('\\', '-')
            return (clean.ifEmpty { "Mii" }) + ".mii"
        }

        fun slotName(slot: Int) = "Mii ${slot + 1}"

        fun colorName(index: Int) = ColorNames[if (index in ColorNames.indices) index else 0]

        /**
         * A Mii's head in a well that follows the theme (a lighter graphite in dark mode, so dark hair stands
         * out), or a head and shoulders in its favourite colour while the portrait renders or can't be.
         */
        internal fun drawPortrait(c: Canvas, context: Context, well: RectF, record: ByteArray, favorite: Int, ready: () -> Unit) {
            KP.fill(c, well, if (KP.dark) 0x48515a else KP.Light.well, well.width() * .08f)
            val portrait = MiiImages.portrait(context, record, ready)
            if (portrait != null) {
                val inset = well.width() * .06f
                c.drawBitmap(portrait, null, RectF(well.left + inset, well.top + inset, well.right - inset, well.bottom - inset), image)
                return
            }
            val s = well.width()
            val hex = KPMiiSource.favoriteHex(favorite)
            val head = RectF(well.centerX() - s * .2f, well.top + s * .18f, well.centerX() + s * .2f, well.top + s * .62f)
            val body = RectF(well.centerX() - s * .32f, well.top + s * .66f, well.centerX() + s * .32f, well.top + s * .9f)
            KP.fill(c, head, hex, s * .2f, .45f)
            KP.fill(c, body, hex, s * .1f, .3f)
            // An outline keeps white and light favourite colours visible on the light well.
            KP.stroke(c, head, 0x000000, 1f, s * .2f, .12f)
            KP.stroke(c, body, 0x000000, 1f, s * .1f, .1f)
        }
    }

    private val upcoming get() = snapshot as? KartPadMiiChanges.Upcoming
    private val miis: List<Mii> get() = upcoming?.miis.orEmpty()
    private val editable get() = upcoming?.canQueue == true
    private val selected: Mii? get() = miis.firstOrNull { it.slot == selectedSlot }
    private val waiting get() = upcoming?.pendingCount ?: waitingUnshown
    private val discardable get() = upcoming?.canDiscard ?: ((snapshot as? KartPadMiiChanges.Unavailable)?.offerDiscard == true)
    // On screen and not closed.
    private val alive get() = this in overlay.stack

    // License titles name their game only when licenses are in more than one.
    private fun licenseTitle(license: License): String {
        val number = "License ${license.slot + 1}"
        val games = upcoming?.licenses.orEmpty().map { it.profile }.toSet().size
        return if (games > 1) "${license.profileTitle} · $number" else number
    }

    private fun licenseName(license: License) = license.name.ifEmpty { "Unnamed" }

    private fun pendingNote(license: License): String? = when {
        license.pendingOperation == "delete" -> "Deletion pending"
        license.pendingOperation == "rename" -> "Rename pending"
        license.pendingOperation == "mii" -> "Mii change pending"
        license.missingLinkedMii -> "Its Mii is missing"
        else -> null
    }

    // Licenses another Mii (or none) races as, which this one can take over.
    private fun othersFor(mii: Mii) = upcoming?.licenses.orEmpty().filter { it.createId != mii.createId && it.pendingOperation != "delete" }

    // MARK: Building

    override fun build() {
        title = "Miis"
        solid = true
        done = button(RectF(), { c, r, state -> KPFaces.pill(c, r, state, KPStyle.Primary, KPUIGlyph.Check, "Done") }) { finish() }
        done.label = "Done"
        done.sound = null
        done.tagObject = "done"
        // Faded as a whole while it can't be used (the pill's face alone would fade by itself).
        importButton = button(RectF(), { c, r, state ->
            dimmed(c, r, state) { KPFaces.pill(c, r, state.copy(enabled = true), KPStyle.Plain, KPUIGlyph.Plus, "Import…") }
        }) { importMii() }
        importButton.label = "Import a Mii"
        importButton.tagObject = "import"
        restart = action("Restart", "restart", KPStyle.Plain) { KartPadScreens.host.restart(null) }
        discard = action("Discard", "discard", KPStyle.Plain) { discardPending() }
        discard.sound = null
        edit = action("Edit Mii", "edit", KPStyle.Primary) { selected?.let { editSlot(it.slot) } }
        edit.sound = null
        use = action("Use for a License…", "use", KPStyle.Plain) { selected?.let(::chooseLicenseFor) }
        use.sound = null
        actions = listOf(
            action("Rename…", "rename", KPStyle.Plain) { selected?.let(::rename) },
            action("Duplicate", "duplicate", KPStyle.Plain) { selected?.let(::duplicate) },
            action("Export…", "export", KPStyle.Plain) { selected?.let(::export) },
            action("Remove", "remove", KPStyle.Plain) { selected?.let(::remove) },
        )
        actions[0].sound = null
        actions[1].sound = null
        actions[3].sound = null
        gridGauge = gauge(grid)
        licenseGauge = gauge(licenseList)
    }

    private fun action(title: String, key: String, style: KPStyle, run: () -> Unit): KPButton {
        val button = button(RectF(), { c, r, state -> drawAction(c, r, state, style, title) }, run)
        button.label = title.removeSuffix("…")
        button.tagObject = key
        button.radius = 10f
        return button
    }

    // A list's scroll gauge: a finger drags its thumb, or takes it to where the track is touched. It never
    // has the focus (no action), and the focus follows into what shows.
    private fun gauge(list: MiiList): KPButton {
        val gauge = button(RectF(), { c, r, _ ->
            KP.fill(c, r, KP.p.buttonStroke, 4f, .45f)
            KP.fill(c, list.thumb(r), KP.p.accentBottom, 4f)
        }, null)
        gauge.margin = 14f
        gauge.focusScale = 1f
        gauge.sound = null
        gauge.slide = { _, y, face, began ->
            if (began) {
                val thumb = list.thumb(face)
                grab = if (y >= thumb.top && y <= thumb.bottom) y - thumb.top else thumb.height() / 2
            }
            if (list.drag(face, y, grab)) {
                layoutDesign()
                val focus = focus
                if (focus != null && focus.hidden && list.lineOf(focus) >= 0)
                    list.buttons().firstOrNull { !it.hidden && it.enabled }?.let { focusOn(it) }
            }
            true
        }
        return gauge
    }

    // The tiles, orphaned licenses and the selected Mii's licenses, from the data; the focus stays on
    // the same control (by its key) where it can.
    private fun rebuild() {
        val key = focus?.tagObject as? String
        for (item in tiles + orphanRows + licenseRows) remove(item)
        val up = upcoming
        tiles = if (up == null) emptyList() else miis.map(::tile) + newTile()
        orphanRows = up?.orphanedLicenses.orEmpty().map { licenseRow(it, "orphan") }
        rebuildLicenses()
        layoutDesign()
        val focus = focus
        if (key != null && (focus == null || focus !in items || focus.hidden || !focus.enabled)) refocus(key)
    }

    private fun rebuildLicenses() {
        for (item in licenseRows) remove(item)
        val mii = selected
        licenseRows = if (mii == null || upcoming?.saveProblem != null) emptyList() else mii.licenses.map { licenseRow(it, "license") }
    }

    private fun tile(mii: Mii): KPButton {
        val tile = button(RectF(), { c, r, state -> drawTile(c, r, state, mii) }, null)
        // A touch selects the Mii; A from a pad (or Return) opens it, as a double-click does on the Mac.
        tile.activate = { if (tile.clicked) selectSlot(mii.slot) else editSlot(mii.slot) }
        tile.sound = null
        tile.radius = 10f
        tile.focusScale = 1.03f
        tile.label = mii.name
        tile.tag2 = mii.slot
        tile.tagObject = "tile:${mii.slot}"
        return tile
    }

    private fun newTile(): KPButton {
        val tile = button(RectF(), { c, r, state -> drawNewTile(c, r, state) }) { createMii() }
        tile.sound = null
        tile.radius = 10f
        tile.focusScale = 1.03f
        tile.label = "New Mii"
        tile.tag2 = -1
        tile.tagObject = "new"
        tile.enabled = editable && miis.size < MaxMiis
        return tile
    }

    private fun licenseRow(license: License, kind: String): KPButton {
        val title = licenseTitle(license)
        val pending = pendingNote(license)
        val row = button(RectF(), { c, r, state -> drawLicense(c, r, state, license, title, pending) }) { licenseMenu(license, title) }
        row.sound = null
        row.radius = 10f
        row.focusScale = 1.02f
        row.label = "${licenseName(license)}, $title${if (pending != null) ", $pending" else ""}"
        row.tagObject = "$kind:${license.profile}:${license.slot}"
        return row
    }

    // MARK: Layout

    override fun layoutDesign() {
        if (!::done.isInitialized) return
        val s = safe
        val doneRect = RectF(s.right - 56 - 150, s.top + 30, s.right - 56, s.top + 90)
        place(done, doneRect)
        place(importButton, RectF(doneRect.left - 16 - 180, s.top + 30, doneRect.left - 16, s.top + 90))
        importButton.enabled = editable && miis.size < MaxMiis
        val top = layoutBanner(s.top + 130)
        val bottom = s.top + 650
        gridCard.set(s.left + 56, top, s.left + 56 + 676, bottom)
        detailCard.set(s.right - 56 - 468, top, s.right - 56, bottom)
        layoutGrid()
        layoutDetails()
        invalidate()
    }

    // The changes waiting for the next launch, or why the Miis can't be shown. Discard also comes with
    // the second, since a waiting change that no longer fits causes one.
    private fun layoutBanner(top: Float): Float {
        val text = bannerText()
        bannerText = text
        val restartShown = text != null && waiting > 0
        val discardShown = text != null && discardable
        restart.hidden = !restartShown
        discard.hidden = !discardShown
        if (text == null) {
            banner.setEmpty()
            return top
        }
        val s = safe
        val restartW = 143f
        val discardW = 125f
        val buttonH = 50f
        val textW = 1168 - 28 - (if (restartShown) restartW + 12 else 0f) - (if (discardShown) discardW + 12 else 0f)
        val line = 17f * 1.193f
        val lines = ceil(KP.textHeight(text, textW, 17f, KPWeight.Regular) / line - .01f).toInt().coerceIn(1, 3)
        val height = max(62f, lines * line + 22)
        banner.set(s.left + 56, top, s.right - 56, top + height)
        val textTop = banner.centerY() - lines * line / 2 - 1
        bannerTextRect.set(banner.left + 14, textTop, banner.left + 14 + textW, textTop + lines * line + 6)
        val buttonTop = banner.centerY() - buttonH / 2
        place(restart, RectF(banner.right - 14 - restartW, buttonTop, banner.right - 14, buttonTop + buttonH))
        val discardRight = banner.right - 14 - (if (restartShown) restartW + 12 else 0f)
        place(discard, RectF(discardRight - discardW, buttonTop, discardRight, buttonTop + buttonH))
        return top + height + 13
    }

    private fun bannerText(): String? {
        val snapshot = snapshot ?: return null
        if (snapshot is KartPadMiiChanges.Unavailable) return "The Miis can’t be shown. ${snapshot.reason}"
        val up = snapshot as KartPadMiiChanges.Upcoming
        if (up.pendingCount <= 0) return null
        val count = max(up.pendingCount, 1)
        val parts = ArrayList<String>()
        up.latestDescription?.let { parts += it }
        if (count > 1) parts += "$count changes are waiting for the next launch."
        else if (up.latestDescription == null) parts += "A change is waiting for the next launch."
        parts += if (count > 1) "Restart KartPad to apply them." else "Restart KartPad to apply it."
        if (!up.canQueue) parts += "Until then, Miis and licenses can’t be changed."
        return parts.joinToString(" ")
    }

    // Five tiles across, as many whole rows as the card holds (smaller tiles under a banner rather than
    // fewer rows), then the licenses whose Mii is missing.
    private fun layoutGrid() {
        val view = RectF(gridCard.left + 10, gridCard.top + 10, gridCard.right - 24, gridCard.bottom - 10)
        grid.view.set(view)
        gridNote.setEmpty()
        val lines = ArrayList<MiiList.Line>()
        if (snapshot is KartPadMiiChanges.Unavailable)
            gridNote.set(view.left + 6, view.top + 6, view.right - 6, view.top + 6 + 3 * 18f * 1.193f + 6)
        if (tiles.isNotEmpty()) {
            val widest = floor((view.width() - TileGap * (Columns - 1)) / Columns)
            val rows = max(1, Math.round((view.height() + TileGap) / (widest + NameRoom + TileGap)))
            val th = min(widest + NameRoom, floor((view.height() - TileGap * (rows - 1)) / rows))
            val tw = th - NameRoom
            val left = view.left + round((view.width() - (Columns * tw + (Columns - 1) * TileGap)) / 2)
            for (row in tiles.chunked(Columns))
                lines += MiiList.Line(th, TileGap, row.mapIndexed { i, tile ->
                    tile to RectF(left + i * (tw + TileGap), 0f, left + i * (tw + TileGap) + tw, th)
                })
        }
        if (orphanRows.isNotEmpty()) {
            // Mac: "Licenses without a Mii" and a note, above the rows.
            val noteLines = ceil(KP.textHeight(OrphanNote, view.width() - 8, 16f, KPWeight.Regular) / (16f * 1.193f) - .01f)
                .toInt().coerceIn(1, 3)
            val noteHeight = noteLines * 16f * 1.193f + 6
            lines += MiiList.Line(8 + 26 + 4 + noteHeight, 10f, emptyList()) { c, r ->
                KP.text(c, "Licenses without a Mii", RectF(r.left + 4, r.top + 8, r.right - 4, r.top + 32), 18f, KP.p.secondaryText,
                    KPWeight.Bold, KPAlign.Left)
                KP.text(c, OrphanNote, RectF(r.left + 4, r.top + 38, r.right - 4, r.top + 38 + noteHeight), 16f, KP.p.secondaryText,
                    KPWeight.Regular, KPAlign.Left)
            }
            for (row in orphanRows) lines += MiiList.Line(64f, 10f, listOf(row to RectF(view.left, 0f, view.right, 64f)))
        }
        grid.lines = lines
        grid.layout(this)
        place(gridGauge, RectF(gridCard.right - 18, view.top + 2, gridCard.right - 10, view.bottom - 2))
        gridGauge.hidden = !grid.overflows
    }

    // Portrait beside the name, slot and creator, favourite colour and Edit Mii; Use for a License… when
    // no license races as the Mii; Rename…, Duplicate, Export… and Remove; then its licenses.
    private fun layoutDetails() {
        val x0 = detailCard.left + 16
        val dw = detailCard.width() - 32
        val y0 = detailCard.top + 16
        for (rect in listOf(portraitRect, nameRect, infoRect, chipRect, colorRect, problemRect, licensesRect, saveProblemRect, detailNoteRect))
            rect.setEmpty()
        val mii = selected
        val details = listOf(edit, use) + actions
        if (mii == null) {
            for (button in details + licenseRows) button.hidden = true
            licenseList.lines = emptyList()
            licenseGauge.hidden = true
            problemShown = null
            detailNote = when {
                snapshot is KartPadMiiChanges.Unavailable -> "No Miis to show."
                snapshot == null -> null
                else -> "Choose a Mii."
            }
            if (detailNote != null) detailNoteRect.set(x0 + 2, y0 + 2, x0 + dw - 2, y0 + 30)
            return
        }
        detailNote = null
        val side = 156f
        portraitRect.set(x0, y0, x0 + side, y0 + side)
        val ix = x0 + side + 18
        val iw = dw - side - 18
        nameRect.set(ix, y0, ix + iw, y0 + 36)
        infoRect.set(ix, y0 + 40, ix + iw, y0 + 62)
        chipRect.set(ix, y0 + 70, ix + 22, y0 + 92)
        colorRect.set(ix + 30, y0 + 69, ix + iw, y0 + 93)
        var iy = y0 + 100
        val problem = portraitProblem(mii)
        problemShown = problem
        if (problem != null) {
            val lines = ceil(KP.textHeight(problem, iw, 14f, KPWeight.Regular) / (14f * 1.193f) - .01f).toInt().coerceIn(1, 3)
            problemRect.set(ix, iy, ix + iw, iy + lines * 14f * 1.193f + 6)
            iy = problemRect.bottom + 4
        }
        val editH = 58f
        val editY = max(y0 + side - editH, iy)
        place(edit, RectF(ix, editY, ix + iw, editY + editH))
        edit.enabled = editable
        var y = max(y0 + side, editY + editH) + 16
        val up = upcoming
        val linked = mii.licenses
        val useShown = linked.isEmpty() && up?.saveProblem == null && othersFor(mii).isNotEmpty()
        use.hidden = !useShown
        use.enabled = editable
        if (useShown) {
            place(use, RectF(x0, y, x0 + dw, y + 52))
            y += 52 + 10
        }
        // In one row when their titles fit, two by two otherwise.
        val gap = 10f
        val widest = listOf("Rename…", "Duplicate", "Export…", "Remove").maxOf { KP.textWidth(it, 18f, KPWeight.Semibold) }
        val across = if ((dw - 3 * gap) / 4 - 18 >= widest) 4 else 2
        val aw = (dw - (across - 1) * gap) / across
        actions.forEachIndexed { i, button ->
            val x = x0 + (i % across) * (aw + gap)
            val ay = y + (i / across) * (52 + gap)
            place(button, RectF(x, ay, x + aw, ay + 52))
            button.hidden = false
        }
        actions[0].enabled = editable
        actions[1].enabled = editable && miis.size < MaxMiis
        actions[2].enabled = true
        actions[3].enabled = editable
        edit.hidden = false
        y += (4 / across) * (52 + gap) - gap + 18
        // Licenses that race as the Mii: one to a row, or two when that would run past the bottom.
        val saveProblem = up?.saveProblem
        val lines = ArrayList<MiiList.Line>()
        if (saveProblem != null || licenseRows.isNotEmpty()) {
            licensesRect.set(x0 + 2, y, x0 + dw - 2, y + 28)
            y += 36
        }
        if (saveProblem != null) {
            saveProblemRect.set(x0 + 2, y, x0 + dw - 2, y + 3 * 16f * 1.193f + 6)
        } else if (licenseRows.isNotEmpty()) {
            val cellH = 62f
            val room = detailCard.bottom - 12 - y
            val columns = if (licenseRows.size > 1 && licenseRows.size * (cellH + gap) - gap > room) 2 else 1
            val cw = (dw - (columns - 1) * gap) / columns
            for (row in licenseRows.chunked(columns))
                lines += MiiList.Line(cellH, gap, row.mapIndexed { i, button ->
                    button to RectF(x0 + i * (cw + gap), 0f, x0 + i * (cw + gap) + cw, cellH)
                })
        }
        licenseList.view.set(x0, y, x0 + dw, detailCard.bottom - 12)
        licenseList.lines = lines
        licenseList.layout(this)
        place(licenseGauge, RectF(detailCard.right - 12, y + 2, detailCard.right - 6, detailCard.bottom - 14))
        licenseGauge.hidden = !licenseList.overflows
    }

    private fun portraitProblem(mii: Mii): String? {
        if (MiiImages.cachedPortrait(mii.record) != null) return null
        val reason = MiiImages.portraitProblem ?: portraitReason ?: return null
        return "Portraits unavailable: $reason"
    }

    // MARK: Appearing, reading, focus

    override fun initialFocus(): KPButton? =
        tiles.firstOrNull { it.tag2 == selectedSlot && !it.hidden } ?: tiles.firstOrNull { !it.hidden && it.enabled } ?: done

    override fun willAppear() {
        if (!opened) {
            opened = true
            // HOME is under it; opening from nothing, the screens play it themselves.
            if (overlay.stack.size > 1) overlay.play(KPUISound.Open)
            MiiImages.requestUnavailableReason(context) { reason ->
                portraitReason = reason
                checkProblem()
            }
        }
        reload()
    }

    override fun tick() {
        // The game writes its saves meanwhile; a read that finds nothing changed costs next to nothing
        // (the queue's replay is kept until a file changes) and redraws nothing.
        val now = SystemClock.uptimeMillis()
        if (now - lastReload < 1000 || busy || overlay.top !== this) return
        reload()
    }

    private fun read(files: File): Pair<KartPadMiiChanges.Snapshot, Int> {
        val snapshot = KartPadMiiChanges.upcoming(files)
        return snapshot to (if (snapshot is KartPadMiiChanges.Unavailable) KartPadMiiChanges.pendingCount(files) else 0)
    }

    /** Reads the Miis again; select picks the Mii to show from the new list (null keeps the selection). */
    private fun reload(select: ((List<Mii>) -> Int?)? = null) {
        lastReload = SystemClock.uptimeMillis()
        val files = files
        worker.execute {
            val (next, waiting) = read(files)
            main.post {
                apply(next, waiting)
                select?.invoke(miis)?.let(::showSlot)
            }
        }
    }

    private fun apply(next: KartPadMiiChanges.Snapshot, waiting: Int) {
        val changed = !loaded || next != snapshot || waiting != waitingUnshown
        snapshot = next
        waitingUnshown = waiting
        if (selected == null) selectedSlot = miis.firstOrNull()?.slot ?: -1
        if (!changed) return
        rebuild()
        // The first read: the ring starts on the selected Mii, as HOME → Miis does on the Mac.
        if (!loaded) {
            loaded = true
            tiles.firstOrNull { it.tag2 == selectedSlot }?.let {
                grid.reveal(grid.lineOf(it))
                layoutDesign()
                if (focus == null || focus === done) focusOn(it)
            }
        }
    }

    // A portrait came in (or failed): the details say why there are none, once that is known.
    private fun checkProblem() {
        val mii = selected
        if ((if (mii == null) null else portraitProblem(mii)) != problemShown) layoutDesign()
        invalidate()
    }

    private fun focusOn(button: KPButton) {
        if (overlay.top === this) {
            overlay.focus(button, false)
            return
        }
        // Under a dialog: the ring is back on it when the dialog goes.
        focus?.let { if (it !== button) it.focused = false }
        focus = button
        button.focused = true
    }

    private fun refocus(key: String) {
        val buttons = items.filterIsInstance<KPButton>()
        val target = buttons.firstOrNull { it.tagObject == key && it.enabled && it.activate != null }
            ?: (if (key.startsWith("license:")) licenseRows.firstOrNull() ?: edit.takeIf { !it.hidden } else null)
            ?: (if (key.startsWith("orphan:")) orphanRows.firstOrNull() else null)
            ?: tiles.firstOrNull { it.tag2 == selectedSlot }
            ?: initialFocus()
            ?: return
        reveal(target)
        focusOn(target)
    }

    private fun reveal(button: KPButton) {
        for (list in listOf(grid, licenseList)) {
            val line = list.lineOf(button)
            if (line >= 0 && button.hidden) {
                list.reveal(line)
                layoutDesign()
            }
        }
    }

    // MARK: Selection and presses

    private fun selectSlot(slot: Int) {
        overlay.play(if (slot == selectedSlot) KPUISound.Same else KPUISound.Tab)
        showSlot(slot)
    }

    private fun showSlot(slot: Int) {
        if (miis.none { it.slot == slot }) return
        if (slot != selectedSlot) {
            selectedSlot = slot
            val key = focus?.tagObject as? String
            rebuildLicenses()
            layoutDesign()
            if (key != null && key.startsWith("license:")) refocus(key)
        }
        tiles.firstOrNull { it.tag2 == slot }?.let(::reveal)
        invalidate()
    }

    private fun finish() = overlay.pop()

    override fun handle(button: KPPad): Boolean {
        val (dx, dy) = when (button) {
            KPPad.Up -> 0 to -1
            KPPad.Down -> 0 to 1
            KPPad.Left -> -1 to 0
            KPPad.Right -> 1 to 0
            KPPad.Start -> {
                finish()
                return true
            }
            else -> return false
        }
        // Up and down stay within a list first, so rows scrolled out of sight are reached one by one.
        val focus = focus
        val list = listOf(grid, licenseList).firstOrNull { focus != null && it.lineOf(focus) >= 0 }
        if (!(dy != 0 && list != null && focus != null && moveInList(list, focus, dy))) overlay.move(dx, dy)
        // Moving onto a Mii selects it, so the details follow the ring.
        val now = this.focus
        if (now != null && now in tiles && now.tag2 >= 0 && now.tag2 != selectedSlot) selectSlot(now.tag2)
        return true
    }

    private fun moveInList(list: MiiList, focus: KPButton, dy: Int): Boolean {
        val buttons = list.buttons().filter { it.enabled && it.activate != null }
        val from = buttons.indexOf(focus)
        if (from < 0) return false
        val column = if (focus === listMovedTo && !listColumn.isNaN()) listColumn else focus.frame.centerX()
        val next = KPNavigation.nearest(buttons.map { list.contentFrame(it) ?: RectF() }, from, 0, dy, column)
        if (next < 0) return false
        val target = buttons[next]
        if (target.hidden) {
            list.reveal(list.lineOf(target))
            layoutDesign()
        }
        overlay.focus(target, true)
        listMovedTo = target
        listColumn = column
        return true
    }

    // A hardware keyboard's Delete removes the selected Mii, as on the Mac (the screens take it for Back).
    override fun takesKey(event: KeyEvent): Boolean {
        if (event.keyCode != KeyEvent.KEYCODE_DEL && event.keyCode != KeyEvent.KEYCODE_FORWARD_DEL) return false
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) selected?.let(::remove)
        return true
    }

    // MARK: Questions

    private fun tell(heading: String, message: String) {
        if (!alive) return
        KPAsk.ask(overlay, heading, message, listOf("OK"), 0, -1) {}
        overlay.play(KPUISound.Reject)
    }

    // As iPhone alerts: a destructive action is red and Cancel is the default.
    private fun confirm(heading: String, message: String, action: String, destructive: Boolean, then: () -> Unit) {
        KPAsk.ask(overlay, heading, message, listOf(action, "Cancel"), if (destructive) 1 else 0, if (destructive) 0 else -1) { choice ->
            if (choice == 0) then()
        }
    }

    // A pending ghost import or save restore (or an interrupted change) waits alone; nothing can be queued.
    private fun blocked(): Boolean {
        if (editable) return false
        val up = upcoming
        if (up == null) {
            val reason = (snapshot as? KartPadMiiChanges.Unavailable)?.reason ?: "The Mii database couldn’t be read."
            tell("Miis Unavailable", reason)
        } else tell("Restart KartPad First", up.blockedReason ?: "Restart KartPad to apply the waiting change first.")
        return true
    }

    /**
     * Queues a change on the worker, then reloads and selects the Mii it concerns: select, or else the Mii
     * that wasn't there before (an import). Problems are told with failure as the title.
     */
    private fun change(failure: String, select: Int? = null, work: (File) -> Result<String>) {
        if (busy) return
        busy = true
        val before = miis.map { it.slot to it.createId }.toSet()
        val files = files
        worker.execute {
            val result = work(files)
            val (next, waiting) = read(files)
            main.post {
                busy = false
                apply(next, waiting)
                val problem = result.exceptionOrNull()
                if (problem != null) {
                    tell(failure, problem.message ?: failure)
                    return@post
                }
                if (alive) overlay.play(KPUISound.Saved)
                (select ?: miis.firstOrNull { (it.slot to it.createId) !in before }?.slot)?.let(::showSlot)
                KPMiiSource.refresh(context)
            }
        }
    }

    // Drops every waiting Mii and license change after a confirmation. Nothing live has changed yet.
    private fun discardPending() {
        val count = max(waiting, 1)
        val heading = if (count > 1) "Discard $count Waiting Changes?" else "Discard the Waiting Change?"
        confirm(heading, "Miis and licenses stay as they are now. This can’t be undone.", "Discard", true) {
            if (busy) return@confirm
            busy = true
            val files = files
            worker.execute {
                val result = KartPadMiiChanges.discardAll(files)
                val (next, waiting) = read(files)
                main.post {
                    busy = false
                    apply(next, waiting)
                    val problem = result.exceptionOrNull()
                    if (problem != null) tell("Changes Couldn’t Be Discarded", problem.message ?: "The waiting changes couldn’t be discarded.")
                    else if (alive) overlay.play(KPUISound.Close)
                    KPMiiSource.refresh(context)
                }
            }
        }
    }

    // MARK: Mii actions

    private fun openEditor(mii: Mii?, copy: ByteArray?) {
        val before = miis.map { it.slot to it.createId }.toSet()
        val slot = mii?.slot
        overlay.present(MiiEditorScreen(overlay, mii, copy) { saved ->
            // The edited Mii, or the one that wasn't there before (a new Mii or a duplicate).
            if (saved) reload { list -> slot ?: list.firstOrNull { (it.slot to it.createId) !in before }?.slot }
        })
    }

    private fun createMii() {
        if (blocked()) return
        openEditor(null, null)
    }

    private fun editSlot(slot: Int) {
        val mii = miis.firstOrNull { it.slot == slot } ?: return
        if (blocked()) return
        if (slot != selectedSlot) selectSlot(slot)
        openEditor(mii, null)
    }

    private fun rename(mii: Mii) {
        if (blocked()) return
        MiiNameEntry.ask(overlay, "Rename “${mii.name}”", "Licenses that race as this Mii get the new name too.", mii.name, false,
            "Rename") { name ->
            if (name != null) change("Mii Couldn’t Be Renamed") { KartPadMiiChanges.renameMii(it, mii.createId, name) }
        }
    }

    // The editor opens on a copy with a fresh Mii ID and this console's ID, saved as a new Mii.
    private fun duplicate(mii: Mii) {
        if (blocked() || busy) return
        busy = true
        val files = files
        worker.execute {
            val result = KartPadMiiChanges.duplicate(files, mii.createId)
            main.post {
                busy = false
                val copy = result.getOrNull()
                if (copy == null) tell("Mii Couldn’t Be Duplicated", result.exceptionOrNull()?.message ?: "The Mii couldn’t be duplicated.")
                else if (alive) openEditor(null, copy)
            }
        }
    }

    private fun remove(mii: Mii) {
        if (blocked()) return
        val linked = mii.licenses.size
        if (miis.size <= 1) {
            tell("This Mii Can’t Be Removed", "KartPad always keeps at least one Mii.")
            return
        }
        if (linked > 0) {
            val one = linked == 1
            tell("“${mii.name}” Is in Use", "${if (one) "A license races" else "$linked licenses race"} as this Mii. " +
                "Delete ${if (one) "that license" else "those licenses"}, or move ${if (one) "it" else "them"} to another Mii " +
                "with Use for a License…, then remove this Mii.")
            return
        }
        confirm("Remove “${mii.name}”?", "The Mii is removed the next time KartPad opens. The current Mii database is backed up first.",
            "Remove", true) {
            // The next Mii takes the selection (the previous one for the last), not the first.
            val index = miis.indexOfFirst { it.slot == mii.slot }
            val next = (miis.getOrNull(index + 1) ?: miis.getOrNull(index - 1))?.slot
            change("Mii Couldn’t Be Removed", next) { KartPadMiiChanges.removeMii(it, mii.createId) }
        }
    }

    // A standard 74-byte .mii, named after the Mii, wherever Android's file picker saves it.
    private fun export(mii: Mii) {
        val files = files
        worker.execute {
            val result = KartPadMiiChanges.exportMii(files, mii.createId)
            main.post {
                val bytes = result.getOrNull()
                if (bytes == null) {
                    tell("Mii Couldn’t Be Exported", result.exceptionOrNull()?.message ?: "The Mii couldn’t be exported.")
                    return@post
                }
                if (!alive) return@post
                KartPadScreens.host.pickDocument(true, fileName(mii.name), "application/octet-stream") { uri ->
                    if (uri == null) {
                        overlay.play(KPUISound.Close)
                        return@pickDocument
                    }
                    worker.execute {
                        val written = runCatching {
                            val stream = context.contentResolver.openOutputStream(uri, "w") ?: error("The file couldn’t be written.")
                            stream.use { it.write(bytes) }
                        }
                        main.post {
                            if (written.isSuccess) overlay.play(KPUISound.Saved)
                            else tell("Mii Couldn’t Be Exported", written.exceptionOrNull()?.message ?: "The file couldn’t be written.")
                        }
                    }
                }
            }
        }
    }

    private fun importMii() {
        if (blocked()) return
        KartPadScreens.host.pickDocument(false, null, "*/*") { uri ->
            if (uri == null) {
                overlay.play(KPUISound.Close)
                return@pickDocument
            }
            change("Mii Couldn’t Be Imported") { files -> KartPadMiiChanges.importMii(files, readDocument(uri)) }
        }
    }

    // Up to 4 KB; anything larger reads as empty, which the import then refuses.
    private fun readDocument(uri: Uri): ByteArray = runCatching {
        val stream = context.contentResolver.openInputStream(uri) ?: return@runCatching ByteArray(0)
        stream.use { input ->
            val buffer = ByteArray(4097)
            var count = 0
            while (count < buffer.size) {
                val read = input.read(buffer, count, buffer.size - count)
                if (read < 0) break
                count += read
            }
            if (count > 4096) ByteArray(0) else buffer.copyOf(count)
        }
    }.getOrDefault(ByteArray(0))

    // MARK: License actions

    private fun licenseMenu(license: License, title: String) {
        val up = upcoming
        val can = editable && up?.saveProblem == null && license.pendingOperation != "delete"
        val missing = license.missingLinkedMii
        val menu = KPMenuScreen(overlay)
        menu.heading = licenseName(license)
        menu.message = pendingNote(license)?.let { "$title · $it" } ?: title
        menu.add(if (missing) "Choose Mii…" else "Change Mii…", glyph = KPUIGlyph.Mii, enabled = can && (missing || miis.size > 1)) {
            chooseMiiForLicense(license)
        }
        if (!missing) menu.add("Rename License…", glyph = KPUIGlyph.Keyboard, enabled = can) { renameLicense(license) }
        menu.add("Delete License", glyph = KPUIGlyph.Close, enabled = can) { deleteLicense(license) }
        overlay.present(menu)
    }

    private fun renameLicense(license: License) {
        if (blocked()) return
        val title = licenseTitle(license)
        MiiNameEntry.ask(overlay, "Rename License", "$title. The license keeps its friend code, online account, records and progress.",
            license.name, false, "Rename") { name ->
            if (name != null) change("License Couldn’t Be Renamed") {
                KartPadMiiChanges.renameLicense(it, license.profile, license.slot, license.createId, name)
            }
        }
    }

    private fun deleteLicense(license: License) {
        if (blocked()) return
        val title = licenseTitle(license)
        confirm("Delete “${licenseName(license)}” from $title?",
            "This permanently removes the license’s friend code, online account data, records and progress. Its Mii stays. " +
                "The save is backed up first.", "Delete License", true) {
            change("License Couldn’t Be Deleted") { KartPadMiiChanges.deleteLicense(it, license.profile, license.slot, license.createId) }
        }
    }

    private fun link(license: License, mii: Mii) {
        val title = licenseTitle(license)
        confirm("Race as “${mii.name}”?",
            "$title (“${licenseName(license)}”) will use this Mii’s name and appearance. Its progress and friend code are kept.",
            "Use This Mii", false) {
            change("Mii Couldn’t Be Linked") { KartPadMiiChanges.setLicenseMii(it, license.profile, license.slot, license.createId, mii.createId) }
        }
    }

    private fun chooseLicenseFor(mii: Mii) {
        if (blocked()) return
        val others = othersFor(mii)
        val choices = others.map { license ->
            val racer = miis.firstOrNull { it.slot == license.miiSlot }
            MiiChoice(licenseName(license), pendingNote(license)?.let { "${licenseTitle(license)} · $it" } ?: licenseTitle(license),
                racer?.record, racer?.favoriteColor ?: 0)
        }
        overlay.present(MiiChoiceScreen(overlay, "Choose a License to Race As “${mii.name}”", choices) { link(others[it], mii) })
    }

    private fun chooseMiiForLicense(license: License) {
        if (blocked()) return
        val candidates = miis.filter { it.createId != license.createId }
        val choices = candidates.map { MiiChoice(it.name, slotName(it.slot), it.record, it.favoriteColor) }
        overlay.present(MiiChoiceScreen(overlay, "Choose a Mii for ${licenseTitle(license)}", choices) { link(license, candidates[it]) })
    }

    // MARK: Drawing

    // Disabled controls fade, text and all (the face fades itself).
    private fun dimmed(c: Canvas, r: RectF, state: KPUIState, draw: () -> Unit) {
        val saved = if (state.enabled) c.save() else c.saveLayerAlpha(r.left - 4, r.top - 4, r.right + 4, r.bottom + 4, 107)
        draw()
        c.restoreToCount(saved)
    }

    private fun drawAction(c: Canvas, r: RectF, state: KPUIState, style: KPStyle, title: String) {
        KP.buttonFace(c, r, style, false, state.enabled, state.pressed, state.focused)
        val dy = if (state.pressed) 2f else 0f
        val face = RectF(r.left + 8, r.top + dy, r.right - 8, r.bottom - 3 + dy)
        KP.text(c, title, RectF(face.left, face.centerY() - 18 * .66f, face.right, face.centerY() - 18 * .66f + 27), 18f,
            if (style == KPStyle.Primary) 0xffffff else KP.p.text, KPWeight.Semibold, KPAlign.Center, if (state.enabled) 1f else .42f)
    }

    private fun drawTile(c: Canvas, r: RectF, state: KPUIState, mii: Mii) {
        KP.buttonFace(c, r, KPStyle.Tile, mii.slot == selectedSlot, true, state.pressed, state.focused)
        val dy = if (state.pressed) 2f else 0f
        val side = r.width() - 20
        val well = RectF(r.left + 10, r.top + 10 + dy, r.left + 10 + side, r.top + 10 + side + dy)
        drawPortrait(c, context, well, mii.record, mii.favoriteColor) { portraitReady() }
        val dot = RectF(well.left + 7, well.top + 7, well.left + 22, well.top + 22)
        KP.fill(c, dot, KPMiiSource.favoriteHex(mii.favoriteColor), 7.5f)
        KP.stroke(c, dot, 0xffffff, 1.5f, 7.5f, .9f)
        KP.text(c, mii.name, RectF(r.left + 5, well.bottom + 3, r.right - 5, well.bottom + 25), 17f, KP.p.text, KPWeight.Semibold)
    }

    private fun drawNewTile(c: Canvas, r: RectF, state: KPUIState) {
        KP.buttonFace(c, r, KPStyle.Tile, false, state.enabled, state.pressed, state.focused)
        dimmed(c, r, state) {
            val dy = if (state.pressed) 2f else 0f
            val side = r.width() - 20
            val arm = side * .3f
            val bar = max(5f, side * .07f)
            val x = r.centerX()
            val y = r.top + 10 + side / 2 + dy
            KP.fill(c, RectF(x - arm, y - bar / 2, x + arm, y + bar / 2), KP.p.icon, bar / 2)
            KP.fill(c, RectF(x - bar / 2, y - arm, x + bar / 2, y + arm), KP.p.icon, bar / 2)
            KP.text(c, "New Mii", RectF(r.left + 5, r.top + 10 + side + 3 + dy, r.right - 5, r.top + 10 + side + 25 + dy), 17f, KP.p.text,
                KPWeight.Semibold)
        }
    }

    // Two lines, and the ⋯ mark when the row is wide enough to spare it.
    private fun drawLicense(c: Canvas, r: RectF, state: KPUIState, license: License, title: String, pending: String?) {
        KP.buttonFace(c, r, KPStyle.Plain, false, true, state.pressed, state.focused)
        val dy = if (state.pressed) 2f else 0f
        val more = r.width() >= 338
        val x = r.left + 17
        val textW = r.width() - (if (more) 78 else 34)
        val y = r.top + (r.height() - 3 - 52) / 2 + dy
        KP.text(c, licenseName(license), RectF(x, y + 1, x + textW, y + 29), 20f, KP.p.text, KPWeight.Semibold, KPAlign.Left)
        KP.text(c, if (pending != null) "$title · $pending" else title, RectF(x, y + 29, x + textW, y + 52), 16f,
            if (pending != null) KP.p.cautionInk else KP.p.secondaryText, KPWeight.Regular, KPAlign.Left)
        if (more) KP.controlIcon(c, RectF(r.right - 52, r.top + (r.height() - 3 - 34) / 2 + dy, r.right - 18,
            r.top + (r.height() - 3 + 34) / 2 + dy), KP.Glyph.More, 0, KP.p.icon)
    }

    private fun portraitReady() {
        invalidate()
        checkProblem()
    }

    override fun drawDesign(c: Canvas) {
        super.drawDesign(c)
        val s = safe
        // The header as on KartPad's other screens: a bold title with the count under it.
        KP.text(c, "Miis", RectF(s.left + 56, s.top + 26, s.left + 696, s.top + 76), 36f, KP.p.text, KPWeight.Bold, KPAlign.Left)
        if (upcoming != null)
            KP.text(c, "${miis.size} of $MaxMiis", RectF(s.left + 58, s.top + 76, s.left + 698, s.top + 102), 18f, KP.p.secondaryText,
                KPWeight.Medium, KPAlign.Left)
        val text = bannerText
        if (text != null && !banner.isEmpty) {
            KP.fill(c, banner, KP.p.caution, 10f, .18f)
            KP.stroke(c, banner, KP.p.cautionInk, 1f, 10f, .5f)
            KP.text(c, text, bannerTextRect, 17f, KP.p.text, KPWeight.Regular, KPAlign.Left)
        }
        if (snapshot != null) {
            KP.card(c, gridCard)
            KP.card(c, detailCard)
        }
        if (!gridNote.isEmpty)
            KP.text(c, "Start the game once to create the Mii database, then open this screen again.", gridNote, 18f, KP.p.secondaryText,
                KPWeight.Regular, KPAlign.Left)
        for (line in grid.lines) if (line.visible) line.paint?.invoke(c, line.shown)
        drawDetails(c)
        KPHints.draw(c, RectF(s.left + 56, s.top + 670, s.left + 1224, s.top + 696),
            listOf(KPHint(KPPad.Confirm, "Select"), KPHint(KPPad.Back, "Back")), 16f, KPAlign.Right)
    }

    private fun drawDetails(c: Canvas) {
        detailNote?.let { KP.text(c, it, detailNoteRect, 19f, KP.p.secondaryText, KPWeight.Regular, KPAlign.Left) }
        val mii = selected ?: return
        if (portraitRect.isEmpty) return
        drawPortrait(c, context, portraitRect, mii.record, mii.favoriteColor) { portraitReady() }
        KP.text(c, mii.name, nameRect, 28f, KP.p.text, KPWeight.Bold, KPAlign.Left)
        KP.text(c, if (mii.creator.isEmpty()) slotName(mii.slot) else "${slotName(mii.slot)} · Created by ${mii.creator}", infoRect, 17f,
            KP.p.secondaryText, KPWeight.Regular, KPAlign.Left)
        KP.fill(c, chipRect, KPMiiSource.favoriteHex(mii.favoriteColor), 6.5f)
        KP.stroke(c, chipRect, 0x000000, 1f, 6.5f, .18f)
        KP.text(c, colorName(mii.favoriteColor), colorRect, 17f, KP.p.text, KPWeight.Regular, KPAlign.Left)
        problemShown?.let { if (!problemRect.isEmpty) KP.text(c, it, problemRect, 14f, KP.p.secondaryText, KPWeight.Regular, KPAlign.Left) }
        if (!licensesRect.isEmpty) KP.text(c, "Licenses", licensesRect, 20f, KP.p.text, KPWeight.Bold, KPAlign.Left)
        upcoming?.saveProblem?.let {
            if (!saveProblemRect.isEmpty) KP.text(c, it, saveProblemRect, 16f, KP.p.secondaryText, KPWeight.Regular, KPAlign.Left)
        }
    }
}

/**
 * A column of lines in a card, scrolled a line at a time (the Mac's lists keep the focus within them):
 * lines that don't fit whole are hidden, and a gauge beside it shows (and drags) where it is.
 */
private class MiiList {
    /** One line: its height, the gap after it, its buttons (x as placed, y from the line's top) and any drawing. */
    class Line(val height: Float, val gap: Float, val buttons: List<Pair<KPButton, RectF>>, val paint: ((Canvas, RectF) -> Unit)? = null) {
        val shown = RectF()
        var visible = false
    }

    var lines: List<Line> = emptyList()
    var first = 0
    val view = RectF()

    // The last line that shows whole when start is the first.
    private fun lastFrom(start: Int): Int {
        var y = 0f
        var last = start - 1
        for (i in start until lines.size) {
            if (y + lines[i].height > view.height() + .5f) break
            last = i
            y += lines[i].height + lines[i].gap
        }
        return last
    }

    private val maxFirst: Int get() {
        var start = lines.size - 1
        while (start > 0 && lastFrom(start - 1) == lines.size - 1) start--
        return max(0, start)
    }

    val overflows get() = lines.isNotEmpty() && (first > 0 || lastFrom(first) < lines.size - 1)

    fun layout(screen: KPScreen) {
        first = first.coerceIn(0, maxFirst)
        val last = lastFrom(first)
        var y = view.top
        for ((i, line) in lines.withIndex()) {
            line.visible = i in first..last
            line.shown.set(view.left, y, view.right, y + line.height)
            for ((button, r) in line.buttons) {
                screen.place(button, RectF(r.left, y + r.top, r.right, y + r.bottom))
                button.hidden = !line.visible
            }
            if (line.visible) y += line.height + line.gap
        }
    }

    fun lineOf(button: KPButton) = lines.indexOfFirst { line -> line.buttons.any { it.first === button } }

    fun buttons(): List<KPButton> = lines.flatMap { line -> line.buttons.map { it.first } }

    fun reveal(index: Int) {
        if (index < 0) return
        if (index < first) first = index
        while (first < index && lastFrom(first) < index) first++
    }

    private fun offset(index: Int): Float {
        var y = 0f
        for (i in 0 until min(index, lines.size)) y += lines[i].height + lines[i].gap
        return y
    }

    /** Where a button sits in the whole list, as if nothing were scrolled away. */
    fun contentFrame(button: KPButton): RectF? {
        val index = lineOf(button)
        if (index < 0) return null
        val r = lines[index].buttons.first { it.first === button }.second
        val y = offset(index)
        return RectF(r.left, y + r.top, r.right, y + r.bottom)
    }

    fun thumb(track: RectF): RectF {
        val total = max(1f, offset(lines.size))
        val top = offset(first) / total
        val bottom = min(1f, (offset(lastFrom(first) + 1)) / total)
        return RectF(track.left, track.top + track.height() * top, track.right, track.top + track.height() * max(bottom, top + .05f))
    }

    /** Scrolls to the line under a finger on the gauge; true when it moved. */
    fun drag(track: RectF, y: Float, grab: Float): Boolean {
        val at = (y - grab - track.top) / track.height() * offset(lines.size)
        var index = 0
        while (index < lines.size - 1 && offset(index) + (lines[index].height + lines[index].gap) / 2 < at) index++
        val next = index.coerceIn(0, maxFirst)
        if (next == first) return false
        first = next
        return true
    }
}

private class MiiChoice(val title: String, val detail: String?, val record: ByteArray?, val favorite: Int)

/**
 * A choice of Mii or license over the Miis screen (the Mac's pop-up menus), with portraits: six rows at a
 * time, up and down scrolling past the ends, a gauge for a finger. A picks, B closes.
 */
private class MiiChoiceScreen(
    overlay: KPOverlay, private val heading: String, private val choices: List<MiiChoice>, private val pick: (Int) -> Unit,
) : KPScreen(overlay) {
    override val overPrevious get() = true
    private val rows = ArrayList<KPButton>()
    private var first = 0
    private var grab = 0f
    private lateinit var gauge: KPButton
    private val shown get() = min(choices.size, Visible)
    private val overflows get() = choices.size > Visible
    // Rows line up when some choices have a Mii and some don't (a license whose Mii is missing).
    private val portraits = choices.any { it.record != null }

    companion object {
        const val Visible = 6
    }

    private fun card(): RectF {
        val s = safe
        val height = 96 + 76f * max(1, shown) + 18
        val top = round(s.top + (720 - height) / 2)
        return RectF(s.left + 290, top, s.left + 990, top + height)
    }

    private fun track(): RectF {
        val card = card()
        return RectF(card.right - 24, card.top + 96, card.right - 16, card.top + 96 + 76 * shown - 10)
    }

    private fun thumb(): RectF {
        val track = track()
        val count = max(1, choices.size).toFloat()
        val top = track.top + track.height() * first / count
        return RectF(track.left, top, track.right, top + track.height() * min(1f, Visible / count))
    }

    override fun build() {
        for (i in 0 until shown) {
            val row = button(RectF(), { c, r, state -> drawRow(c, r, state, choices[min(first + i, choices.size - 1)]) }) {
                overlay.pop()
                pick(first + i)
            }
            row.tag2 = i
            row.sound = KPUISound.Confirm
            rows += row
        }
        gauge = button(RectF(), { c, _, _ ->
            KP.fill(c, track(), KP.p.buttonStroke, 4f, .45f)
            KP.fill(c, thumb(), KP.p.accentBottom, 4f)
        }, null)
        gauge.margin = 14f
        gauge.focusScale = 1f
        gauge.sound = null
        gauge.slide = { _, y, _, began ->
            if (began) {
                val thumb = thumb()
                grab = if (y >= thumb.top && y <= thumb.bottom) y - thumb.top else thumb.height() / 2
            }
            val track = track()
            val next = Math.round((y - grab - track.top) / track.height() * choices.size).coerceIn(0, max(0, choices.size - Visible))
            if (next != first) {
                first = next
                layoutDesign()
            }
            true
        }
    }

    override fun layoutDesign() {
        val card = card()
        val top = card.top + 96
        for (row in rows) {
            place(row, RectF(card.left + 28, top + row.tag2 * 76, card.right - (if (overflows) 44 else 28), top + row.tag2 * 76 + 66))
            row.label = choices.getOrNull(first + row.tag2)?.title
        }
        place(gauge, track())
        gauge.hidden = !overflows
        invalidate()
    }

    override fun initialFocus(): KPButton? = rows.firstOrNull()

    override fun willAppear() {
        overlay.play(KPUISound.Dialog)
    }

    override fun handle(button: KPPad): Boolean {
        val row = focus?.takeIf { it in rows } ?: return false
        if (button != KPPad.Up && button != KPPad.Down) return false
        val next = first + row.tag2 + if (button == KPPad.Down) 1 else -1
        if (next < 0 || next >= choices.size) {
            overlay.play(KPUISound.Same)
            return true
        }
        if (next < first) first = next
        if (next >= first + shown) first = next - shown + 1
        layoutDesign()
        val target = rows[next - first]
        if (target === focus) overlay.play(KPUISound.Hover) else overlay.focus(target, true)
        return true
    }

    private fun drawRow(c: Canvas, r: RectF, state: KPUIState, choice: MiiChoice) {
        KP.buttonFace(c, r, KPStyle.Plain, false, state.enabled, state.pressed, state.focused)
        val dy = if (state.pressed) 2f else 0f
        val x = if (portraits) r.left + 80 else r.left + 22
        if (portraits) {
            val well = RectF(r.left + 14, r.centerY() - 26 + dy, r.left + 66, r.centerY() + 26 + dy)
            val record = choice.record
            if (record != null) MiisScreen.drawPortrait(c, overlay.activity, well, record, choice.favorite) { invalidate() }
            else KP.fill(c, well, KP.p.well, well.width() * .08f)
        }
        val detail = choice.detail
        if (!detail.isNullOrEmpty()) {
            KP.text(c, choice.title, RectF(x, r.top + 9 + dy, r.right - 16, r.top + 37 + dy), 21f, KP.p.text, KPWeight.Semibold, KPAlign.Left)
            KP.text(c, detail, RectF(x, r.top + 36 + dy, r.right - 16, r.top + 58 + dy), 15f, KP.p.secondaryText, KPWeight.Regular, KPAlign.Left)
        } else {
            KP.text(c, choice.title, RectF(x, r.centerY() - 15 + dy, r.right - 16, r.centerY() + 15 + dy), 21f, KP.p.text, KPWeight.Semibold,
                KPAlign.Left)
        }
    }

    override fun drawDesign(c: Canvas) {
        KP.fill(c, RectF(0f, 0f, width, height), 0x000000, 0f, .35f)
        val card = card()
        KP.shadowed(c, 10f, 30f, .35f, card, KP.p.panel, 28f)
        KP.stroke(c, card, KP.p.panelStroke, 1.5f, 28f)
        // A long heading ("Choose a Mii for Retro Rewind · License 2") steps down in size to fit.
        var size = 29f
        while (size > 20f && KP.textWidth(heading, size, KPWeight.Bold) > card.width() - 68) size -= 1f
        KP.text(c, heading, RectF(card.left + 34, card.top + 28 + (29 - size) / 2, card.right - 34, card.top + 72), size, KP.p.text,
            KPWeight.Bold, KPAlign.Left)
        if (choices.isEmpty())
            KP.text(c, "Nothing to choose.", RectF(card.left + 34, card.top + 100, card.right - 34, card.top + 130), 18f, KP.p.secondaryText,
                KPWeight.Regular, KPAlign.Left)
    }
}
