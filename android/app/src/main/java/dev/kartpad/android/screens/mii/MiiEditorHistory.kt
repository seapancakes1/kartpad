package dev.kartpad.android.screens.mii

/**
 * The editor's undo and redo (runtime/include/kartpad/mii/editor.h DraftHistory): whole records,
 * at most 200 back. Between begin and end, edits (a held adjustment, a gauge drag, one name) make one
 * entry. Undo and redo end a group.
 */
internal class MiiEditorHistory {
    private val undo = ArrayList<ByteArray>()
    private val redo = ArrayList<ByteArray>()
    private var grouping = false
    private var captured = false

    val canUndo get() = undo.isNotEmpty()
    val canRedo get() = redo.isNotEmpty()

    fun begin() {
        grouping = true
        captured = false
    }

    fun end() {
        grouping = false
        captured = false
    }

    fun record(before: ByteArray, after: ByteArray) {
        if (before.contentEquals(after)) return
        if (!grouping || !captured) {
            undo += before.copyOf()
            if (undo.size > 200) undo.removeAt(0)
            captured = true
        }
        redo.clear()
    }

    fun undo(current: ByteArray): ByteArray {
        end()
        if (undo.isEmpty()) return current
        redo += current.copyOf()
        return undo.removeAt(undo.size - 1)
    }

    fun redo(current: ByteArray): ByteArray {
        end()
        if (redo.isEmpty()) return current
        undo += current.copyOf()
        return redo.removeAt(redo.size - 1)
    }

    fun clear() {
        undo.clear()
        redo.clear()
        end()
    }
}
