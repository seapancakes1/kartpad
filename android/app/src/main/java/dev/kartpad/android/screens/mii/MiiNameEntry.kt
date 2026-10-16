package dev.kartpad.android.screens.mii

import android.content.Context
import android.graphics.Canvas
import android.graphics.Path
import android.graphics.RectF
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.util.TypedValue
import android.view.Gravity
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import dev.kartpad.android.screens.KP
import dev.kartpad.android.screens.KPAlign
import dev.kartpad.android.screens.KPButton
import dev.kartpad.android.screens.KPHint
import dev.kartpad.android.screens.KPHints
import dev.kartpad.android.screens.KPNavigation
import dev.kartpad.android.screens.KPOverlay
import dev.kartpad.android.screens.KPPad
import dev.kartpad.android.screens.KPScreen
import dev.kartpad.android.screens.KPStyle
import dev.kartpad.android.screens.KPUISound
import dev.kartpad.android.screens.KPUIState
import dev.kartpad.android.screens.KPWeight
import dev.kartpad.android.screens.KartPadScreens
import kotlin.math.ceil
import kotlin.math.round

// Typing a Mii or license name: on a Wii-style key grid when the screens are worked with a controller
// (apple/shared/KartPadMiiPadKeyboard.inc.mm), or in a small card with Android's own keyboard when they
// are touched. Rename… on the Miis screen and the editor's Nickname and Creator fields use it.

/** The editor's naming rules (apple/shared/KartPadMiiEditor.inc.mm): 10 UTF-16 units, checked trimmed. */
object MiiNames {
    const val Limit = 10
    /** What the field's hint says. */
    const val Rule = "Up to 10 characters. Emoji and some symbols take up more than one."

    /** UTF-16 units as typed, as the count line counts them. */
    fun units(text: String): Int = text.length

    fun count(text: String) = "${units(text)} of 10 characters"

    /**
     * Why the name can't be stored, or null. It is checked without surrounding spaces, as it is saved;
     * an empty name is only a problem where one is required.
     */
    fun problem(text: String, allowEmpty: Boolean): String? {
        val name = text.trim()
        if (name.isEmpty()) return if (allowEmpty) null else "Enter a name."
        if (name.length > Limit) return "This name is too long."
        return if (storable(name)) null else "This name has a character a Mii can’t use."
    }

    // ValidateUtf16BigEndianName: no control characters, surrogates only in pairs.
    private fun storable(name: String): Boolean {
        var i = 0
        while (i < name.length) {
            val unit = name[i].code
            if (unit < 0x20 || unit in 0xdc00..0xdfff) return false
            if (unit in 0xd800..0xdbff) {
                if (i + 1 >= name.length || name[i + 1].code !in 0xdc00..0xdfff) return false
                i++
            }
            i++
        }
        return true
    }
}

object MiiNameEntry {
    /** Asks for a name; done gets it as typed (stored trimmed), or null on Cancel. */
    fun ask(overlay: KPOverlay, title: String, initial: String, allowEmpty: Boolean, done: (String?) -> Unit) =
        ask(overlay, title, null, initial, allowEmpty, "OK", done)

    /** As above, with a line under the title and the confirming button's word (Rename) for the touch card. */
    fun ask(overlay: KPOverlay, title: String, message: String?, initial: String, allowEmpty: Boolean, action: String,
            done: (String?) -> Unit) {
        overlay.present(if (!overlay.touching) MiiPadKeyboardScreen(overlay, title, initial, allowEmpty, done)
            else MiiTextNameScreen(overlay, title, message, initial, allowEmpty, action, done))
    }
}

/**
 * The controller keyboard: a name well with its count (or what is wrong, in red), letters and digits, a
 * page of accented letters and punctuation, and Shift, Space, Delete, Cancel and OK. The D-pad moves
 * between keys (wrapping at the edges), A types, B deletes, X is Shift (twice for caps lock; on by itself
 * for an empty name), Y types a space, LB/RB switch pages and Start is OK. Touch and a hardware keyboard
 * work too. done gets the name, or null on Cancel.
 */
