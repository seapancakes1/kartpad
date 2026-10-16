package dev.kartpad.android

import android.system.Os
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.util.UUID
import java.util.zip.CRC32
import java.util.zip.CheckedOutputStream

/**
 * The Miis screen's data. Every Mii and license change waits in a queue (PendingMiiChanges.bin)
 * until the next cold launch, because the running game holds the database and saves. A change is
 * checked against the queue replayed over the live files before it is added; launch replays the
 * queue over the latest files, keeping race progress saved meanwhile, and a change that no longer
 * fits rejects the whole queue with nothing written. Older single-change files apply first, and
 * nothing is queued until they have. Call everything off the main thread; nothing throws.
 */
internal object KartPadMiiChanges {
    /** A Mii as the queue will leave it. createId is 16 hex digits (the record's 0x18-0x1F). */
    class Mii(
        val slot: Int, val createId: String, val name: String, val creator: String,
        val favoriteColor: Int, val record: ByteArray, val licenses: List<License>,
    ) {
        override fun equals(other: Any?) = other is Mii && slot == other.slot &&
            createId == other.createId && name == other.name && creator == other.creator &&
            favoriteColor == other.favoriteColor && record.contentEquals(other.record) &&
            licenses == other.licenses
        override fun hashCode() = 31 * createId.hashCode() + record.contentHashCode()
    }

    /**
     * A license as the queue will leave it. createId is the Mii it races as; miiSlot is that Mii's
     * slot, or null when it is missing. pendingOperation is "", "rename", "delete" (still listed
     * until launch) or "mii".
     */
    data class License(
        val profile: String, val profileTitle: String, val slot: Int, val name: String,
        val createId: String, val pendingOperation: String, val miiSlot: Int?,
    ) {
        val missingLinkedMii get() = miiSlot == null
    }

    sealed interface Snapshot

    /** The Miis and licenses as they will be after the next launch. */
    data class Upcoming(
        val miis: List<Mii>,
        val licenses: List<License>,
        val orphanedLicenses: List<License>,
        val pendingCount: Int,
        val latestDescription: String?,
        /** Why nothing can be queued now (another pending change); null when changes can be. */
        val blockedReason: String?,
        val canDiscard: Boolean,
        /** A save that exists but can't be read; changes that touch it fail. */
        val saveProblem: String?,
    ) : Snapshot {
        val canQueue get() = blockedReason == null
        val licensesByProfile get() = licenses.groupBy { it.profile }
    }

    /** Why the Miis can't be shown. offerDiscard: discarding the waiting changes would help. */
    data class Unavailable(val reason: String, val offerDiscard: Boolean) : Snapshot

    fun upcoming(files: File): Snapshot = synchronized(lock) {
        try {
            if (KartPadMiiStorage.journalFile(files).isFile) return Unavailable(INTERRUPTED, false)
            val replayed = current(files).replayed
            (replayed.error ?: replayed.databaseProblem)?.let { return Unavailable(it, canDiscard(files)) }
            Upcoming(
                replayed.miis, replayed.licenses, replayed.licenses.filter { it.missingLinkedMii },
                count(files, replayed.descriptions), replayed.descriptions.lastOrNull(),
                blockedReason(files), canDiscard(files), replayed.saveProblem,
            )
        } catch (failure: Exception) {
            Unavailable(readable(failure, "The Mii database couldn’t be read."), canDiscard(files))
        }
    }

    /** Waiting changes, counting an older kind of pending change (or an unreadable queue) as one. */
    fun pendingCount(files: File): Int = synchronized(lock) { count(files, descriptions(files)) }

    /** The newest waiting change, as the banner names it. */
    fun latestDescription(files: File): String? = synchronized(lock) { descriptions(files)?.lastOrNull() }

    /**
     * An editor save. For an edit, slot and expected (the record the editor opened) say which Mii
     * it replaces; both are null for a new Mii or a duplicate. The name is trimmed as licenses
     * store it. Returns the banner text.
     */
    fun saveMii(files: File, slot: Int?, expected: ByteArray?, record: ByteArray): Result<String> =
        change(files, "The Mii couldn’t be saved.") {
            if ((slot == null) != (expected == null)) fail("Invalid Mii selection.")
            Change(SAVE, slot = slot ?: -1, record = normalizedRecord(record), expected = expected)
        }

    /** A .mii file's 74 bytes, added as a new Mii. */
    fun importMii(files: File, bytes: ByteArray): Result<String> =
        change(files, "The Mii couldn’t be imported.") { Change(IMPORT, record = bytes) }

