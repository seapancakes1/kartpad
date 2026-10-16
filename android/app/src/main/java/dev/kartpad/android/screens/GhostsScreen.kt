package dev.kartpad.android.screens

import android.graphics.Canvas
import android.graphics.RectF
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import dev.kartpad.android.KartPadIdentityStorage
import dev.kartpad.android.KartPadMiiStorage
import dev.kartpad.android.KartPadRatingStorage
import dev.kartpad.android.KartPadSaveStorage
import dev.kartpad.android.readBytesBounded
import java.io.File
import kotlin.math.max

// Time Trial ghosts, as Mario Kart Wii's own .rkg files (the Mac's KartPadGhostsScreen.inc.mm, with the
// iPhone's files in apple/ios/KartPadScreensGhostFiles.inc.mm): each license's saved ghosts with the
// course, the time and the racer's Mii; A saves one where the player chooses. Import picks a .rkg with
// Android's file picker: it becomes the license's downloaded ghost for that course (the one Time Trials
// offer to race against) at the next restart, with a backup, and personal bests stay as they are. Only
// the original game's courses, from its save whichever game is playing; the files are read in
// kartpad_ghosts_jni.cpp, and KartPadSaveStorage stages the import.
class GhostsScreen(overlay: KPOverlay) : KPScreen(overlay) {
    private val context = overlay.activity
    private val files: File get() = context.filesDir
    private lateinit var done: KPButton
    private lateinit var importButton: KPButton
    private lateinit var restart: KPButton
    private val tiles = ArrayList<KPButton>()
    private val licensePills = ArrayList<KPButton>()
    private var save: ByteArray? = null
    private var saveProblem: String? = null
    private var licenses: List<GhostsNative.License> = emptyList()
    private var license = 0  // index into licenses
    private var ghosts: List<GhostsNative.Ghost> = emptyList()
    private var problem: String? = null
    private var page = 0
    private lateinit var previousPage: KPButton
    private lateinit var nextPage: KPButton

    companion object {
        private const val TAG = "KartPadGhosts"
        private const val Columns = 4
        private const val Rows = 3

        private fun licenseTitle(license: GhostsNative.License): String =
            license.name?.let { "License ${license.slot + 1} · $it" } ?: "License ${license.slot + 1}"
    }

    override fun build() {
        solid = true
        title = "Time Trial Ghosts"
        done = button(RectF(), { c, r, state -> KPFaces.pill(c, r, state, KPStyle.Primary, KPUIGlyph.Check, "Done") }) {
            overlay.pop()
        }
        done.label = "Done"
        done.sound = KPUISound.Close
        importButton = button(RectF(), { c, r, state -> KPFaces.pill(c, r, state, KPStyle.Plain, KPUIGlyph.Plus, "Import") }) {
            chooseGhostToImport()
        }
        importButton.label = "Import a ghost"
        restart = button(RectF(), { c, r, state ->
            KP.buttonFace(c, r, KPStyle.Plain, false, state.enabled, state.pressed, state.focused)
            val dy = if (state.pressed) 2f else 0f
            KP.fill(c, RectF(r.left + 2, r.top + dy + 2, r.right - 2, r.bottom - 3 + dy - 2), KP.p.caution, 6f, .22f)
            KPGlyphs.draw(c, KPUIGlyph.Restart, RectF(r.left + 16, r.centerY() - 14 + dy, r.left + 42, r.centerY() + 12 + dy), KP.p.cautionInk)
            KP.text(c, HomeScreen.RestartTitle, RectF(r.left + 50, r.centerY() - 13 + dy, r.right - 8, r.centerY() + 13 + dy), 19f, KP.p.text,
                KPWeight.Semibold, KPAlign.Left)
        }) {
            KPAsk.warning(overlay, "Restart KartPad?", "Unsaved progress will be lost.", listOf("Restart", "Later"), 0, -1) { choice ->
                if (choice == 0) KartPadScreens.host.restart(null)
            }
        }
        restart.label = "Restart to apply changes"
        // The pages, under the grid: L and R turn them on a controller, these by touch (and A).
        previousPage = pageButton(-1)
        nextPage = pageButton(1)
        for (i in 0 until Columns * Rows) {
            val tile = button(RectF(), { c, r, state -> drawTile(i, c, r, state) }) { ghostAt(i)?.let { export(it) } }
            tile.tag2 = i
            tile.radius = 16f
            tile.sound = KPUISound.Press
            tiles += tile
        }
        readSave()
        licenses.forEachIndexed { i, entry ->
            val pill = button(RectF(), { c, r, state ->
                val chosen = i == license
                KP.buttonFace(c, r, KPStyle.Tab, chosen, state.enabled, state.pressed, state.focused)
                val dy = if (state.pressed) 2f else 0f
                KP.text(c, licenseTitle(entry), RectF(r.left + 10, r.centerY() - 13 + dy, r.right - 10, r.centerY() + 13 + dy), 18f,
                    if (chosen) 0xffffff else KP.p.text, KPWeight.Semibold)
            }) { showLicense(i) }
            pill.tag2 = i
            pill.label = licenseTitle(entry)
            pill.sound = KPUISound.Tab
            pill.hidden = licenses.size < 2
            licensePills += pill
        }
        load()
    }