class MiiPadKeyboardScreen(
    overlay: KPOverlay, private val heading: String, initial: String, private val allowEmpty: Boolean,
    private val done: (String?) -> Unit,
) : KPScreen(overlay) {
    override val overPrevious get() = true
    private var text = initial
    private var problem: String? = null
    private var shift = initial.isEmpty()
    private var capsLock = false
    private var page = 0
    // The 40 character keys, then Shift, page, Space, Delete, Cancel and OK.
    private val keys = ArrayList<KPButton>()
    private var finished = false
    private var opened = false
    private var backDown = -1

    companion object {
        /** Letters and digits, then accented letters and punctuation (the Mac's KPPadKeyRows). Shift capitalises either page. */
        val Pages = arrayOf(
            arrayOf("1234567890", "qwertyuiop", "asdfghjkl'", "zxcvbnm,.-"),
            arrayOf("!?&#@()\":;", "àáâäãåæçèé", "êëìíîïñòóô", "öõøœùúûüßÿ"),
        )
        private const val KeyW = 72f
        private const val KeyH = 62f
        private const val Gap = 8f
        private const val Margin = 28f
        private const val CardH = 584f
        // The bottom row in the Mac's proportions: Shift, page, Space, Delete, Cancel, OK.
        private val BottomWidths = floatArrayOf(76f, 76f, 160f, 76f, 68f, 68f)
    }

    private fun character(index: Int): String = Pages[page][index / 10].substring(index % 10, index % 10 + 1)

    private fun label(character: String): String {
        if (!shift) return character
        val upper = character.uppercase()
        return if (upper.length == 1) upper else character
    }

    private fun card(): RectF {
        val s = safe
        val width = 10 * KeyW + 9 * Gap + 2 * Margin
        val top = round(s.top + (720 - CardH) / 2)
        val left = round(s.left + (1280 - width) / 2)
        return RectF(left, top, left + width, top + CardH)
    }

    override fun build() {
        title = heading
        solid = false
        for (index in 0 until 40) {
            val key = button(RectF(), { c, r, state -> drawKey(c, r, state, KPStyle.Plain, false) { label(character(index)) } }) {
                type(label(character(index)))
            }
            key.sound = null
            key.radius = 10f
            keys += key
        }
        val titles = listOf("Shift", "Symbols", "Space", "Delete", "Cancel", "OK")
        for (i in 0 until 6) {
            val key = button(RectF(), { c, r, state ->
                when (i) {
                    0 -> drawKey(c, r, state, KPStyle.Plain, shift, null) { ink, face -> shiftGlyph(c, face, capsLock, ink) }
                    1 -> drawKey(c, r, state, KPStyle.Plain, false) { if (page == 0) "àé?" else "ABC" }
                    2 -> drawKey(c, r, state, KPStyle.Plain, false) { "Space" }
                    3 -> drawKey(c, r, state, KPStyle.Plain, false, null) { ink, face -> eraseGlyph(c, face, ink) }
                    4 -> drawKey(c, r, state, KPStyle.Plain, false) { "Cancel" }
                    else -> drawKey(c, r, state, KPStyle.Primary, false) { "OK" }
                }
            }) {
                when (i) {
                    0 -> toggleShift()
                    1 -> togglePage()
                    2 -> type(" ")
                    3 -> erase()
                    4 -> finish(false)
                    else -> finish(true)
                }
            }
            key.sound = null
            key.radius = 10f
            key.label = titles[i]
            keys += key
        }
        refresh()
    }

    override fun layoutDesign() {
        val card = card()
        val top = card.top + 180
        for (index in 0 until 40) {
            val x = card.left + Margin + (index % 10) * (KeyW + Gap)
            val y = top + (index / 10) * (KeyH + Gap)
            place(keys[index], RectF(x, y, x + KeyW, y + KeyH))
        }
        val grid = 10 * KeyW + 9 * Gap
        val scale = (grid - 5 * Gap) / BottomWidths.sum()
        var x = card.left + Margin
        val y = top + 4 * (KeyH + Gap)
        for (i in 0 until 6) {
            val w = if (i == 5) card.left + Margin + grid - x else round(BottomWidths[i] * scale)
            place(keys[40 + i], RectF(x, y, x + w, y + KeyH))
            x += w + Gap
        }
    }

    // The first letter on the top row of letters.
    override fun initialFocus(): KPButton? = keys.getOrNull(10)

    override fun willAppear() {
        if (opened) return
        opened = true
        overlay.play(KPUISound.Open)
    }

    private fun refresh() {
        for (index in 0 until 40) keys[index].label = label(character(index))
        invalidate()
    }

    private fun type(typed: String) {
        // At most 10 units as typed; the rest is checked as the name is kept.
        val next = text + typed
        val wrong = if (next.length > MiiNames.Limit) "This name is too long." else MiiNames.problem(next, true)
        if (wrong != null) {
            problem = wrong
            overlay.play(KPUISound.Reject)
            invalidate()
            return
        }
        text = next
        overlay.play(KPUISound.Key)
        problem = null
        if (shift && !capsLock) shift = false
        refresh()
    }

    private fun erase() {
        if (text.isEmpty()) {
            overlay.play(KPUISound.Reject)
            return
        }
        var end = text.length - 1
        if (end > 0 && text[end].isLowSurrogate() && text[end - 1].isHighSurrogate()) end--
        text = text.substring(0, end)
        overlay.play(KPUISound.Erase)
        problem = null
        if (text.isEmpty() && !capsLock) shift = true
        refresh()
    }

    // Off, then one capital, then caps lock, then off.
    private fun toggleShift() {
        if (!shift) shift = true else if (!capsLock) capsLock = true else { shift = false; capsLock = false }
        overlay.play(KPUISound.Tab)
        refresh()
    }

    private fun togglePage() {
        page = 1 - page
        overlay.play(KPUISound.Tab)
        refresh()
    }

    private fun finish(ok: Boolean) {
        if (finished) return
        if (ok) MiiNames.problem(text, allowEmpty)?.let {
            problem = it
            overlay.play(KPUISound.Reject)
            invalidate()
            return
        }
        finished = true
        if (overlay.top === this) overlay.pop()
        overlay.play(if (ok) KPUISound.Confirm else KPUISound.Close)
        done(if (ok) text else null)
    }

    override fun back() = finish(false)

    override fun handle(button: KPPad): Boolean = when (button) {
        KPPad.Up -> move(0, -1)
        KPPad.Down -> move(0, 1)
        KPPad.Left -> move(-1, 0)
        KPPad.Right -> move(1, 0)
        KPPad.Back -> { erase(); true }
        KPPad.Undo -> { toggleShift(); true }
        KPPad.Redo -> { type(" "); true }
        KPPad.PreviousTab, KPPad.NextTab -> { togglePage(); true }
        KPPad.Start -> { finish(true); true }
        KPPad.Confirm -> false
    }

    // The nearest key that way; off the edge, the far end of the same row or column.
    private fun move(dx: Int, dy: Int): Boolean {
        val from = keys.indexOf(focus)
        if (from < 0) {
            overlay.focus(initialFocus(), true)
            return true
        }
        val frames = keys.map { it.frame }
        var next = KPNavigation.nearest(frames, from, dx, dy)
        if (next < 0) {
            val here = frames[from]
            var best = -Float.MAX_VALUE
            for ((i, r) in frames.withIndex()) {
                if (i == from) continue
                val inLine = if (dx != 0) r.top < here.bottom && here.top < r.bottom else r.left < here.right && here.left < r.right
                val score = if (dx != 0) -dx * r.centerX() else -dy * r.centerY()
                if (inLine && score > best) {
                    best = score
                    next = i
                }
            }
        }
        if (next >= 0) overlay.focus(keys[next], true)
        return true
    }

    // A hardware keyboard types, deletes, confirms and cancels; arrows and pads move as above.
    override fun takesKey(event: KeyEvent): Boolean {
        val down = event.action == KeyEvent.ACTION_DOWN
        when (event.keyCode) {
            KeyEvent.KEYCODE_ESCAPE, KeyEvent.KEYCODE_BACK -> {
                if (down && event.repeatCount == 0) backDown = event.keyCode
                else if (!down && backDown == event.keyCode) {
                    backDown = -1
                    finish(false)
                }
                return true
            }
            KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> {
                if (down && event.repeatCount == 0) finish(true)
                return true
            }
            KeyEvent.KEYCODE_DEL -> {
                if (down) erase()
                return true
            }
        }
        if (KeyEvent.isGamepadButton(event.keyCode)) return false
        val unicode = event.unicodeChar
        if (unicode < 0x20 || unicode == 0x7f) return false
        if (down) type(String(Character.toChars(unicode)))
        return true
    }

    // MARK: Drawing

    private fun drawKey(c: Canvas, r: RectF, state: KPUIState, style: KPStyle, selected: Boolean, title: () -> String) =
        drawKey(c, r, state, style, selected, title()) { _, _ -> }

    private fun drawKey(c: Canvas, r: RectF, state: KPUIState, style: KPStyle, selected: Boolean, title: String?,
                        glyph: (ink: Int, face: RectF) -> Unit) {
        KP.buttonFace(c, r, style, selected, true, state.pressed, state.focused)
        val dy = if (state.pressed) 2f else 0f
        val face = RectF(r.left + 4, r.top + dy, r.right - 4, r.bottom - 3 + dy)
        val ink = if (style == KPStyle.Primary) 0xffffff else KP.p.text
        if (title == null) {
            glyph(ink, face)
            return
        }
        val size = if (title.length > 1) 20f else 26f
        KP.centredLabel(c, title, face, size, ink, KPWeight.Semibold)
    }

    // ⇧, or ⇪ for caps lock, drawn (the bundled face has no arrows).
    private fun shiftGlyph(c: Canvas, face: RectF, locked: Boolean, ink: Int) {
        val box = glyphBox(face, 34f)
        val u = box.width() / 40
        val path = Path()
        path.moveTo(box.left + 20 * u, box.top + 5 * u)
        path.lineTo(box.left + 35 * u, box.top + 21 * u)
        path.lineTo(box.left + 26 * u, box.top + 21 * u)
        path.lineTo(box.left + 26 * u, box.top + (if (locked) 28 else 33) * u)
        path.lineTo(box.left + 14 * u, box.top + (if (locked) 28 else 33) * u)
        path.lineTo(box.left + 14 * u, box.top + 21 * u)
        path.lineTo(box.left + 5 * u, box.top + 21 * u)
        path.close()
        if (locked) {
            c.drawPath(path, KP.ink(ink))
            KP.fill(c, RectF(box.left + 14 * u, box.top + 31 * u, box.left + 26 * u, box.top + 35 * u), ink, u)
        } else c.drawPath(path, KP.ink(ink, stroke = 2.6f * u))
    }

    // ⌫: a key pointing left with a cross in it.
    private fun eraseGlyph(c: Canvas, face: RectF, ink: Int) {
        val box = glyphBox(face, 34f)
        val u = box.width() / 40
        val path = Path()
        path.moveTo(box.left + 4 * u, box.top + 20 * u)
        path.lineTo(box.left + 14 * u, box.top + 9 * u)
        path.lineTo(box.left + 36 * u, box.top + 9 * u)
        path.lineTo(box.left + 36 * u, box.top + 31 * u)
        path.lineTo(box.left + 14 * u, box.top + 31 * u)
        path.close()
        val line = KP.ink(ink, stroke = 2.6f * u)
        c.drawPath(path, line)
        c.drawLine(box.left + 19 * u, box.top + 15 * u, box.left + 29 * u, box.top + 25 * u, line)
        c.drawLine(box.left + 29 * u, box.top + 15 * u, box.left + 19 * u, box.top + 25 * u, line)
    }

    private fun glyphBox(face: RectF, side: Float) =
        RectF(face.centerX() - side / 2, face.centerY() - side / 2, face.centerX() + side / 2, face.centerY() + side / 2)

    override fun drawDesign(c: Canvas) {
        KP.fill(c, RectF(0f, 0f, width, height), 0x000000, 0f, .35f)
        val card = card()
        // The Mii Channel's pinstriped panel, the name in a well with a caret, and its count or problem below.
        KP.shadowed(c, 10f, 30f, .35f, card, KP.p.background, 24f)
        val clip = Path()
        clip.addRoundRect(card, 24f, 24f, Path.Direction.CW)
        c.save()
        c.clipPath(clip)
        KP.pinstripes(c, card, KP.p.stripe)
        c.restore()
        KP.stroke(c, card, KP.p.panelStroke, 1.5f, 24f)
        val left = card.left + Margin
        val right = card.right - Margin
        KP.text(c, heading, RectF(left, card.top + 22, right, card.top + 58), 26f, KP.p.text, KPWeight.Bold, KPAlign.Left)
        val well = RectF(left, card.top + 66, right, card.top + 136)
        val wrong = problem
        KP.fill(c, well, KP.p.panel, 14f)
        KP.stroke(c, well, if (wrong != null) KP.p.danger else KP.p.panelStroke, if (wrong != null) 2f else 1f, 14f)
        KP.centeredText(c, "$text|", RectF(well.left + 20, well.top, well.right - 20, well.bottom), 30f, KP.p.text, KPWeight.Medium,
            KPAlign.Left)
        KP.text(c, wrong ?: MiiNames.count(text), RectF(left + 4, card.top + 144, right - 4, card.top + 168), 17f,
            if (wrong != null) KP.p.danger else KP.p.secondaryText, KPWeight.Regular, KPAlign.Left)
        KPHints.draw(c, RectF(left, card.bottom - 46, right, card.bottom - 20),
            listOf(KPHint(KPPad.Confirm, "Type"), KPHint(KPPad.Back, "Delete"), KPHint(KPPad.Undo, "Shift"), KPHint(KPPad.Redo, "Space"),
                KPHint(KPPad.PreviousTab, "Symbols", KPPad.NextTab), KPHint(KPPad.Start, "OK")), 15f, KPAlign.Center)
    }
}

