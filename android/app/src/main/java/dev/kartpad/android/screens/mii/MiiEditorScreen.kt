package dev.kartpad.android.screens.mii

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import dev.kartpad.android.KartPadMiiChanges
import dev.kartpad.android.screens.KP
import dev.kartpad.android.screens.KPAlign
import dev.kartpad.android.screens.KPAsk
import dev.kartpad.android.screens.KPButton
import dev.kartpad.android.screens.KPGlyphs
import dev.kartpad.android.screens.KPMenuScreen
import dev.kartpad.android.screens.KPMiiSource
import dev.kartpad.android.screens.KPOverlay
import dev.kartpad.android.screens.KPOverlayTheme
import dev.kartpad.android.screens.KPPad
import dev.kartpad.android.screens.KPScreen
import dev.kartpad.android.screens.KPSlide
import dev.kartpad.android.screens.KPStyle
import dev.kartpad.android.screens.KPUISound
import dev.kartpad.android.screens.KPUIGlyph
import dev.kartpad.android.screens.KPUIState
import dev.kartpad.android.screens.KPWeight
import dev.kartpad.android.screens.KartPadScreens
import dev.kartpad.android.screens.KartPadUISounds
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import kotlin.random.Random
import dev.kartpad.android.screens.mii.MiiEditorNative as N

/**
 * The Mii editor (apple/shared/KartPadMiiEditor.inc.mm, with the controller handling of
 * KartPadMiiGamepad.inc.mm and KartPadMiiGamepadIOS.inc.mm), on the 1280×720 design canvas: the
 * preview card on the left with the Mii's name and the turn controls, Cancel and Save under it with
 * the status line, and the editing panel on the right under the category tabs, undo, redo and ⋯.
 * Pages never scroll; each fits whole. Create Mii (mii null) opens on its start screen; a duplicate
 * (copy) is a new Mii that opens on Profile. done(true) after a save, which the Miis screen's banner
 * names; done(false) when it closes without one.
 */