    /** A new Mii for the editor: a unique Mii ID and this console's ID. Nothing is queued. */
    fun newMii(files: File): Result<ByteArray> = synchronized(lock) {
        attempt("A new Mii couldn’t be made.") { create(files, null) }
    }

    /** A copy of the Mii for the editor, with a fresh Mii ID and this console's ID. Nothing is queued. */
    fun duplicate(files: File, createId: String): Result<ByteArray> = synchronized(lock) {
        attempt("The Mii couldn’t be duplicated.") { create(files, mii(files, createId).record) }
    }

    fun removeMii(files: File, createId: String): Result<String> =
        change(files, "The Mii couldn’t be removed.") {
            Change(REMOVE, slot = mii(files, createId).slot, createId = identity(createId))
        }

    /** Renames the Mii and every license that races as it, keeping progress and friend codes. */
    fun renameMii(files: File, createId: String, name: String): Result<String> =
        change(files, "The Mii couldn’t be renamed.") {
            Change(RENAME, slot = mii(files, createId).slot, createId = identity(createId), name = nameBytes(name))
        }

    /** Renames one license, and the Mii it races as. createId is the license's, from the listing. */
    fun renameLicense(files: File, profile: String, slot: Int, createId: String, name: String): Result<String> =
        change(files, "The license couldn’t be renamed.") {
            Change(LICENSE_RENAME, profile(profile), slot, identity(createId), name = nameBytes(name))
        }

    fun deleteLicense(files: File, profile: String, slot: Int, createId: String): Result<String> =
        change(files, "The license couldn’t be deleted.") {
            Change(LICENSE_DELETE, profile(profile), slot, identity(createId))
        }

    /** The license races as another Mii, keeping its progress and friend code. */
    fun setLicenseMii(files: File, profile: String, slot: Int, createId: String, miiCreateId: String): Result<String> =
        change(files, "The Mii couldn’t be linked.") {
            Change(LICENSE_MII, profile(profile), slot, identity(createId),
                miiSlot = mii(files, miiCreateId).slot, miiCreateId = identity(miiCreateId))
        }

    /** The Mii's standard 74-byte .mii record, as it will be after the next launch. */
    fun exportMii(files: File, createId: String): Result<ByteArray> = synchronized(lock) {
        attempt("The Mii couldn’t be exported.") { mii(files, createId).record.copyOf() }
    }

    /** Whether discardAll has anything to drop. An interrupted commit can't be discarded. */
    fun canDiscard(files: File): Boolean = discardable(files).any { it.exists() }

    /** Drops every waiting Mii and license change, an older version's included. Live files stay. */
    fun discardAll(files: File): Result<Unit> = synchronized(lock) {
        attempt("The waiting changes couldn’t be discarded.") {
            cache = null
            for (file in discardable(files)) check(!file.exists() || file.delete())
            val root = File(files, ROOT)
            if (root.isDirectory) KartPadAtomicFile.syncDirectory(root)
        }
    }

    /**
     * Called once at cold launch before the game starts: finishes an interrupted commit (without
     * replaying the queue again), applies an older version's pending database and identity change,
     * then replays the queue over the latest files and commits what it changed. Returns why it
     * couldn't; the game must not start until this returns null. When canDiscard is true,
     * discardAll then another call lets it start with Miis and licenses as they are.
     */
    fun applyAtLaunch(files: File): String? = synchronized(lock) {
        cache = null
        finishInterruptedCommit(files)?.let { return it }
        KartPadMiiStorage.applyPending(files)?.let { return it }
        KartPadIdentityStorage.applyPending(files)?.let { return it }
        applyQueue(files)
    }

    private class Entry(val target: Int, val before: ByteArray, val after: ByteArray)

    private fun applyQueue(files: File): String? {
        if (!KartPadMiiStorage.queueFile(files).exists()) return null
        return try {
            val queue = readQueue(files)
            val targets = targets(files)
            val live = readFiles(targets)
            val replayed = parse(nativeReplay(live[0], live.drop(1).toTypedArray(), queue))
            replayed.error?.let { return it }
            val entries = replayed.changed.indices.mapNotNull { index ->
                replayed.changed[index]?.let { Entry(index, checkNotNull(live[index]), it) }
            }
            // Back up, then journal every replacement before any live file changes.
            val stamp = "${System.currentTimeMillis()}-${UUID.randomUUID()}"
            for (entry in entries) KartPadMiiStorage.backup(files, profileName(entry.target), entry.before, stamp)
            if (entries.isNotEmpty()) KartPadAtomicFile.write(KartPadMiiStorage.journalFile(files), encodeJournal(entries))
            commit(files, entries)
            null
        } catch (failure: Exception) {
            readable(failure, "The pending Mii changes couldn’t be applied safely. Backups were kept.")
        }
    }