/**
 * The touch card: Android's own keyboard in a field near the top (clear of the keyboard), with the live
 * count or what is wrong in red, Cancel, and the action while the name can be stored. A controller press
 * other than B (Cancel) or Start (the action) brings the controller keyboard instead, as the Mac's alerts do.
 */
internal class MiiTextNameScreen(
    overlay: KPOverlay, private val heading: String, private val message: String?, private val initial: String,
    private val allowEmpty: Boolean, private val action: String, private val done: (String?) -> Unit,
) : KPScreen(overlay) {
    override val overPrevious get() = true
    // While it has the focus Android hands it the gamepads' presses, which go on to SDL's surface instead.
    private val field: EditText = object : EditText(overlay.activity) {
        override fun onGenericMotionEvent(event: MotionEvent): Boolean =
            KartPadScreens.host.gameSurface?.dispatchGenericMotionEvent(event) == true || super.onGenericMotionEvent(event)
    }
    private lateinit var cancel: KPButton
    private lateinit var confirm: KPButton
    private var status = ""
    private var wrong = false
    private var checked: String? = null
    private var finished = false
    private var opened = false
    private var lines = 0

    private fun card(): RectF {
        val s = safe
        val top = s.top + 24
        val text = if (lines > 0) lines * 18f * 1.193f + 10 else 0f
        return RectF(s.left + 240, top, s.left + 1040, top + 24 + 40 + text + 14 + 64 + 8 + 24 + 22)
    }

    private fun rowTop(card: RectF) = card.top + 24 + 40 + (if (lines > 0) lines * 18f * 1.193f + 10 else 0f) + 14

    override fun build() {
        title = heading
        solid = false
        message?.takeIf { it.isNotEmpty() }?.let {
            lines = ceil(KP.textHeight(it, 736f, 18f, KPWeight.Regular) / (18f * 1.193f)).toInt().coerceIn(1, 2)
        }
        cancel = button(RectF(), { c, r, state -> drawButton(c, r, state, KPStyle.Plain, "Cancel") }) { finish(false) }
        cancel.sound = null
        cancel.label = "Cancel"
        confirm = button(RectF(), { c, r, state -> drawButton(c, r, state, KPStyle.Primary, action) }) { finish(true) }
        confirm.sound = null
        confirm.label = action
        field.setText(initial)
        field.setSelection(field.text.length)
        field.setSingleLine(true)
        field.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_WORDS or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        // No full-screen extract view, so the card and the count stay in sight.
        field.imeOptions = EditorInfo.IME_ACTION_DONE or EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN
        field.background = null
        field.setPadding(0, 0, 0, 0)
        field.gravity = Gravity.CENTER_VERTICAL or Gravity.START
        field.typeface = KP.typeface(KPWeight.Medium)
        field.hint = "Name"
        field.contentDescription = MiiNames.Rule
        field.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
            override fun afterTextChanged(s: Editable?) = check()
        })
        field.setOnKeyListener { _, _, event ->
            val pad = KeyEvent.isGamepadButton(event.keyCode) || event.isFromSource(InputDevice.SOURCE_GAMEPAD) ||
                event.isFromSource(InputDevice.SOURCE_JOYSTICK)
            pad && KartPadScreens.host.gameSurface?.dispatchKeyEvent(event) == true
        }
        field.setOnEditorActionListener { _, id, _ ->
            if (id == EditorInfo.IME_ACTION_DONE) {
                finish(true)
                true
            } else false
        }
        check()
    }

    override fun layoutDesign() {
        val card = card()
        val top = rowTop(card)
        val buttonW = 150f
        place(confirm, RectF(card.right - 32 - buttonW, top, card.right - 32, top + 64))
        place(cancel, RectF(card.right - 32 - 2 * buttonW - 14, top, card.right - 32 - buttonW - 14, top + 64))
        val well = well(card)
        placeView(field, RectF(well.left + 18, well.top + 6, well.right - 18, well.bottom - 6))
        field.setTextSize(TypedValue.COMPLEX_UNIT_PX, 26f * overlay.scale)
        field.setTextColor(KP.argb(KP.p.text))
        field.setHintTextColor(KP.argb(KP.p.secondaryText, .7f))
    }

    private fun well(card: RectF): RectF {
        val top = rowTop(card)
        return RectF(card.left + 32, top, card.right - 32 - 2 * 150 - 28, top + 64)
    }

    override fun initialFocus(): KPButton? = confirm.takeIf { it.enabled } ?: cancel

    override fun willAppear() {
        if (opened) return
        opened = true
        overlay.play(KPUISound.Dialog)
    }

    override fun didAppear() {
        field.requestFocus()
        // Asked for outright (an implicit request may be ignored), and once more after the field has laid out.
        val show = Runnable {
            val keyboard = overlay.activity.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
            if (!finished) keyboard?.showSoftInput(field, 0)
        }
        field.post(show)
        field.postDelayed(show, 250)
    }

    // The keyboard goes, and the game's surface gets the focus back so SDL keeps the gamepads.
    override fun willDisappear() = release()

    private fun release() {
        val keyboard = overlay.activity.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
        field.windowToken?.let { keyboard?.hideSoftInputFromWindow(it, 0) }
        field.clearFocus()
        KartPadScreens.host.gameSurface?.requestFocus()
    }

    // Composing text (a word being built in the keyboard) is checked once it's committed.
    private fun check() {
        val editable = field.text ?: return
        if (BaseInputConnection.getComposingSpanStart(editable) >= 0) return
        val text = editable.toString()
        if (text == checked) return
        checked = text
        val problem = MiiNames.problem(text, allowEmpty)
        status = problem ?: MiiNames.count(text)
        wrong = problem != null
        if (::confirm.isInitialized) confirm.enabled = problem == null
        invalidate()
    }

    override fun tick() = check()

    private fun finish(ok: Boolean) {
        if (finished) return
        val text = field.text?.toString() ?: ""
        if (ok && MiiNames.problem(text, allowEmpty) != null) {
            overlay.play(KPUISound.Reject)
            return
        }
        finished = true
        release()
        if (overlay.top === this) overlay.pop()
        overlay.play(if (ok) KPUISound.Confirm else KPUISound.Close)
        done(if (ok) text else null)
    }

    override fun back() = finish(false)

    override fun handle(button: KPPad): Boolean {
        when (button) {
            KPPad.Back -> return false
            KPPad.Start -> finish(true)
            else -> {
                // The controller keyboard takes over with the name so far; its OK and Cancel answer for this card.
                if (finished) return true
                finished = true
                val text = field.text?.toString() ?: ""
                release()
                overlay.replaceTop(MiiPadKeyboardScreen(overlay, heading, text, allowEmpty, done))
            }
        }
        return true
    }

    // Keys from a hardware keyboard go to the field, which the screens would otherwise take for navigation.
    override fun takesKey(event: KeyEvent): Boolean {
        val down = event.action == KeyEvent.ACTION_DOWN
        when (event.keyCode) {
            KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> {
                if (down && event.repeatCount == 0) finish(true)
                return true
            }
            KeyEvent.KEYCODE_ESCAPE -> {
                if (down && event.repeatCount == 0) finish(false)
                return true
            }
            KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN, KeyEvent.KEYCODE_DPAD_CENTER -> return false
        }
        if (KeyEvent.isGamepadButton(event.keyCode) || !field.hasFocus()) return false
        field.dispatchKeyEvent(event)
        return true
    }

    private fun drawButton(c: Canvas, r: RectF, state: KPUIState, style: KPStyle, title: String) {
        KP.buttonFace(c, r, style, false, state.enabled, state.pressed, state.focused)
        val dy = if (state.pressed) 2f else 0f
        val face = RectF(r.left + 8, r.top + dy, r.right - 8, r.bottom - 3 + dy)
        KP.text(c, title, RectF(face.left, face.centerY() - 21 * .66f, face.right, face.centerY() - 21 * .66f + 32), 21f,
            if (style == KPStyle.Primary) 0xffffff else KP.p.text, KPWeight.Semibold, KPAlign.Center, if (state.enabled) 1f else .42f)
    }

    override fun drawDesign(c: Canvas) {
        KP.fill(c, RectF(0f, 0f, width, height), 0x000000, 0f, .35f)
        val card = card()
        KP.shadowed(c, 10f, 30f, .35f, card, KP.p.panel, 28f)
        KP.stroke(c, card, KP.p.panelStroke, 1.5f, 28f)
        KP.text(c, heading, RectF(card.left + 32, card.top + 24, card.right - 32, card.top + 64), 28f, KP.p.text, KPWeight.Bold, KPAlign.Left)
        if (lines > 0) KP.text(c, message ?: "", RectF(card.left + 32, card.top + 70, card.right - 32, card.top + 70 + lines * 18f * 1.193f + 6),
            18f, KP.p.secondaryText, KPWeight.Regular, KPAlign.Left)
        val well = well(card)
        KP.fill(c, well, KP.p.well, 14f)
        KP.stroke(c, well, if (wrong) KP.p.danger else KP.p.panelStroke, if (wrong) 2f else 1f, 14f)
        KP.text(c, status, RectF(well.left + 4, well.bottom + 8, card.right - 32, well.bottom + 32), 17f,
            if (wrong) KP.p.danger else KP.p.secondaryText, KPWeight.Regular, KPAlign.Left)
    }
}