    // The Mario Kart Wii save (in either game) and its licenses. No save yet: no licenses.
    private fun readSave() {
        val read = if (KartPadSaveStorage.active(files).isFile) runCatching { KartPadSaveStorage.readActive(files) } else null
        save = read?.getOrNull()
        saveProblem = read?.exceptionOrNull()?.let { it.message ?: "The save couldn’t be read." }
        licenses = save?.let { runCatching { GhostsNative.licenses(it) }.getOrNull() }.orEmpty()
    }

    private fun load() {
        problem = null
        ghosts = emptyList()
        val save = save
        if (licenses.isEmpty() || save == null) {
            problem = saveProblem ?: "Make a license in Mario Kart Wii first."
            return
        }
        val records = runCatching { GhostsNative.ghosts(save, licenses[license].slot) }
        records.exceptionOrNull()?.let { problem = it.message ?: "The save couldn’t be read." }
        // By course, in the game's order, the personal best first.
        ghosts = records.getOrDefault(emptyList()).sortedWith(compareBy({ it.info.slot }, { it.downloaded }))
    }

    private fun showLicense(index: Int) {
        if (index == license) return
        license = index
        page = 0
        load()
        layoutDesign()
    }

    private fun pageButton(direction: Int): KPButton {
        val button = button(RectF(), { c, r, state ->
            KP.buttonFace(c, r, KPStyle.Round, false, state.enabled, state.pressed, state.focused)
            val dy = if (state.pressed) 2f else 0f
            KP.controlIcon(c, RectF(r.left + 9, r.top + 7 + dy, r.right - 9, r.bottom - 11 + dy), KP.Glyph.Chevron, direction, KP.p.accentBottom)
        }) { turnPage(direction) }
        button.label = if (direction < 0) "Previous page" else "Next page"
        button.sound = null
        button.radius = 12f
        return button
    }

    private fun turnPage(direction: Int): Boolean {
        val next = page + direction
        if (next < 0 || next >= pages) {
            overlay.play(KPUISound.Reject)
            return true
        }
        page = next
        overlay.play(if (direction > 0) KPUISound.PageNext else KPUISound.PagePrevious)
        layoutDesign()
        return true
    }

    private val perPage get() = Columns * Rows
    private val pages get() = max(1, (ghosts.size + perPage - 1) / perPage)
    private fun ghostAt(tile: Int): GhostsNative.Ghost? = ghosts.getOrNull(page * perPage + tile)

    private val gridTop get() = safe.top + if (licenses.size > 1) 196 else 130

    private fun ghostWaiting() = runCatching { KartPadSaveStorage.hasPendingGhost(files) }.getOrDefault(false)