    // Every file the journal names must still hold its old or new contents.
    private fun finishInterruptedCommit(files: File): String? {
        if (!KartPadMiiStorage.journalFile(files).exists()) return null
        return try {
            val entries = readJournal(files)
            val targets = targets(files)
            for (entry in entries) {
                if (entry.target == 0) {
                    if (!KartPadMiiStorage.isValidDatabase(entry.before) || !KartPadMiiStorage.isValidDatabase(entry.after))
                        fail(INVALID_JOURNAL)
                } else {
                    KartPadSaveStorage.validate(entry.before)
                    KartPadSaveStorage.validate(entry.after)
                }
                val current = read(targets[entry.target], entry.after.size)
                if (current == null || !(current.contentEquals(entry.before) || current.contentEquals(entry.after)))
                    fail("Game data changed since the Mii edit. Nothing further was applied.")
            }
            commit(files, entries)
            null
        } catch (failure: Exception) {
            readable(failure, "An interrupted Mii change couldn’t be finished. Backups were kept.")
        }
    }

    // Writes each file's new contents, then drops the queue and only then the journal: a crash in
    // between rolls forward again rather than replaying the queue a second time.
    private fun commit(files: File, entries: List<Entry>) {
        val targets = targets(files)
        for (entry in entries) {
            val target = targets[entry.target]
            if (read(target, entry.after.size)?.contentEquals(entry.after) == true) {
                KartPadAtomicFile.syncDirectory(checkNotNull(target.parentFile))
            } else {
                KartPadAtomicFile.write(target, entry.after)
            }
        }
        val root = File(files, ROOT)
        val queue = KartPadMiiStorage.queueFile(files)
        check(!queue.exists() || queue.delete()) { "The applied Mii changes couldn’t be cleared." }
        KartPadAtomicFile.syncDirectory(root)
        val journal = KartPadMiiStorage.journalFile(files)
        check(!journal.exists() || journal.delete()) { "The applied Mii changes couldn’t be cleared." }
        KartPadAtomicFile.syncDirectory(root)
    }

    // "KPMJ", version, count, then each target (0 database, then KartPadSaveStorage.profiles),
    // its size and its old and new contents, then a CRC-32 of everything before it.
    private const val JOURNAL_MAGIC = 0x4b504d4a

    private fun encodeJournal(entries: List<Entry>): ByteArray {
        val output = ByteArrayOutputStream(16 + entries.sumOf { 8 + 2 * it.after.size })
        val checked = CheckedOutputStream(output, CRC32())
        DataOutputStream(checked).apply {
            writeInt(JOURNAL_MAGIC); writeInt(1); writeInt(entries.size)
            for (entry in entries) {
                writeInt(entry.target); writeInt(entry.after.size)
                write(entry.before); write(entry.after)
            }
            flush()
        }
        DataOutputStream(output).writeInt(checked.checksum.value.toInt())
        return output.toByteArray()
    }

    private fun readJournal(files: File): List<Entry> {
        val file = KartPadMiiStorage.journalFile(files)
        val limit = 16L + 8 + 2L * DATABASE_SIZE + 3 * (8 + 2L * KartPadSaveStorage.SAVE_BYTES)
        if (!file.isFile || file.length() !in 20L..limit) fail(INVALID_JOURNAL)
        val bytes = file.readBytes()
        val buffer = ByteBuffer.wrap(bytes)
        val crc = CRC32().apply { update(bytes, 0, bytes.size - 4) }.value.toInt()
        if (buffer.getInt(bytes.size - 4) != crc || buffer.int != JOURNAL_MAGIC || buffer.int != 1) fail(INVALID_JOURNAL)
        val count = buffer.int
        if (count !in 1..targetCount) fail(INVALID_JOURNAL)
        val seen = mutableSetOf<Int>()
        val entries = List(count) {
            val target = buffer.int
            val size = buffer.int
            if (target !in 0 until targetCount || !seen.add(target) || size != expectedSize(target) ||
                buffer.remaining() < 2L * size + 4) fail(INVALID_JOURNAL)
            Entry(target, ByteArray(size).also { buffer.get(it) }, ByteArray(size).also { buffer.get(it) })
        }
        if (buffer.remaining() != 4) fail(INVALID_JOURNAL)
        return entries
    }