internal class MiiEditorScreen(
    overlay: KPOverlay,
    mii: KartPadMiiChanges.Mii?,
    copy: ByteArray? = null,
    private val done: (saved: Boolean) -> Unit,
) : KPScreen(overlay) {
    private enum class Act {
        Category, Select, Adjust, Page, Mode, Toggle, Rotate, Front, Quit, Save, Discard, Month, Day, Undo, Redo, More,
        Gender, Start, LookAlike, Shuffle, Back, Gauge, Name,
    }

    /** What a control does; a rebuilt page's focus returns to the control with the same one. */
    private data class Item(val act: Act, val field: Int = 0, val value: Int = 0, val panel: Boolean = false)

    private class Label(val rect: RectF, val size: Float, val weight: Int, val align: KPAlign, val text: () -> String,
                        val ink: () -> Int)

    private val context: Context = overlay.activity
    private val slot: Int? = mii?.slot
    private val expected: ByteArray? = mii?.record?.copyOf()
    private val duplicating = copy != null
    private var draft: ByteArray = (mii?.record ?: copy)?.copyOf() ?: ByteArray(0)
    private var original: ByteArray = draft.copyOf()
    // Create Mii waits for a fresh record (this console's identity, a unique Mii ID).
    private var loading = mii == null && copy == null
    private var creating = loading
    // The new Mii before a face was chosen, so Start Over can return to the start screen.
    private var blank: ByteArray? = null
    private var gender = 0
    private var picking = false
    private var seeds = IntArray(LookAlikeCount)
    private var lookAlikes: List<ByteArray> = emptyList()
    private var scratch: ByteArray = draft
    private var category = 0
    private var feature = 0
    private var page = 0
    private val history = MiiEditorHistory()
    // Every field clamped (what the editor shows) and as stored.
    private var shown = IntArray(0)
    private var raw = IntArray(0)
    private var validationMessage: String? = null
    private var validationField = N.NICKNAME
    private var previewMessage: String? = null
    private var animated = true
    private var opened = false
    private var finished = false
    private var saving = false
    private var allowClose = false
    // HOME or Start asked to close every screen, and Save was chosen: close them once it's saved.
    private var closeAllAfterSave = false

    private val preview = MiiPreviewView(context)
    private val buttons = ArrayList<KPButton>()
    private val labels = ArrayList<Label>()
    private val tiles = HashMap<Int, Bitmap>()
    private var tileField = -1
    private var tilePage = -1
    private var tileInputs: String? = null
    private var tileGeneration = 0

    // A held adjustment repeats while its button stays pressed (a finger, A or Enter): one history entry.
    private var hold: KPButton? = null
    private var holdFired = false
    private var holdStart = 0L
    private var holdLast = 0L
    private var swallow: KPButton? = null
    private var swallowUntil = 0L
    private var adjustAt = 0L
    private var adjustKey = -1
    // A gauge drag is one history entry; it ends with the next edit of any other kind.
    private var dragGroup = false
    private var dragging = -1

    private companion object {
        const val LookAlikeCount = 12
        const val Preferences = "kartpad_screens"
        const val AnimationKey = "mii_preview_animation"
        val months = listOf("Not set", "January", "February", "March", "April", "May", "June", "July", "August",
            "September", "October", "November", "December")
        val work = Executors.newSingleThreadExecutor { Thread(it, "KartPadMiiEditor").apply { isDaemon = true } }
        val main = Handler(Looper.getMainLooper())

        // The layout, in design points from the top-left of the 1280×720 area.
        val PreviewCard = RectF(24f, 160f, 434f, 612f)
        val PreviewView = RectF(34f, 222f, 424f, 602f)
        val Panel = RectF(458f, 160f, 1256f, 704f)
        const val PanelX = 472f
        const val PanelY = 174f
        const val PanelW = 770f
        const val PanelH = 516f
        const val FooterY = 646f
        const val FooterH = 58f
        const val Side = 280f // the colour, switch and adjustment column beside the style grid
        const val Gap = 12f
    }

    init {
        title = if (slot != null) "Edit Mii" else if (duplicating) "Duplicate Mii" else "Create Mii"
        solid = true
        animated = context.getSharedPreferences(Preferences, Context.MODE_PRIVATE).getBoolean(AnimationKey, true)
        preview.animated = animated
        preview.onStatus = { previewMessage = it; invalidate() }
        if (!loading) {
            read()
            preview.setMii(draft)
            preview.setFraming(head = false)
        }
    }

    // MARK: State

    private fun read() {
        shown = N.values(draft, true)
        raw = N.values(draft, false)
    }

    private val edited get() = !draft.contentEquals(original)
    // A new Mii is unsaved until it is saved; otherwise only edits since opening count.
    private val dirty get() = (!creating && slot == null) || edited

    private fun set(record: ByteArray, field: Int, value: Int) = N.with(record, field, value) ?: record

    private fun sound(sound: KPUISound) {
        overlay.play(sound)
        KartPadUISounds.haptic(overlay.host, sound.ordinal)
    }

    /** An edit: one history step (unless grouped), the preview, the controls and the tiles follow. */
    private fun apply(next: ByteArray, fromDrag: Boolean = false) {
        if (!fromDrag) endDrag()
        history.record(draft, next)
        draft = next
        read()
        validationMessage = null
        preview.setMii(draft)
        refreshControls()
        requestTiles()
        invalidate()
    }

    private fun endDrag() {
        if (!dragGroup) return
        dragGroup = false
        history.end()
    }

    // The blank face for the chosen gender; female starts with the Mii Channel's female hair, eyes and eyebrows.
    private fun makeScratch(): ByteArray {
        var a = set(draft, N.GENDER, gender)
        if (gender == 1) {
            a = set(a, N.HAIR_TYPE, 12)
            a = set(a, N.EYE_TYPE, 4)
            a = set(a, N.EYEBROW_TYPE, 0)
        }
        return a
    }

    private fun shuffle() {
        seeds = IntArray(LookAlikeCount) { Random.nextInt() }
        makeLookAlikes()
    }

    // One seed per tile, so changing gender keeps the shuffle.
    private fun makeLookAlikes() {
        lookAlikes = seeds.map { N.lookAlike(draft, gender, it) }
        scratch = makeScratch()
    }

    // MARK: Opening and closing

    override fun didAppear() {
        if (opened) return
        opened = true
        // Opening over the Miis screen; the overlay plays it when the editor is all there is.
        if (overlay.stack.size > 1) sound(KPUISound.Open)
        if (loading) loadNewMii()
    }

    private fun loadNewMii() {
        val files = context.filesDir
        work.execute {
            val result = KartPadMiiChanges.newMii(files)
            main.post {
                if (finished) return@post
                result.onSuccess { record ->
                    loading = false
                    draft = record.copyOf()
                    original = record.copyOf()
                    blank = record.copyOf()
                    read()
                    shuffle()
                    rebuild()
                    if (overlay.top === this) overlay.focus(initialFocus(), false)
                }.onFailure { error ->
                    finish(false, KPUISound.Reject)
                    KPAsk.ask(overlay, "Mii Couldn’t Be Opened", error.message ?: "This Mii couldn’t be read.", listOf("OK"), 0, -1) {}
                }
            }
        }
    }

    // HOME closing every screen takes the editor too; the Miis screen still hears it closed.
    override fun willDisappear() {
        main.post {
            if (!finished && overlay.stack.none { it === this }) {
                finished = true
                MiiImages.clearTiles()
                done(false)
            }
        }
    }

    /** Closes the editor; sound plays after the close's own (a save, discarding). */
    private fun finish(saved: Boolean, sound: KPUISound?) {
        if (finished) return
        finished = true
        endHold()
        MiiImages.clearTiles()
        if (overlay.top === this) overlay.pop()
        sound?.let(::sound)
        done(saved)
        if (closeAllAfterSave) overlay.closeAll()
    }

    override fun asksBeforeClosingAll() = !finished && !saving && !allowClose && !loading && dirty

    // HOME or Start with unsaved changes: the same question as closing, then back to the game.
    override fun askBeforeClosingAll() {
        KPAsk.ask(overlay, saveQuestion(), "", listOf("Save", "Discard Changes", "Keep Editing"), 0, 1) { choice ->
            when (choice) {
                0 -> {
                    closeAllAfterSave = true
                    save()
                }
                1 -> {
                    allowClose = true
                    finish(false, KPUISound.PagePrevious)
                    overlay.closeAll()
                }
            }
        }
    }

    private fun saveQuestion(): String {
        val name = N.name(draft, N.NICKNAME)
        return if (name.isNotEmpty()) "Save Changes to “$name”?" else "Save Changes to This Mii?"
    }

    // B and closing: straight away when nothing changed, otherwise Save / Discard Changes / Keep Editing (B).
    private fun quit() {
        if (saving) return
        if (allowClose || loading || !dirty) {
            finish(false, null)
            return
        }
        KPAsk.ask(overlay, saveQuestion(), "", listOf("Save", "Discard Changes", "Keep Editing"), 0, 1) { choice ->
            when (choice) {
                0 -> save()
                1 -> finish(false, KPUISound.PagePrevious)
            }
        }
    }

    // Cancel closes an untouched draft straight away; changed drafts confirm first.
    private fun discard() {
        if (!dirty) {
            finish(false, null)
            return
        }
        val message = if (slot == null) "This new Mii won’t be saved." else "This Mii will stay as it was before you opened the editor."
        KPAsk.ask(overlay, "Discard Your Changes?", message, listOf("Discard Changes", "Keep Editing"), 1, 0) { choice ->
            if (choice == 0) finish(false, KPUISound.PagePrevious)
        }
    }

    // The nickname is required and both names must be storable; says what is wrong under the field.
    private fun namesProblem(): Boolean {
        for (offset in intArrayOf(N.NICKNAME, N.CREATOR)) {
            val problem = MiiNames.problem(N.name(draft, offset), offset == N.CREATOR) ?: continue
            validationField = offset
            validationMessage = problem
            sound(KPUISound.Reject)
            invalidate()
            return true
        }
        return false
    }

    // Saving queues the Mii for the next launch and closes; the Miis screen's banner names the change.
    private fun save() {
        if (saving || finished) return
        endDrag()
        if (namesProblem()) return
        saving = true
        refreshControls()
        val files = context.filesDir
        val record = draft.copyOf()
        val replaces = expected
        val target = slot
        work.execute {
            val result = KartPadMiiChanges.saveMii(files, target, replaces, record)
            main.post {
                saving = false
                result.onSuccess {
                    KPMiiSource.refresh(context)
                    allowClose = true
                    finish(true, KPUISound.Saved)
                }.onFailure { error ->
                    closeAllAfterSave = false
                    refreshControls()
                    sound(KPUISound.Reject)
                    tell("Mii Couldn’t Be Saved", error.message ?: "This Mii couldn’t be saved.")
                }
            }
        }
    }

    private fun tell(heading: String, message: String) {
        if (finished) return
        KPAsk.ask(overlay, heading, message, listOf("OK"), 0, -1) {}
    }

    // MARK: ⋯

    private fun showMore() {
        val menu = KPMenuScreen(overlay)
        menu.heading = "More"
        menu.add("Export…") { export() }
        menu.add("Reset Changes…", enabled = edited) { reset() }
        if (blank != null) menu.add("Start Over…") { startOver() }
        menu.add(if (animated) "Stop Preview Animation" else "Animate Preview") { toggleAnimation() }
        overlay.present(menu)
    }

    private fun fileName(name: String): String {
        val clean = name.replace(Regex("[/:\\\\]"), "-")
        return (clean.ifEmpty { "Mii" }) + ".mii"
    }

    // A standard 74-byte .mii, named after the Mii.
    private fun export() {
        endDrag()
        N.problem(draft)?.let {
            sound(KPUISound.Reject)
            tell("Mii Couldn’t Be Exported", it)
            return
        }
        val data = draft.copyOf()
        val resolver = context.contentResolver
        KartPadScreens.host.pickDocument(true, fileName(N.name(draft, N.NICKNAME)), "application/octet-stream") { uri ->
            if (uri == null) return@pickDocument
            work.execute {
                val failure = runCatching {
                    checkNotNull(resolver.openOutputStream(uri, "w")) { "This Mii couldn’t be exported." }.use { it.write(data) }
                }.exceptionOrNull()
                main.post {
                    if (failure == null) sound(KPUISound.Saved)
                    else {
                        sound(KPUISound.Reject)
                        tell("Mii Couldn’t Be Exported", failure.message ?: "This Mii couldn’t be exported.")
                    }
                }
            }
        }
    }

    private fun reset() {
        if (!edited) return
        val message = if (slot == null) "The Mii goes back to the face you started from." else "The Mii goes back to how it was when you opened it."
        KPAsk.ask(overlay, "Reset All Changes?", message, listOf("Reset Changes", "Keep Editing"), 1, 0) { choice ->
            if (choice != 0) return@ask
            sound(KPUISound.PagePrevious)
            endDrag()
            history.end()
            apply(original.copyOf())
            historyChanged()
        }
    }

    // A new Mii can go back to the start screen to pick another way to start (asking first if edited).
    private fun startOver() {
        val restart = {
            sound(KPUISound.PagePrevious)
            val face = checkNotNull(blank)
            endHold()
            history.clear()
            dragGroup = false
            draft = face.copyOf()
            original = face.copyOf()
            creating = true
            picking = false
            validationMessage = null
            read()
            makeLookAlikes()
            rebuild()
        }
        if (!edited) {
            restart()
            return
        }
        KPAsk.ask(overlay, "Start Over?", "Your changes to this Mii will be lost.", listOf("Start Over", "Keep Editing"), 1, 0) { choice ->
            if (choice == 0) restart()
        }
    }

    private fun toggleAnimation() {
        animated = !animated
        sound(if (animated) KPUISound.Confirm else KPUISound.Same)
        context.getSharedPreferences(Preferences, Context.MODE_PRIVATE).edit().putBoolean(AnimationKey, animated).apply()
        preview.animated = animated
    }

    // MARK: Actions

    // Leaves the start screen with the chosen face and opens Face.
    private fun begin(face: ByteArray) {
        sound(KPUISound.NewMii)
        draft = face.copyOf()
        original = face.copyOf()
        creating = false
        picking = false
        lookAlikes = emptyList()
        read()
        preview.setMii(draft)
        categoryChanged(2)
    }

    private fun categoryChanged(next: Int) {
        endDrag()
        category = next
        feature = N.primaryFeatures[next]
        page = N.featurePage(feature, shown[feature])
        preview.setFraming(head = next >= 2)
        if (next >= 2) preview.easeToFront()
        rebuild()
    }

    private fun historyChanged() {
        page = N.featurePage(feature, shown[feature])
        rebuild()
    }

    private fun undoRedo(redo: Boolean) {
        endDrag()
        if (if (redo) !history.canRedo else !history.canUndo) {
            sound(KPUISound.Same)
            return
        }
        sound(if (redo) KPUISound.PageNext else KPUISound.PagePrevious)
        draft = if (redo) history.redo(draft) else history.undo(draft)
        read()
        preview.setMii(draft)
        historyChanged()
    }

    private fun toggleOn(field: Int, values: IntArray) = if (field == N.MINGLE_OFF) values[field] == 0 else values[field] != 0

    private fun perform(item: Item) {
        if (saving || finished) return
        when (item.act) {
            Act.Category -> {
                sound(if (item.field == category) KPUISound.Same else KPUISound.Tab)
                categoryChanged(item.field)
            }
            Act.Page -> {
                sound(if (item.value > 0) KPUISound.PageNext else KPUISound.PagePrevious)
                page += item.value
                rebuild()
            }
            Act.Mode -> {
                sound(if (item.field == feature) KPUISound.Same else KPUISound.Tab)
                feature = item.field
                page = N.featurePage(feature, shown[feature])
                rebuild()
            }
            Act.Gender -> {
                sound(if (gender == item.value) KPUISound.Same else KPUISound.Confirm)
                gender = item.value
                makeLookAlikes()
                rebuild()
            }
            Act.Start -> if (item.value == 1) {
                sound(KPUISound.Press)
                picking = true
                rebuild()
            } else begin(scratch)
            Act.LookAlike -> lookAlikes.getOrNull(item.value)?.let(::begin)
            Act.Shuffle -> {
                sound(KPUISound.PageNext)
                shuffle()
                rebuild()
            }
            Act.Back -> {
                sound(KPUISound.PagePrevious)
                picking = false
                rebuild()
            }
            // Choosing what a field shows still stores it, which brings a field out of range into range.
            Act.Select -> {
                val changed = shown[item.field] != item.value
                sound(when {
                    !changed -> KPUISound.Same
                    item.field == N.GENDER -> KPUISound.Confirm
                    isColor(item.field) -> KPUISound.Tab
                    else -> KPUISound.Press
                })
                apply(set(draft, item.field, item.value))
                if (changed) preview.smile()
            }
            Act.Toggle -> {
                val next = set(draft, item.field, if (raw[item.field] != 0) 0 else 1)
                sound(if (toggleOn(item.field, N.values(next, false))) KPUISound.Confirm else KPUISound.Same)
                apply(next)
                if (item.field == N.MOLE) rebuild()
            }
            Act.Rotate -> {
                sound(if (item.value < 0) KPUISound.Left else KPUISound.Right)
                preview.turnBy(item.value * MiiPreviewView.BUTTON_TURN_DEGREES)
            }
            Act.Front -> {
                sound(KPUISound.Tab)
                preview.faceFront()
            }
            Act.Undo -> undoRedo(false)
            Act.Redo -> undoRedo(true)
            Act.Quit -> quit()
            Act.Save -> save()
            Act.Discard -> discard()
            Act.More -> {
                sound(KPUISound.Press)
                showMore()
            }
            Act.Name -> askName(item.field)
            Act.Adjust, Act.Month, Act.Day -> {
                history.begin()
                step(item)
                history.end()
            }
            Act.Gauge -> {}
        }
    }

    // Nickname and Creator are typed on the name entry; a typed name is one undo step.
    private fun askName(offset: Int) {
        endDrag()
        val creator = offset == N.CREATOR
        MiiNameEntry.ask(overlay, if (creator) "Creator" else "Nickname", N.name(draft, offset), creator) { text ->
            if (text == null || finished) return@ask
            val problem = MiiNames.problem(text, creator)
            val next = if (problem == null) N.withName(draft, offset, text.trim()) else null
            if (next == null) {
                validationField = offset
                validationMessage = problem ?: "This name is too long."
                sound(KPUISound.Reject)
                invalidate()
                return@ask
            }
            history.begin()
            apply(next)
            history.end()
        }
    }

    // The first press plays the step; held repeats tick, and a hold that reaches the limit is rejected.
    private fun step(item: Item) {
        val now = SystemClock.uptimeMillis()
        val key = item.act.ordinal * 1000 + item.field * 2 + if (item.value > 0) 1 else 0
        val repeat = now - adjustAt < 400 && adjustKey == key
        adjustAt = now
        adjustKey = key
        fun play(limit: Boolean) = sound(when {
            repeat -> if (limit) KPUISound.Reject else KPUISound.Tick
            item.value > 0 -> KPUISound.Right
            else -> KPUISound.Left
        })
        when (item.act) {
            Act.Adjust -> {
                val f = N.fields[item.field]
                val value = shown[item.field] + item.value
                if (value < f.minimum || value > f.maximum) return sound(KPUISound.Reject)
                play(value == f.minimum || value == f.maximum)
                apply(set(draft, item.field, value))
            }
            // Not set clears both; a month keeps the day where it can.
            Act.Month -> {
                val month = shown[N.MONTH] + item.value
                if (month !in 0..12) return sound(KPUISound.Reject)
                play(month == 0 || month == 12)
                val next = set(draft, N.MONTH, month)
                apply(set(next, N.DAY, if (month > 0) min(max(1, shown[N.DAY]), N.birthdayDays(month)) else 0))
            }
            Act.Day -> {
                val days = N.birthdayDays(shown[N.MONTH])
                val day = min(shown[N.DAY] + item.value, days)
                if (shown[N.MONTH] == 0 || day < 1) return sound(KPUISound.Reject)
                play(day == 1 || day == days)
                apply(set(draft, N.DAY, day))
            }
            else -> {}
        }
    }

    // Height and weight: left and right step by 4; at a limit it is rejected.
    private fun stepGauge(field: Int, delta: Int) {
        val before = shown[field]
        endDrag()
        history.begin()
        val value = (before + delta).coerceIn(0, 127)
        if (raw[field] != value) apply(set(draft, field, value))
        history.end()
        sound(if (shown[field] == before) KPUISound.Reject else KPUISound.Tick)
    }

    // A drag on the gauge: one history entry, a tick every 8 of 128.
    private fun slideGauge(field: Int, frame: RectF, x: Float, began: Boolean) {
        if (began) {
            endDrag()
            history.begin()
            dragGroup = true
        }
        dragging = field
        KPSlide.saveSoon { dragging = -1; invalidate() }
        val before = shown[field]
        val value = MiiEditorArt.gaugeValue(frame, x)
        if (raw[field] != value) apply(set(draft, field, value), fromDrag = true)
        if (shown[field] / 8 != before / 8) sound(KPUISound.Tick)
        invalidate()
    }

    private fun holds(button: KPButton) = (button.tagObject as? Item)?.act.let { it == Act.Adjust || it == Act.Month || it == Act.Day }

    private fun startHold(button: KPButton, now: Long) {
        endDrag()
        hold = button
        holdFired = false
        holdStart = now
        holdLast = now
        history.begin()
        step(button.tagObject as Item)
    }

    private fun endHold() {
        val held = hold ?: return
        hold = null
        history.end()
        swallow = if (holdFired) null else held
        swallowUntil = SystemClock.uptimeMillis() + 300
    }

    // A hold's release still fires the button; that press was the hold's.
    private fun activated(button: KPButton, item: Item) {
        if (holds(button)) {
            if (hold === button) {
                holdFired = true
                return
            }
            if (swallow === button && SystemClock.uptimeMillis() < swallowUntil) {
                swallow = null
                return
            }
        }
        perform(item)
    }

    override fun tick() {
        val now = SystemClock.uptimeMillis()
        hold?.let { held ->
            if (!held.pressed || !held.enabled || held !in buttons) endHold()
            else if (now - holdStart >= 350 && now - holdLast >= 85) {
                holdLast = now
                step(held.tagObject as Item)
            }
        }
        // A new press of the button a hold ended on is a press of its own.
        if (hold == null && !saving && !finished) buttons.firstOrNull { it.pressed && it.enabled && holds(it) }?.let {
            if (it === swallow) swallow = null
            startHold(it, now)
        }
    }

    // MARK: Controllers

    override fun handle(button: KPPad): Boolean {
        if (loading || saving) return button != KPPad.Back
        when (button) {
            // LB and RB change category; the focus goes to its tab.
            KPPad.PreviousTab, KPPad.NextTab -> {
                if (creating) return true
                val next = (category + if (button == KPPad.NextTab) 1 else 9) % 10
                perform(Item(Act.Category, next))
                buttons.firstOrNull { it.tagObject == Item(Act.Category, next) }?.let { overlay.focus(it, false) }
                return true
            }
            KPPad.Undo, KPPad.Redo -> {
                if (!creating) perform(Item(if (button == KPPad.Undo) Act.Undo else Act.Redo))
                return true
            }
            KPPad.Start -> {
                if (!creating) {
                    if (dirty) save() else sound(KPUISound.Reject)
                }
                return true
            }
            // Down from a category tab opens onto its page rather than whatever sits below the tab.
            KPPad.Down -> {
                val from = focus?.tagObject as? Item ?: return false
                if (from.act != Act.Category) return false
                defaultFocus(panelOnly = true)?.let { overlay.focus(it, true) } ?: return false
                return true
            }
            else -> return false
        }
    }

    // B closes (asking about unsaved changes), or steps back from the look-alike grid.
    override fun back() {
        if (saving) return
        if (loading) return finish(false, null)
        if (creating && picking) {
            perform(Item(Act.Back))
            buttons.firstOrNull { it.tagObject == Item(Act.Start, value = 1) }?.let { overlay.focus(it, false) }
            return
        }
        quit()
    }

    // The right stick: half a turn a second at full tilt.
    override fun turn(x: Float, seconds: Float) {
        if (creating || loading) return
        preview.turnBy(x * min(seconds, .1f) * 180f)
    }

    override fun initialFocus(): KPButton? = defaultFocus(false)

    // The current choice (a feature, a colour, the gender), else the open category or mode, else the first control.
    private fun defaultFocus(panelOnly: Boolean): KPButton? {
        val controls = focusables().filter { !panelOnly || (it.tagObject as? Item)?.panel == true }
        controls.firstOrNull { val item = it.tagObject as Item; item.act == Act.Select && shown[item.field] == item.value }?.let { return it }
        return controls.firstOrNull { selected(it.tagObject as Item) } ?: controls.firstOrNull()
    }

    // MARK: Layout

    override fun layoutDesign() = rebuild()

    private fun at(x: Float, y: Float, w: Float, h: Float) = RectF(safe.left + x, safe.top + y, safe.left + x + w, safe.top + y + h)
    private fun at(r: RectF) = at(r.left, r.top, r.width(), r.height())

    private fun add(item: Item, rect: RectF, label: String): KPButton {
        val button = button(rect, { c, r, state -> drawItem(c, r, state, item) }, null)
        button.activate = { activated(button, item) }
        button.tagObject = item
        button.label = label
        button.sound = null
        button.radius = 10f
        buttons += button
        return button
    }

    private fun label(rect: RectF, size: Float, weight: Int, align: KPAlign = KPAlign.Left, ink: () -> Int = { KP.p.secondaryText },
                      text: () -> String) {
        labels += Label(rect, size, weight, align, text, ink)
    }

    /** Lays out the controls for what shows now; the focus returns to the same control, else the default. */
    private fun rebuild() {
        val previous = focus?.tagObject as? Item
        val hadFocus = focus != null
        endHold()
        for (button in buttons) remove(button)
        buttons.clear()
        labels.clear()
        focus = null
        if (!loading) {
            if (creating) buildCreate() else buildEditor()
        }
        // The start screen has no preview: it leaves the view tree, so its GL thread stops.
        if (creating || loading) {
            if (views.remove(preview) != null) overlay.host.removeView(preview)
        } else placeView(preview, at(PreviewView))
        preview.wellColor = if (KPOverlayTheme.dark) KP.Dark.well else KP.Light.well
        preview.cornerRadius = 10 * overlay.scale
        refreshControls()
        requestTiles()
        if (hadFocus) {
            val next = buttons.firstOrNull { it.tagObject == previous && it.enabled } ?: defaultFocus(false)
            if (overlay.top === this) overlay.focus(next, false)
            else {
                focus = next
                next?.focused = true
            }
        }
        invalidate()
    }

    private fun buildCreate() {
        // A small gender switch, then either the two ways to start or the look-alike grid.
        add(Item(Act.Gender, value = 0), at(462f, 168f, 170f, 58f), "Male")
        add(Item(Act.Gender, value = 1), at(648f, 168f, 170f, 58f), "Female")
        if (picking) {
            val side = 176f
            val gap = 16f
            val left = (1280 - 6 * side - 5 * gap) / 2
            for (i in 0 until LookAlikeCount)
                add(Item(Act.LookAlike, value = i), at(left + (i % 6) * (side + gap), 254 + (i / 6) * (side + gap), side, side),
                    "Look-alike ${i + 1}")
            add(Item(Act.Back), at(24f, FooterY, 140f, FooterH), "Back")
            add(Item(Act.Shuffle), at(1256 - 160f, FooterY, 160f, FooterH), "Shuffle")
        } else {
            add(Item(Act.Start, value = 0), at(328f, 256f, 300f, 320f), "Start from scratch")
            add(Item(Act.Start, value = 1), at(652f, 256f, 300f, 320f), "Choose a look-alike")
            add(Item(Act.Quit), at(24f, FooterY, 140f, FooterH), "Cancel")
        }
    }

    private fun buildEditor() {
        for (i in 0 until 10) add(Item(Act.Category, i), at(24 + i * 124f, 84f, 116f, 62f), N.categories[i])
        // The preview card's header: the name, then turn left, face front and turn right.
        add(Item(Act.Rotate, value = -1), at(270f, 167f, 46f, 46f), "Turn left")
        add(Item(Act.Front), at(324f, 167f, 46f, 46f), "Face front")
        add(Item(Act.Rotate, value = 1), at(378f, 167f, 46f, 46f), "Turn right")
        // Save and Cancel sit under the preview, below the status line, so the panel runs to the bottom.
        add(Item(Act.Discard), at(92f, FooterY, 140f, FooterH), "Cancel")
        add(Item(Act.Save), at(244f, FooterY, 190f, FooterH), "Save")
        add(Item(Act.Undo), at(1064f, 12f, 56f, 56f), "Undo")
        add(Item(Act.Redo), at(1132f, 12f, 56f, 56f), "Redo")
        add(Item(Act.More), at(1200f, 12f, 56f, 56f), "More")
        when (category) {
            0 -> buildProfile()
            1 -> buildBody()
            else -> buildFeature()
        }
    }

    private fun panel(x: Float, y: Float, w: Float, h: Float) = at(PanelX + x, PanelY + y, w, h)

    private fun buildProfile() {
        val half = (PanelW - 20) / 2
        // Nickname and Creator side by side, each with its count (or what is wrong with it) below.
        for ((n, offset) in intArrayOf(N.NICKNAME, N.CREATOR).withIndex()) {
            val x = n * (half + 20)
            val title = if (n == 0) "Nickname" else "Creator"
            label(panel(x + 2, 0f, half - 2, 24f), 18f, KPWeight.Semibold) { title }
            add(Item(Act.Name, offset, panel = true), panel(x, 30f, half, 58f), title)
            label(panel(x + 2, 94f, half - 2, 22f), 16f, KPWeight.Regular,
                ink = { if (validationMessage != null && validationField == offset) KP.p.danger else KP.p.secondaryText }) {
                validationMessage?.takeIf { validationField == offset } ?: MiiNames.count(N.name(draft, offset))
            }
        }
        // Gender beside Birthday: month and day, each a pair of buttons around its value.
        var y = 140f
        label(panel(2f, y, half, 24f), 18f, KPWeight.Semibold) { "Gender" }
        add(Item(Act.Select, N.GENDER, 0, true), panel(0f, y + 30, (half - 10) / 2, 58f), "Male")
        add(Item(Act.Select, N.GENDER, 1, true), panel((half + 10) / 2, y + 30, (half - 10) / 2, 58f), "Female")
        val bx = half + 20
        label(panel(bx + 2, y, half, 24f), 18f, KPWeight.Semibold) { "Birthday" }
        add(Item(Act.Month, N.MONTH, -1, true), panel(bx, y + 30, 50f, 58f), "Previous month")
        label(panel(bx + 50, y + 46, 120f, 26f), 20f, KPWeight.Semibold, KPAlign.Center, { KP.p.text }) { months[shown[N.MONTH]] }
        add(Item(Act.Month, N.MONTH, 1, true), panel(bx + 170, y + 30, 50f, 58f), "Next month")
        add(Item(Act.Day, N.DAY, -1, true), panel(bx + 230, y + 30, 50f, 58f), "Previous day")
        label(panel(bx + 280, y + 46, 45f, 26f), 20f, KPWeight.Semibold, KPAlign.Center, { KP.p.text }) {
            if (shown[N.MONTH] > 0 && shown[N.DAY] > 0) "${shown[N.DAY]}" else "Day"
        }
        add(Item(Act.Day, N.DAY, 1, true), panel(bx + 325, y + 30, 50f, 58f), "Next day")
        // Favorite and Mingle side by side.
        y += 30 + 58 + 24
        add(Item(Act.Toggle, N.FAVORITE, panel = true), panel(0f, y, half, 58f), "Favorite")
        add(Item(Act.Toggle, N.MINGLE_OFF, panel = true), panel(half + 20, y, half, 58f), "Mingle")
        y += 58 + 24
        label(panel(2f, y, PanelW, 24f), 18f, KPWeight.Semibold) { "Favorite color" }
        val chip = (PanelW - 11 * 8) / 12
        for (i in 0 until 12) add(Item(Act.Select, N.FAVORITE_COLOR, i, true), panel(i * (chip + 8), y + 30, chip, 56f), "Favorite color, choice ${i + 1}")
    }

    private fun buildBody() {
        for ((n, field) in intArrayOf(N.HEIGHT, N.WEIGHT).withIndex()) {
            val y = n * 150f
            val title = if (n == 0) "Height" else "Weight"
            label(panel(4f, y, PanelW - 8, 30f), 22f, KPWeight.Semibold, ink = { KP.p.text }) { title }
            val gauge = add(Item(Act.Gauge, field, panel = true), panel(0f, y + 36, PanelW, 84f), title)
            gauge.radius = 14f
            gauge.adjust = { direction -> stepGauge(field, direction * 4); true }
            gauge.slide = { x, _, face, began -> slideGauge(field, face, x, began); true }
            gauge.activate = null
        }
        // The game snaps height + weight to one of three body models; say which one the preview shows.
        label(panel(4f, 300f, PanelW - 8, 30f), 22f, KPWeight.Semibold, ink = { KP.p.text }) { N.buildName(draft) }
        label(panel(4f, 340f, PanelW - 8, 60f), 18f, KPWeight.Regular) {
            "Height and weight set the Mii’s size, which sets its kart and bike size."
        }
    }

    private fun buildFeature() {
        val ids = N.featureIds(feature)
        val pages = (ids.size + 11) / 12
        page = page.coerceIn(0, max(1, pages) - 1)
        val gridW = PanelW - Side - 18
        // The style grid: three across, four down, with the pager above it only when there is more than one page.
        val pager = if (pages > 1) 68f else 0f
        if (pages > 1) {
            add(Item(Act.Page, value = -1, panel = true), panel(0f, 0f, 56f, 56f), "Previous page").enabled = page > 0
            add(Item(Act.Page, value = 1, panel = true), panel(gridW - 56, 0f, 56f, 56f), "Next page")
            label(panel(64f, 16f, gridW - 128, 26f), 18f, KPWeight.Semibold, KPAlign.Center) { "Page ${page + 1} of $pages" }
        }
        val tileW = (gridW - 2 * Gap) / 3
        val tileH = min(tileW, (PanelH - pager - 3 * Gap) / 4)
        for (i in 0 until 12) {
            val index = page * 12 + i
            if (index >= ids.size) break
            add(Item(Act.Select, feature, ids[index], true),
                panel((i % 3) * (tileW + Gap), pager + (i / 3) * (tileH + Gap), tileW, tileH), "Feature, choice ${ids[index] + 1}")
        }
        // Beside it, a column of colours, the two-part switch, the toggle and the adjustments.
        val x = PanelW - Side
        var y = 0f
        val colorField = N.colorField(category)
        if (colorField >= 0) {
            val count = N.fields[colorField].maximum + 1
            val chipW = (Side - 3 * 8) / 4
            for (i in 0 until count)
                add(Item(Act.Select, colorField, i, true), panel(x + (i % 4) * (chipW + 8), y + (i / 4) * 66, chipW, 58f), "Color, choice ${i + 1}")
            y += ((count + 3) / 4) * 66 - 8 + 16
        }
        val modes = N.modes(category)
        if (modes.isNotEmpty()) {
            val half = (Side - 8) / 2
            modes.forEachIndexed { i, mode ->
                add(Item(Act.Mode, mode.field, panel = true), panel(x + i * (half + 8), y, half, 56f), mode.title)
            }
            y += 56 + 14
        }
        val toggle = N.toggleField(category)
        if (toggle >= 0) {
            add(Item(Act.Toggle, toggle, panel = true), panel(x, y, Side, 58f), N.toggleTitle(category))
            y += 58 + 14
        }
        // Each adjustment is a pair of buttons around its title, naming both directions.
        for (adjustment in N.adjustments(category, draft)) {
            add(Item(Act.Adjust, adjustment.field, -1, true), panel(x, y, 58f, 58f), adjustment.less)
            label(panel(x + 62, y + 18, Side - 124, 24f), 16f, KPWeight.Semibold, KPAlign.Center) { adjustment.title }
            add(Item(Act.Adjust, adjustment.field, 1, true), panel(x + Side - 58, y, 58f, 58f), adjustment.more)
            y += 58 + 10
        }
    }

    /** The states controls show besides focus and press: limits, undo and redo, Save, and what they read out. */
    private fun refreshControls() {
        if (loading) return
        val month = shown.getOrElse(N.MONTH) { 0 }
        val day = shown.getOrElse(N.DAY) { 0 }
        val pages = if (category >= 2) (N.featureIds(feature).size + 11) / 12 else 0
        for (button in buttons) {
            val item = button.tagObject as Item
            button.enabled = when (item.act) {
                Act.Adjust -> N.fields[item.field].let { shown[item.field] + item.value in it.minimum..it.maximum }
                Act.Month -> if (item.value < 0) month > 0 else month < 12
                Act.Day -> month > 0 && if (item.value < 0) day > 1 else day < N.birthdayDays(month)
                Act.Page -> if (item.value < 0) page > 0 else page + 1 < pages
                Act.Undo -> history.canUndo
                Act.Redo -> history.canRedo
                Act.Save -> dirty && !saving
                else -> true
            }
            when (item.act) {
                Act.Adjust -> N.fields[item.field].let {
                    button.label = "${labelOf(item)}, ${shown[item.field] - it.minimum + 1} of ${it.maximum - it.minimum + 1}"
                }
                Act.Toggle -> button.label = "${labelOf(item)}, ${if (toggleOn(item.field, raw)) "On" else "Off"}"
                Act.Gauge -> button.label = "${labelOf(item)}, ${Math.round(shown[item.field] / 127f * 100)} percent"
                Act.Name -> button.label = "${labelOf(item)}, ${N.name(draft, item.field)}. ${MiiNames.Rule}"
                else -> {}
            }
        }
        // A control that just reached its limit hands the focus to its pair.
        val focused = focus
        if (focused != null && !focused.enabled && overlay.top === this) {
            val item = focused.tagObject as Item
            val pair = when (item.act) {
                Act.Adjust, Act.Month, Act.Day, Act.Page -> item.copy(value = -item.value)
                Act.Undo -> Item(Act.Redo)
                Act.Redo -> Item(Act.Undo)
                Act.Save -> Item(Act.Discard)
                else -> null
            }
            overlay.focus(buttons.firstOrNull { it.tagObject == pair && it.enabled } ?: defaultFocus(false), false)
        }
    }

    // The base title of a control whose label also says its value.
    private fun labelOf(item: Item): String = when (item.act) {
        Act.Adjust -> N.adjustments(category, draft).firstOrNull { it.field == item.field }?.let { if (item.value < 0) it.less else it.more } ?: ""
        Act.Toggle -> when (item.field) {
            N.FAVORITE -> "Favorite"
            N.MINGLE_OFF -> "Mingle"
            else -> N.toggleTitle(category)
        }
        Act.Gauge -> if (item.field == N.HEIGHT) "Height" else "Weight"
        Act.Name -> if (item.field == N.CREATOR) "Creator" else "Nickname"
        else -> ""
    }

    // MARK: Tiles

    // The current page's feature tiles in the Mii's own colours. Changing a colour they show renders them
    // again; the old ones stay until each new one is ready.
    private fun requestTiles() {
        if (loading || creating || category < 2) return
        val inputs = runCatching { MiiNative.nativeTileInputs(feature, draft) }.getOrNull()
        if (feature == tileField && page == tilePage && inputs == tileInputs) return
        if (feature != tileField || page != tilePage) tiles.clear()
        MiiImages.cancelPendingTiles()
        tileField = feature
        tilePage = page
        tileInputs = inputs
        val generation = ++tileGeneration
        val ids = N.featureIds(feature)
        val field = feature
        for (index in page * 12 until min(ids.size, page * 12 + 12)) {
            val value = ids[index]
            MiiImages.requestTile(context, field, value, draft) { image ->
                if (generation != tileGeneration) return@requestTile
                if (image != null) tiles[value] = image else tiles.remove(value)
                invalidate()
            }
        }
    }

    // MARK: Drawing

    private fun selected(item: Item) = when (item.act) {
        Act.Select -> shown.getOrElse(item.field) { -1 } == item.value
        Act.Category -> item.field == category
        Act.Mode -> item.field == feature
        Act.Gender -> item.value == gender
        else -> false
    }

    private fun isColor(field: Int) = field == N.FAVORITE_COLOR || field == N.colorField(category)

    private fun style(item: Item): KPStyle = when (item.act) {
        Act.Category -> KPStyle.Tab
        Act.Save -> KPStyle.Primary
        Act.Start -> KPStyle.Card
        Act.LookAlike -> KPStyle.Art
        Act.Select -> if (item.field == N.GENDER) KPStyle.Plain else if (isColor(item.field)) KPStyle.Tile else KPStyle.Art
        Act.Undo, Act.Redo, Act.More, Act.Rotate, Act.Front, Act.Page -> KPStyle.Round
        else -> KPStyle.Plain
    }

    private val image = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)

    // A bitmap fitted and centred in a box.
    private fun drawImage(c: Canvas, bitmap: Bitmap, box: RectF) {
        if (bitmap.width <= 0 || bitmap.height <= 0) return
        val scale = min(box.width() / bitmap.width, box.height() / bitmap.height)
        val w = bitmap.width * scale
        val h = bitmap.height * scale
        c.drawBitmap(bitmap, null, RectF(box.centerX() - w / 2, box.centerY() - h / 2, box.centerX() + w / 2, box.centerY() + h / 2), image)
    }

    private fun portrait(mii: ByteArray): Bitmap? = MiiImages.portrait(context, mii) { invalidate() }

    private fun drawItem(c: Canvas, r: RectF, state: KPUIState, item: Item) {
        val selected = selected(item)
        val style = style(item)
        val face = RectF(r.left, r.top, r.right, r.bottom - 3)
        when (item.act) {
            Act.Gauge -> {
                MiiEditorArt.gauge(c, r, shown[item.field], item.field == N.HEIGHT, dragging == item.field)
                KP.faceRadiusDrawn = 14f // the focus ring goes round the gauge, not its handle
                return
            }
            // A name well: the name as it is stored, and the keyboard it opens.
            Act.Name -> {
                KP.fill(c, r, KP.p.well, 10f)
                KP.stroke(c, r, if (state.pressed) KP.p.accentStroke else KP.p.buttonStroke, if (state.pressed) 2f else 1.25f, 10f)
                KP.text(c, N.name(draft, item.field), RectF(r.left + 16, r.centerY() - 15, r.right - 56, r.centerY() + 17), 22f, KP.p.text,
                    KPWeight.Medium, KPAlign.Left)
                KPGlyphs.draw(c, KPUIGlyph.Keyboard, RectF(r.right - 46, r.centerY() - 14, r.right - 14, r.centerY() + 14), KP.p.secondaryText)
                return
            }
            else -> {}
        }
        KP.buttonFace(c, r, style, selected, state.enabled, state.pressed, state.focused)
        val saved = if (!state.enabled) c.saveLayerAlpha(r.left - 2, r.top - 2, r.right + 2, r.bottom + 2, 107) else c.save()
        if (state.pressed) c.translate(0f, 2f)
        val ink = if (style == KPStyle.Primary || (style == KPStyle.Tab && selected)) 0xffffff else KP.p.icon
        val round = style == KPStyle.Round
        val side = min(face.width(), face.height()) * if (round) .6f else .68f
        val glyph = RectF(face.centerX() - side / 2, face.centerY() - side / 2, face.centerX() + side / 2, face.centerY() + side / 2)
        when (item.act) {
            Act.Category -> {
                val icon = min(36f, face.height() - 14)
                MiiEditorArt.icon(c, item.field, RectF(face.centerX() - icon / 2, face.centerY() - icon / 2, face.centerX() + icon / 2,
                    face.centerY() + icon / 2), ink)
            }
            Act.Gender -> {
                val icon = face.height() - 16
                val title = if (item.value == 1) "Female" else "Male"
                val width = KP.textWidth(title, 20f, KPWeight.Semibold)
                val left = face.centerX() - (icon + 8 + width) / 2
                val tint = if (selected) KP.p.accentStroke else KP.p.icon
                MiiEditorArt.icon(c, if (item.value == 1) MiiEditorArt.FEMALE else MiiEditorArt.MALE,
                    RectF(left, face.top + 8, left + icon, face.top + 8 + icon), tint)
                KP.centeredText(c, title, RectF(left + icon + 8, face.top, left + icon + 12 + width, face.bottom), 20f,
                    if (selected) KP.p.accentStroke else KP.p.text, KPWeight.Semibold, KPAlign.Left)
            }
            Act.Start -> drawStart(c, face, item.value)
            Act.LookAlike -> {
                val well = RectF(face).apply { inset(face.width() * .08f, face.height() * .08f) }
                val bitmap = lookAlikes.getOrNull(item.value)?.let(::portrait)
                if (bitmap != null) drawImage(c, bitmap, well)
                else {
                    val faint = c.saveLayerAlpha(well, 77)
                    MiiEditorArt.icon(c, 2, RectF(well).apply { inset(well.width() * .14f, well.height() * .14f) }, KP.Light.icon)
                    c.restoreToCount(faint)
                }
            }
            Act.Select -> drawSelect(c, face, item, selected)
            Act.Page -> KP.controlIcon(c, glyph, KP.Glyph.Chevron, item.value, ink)
            Act.Month, Act.Day -> {
                val small = min(face.width(), face.height()) * .56f
                KP.controlIcon(c, RectF(face.centerX() - small / 2, face.centerY() - small / 2, face.centerX() + small / 2,
                    face.centerY() + small / 2), KP.Glyph.Chevron, item.value, ink)
            }
            Act.Rotate -> KP.controlIcon(c, glyph, KP.Glyph.Turn, item.value, ink)
            Act.Front -> KP.controlIcon(c, glyph, KP.Glyph.Front, 0, ink)
            Act.Undo, Act.Redo -> KP.controlIcon(c, glyph, KP.Glyph.Undo, if (item.act == Act.Undo) -1 else 1, ink)
            Act.More -> KP.controlIcon(c, glyph, KP.Glyph.More, 0, ink)
            Act.Adjust -> {
                val f = item.field
                val kind = when (f) {
                    45 -> KP.Glyph.Across
                    16, 24, 28, 32, 36, 41, 44 -> KP.Glyph.Move
                    19, 25 -> KP.Glyph.Spacing
                    15, 21 -> KP.Glyph.Rotate
                    else -> KP.Glyph.Size
                }
                KP.controlIcon(c, glyph, kind, item.value, ink)
            }
            Act.Toggle -> {
                val track = RectF(face.right - 14 - 56, face.centerY() - 16, face.right - 14, face.centerY() + 16)
                KP.centeredText(c, labelOf(item), RectF(face.left + 18, face.top, track.left - 12, face.bottom), 20f, KP.p.text,
                    KPWeight.Medium, KPAlign.Left)
                KP.switch(c, track, toggleOn(item.field, raw))
            }
            Act.Mode -> KP.centeredText(c, N.modes(category).firstOrNull { it.field == item.field }?.title ?: "", face, 19f,
                if (selected) KP.p.accentStroke else KP.p.text, KPWeight.Semibold)
            else -> {
                val text = when (item.act) {
                    Act.Save -> "Save"
                    Act.Discard, Act.Quit -> "Cancel"
                    Act.Back -> "Back"
                    Act.Shuffle -> "Shuffle"
                    else -> ""
                }
                KP.centeredText(c, text, face, 21f, if (style == KPStyle.Primary) 0xffffff else KP.p.text, KPWeight.Semibold)
            }
        }
        c.restoreToCount(saved)
    }

    // Light portrait wells, as on the Miis screen, so dark hair shows in dark mode.
    private fun drawStart(c: Canvas, face: RectF, value: Int) {
        val side = min(face.width() - 40, face.height() - 74)
        val well = RectF(face.centerX() - side / 2, face.top + 18, face.centerX() + side / 2, face.top + 18 + side)
        KP.fill(c, well, KP.Light.well, side * .12f)
        if (value == 0) {
            val bitmap = portrait(scratch)
            if (bitmap != null) drawImage(c, bitmap, RectF(well).apply { inset(side * .1f, side * .1f) })
            else MiiEditorArt.icon(c, MiiEditorArt.SCRATCH, RectF(well).apply { inset(side * .16f, side * .16f) }, KP.Light.icon)
        } else {
            // A 2 × 2 sample of the look-alikes.
            val cell = side * .42f
            val gap = side * .04f
            var any = false
            for (k in 0 until min(4, lookAlikes.size)) {
                val bitmap = portrait(lookAlikes[k]) ?: continue
                any = true
                val x = if (k % 2 == 1) well.centerX() + gap / 2 else well.centerX() - gap / 2 - cell
                val y = if (k / 2 == 1) well.centerY() + gap / 2 else well.centerY() - gap / 2 - cell
                drawImage(c, bitmap, RectF(x, y, x + cell, y + cell))
            }
            if (!any) MiiEditorArt.icon(c, MiiEditorArt.LOOK_ALIKES, RectF(well).apply { inset(side * .12f, side * .12f) }, KP.Light.icon)
        }
        KP.centeredText(c, if (value == 0) "Start from scratch" else "Choose a look-alike",
            RectF(face.left + 6, well.bottom + 8, face.right - 6, face.bottom - 6), 22f, KP.p.text, KPWeight.Semibold)
    }

    private fun drawSelect(c: Canvas, face: RectF, item: Item, selected: Boolean) {
        val field = item.field
        if (field == N.GENDER) {
            KP.centeredText(c, if (item.value == 1) "Female" else "Male", face, 20f, KP.p.text, if (selected) KPWeight.Bold else KPWeight.Medium)
            return
        }
        if (isColor(field)) {
            val hex = N.color(field, item.value)
            val chip = RectF(face).apply { inset(6f, 6f) }
            KP.fill(c, chip, hex, 8f)
            KP.stroke(c, chip, 0x000000, 1f, 8f, .16f)
            if (selected) {
                val luma = (.299f * (hex shr 16 and 255) + .587f * (hex shr 8 and 255) + .114f * (hex and 255)) / 255
                val side = min(chip.width(), chip.height()) * .62f
                KP.controlIcon(c, RectF(chip.centerX() - side / 2, chip.centerY() - side / 2, chip.centerX() + side / 2, chip.centerY() + side / 2),
                    KP.Glyph.Check, 0, if (luma > .62f) 0x263238 else 0xffffff)
            }
            return
        }
        val bitmap = tiles[item.value]
        when {
            bitmap != null -> drawImage(c, bitmap, RectF(face).apply { inset(face.width() * .13f, face.height() * .13f) })
            (field == 33 || field == N.MUSTACHE || field == N.BEARD) && item.value == 0 -> {
                val side = min(face.width(), face.height()) * .42f
                KP.controlIcon(c, RectF(face.centerX() - side / 2, face.centerY() - side / 2 - 9, face.centerX() + side / 2,
                    face.centerY() + side / 2 - 9), KP.Glyph.None, 0, KP.Light.icon)
                KP.text(c, "None", RectF(face.left, face.centerY() + side / 2 - 6, face.right, face.centerY() + side / 2 + 16), 15f,
                    KP.Light.secondaryText, KPWeight.Semibold)
            }
            else -> {
                val faint = c.saveLayerAlpha(face, 64)
                MiiEditorArt.icon(c, category, RectF(face).apply { inset(face.width() * .25f, face.height() * .25f) }, KP.Light.icon)
                c.restoreToCount(faint)
            }
        }
    }

    override fun drawDesign(c: Canvas) {
        super.drawDesign(c)
        val s = safe
        if (loading || creating) {
            val note = if (loading) "" else if (!picking) "Start from scratch, or pick from random look-alikes."
                else if (MiiImages.portraitProblem != null) "Faces appear once game data is imported."
                else "Pick a face to start from, or shuffle for new ones."
            KP.text(c, if (picking) "Choose a look-alike" else "Create a Mii", at(0f, 70f, 1280f, 44f), 34f, KP.p.text, KPWeight.Bold)
            KP.text(c, note, at(0f, 122f, 1280f, 28f), 20f, KP.p.secondaryText, KPWeight.Regular)
            return
        }
        KP.text(c, N.categories[category], at(28f, 20f, 900f, 40f), 28f, KP.p.text, KPWeight.Bold, KPAlign.Left)
        KP.card(c, at(PreviewCard), 18f)
        KP.card(c, at(Panel), 18f)
        val well = at(PreviewView).apply { inset(-4f, -4f) }
        KP.fill(c, well, KP.p.well, 14f)
        KP.centeredText(c, N.name(draft, N.NICKNAME), at(40f, 160f, 222f, 60f), 24f, KP.p.text, KPWeight.Semibold, KPAlign.Left)
        for (label in labels) KP.text(c, label.text(), label.rect, label.size, label.ink(), label.weight, label.align)
        // The status line: what is wrong with a name in red, else the preview's state.
        val message = validationMessage ?: previewMessage
        if (!message.isNullOrEmpty())
            KP.text(c, message, RectF(s.left + 30, s.top + 617, s.left + 430, s.top + 641), 16f,
                if (validationMessage != null) KP.p.danger else KP.p.secondaryText, KPWeight.Regular, KPAlign.Left)
    }
}