    override fun layoutDesign() {
        val s = safe
        val right = s.right - 56
        val y = s.top + 30
        place(done, RectF(right - 150, y, right, y + 60))
        place(importButton, RectF(right - 150 - 16 - 180, y, right - 150 - 16, y + 60))
        restart.hidden = !ghostWaiting()
        val restartRight = right - 150 - 16 - 180 - 16
        place(restart, RectF(restartRight - 236, y, restartRight, y + 60))
        val pillWidth = 236f
        val pillGap = 14f
        for (pill in licensePills) {
            val x = s.left + 56 + pill.tag2 * (pillWidth + pillGap)
            place(pill, RectF(x, s.top + 120, x + pillWidth, s.top + 174))
        }
        val w = 278f
        val h = 128f
        val gap = 20f
        val x0 = s.left + (1280 - (Columns * w + (Columns - 1) * gap)) / 2
        for (tile in tiles) {
            val i = tile.tag2
            val ghost = ghostAt(i)
            tile.hidden = ghost == null
            tile.label = ghost?.let { "${it.info.course} ${if (it.downloaded) "downloaded" else "best"}" }
            val x = x0 + (i % Columns) * (w + gap)
            val top = gridTop + (i / Columns) * (h + 16)
            place(tile, RectF(x, top, x + w, top + h))
        }
        val pagerTop = s.top + 652
        place(previousPage, RectF(s.left + 56, pagerTop, s.left + 108, pagerTop + 48))
        place(nextPage, RectF(s.left + 248, pagerTop, s.left + 300, pagerTop + 48))
        previousPage.hidden = pages < 2
        nextPage.hidden = pages < 2
        previousPage.enabled = page > 0
        nextPage.enabled = page + 1 < pages
        invalidate()
    }

    override fun initialFocus(): KPButton? = if (ghosts.isNotEmpty()) tiles.first() else done

    // Back from importing: the restart may be waiting now.
    override fun willAppear() = layoutDesign()

    override fun handle(button: KPPad): Boolean {
        if (button != KPPad.NextTab && button != KPPad.PreviousTab) return false
        val before = page
        turnPage(if (button == KPPad.NextTab) 1 else -1)
        if (page != before) overlay.focus(tiles.first(), false)
        return true
    }

    // MARK: Drawing

    private fun drawTile(i: Int, c: Canvas, r: RectF, state: KPUIState) {
        val ghost = ghostAt(i) ?: return
        KP.buttonFace(c, r, KPStyle.Tile, false, true, state.pressed, state.focused)
        val dy = if (state.pressed) 2f else 0f
        val well = RectF(r.left + 16, r.top + 18 + dy, r.left + 84, r.top + 86 + dy)
        val tile = tiles[i]
        val portrait = ghost.info.mii?.let { KPMiiSource.portrait(it) { tile.invalidate() } }
        KPFaces.miiWell(c, well, portrait, KP.p.accentBottom, false)
        val x = r.left + 98
        val end = r.right - 14
        KP.text(c, ghost.info.course, RectF(x, r.top + 14 + dy, end, r.top + 38 + dy), 17f, KP.p.text, KPWeight.Semibold, KPAlign.Left)
        KP.text(c, ghost.info.time, RectF(x, r.top + 40 + dy, end, r.top + 76 + dy), 28f, KP.p.text, KPWeight.Heavy, KPAlign.Left)
        val kind = if (ghost.downloaded) "Downloaded" else "Personal best"
        val detail = ghost.info.name?.let { "$kind · $it" } ?: kind
        KP.text(c, detail, RectF(x, r.top + 82 + dy, end, r.top + 104 + dy), 15f, if (ghost.downloaded) KP.p.secondaryText else KP.p.accentBottom,
            KPWeight.Medium, KPAlign.Left)
    }

    override fun drawDesign(c: Canvas) {
        super.drawDesign(c)
        val s = safe
        KP.text(c, "Time Trial Ghosts", RectF(s.left + 56, s.top + 26, s.left + 696, s.top + 76), 36f, KP.p.text, KPWeight.Bold, KPAlign.Left)
        val subtitle = if (licenses.size == 1) licenseTitle(licenses[0]) else "Mario Kart Wii"
        KP.text(c, subtitle, RectF(s.left + 58, s.top + 76, s.left + 698, s.top + 102), 18f, KP.p.secondaryText, KPWeight.Medium, KPAlign.Left)
        val empty = problem ?: if (ghosts.isEmpty()) "No ghosts on this license yet." else null
        if (empty != null)
            KP.text(c, empty, RectF(s.left + 56, gridTop + 150, s.left + 1224, gridTop + 180), 20f, KP.p.secondaryText, KPWeight.Medium)
        if (pages > 1)
            KP.text(c, "${page + 1} / $pages", RectF(s.left + 108, s.top + 664, s.left + 248, s.top + 690), 18f, KP.p.secondaryText,
                KPWeight.Semibold)
        val hints = ArrayList<KPHint>()
        if (pages > 1) hints += KPHint(KPPad.PreviousTab, "Page", KPPad.NextTab)
        if (ghosts.isNotEmpty()) hints += KPHint(KPPad.Confirm, "Save")
        hints += KPHint(KPPad.Back, "Back")
        KPHints.draw(c, RectF(s.left + 56, s.top + 670, s.left + 1224, s.top + 696), hints, 16f, KPAlign.Right)
    }