    private const val ROOT = "KartPad"
    private const val DATABASE_SIZE = 779_968
    private const val MAX_QUEUE_BYTES = 1 shl 20
    private const val INTERRUPTED = "A Mii change was interrupted. Fully close and reopen KartPad to finish it."
    private const val INVALID_JOURNAL = "Invalid Mii transaction."
    private const val UNREADABLE_QUEUE = "The pending Mii changes can’t be read."
    private const val CHANGED_MII = "The selected Mii changed. Reopen Miis and choose it again."
    // Change kinds for nativeAppend (kartpad_mii_jni.cpp BuildChange).
    private const val SAVE = 1
    private const val IMPORT = 2
    private const val REMOVE = 3
    private const val RENAME = 4
    private const val LICENSE_RENAME = 5
    private const val LICENSE_DELETE = 6
    private const val LICENSE_MII = 7
    private val OPERATIONS = listOf("", "rename", "delete", "mii")
    private val targetCount get() = 1 + KartPadSaveStorage.profiles.size

    private val lock = Any()

    /** A refusal whose message the UI shows as is. */
    private class Refusal(message: String) : IllegalStateException(message)

    private fun fail(message: String): Nothing = throw Refusal(message)

    private fun readable(failure: Throwable, fallback: String): String =
        (failure as? Refusal)?.message ?: if (failure is IllegalArgumentException) failure.message ?: fallback else fallback

    private inline fun <T> attempt(fallback: String, block: () -> T): Result<T> = try {
        Result.success(block())
    } catch (failure: Exception) {
        Result.failure(Refusal(readable(failure, fallback)))
    }

    private class Change(
        val kind: Int, val profile: Int = -1, val slot: Int = -1, val createId: ByteArray? = null,
        val name: ByteArray? = null, val miiSlot: Int = -1, val miiCreateId: ByteArray? = null,
        val record: ByteArray? = null, val expected: ByteArray? = null,
    )

    // Queues the change on top of the replayed queue and keeps the result for the next read.
    private inline fun change(files: File, fallback: String, build: () -> Change): Result<String> = synchronized(lock) {
        attempt(fallback) {
            blockedReason(files)?.let { fail(it) }
            val change = build()
            val queue = readQueue(files)
            val targets = targets(files)
            val stamps = targets.map(::stamp)
            val live = readFiles(targets)
            val replayed = parse(nativeAppend(live[0], live.drop(1).toTypedArray(), queue, change.kind,
                change.profile, change.slot, change.createId, change.miiSlot, change.miiCreateId,
                change.record, change.expected, change.name))
            replayed.error?.let { fail(it) }
            val next = checkNotNull(replayed.queue)
            KartPadAtomicFile.write(KartPadMiiStorage.queueFile(files), next)
            cache = Cache(next, stamps, replayed.changed[0] ?: live[0], replayed)
            replayed.descriptions.last()
        }
    }

    // Older kinds of pending change wait alone; an interrupted commit must finish first.
    private fun blockedReason(files: File): String? = when {
        KartPadMiiStorage.journalFile(files).exists() -> INTERRUPTED
        KartPadMiiStorage.hasLegacyPending(files) || KartPadIdentityStorage.hasPending(files) ||
            KartPadSaveStorage.hasPending(files) -> "Fully close and reopen KartPad to apply the pending data change first."
        else -> null
    }

    // The waiting changes' descriptions; null when the queue can't be read.
    private fun descriptions(files: File): List<String>? = try {
        val queue = readQueue(files)
        if (queue == null) emptyList() else nativeDescribe(queue)?.toList()
    } catch (failure: Exception) {
        null
    }

    private fun count(files: File, descriptions: List<String>?): Int {
        val other = blockedReason(files) != null || descriptions == null
        return (descriptions?.size ?: 0) + if (other) 1 else 0
    }

    // The identity store's request and in-progress pointer (KartPadIdentityStorage).
    private fun identityRequest(files: File) = File(files, "$ROOT/PendingAndroidIdentity.json")
    private fun identityTransaction(files: File) = File(files, "$ROOT/PendingAndroidIdentityTransaction")

    private fun discardable(files: File): List<File> = listOfNotNull(
        KartPadMiiStorage.queueFile(files), KartPadMiiStorage.pendingFile(files),
        identityRequest(files).takeIf { !identityTransaction(files).exists() },
    )

    // The upcoming files for the queue and live files as they are now (see Cache).
    private class Replayed(
        val error: String?, val queue: ByteArray?, val changed: Array<ByteArray?>,
        val miis: List<Mii>, val licenses: List<License>, val descriptions: List<String>,
        val saveProblem: String?, val databaseProblem: String?,
    )

    /**
     * A replay kept while the queue's contents and each input file's identity and version (path,
     * device, inode, size, change times) stay the same, so refreshes don't replay the queue.
     * database is the upcoming database, which new Miis and duplicates are checked against.
     */
    private class Cache(val queue: ByteArray?, val stamps: List<String>, val database: ByteArray?, val replayed: Replayed)
    private var cache: Cache? = null

    private fun current(files: File): Cache {
        val queue = readQueue(files)
        // An older version's pending database applies before anything queued, so reading starts from it.
        val inputs = targets(files).toMutableList()
        if (KartPadMiiStorage.hasLegacyPending(files)) inputs[0] = KartPadMiiStorage.pendingFile(files)
        val stamps = inputs.map(::stamp)
        cache?.let {
            if (it.stamps == stamps && (it.queue?.contentEquals(queue) ?: (queue == null))) return it
        }
        val live = readFiles(inputs)
        val replayed = parse(nativeReplay(live[0], live.drop(1).toTypedArray(), queue))
        return Cache(queue, stamps, replayed.changed[0] ?: live[0], replayed).also { cache = it }
    }

    private fun stamp(file: File): String = try {
        val info = Os.stat(file.path)
        "${file.path}|${info.st_dev}|${info.st_ino}|${info.st_size}|" +
            "${info.st_mtim.tv_sec}.${info.st_mtim.tv_nsec}|${info.st_ctim.tv_sec}.${info.st_ctim.tv_nsec}"
    } catch (failure: Exception) {
        "${file.path}|${if (file.exists()) "${file.length()}|${file.lastModified()}" else "-"}"
    }

    private fun targets(files: File): List<File> =
        listOf(KartPadMiiStorage.databaseFile(files)) + KartPadSaveStorage.profiles.map { KartPadSaveStorage.active(files, it) }

    private fun profileName(target: Int) = if (target == 0) "mii" else KartPadSaveStorage.profiles[target - 1]

    private fun expectedSize(target: Int) = if (target == 0) DATABASE_SIZE else KartPadSaveStorage.SAVE_BYTES

    // A file that exists with another size reads as empty, which native validation reports.
    private fun read(file: File, size: Int): ByteArray? {
        if (!file.exists()) return null
        if (file.length() != size.toLong()) return ByteArray(0)
        return file.readBytes().takeIf { it.size == size } ?: ByteArray(0)
    }

    private fun readFiles(targets: List<File>) = targets.mapIndexed { index, file -> read(file, expectedSize(index)) }

    /** The queue's bytes, or null when none is waiting. */
    private fun readQueue(files: File): ByteArray? {
        val file = KartPadMiiStorage.queueFile(files)
        if (!file.exists()) return null
        if (!file.isFile || file.length() > MAX_QUEUE_BYTES) fail(UNREADABLE_QUEUE)
        return file.readBytes().also { if (it.size > MAX_QUEUE_BYTES) fail(UNREADABLE_QUEUE) }
    }

    private fun parse(result: Array<Any?>?): Replayed {
        checkNotNull(result)
        val licenses = (result[5] as Array<*>).toList().chunked(7).map {
            License(KartPadSaveStorage.profiles[it[0] as Int], it[6] as String, it[1] as Int,
                it[2] as String, it[3] as String, OPERATIONS[it[4] as Int], (it[5] as Int).takeIf { slot -> slot >= 0 })
        }
        val miis = (result[4] as Array<*>).toList().chunked(6).map {
            val slot = it[0] as Int
            Mii(slot, it[1] as String, it[2] as String, it[3] as String, it[4] as Int, it[5] as ByteArray,
                licenses.filter { license -> license.miiSlot == slot })
        }
        val changed = (result[3] as Array<*>).map { it as ByteArray? }.toTypedArray()
        val descriptions = (result[6] as Array<*>).map { it as String }
        return Replayed(result[0] as String?, result[2] as ByteArray?, changed, miis, licenses,
            descriptions, result[7] as String?, result[8] as String?)
    }

    private fun mii(files: File, createId: String): Mii {
        if (KartPadMiiStorage.journalFile(files).exists()) fail(INTERRUPTED)
        val replayed = current(files).replayed
        (replayed.error ?: replayed.databaseProblem)?.let { fail(it) }
        return replayed.miis.firstOrNull { it.createId == createId } ?: fail(CHANGED_MII)
    }