    // MARK: Exporting

    // "Luigi Circuit 1'23.456 (Mii).rkg", as on the Mac and iPhone.
    private fun fileName(info: GhostsNative.Info): String {
        val time = info.time.replace(":", "'")
        val name = info.name?.let { " ($it)" } ?: ""
        return "${info.course} $time$name".replace("/", "-") + ".rkg"
    }

    // Where the player chooses, with Android's file picker (the Mac saves to Downloads, iPhone shares it).
    private fun export(ghost: GhostsNative.Ghost) {
        val save = save ?: return
        val exported = runCatching { GhostsNative.nativeExportGhost(save, licenses[license].slot, ghost.info.slot, ghost.downloaded) }
        val data = exported.getOrNull()
        if (data == null) {
            ghostProblem("Couldn’t Save the Ghost", exported.exceptionOrNull()?.message ?: "The ghost couldn’t be read.")
            return
        }
        val name = fileName(ghost.info)
        KartPadScreens.host.pickDocument(true, name, "application/octet-stream") { uri ->
            if (uri == null) return@pickDocument
            val written = runCatching {
                KartPadScreens.activity.contentResolver.openOutputStream(uri, "wt")?.use { it.write(data) }
                    ?: error("The file couldn’t be opened.")
            }
            written.exceptionOrNull()?.let {
                ghostProblem("Couldn’t Save the Ghost", it.message ?: "The file couldn’t be written.")
                return@pickDocument
            }
            val saved = displayName(uri) ?: name
            Log.i(TAG, "ghostExported=$saved")
            overlay.play(KPUISound.Saved)
            overlay.toast("Ghost saved", saved, icon = { c, r -> KPGlyphs.draw(c, KPUIGlyph.Export, r, KP.p.accentBottom) })
        }
    }

    // MARK: Importing

    private fun ghostProblem(heading: String, message: String) {
        overlay.play(KPUISound.Reject)
        KPAsk.ask(overlay, heading, message, listOf("Done"), 0, -1) {}
    }

    private fun displayName(uri: Uri): String? = runCatching {
        KartPadScreens.activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    }.getOrNull()?.takeIf { it.isNotEmpty() }

    // Any file: .rkg has no type of its own on Android.
    private fun chooseGhostToImport() {
        KartPadScreens.host.pickDocument(false, null, "*/*") { uri -> if (uri != null) importFile(uri) }
    }

    private fun importFile(uri: Uri) {
        val name = displayName(uri) ?: "The file"
        val data = runCatching {
            KartPadScreens.activity.contentResolver.openInputStream(uri)?.use { it.readBytesBounded(GhostsNative.GhostBytes) }
        }.getOrNull()
        if (data == null || data.size > GhostsNative.GhostBytes) {
            ghostProblem("Can’t Use This Ghost", "$name isn’t an RKG ghost.")
            return
        }
        Log.i(TAG, "ghostFile=$name")
        importGhost(data, name)
    }

    // Mii, license and save changes waiting for a restart (not a waiting ghost, which can be replaced).
    private fun otherChangesWaiting(): Boolean = runCatching {
        KartPadMiiStorage.hasPending(files) || KartPadIdentityStorage.hasPending(files) || KartPadRatingStorage.hasPending(files) ||
            KartPadSaveStorage.profiles.any { KartPadSaveStorage.hasPending(files, it) }
    }.getOrDefault(true)

    private fun importGhost(data: ByteArray, fileName: String) {
        val inspected = runCatching { GhostsNative.inspect(data) }
        val info = inspected.getOrNull()
        if (info == null) {
            ghostProblem("Can’t Use This Ghost", "$fileName: ${inspected.exceptionOrNull()?.message ?: "Not an RKG ghost"}")
            return
        }
        // Other changes waiting for a restart have to go first; a waiting ghost can be replaced.
        if (otherChangesWaiting()) {
            KPAsk.ask(overlay, "Restart First", "Other changes are waiting for a restart.", listOf("Restart", "Cancel"), 0, -1) { choice ->
                if (choice == 0) KartPadScreens.host.restart(null)
            }
            return
        }
        when (licenses.size) {
            0 -> ghostProblem("No License Yet", "Make a license in Mario Kart Wii first.")
            1 -> stage(data, info, licenses[0])
            else -> {
                val menu = KPMenuScreen(overlay)
                menu.heading = "Which license?"
                for (entry in licenses) menu.add(licenseTitle(entry)) { stage(data, info, entry) }
                overlay.present(menu)
            }
        }
    }