    private fun create(files: File, source: ByteArray?): ByteArray {
        if (KartPadMiiStorage.journalFile(files).exists()) fail(INTERRUPTED)
        val current = current(files)
        (current.replayed.error ?: current.replayed.databaseProblem)?.let { fail(it) }
        val result = checkNotNull(nativeNewMii(checkNotNull(current.database),
            System.currentTimeMillis() / 1000, consoleMac(files), source))
        (result[1] as String?)?.let { fail(it) }
        return result[0] as ByteArray
    }

    /**
     * This console's MAC as RuntimeConsoleIdentity::FromSerial derives it from setting.txt's
     * serial (decoded as KartPadIdentityStorage does): Nintendo's OUI, then 24 bits of FNV-1a.
     */
    internal fun consoleMac(files: File): ByteArray {
        val settings = File(files, "$ROOT/NAND/title/00000001/00000002/data/setting.txt")
        val unreadable = "This console’s identity can’t be read. Start Mario Kart Wii once, then try again."
        if (!settings.isFile || settings.length() != 256L) fail(unreadable)
        var key = 0x73b5dbfa
        val decoded = StringBuilder()
        for (byte in settings.readBytes()) {
            val value = ((byte.toInt() and 255) xor (key and 255)).toChar()
            key = Integer.rotateLeft(key, 1)
            if (value == '\u0000') break
            decoded.append(value)
        }
        val serial = Regex("(?:^|[\r\n])SERNO=([0-9]{1,9})(?:[\r\n]|$)").find(decoded)?.groupValues?.get(1)
            ?.takeIf { digits -> digits.any { it != '0' } } ?: fail(unreadable)
        var hash = 0x811c9dc5.toInt()
        for (character in serial) hash = (hash xor character.code) * 16777619
        var suffix = hash and 0xffffff
        if (suffix == 0 || suffix == 0xffffff) suffix = suffix xor 0x5a17c3
        return byteArrayOf(0x00, 0x09, 0xbf.toByte(), (suffix shr 16).toByte(), (suffix shr 8).toByte(), suffix.toByte())
    }

    private fun profile(profile: String): Int =
        KartPadSaveStorage.profiles.indexOf(profile).takeIf { it >= 0 } ?: fail("The selected license location is invalid.")

    private fun identity(createId: String): ByteArray {
        if (!Regex("[0-9a-f]{16}").matches(createId)) fail(CHANGED_MII)
        return ByteArray(8) { createId.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    }

    /** A name as Miis and licenses store it: trimmed, 1 to 10 UTF-16 units, units kept as they are. */
    private fun nameBytes(name: String): ByteArray {
        val trimmed = name.trim()
        if (trimmed.length !in 1..10) fail("A player name must contain 1 to 10 characters.")
        // Raw units, so native validation rejects an unpaired surrogate instead of replacing it.
        return ByteArray(trimmed.length * 2) { (trimmed[it / 2].code shr if (it % 2 == 0) 8 else 0).toByte() }
    }

    // The editor's record with its name trimmed as its licenses will get it; never blank.
    private fun normalizedRecord(record: ByteArray): ByteArray {
        if (record.size != 74) return record  // Native validation reports it.
        val units = (0 until 10).map {
            ((record[2 + it * 2].toInt() and 255) shl 8) or (record[3 + it * 2].toInt() and 255)
        }.takeWhile { it != 0 }
        val text = String(CharArray(units.size) { units[it].toChar() })
        val trimmed = text.trim()
        if (trimmed.isEmpty()) fail("A player name must contain 1 to 10 characters.")
        if (trimmed == text) return record
        return record.copyOf().also { it.fill(0, 2, 22); nameBytes(trimmed).copyInto(it, 2) }
    }

    private external fun nativeReplay(database: ByteArray?, saves: Array<ByteArray?>, queue: ByteArray?): Array<Any?>?
    private external fun nativeAppend(
        database: ByteArray?, saves: Array<ByteArray?>, queue: ByteArray?, kind: Int, profile: Int, slot: Int,
        createId: ByteArray?, miiSlot: Int, miiCreateId: ByteArray?, record: ByteArray?, expected: ByteArray?,
        name: ByteArray?,
    ): Array<Any?>?
    private external fun nativeDescribe(queue: ByteArray): Array<String>?
    private external fun nativeNewMii(database: ByteArray, seconds: Long, mac: ByteArray, source: ByteArray?): Array<Any?>?
}