    // Stages the ghost on a license and offers the restart that applies it. A ghost already waiting is
    // replaced (only one waits at a time).
    private fun stage(data: ByteArray, info: GhostsNative.Info, target: GhostsNative.License) {
        val whose = target.name?.let { "$it’s" } ?: "License ${target.slot + 1}’s"
        KPAsk.ask(overlay, "${info.course} · ${info.time}", "Replaces $whose downloaded ghost for this course.",
            listOf("Restart", "Later", "Cancel"), 0, -1) { choice ->
            if (choice == 2) return@ask
            runCatching { KartPadSaveStorage.cancelPendingGhost(files) }.exceptionOrNull()?.let {
                ghostProblem("Couldn’t Import the Ghost", it.message ?: "The waiting ghost couldn’t be cancelled.")
                return@ask
            }
            runCatching {
                val before = KartPadSaveStorage.readActive(files)
                val after = GhostsNative.nativeImportGhost(before, data, target.slot) ?: error("The ghost doesn’t fit this save.")
                KartPadSaveStorage.writePendingGhost(files, before, after, target.slot, info.slot)
            }.exceptionOrNull()?.let {
                ghostProblem("Couldn’t Import the Ghost", it.message ?: "The ghost doesn’t fit this save.")
                return@ask
            }
            Log.i(TAG, "ghostStaged=${info.course}; license=${target.slot + 1}")
            for (screen in overlay.stack.toList()) screen.relayout()
            if (choice == 0) {
                KartPadScreens.host.restart(null)
                return@ask
            }
            overlay.play(KPUISound.Saved)
            overlay.toast("Ghost ready", "Restart to race it.", icon = { c, r -> KPGlyphs.draw(c, KPUIGlyph.Ghost, r, KP.p.accentBottom) })
        }
    }
}

/**
 * Mario Kart Wii's ghosts in its save (kartpad_ghosts_jni.cpp): the licenses, each one's saved ghosts,
 * what a .rkg file says about itself, and the save with an imported one. Failures throw
 * IllegalArgumentException with why.
 */
internal object GhostsNative {
    const val GhostBytes = 0x2800

    class License(val slot: Int, val name: String?)
    /** What a ghost says about itself: course slot (0–31, the game's order), course, time, and the racer's Mii when it's a valid one. */
    class Info(val slot: Int, val course: String, val time: String, val name: String?, val mii: ByteArray?)
    class Ghost(val info: Info, val downloaded: Boolean)

    fun licenses(save: ByteArray): List<License> =
        nativeListLicenses(save).toList().chunked(2).map { License(it[0] as Int, it[1] as String?) }

    /** In the save's order: the personal bests, then the downloaded ghosts. */
    fun ghosts(save: ByteArray, license: Int): List<Ghost> =
        nativeListGhosts(save, license).toList().chunked(6).map { Ghost(info(it, 1), it[0] as Boolean) }

    fun inspect(rkg: ByteArray): Info = info(nativeInspectGhost(rkg).toList(), 0)

    private fun info(row: List<Any?>, at: Int) =
        Info(row[at] as Int, row[at + 1] as String, row[at + 2] as String, row[at + 3] as String?, row[at + 4] as ByteArray?)

    /** The initialized licenses, two entries each: slot (Int) and name (null when empty). The save is validated already. */
    external fun nativeListLicenses(save: ByteArray): Array<Any?>
    /** A license's ghosts, six entries each: downloaded (Boolean), then an Info's five. */
    external fun nativeListGhosts(save: ByteArray, license: Int): Array<Any?>
    /** A saved ghost's .rkg. */
    external fun nativeExportGhost(save: ByteArray, license: Int, slot: Int, downloaded: Boolean): ByteArray?
    /** A ghost file's Info entries. */
    external fun nativeInspectGhost(rkg: ByteArray): Array<Any?>
    /** The save with the ghost as the license's downloaded ghost for its course, for KartPadSaveStorage.writePendingGhost. */
    external fun nativeImportGhost(save: ByteArray, rkg: ByteArray, license: Int): ByteArray?
}
