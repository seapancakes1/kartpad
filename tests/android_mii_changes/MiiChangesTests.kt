package dev.kartpad.android

import android.util.AtomicFile
import java.io.File
import java.io.RandomAccessFile
import java.nio.file.Files
import java.util.zip.CRC32

// End-to-end tests of KartPadMiiChanges over the real JNI library, on synthetic files only.
private var checks = 0

private fun expect(condition: Boolean, message: () -> String = { "check failed" }) {
    checks++
    if (!condition) throw AssertionError(message())
}

private fun <T> Result<T>.ok(): T = getOrElse { throw AssertionError("unexpected failure: ${it.message}") }
private fun Result<*>.refused(): String = exceptionOrNull()?.message ?: throw AssertionError("unexpected success")

private fun upcoming(files: File): KartPadMiiChanges.Upcoming = KartPadMiiChanges.upcoming(files).let {
    it as? KartPadMiiChanges.Upcoming ?: throw AssertionError("Miis unavailable: $it")
}

private const val INTERRUPTED = "A Mii change was interrupted. Fully close and reopen KartPad to finish it."
private const val BLOCKED = "Fully close and reopen KartPad to apply the pending data change first."
private const val CHANGED = "The selected Mii changed. Reopen Miis and choose it again."

private fun name(bytes: ByteArray, offset: Int) = buildString {
    for (index in 0 until 10) {
        val unit = ((bytes[offset + index * 2].toInt() and 255) shl 8) or (bytes[offset + index * 2 + 1].toInt() and 255)
        if (unit == 0) break
        append(unit.toChar())
    }
}
private fun licenseName(save: ByteArray, slot: Int) = name(save, 8 + slot * 0x8cc0 + 0x14)
private fun licenseId(save: ByteArray, slot: Int) = save.copyOfRange(8 + slot * 0x8cc0 + 0x28, 8 + slot * 0x8cc0 + 0x30)
private fun miiName(database: ByteArray, slot: Int) = name(database, 4 + slot * 74 + 2)
private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }

private fun ByteArray.withName(text: String) = copyOf().also { record ->
    record.fill(0, 2, 22)
    text.forEachIndexed { index, c -> record[2 + index * 2] = (c.code shr 8).toByte(); record[3 + index * 2] = c.code.toByte() }
}

private fun fixSave(save: ByteArray) = save.also {
    val crc = CRC32().apply { update(it, 0, 0x27ffc) }.value
    repeat(4) { index -> it[0x27ffc + index] = (crc shr (24 - index * 8)).toByte() }
}

private fun fixDatabase(database: ByteArray) = database.also {
    var crc = 0
    for (index in 0 until 0x1f1de) {
        crc = crc xor ((it[index].toInt() and 255) shl 8)
        repeat(8) { crc = if (crc and 0x8000 != 0) (crc shl 1) xor 0x1021 else crc shl 1 }
        crc = crc and 0xffff
    }
    it[0x1f1de] = (crc shr 8).toByte(); it[0x1f1df] = crc.toByte()
}

// The database with record placed in slot.
private fun withMii(database: ByteArray, slot: Int, record: ByteArray) =
    fixDatabase(database.copyOf().also { record.copyInto(it, 4 + slot * 74) })

// Only license names and the checksum may differ.
private fun onlyNamesChanged(before: ByteArray, after: ByteArray) = before.indices.all { index ->
    val name = (0 until 4).any { slot -> index - (8 + slot * 0x8cc0 + 0x14) in 0 until 20 }
    name || index in 0x27ffc..0x27fff || before[index] == after[index]
}

/** A disposable files directory with the fixture database, three saves and console settings. */
private class Root(fixtures: File) {
    val files: File = Files.createTempDirectory("kartpad-mii-changes-").toFile()
    fun target(profile: String) = File(files, "KartPad/${KartPadIdentityStorage.paths.getValue(profile)}")
    fun read(profile: String) = target(profile).readBytes()
    fun write(profile: String, bytes: ByteArray) = target(profile).writeBytes(bytes)
    fun backups(folder: String) = File(files, "KartPad/$folder").listFiles().orEmpty().toList()

    init {
        for (profile in KartPadIdentityStorage.paths.keys) {
            target(profile).parentFile.mkdirs()
            File(fixtures, if (profile == "mii") "mii.dat" else "$profile.dat").copyTo(target(profile))
        }
        val encode = KartPadIdentityStorage::class.java.getDeclaredMethod("nativeConsoleSettings", String::class.java)
            .apply { isAccessible = true }
        File(files, "KartPad/NAND/title/00000001/00000002/data/setting.txt").apply { parentFile.mkdirs() }
            .writeBytes(encode.invoke(KartPadIdentityStorage, "123456789") as ByteArray)
    }

    fun close() { AtomicFile.failSuffix = null; files.deleteRecursively() }  // Only this test's directory.
}

private fun testQueueAndLaunch(fixtures: File) {
    val root = Root(fixtures)
    try {
        val files = root.files
        val live = KartPadIdentityStorage.paths.keys.associateWith(root::read)
        var view = upcoming(files)
        val (seed, bob, cat) = view.miis
        expect(view.miis.map { it.name } == listOf("KartPad", "Bob", "Cat"))
        expect(bob.licenses.map { it.profile to it.slot } ==
            listOf("original" to 0, "retro_rewind" to 1, "retro_rewind_separate" to 0))
        expect(cat.licenses.single().let { it.profile == "retro_rewind_separate" && it.slot == 2 })
        expect(view.orphanedLicenses.isEmpty() && view.pendingCount == 0 && view.canQueue && !view.canDiscard)
        expect(view.licensesByProfile.keys == setOf("original", "retro_rewind", "retro_rewind_separate"))
        // Refreshes reuse the replay while the queue and the files stay the same.
        expect(upcoming(files).miis === view.miis)

        expect(KartPadMiiChanges.renameMii(files, bob.createId, "  Ann ").ok() ==
            "“Bob” will be renamed “Ann”. Its 3 licenses will use the new name.")
        view = upcoming(files)
        val ann = view.miis[1]
        expect(ann.name == "Ann" && ann.licenses.all { it.name == "Ann" && it.pendingOperation == "rename" })
        // The editor saves against the record it opened; the one from before the rename is stale.
        val edited = ann.record.copyOf().apply { this[0x22] = (this[0x22].toInt() xor 0x02).toByte() }
        expect(KartPadMiiChanges.saveMii(files, 1, bob.record, edited).refused() == "This Mii changed. Reopen the editor.")
        expect(KartPadMiiChanges.saveMii(files, 1, ann.record, edited).ok() == "“Ann” will be updated.")
        val dan = cat.record.withName("Dan").apply { this[0x1b] = 9 }
        expect(KartPadMiiChanges.importMii(files, dan).ok() == "“Dan” will be added.")
        expect(KartPadMiiChanges.importMii(files, dan).refused() == "That Mii is already in the database.")
        expect(KartPadMiiChanges.importMii(files, dan.copyOf(73)).refused() == "A Mii file must contain exactly 74 bytes.")

        // New Miis and duplicates take this console's ID (as the runtime derives it) and an ID of their own.
        val mac = File(fixtures, "console-mac.bin").readBytes()
        expect(KartPadMiiChanges.consoleMac(files).contentEquals(mac)) { "console MAC differs from FromSerial" }
        val systemId = byteArrayOf((mac[0] + mac[1] + mac[2]).toByte(), mac[3], mac[4], mac[5])
        val fresh = KartPadMiiChanges.newMii(files).ok()
        expect(fresh.size == 74 && fresh.copyOfRange(0x1c, 0x20).contentEquals(systemId))
        expect(KartPadMiiChanges.saveMii(files, null, null, fresh).ok() == "“KartPad” will be added.")
        val copy = KartPadMiiChanges.duplicate(files, cat.createId).ok()
        expect(copy.copyOfRange(0x1c, 0x20).contentEquals(systemId) &&
            !copy.copyOfRange(0x18, 0x1c).contentEquals(cat.record.copyOfRange(0x18, 0x1c)))
        expect(copy.indices.all { it in 0x18 until 0x20 || copy[it] == cat.record[it] })
        expect(KartPadMiiChanges.saveMii(files, null, null, copy).ok() == "“Cat” will be added.")
        // A second copy queued behind the first still gets an identity of its own.
        val second = KartPadMiiChanges.duplicate(files, cat.createId).ok()
        expect(!second.copyOfRange(0x18, 0x1c).contentEquals(copy.copyOfRange(0x18, 0x1c)))

        expect(KartPadMiiChanges.deleteLicense(files, "retro_rewind", 1, bob.createId).ok() ==
            "Retro Rewind · License 2 (“Ann”) will be deleted.")
        expect(upcoming(files).licenses.single { it.profile == "retro_rewind" && it.slot == 1 }.pendingOperation == "delete")
        expect(KartPadMiiChanges.setLicenseMii(files, "original", 1, seed.createId, cat.createId).ok() ==
            "Mario Kart Wii · License 2 will race as “Cat”.")
        expect(KartPadMiiChanges.renameLicense(files, "original", 0, bob.createId, "Racer").ok() ==
            "Mario Kart Wii · License 1 will be renamed “Racer”.")
        expect(KartPadMiiChanges.deleteLicense(files, "original", 0, cat.createId).refused() ==
            "The selected license changed before it could be deleted.")
        expect(KartPadMiiChanges.removeMii(files, cat.createId).refused() ==
            "This Mii is linked to an existing license. Change the license first.")
        view = upcoming(files)
        expect(view.miis.map { it.name } == listOf("KartPad", "Racer", "Cat", "Dan", "KartPad", "Cat"))
        expect(view.pendingCount == 8 && KartPadMiiChanges.pendingCount(files) == 8)
        expect(view.latestDescription == "Mario Kart Wii · License 1 will be renamed “Racer”." &&
            KartPadMiiChanges.latestDescription(files) == view.latestDescription)
        expect(KartPadMiiChanges.exportMii(files, view.miis[1].createId).ok().contentEquals(view.miis[1].record))
        expect(KartPadIdentityStorage.paths.keys.all { root.read(it).contentEquals(live.getValue(it)) }) { "staging changed live files" }

        // Race progress saved in place meanwhile is kept, and the in-place write is noticed.
        val progress = fixSave(root.read("original").also { it[8 + 0x90] = 0x5a })
        RandomAccessFile(root.target("original"), "rw").use { it.write(progress) }
        expect(upcoming(files).miis !== view.miis)
        val miiBefore = root.read("mii")
        val savesBefore = KartPadSaveStorage.profiles.associateWith(root::read)
        expect(KartPadMiiChanges.applyAtLaunch(files) == null)
        expect(!KartPadMiiStorage.hasPending(files) && !KartPadMiiStorage.queueFile(files).exists() &&
            !KartPadMiiStorage.journalFile(files).exists())
        val database = root.read("mii")
        expect((0..5).map { miiName(database, it) } == listOf("KartPad", "Racer", "Cat", "Dan", "KartPad", "Cat"))
        val original = root.read("original")
        expect(licenseName(original, 0) == "Racer" && original[8 + 0x90] == 0x5a.toByte())
        expect(licenseName(original, 1) == "Cat" && hex(licenseId(original, 1)) == cat.createId)
        expect(root.read("retro_rewind").copyOfRange(8 + 0x8cc0, 8 + 2 * 0x8cc0).all { it == 0.toByte() })
        val separate = root.read("retro_rewind_separate")
        expect(licenseName(separate, 0) == "Ann" && licenseName(separate, 2) == "Player" &&
            onlyNamesChanged(savesBefore.getValue("retro_rewind_separate"), separate))
        // The files as they were before the launch are backed up, named as the save restores name theirs.
        expect(root.backups("MiiBackups").single().readBytes().contentEquals(miiBefore))
        val saves = root.backups("SaveBackups")
        expect(saves.size == 3)
        for ((profile, prefix) in listOf("original" to "rksys-", "retro_rewind" to "retro_rewind-",
                "retro_rewind_separate" to "retro_rewind_separate-")) {
            expect(saves.any { it.name.startsWith(prefix) && it.readBytes().contentEquals(savesBefore.getValue(profile)) })
        }
        view = upcoming(files)
        expect(view.pendingCount == 0 && view.latestDescription == null && view.miis.size == 6)
        println("Android Mii queue passed: renames, edits, imports, new Miis, duplicates, license changes, " +
            "stale refusals, cached replay, latest progress, launch commit and backups")
    } finally {
        root.close()
    }
}

private fun testInterruptedCommit(fixtures: File) {
    val root = Root(fixtures)
    try {
        val files = root.files
        val bob = upcoming(files).miis[1]
        expect(KartPadMiiChanges.renameMii(files, bob.createId, "Ann").isSuccess)
        val before = KartPadIdentityStorage.paths.keys.associateWith(root::read)
        // The second save's replacement fails after the database and the first save were written.
        AtomicFile.failSuffix = "/RetroWFC/RMCP/rksys.dat"
        expect(KartPadMiiChanges.applyAtLaunch(files) != null)
        expect(KartPadMiiStorage.journalFile(files).isFile && KartPadMiiStorage.queueFile(files).isFile)
        expect(miiName(root.read("mii"), 1) == "Ann" && licenseName(root.read("original"), 0) == "Ann")
        expect(root.read("retro_rewind").contentEquals(before.getValue("retro_rewind")))
        // Until it finishes, nothing new is queued and older stores refuse too.
        expect(KartPadMiiChanges.upcoming(files) == KartPadMiiChanges.Unavailable(INTERRUPTED, false))
        expect(KartPadMiiChanges.renameMii(files, bob.createId, "Zed").refused() == INTERRUPTED)
        expect(KartPadMiiChanges.newMii(files).refused() == INTERRUPTED)
        expect(runCatching { KartPadSaveStorage.writePending(files, before.getValue("original"), "original") }.isFailure)
        expect(runCatching { KartPadMiiStorage.writePending(files, before.getValue("mii")) }.isFailure)
        expect(KartPadMiiChanges.pendingCount(files) == 2)
        // Still blocked while the write keeps failing.
        expect(KartPadMiiChanges.applyAtLaunch(files) != null && KartPadMiiStorage.journalFile(files).isFile)
        AtomicFile.failSuffix = null
        // Recovery rolls the journal forward without replaying the queue: a garbled queue doesn't matter.
        KartPadMiiStorage.queueFile(files).writeBytes(ByteArray(40) { 7 })
        expect(KartPadMiiChanges.applyAtLaunch(files) == null)
        expect(!KartPadMiiStorage.journalFile(files).exists() && !KartPadMiiStorage.queueFile(files).exists())
        expect(miiName(root.read("mii"), 1) == "Ann")
        for (profile in KartPadSaveStorage.profiles) {
            val save = root.read(profile)
            expect(onlyNamesChanged(before.getValue(profile), save))
            expect(KartPadIdentityStorage.records(files, false).filter { it.profile == profile && it.createId == bob.createId }
                .all { it.name == "Ann" })
        }
        // Backups come from the commit itself; recovery adds none.
        expect(root.backups("MiiBackups").size == 1 && root.backups("SaveBackups").size == 3)

        // A file changed to neither its old nor its new contents stops recovery with nothing more written.
        expect(KartPadMiiChanges.renameMii(files, bob.createId, "Bo").isSuccess)
        AtomicFile.failSuffix = "/RetroWFC/RMCP/rksys.dat"
        expect(KartPadMiiChanges.applyAtLaunch(files) != null)
        AtomicFile.failSuffix = null
        val other = fixSave(root.read("retro_rewind").also { it[8 + 0x8cc0 + 0x90] = 0x11 })
        root.write("retro_rewind", other)
        val database = root.read("mii")
        expect(KartPadMiiChanges.applyAtLaunch(files) == "Game data changed since the Mii edit. Nothing further was applied.")
        expect(KartPadMiiStorage.journalFile(files).isFile && root.read("mii").contentEquals(database) &&
            root.read("retro_rewind").contentEquals(other))
        // A damaged journal is refused the same way.
        val journal = KartPadMiiStorage.journalFile(files)
        val intact = journal.readBytes()
        journal.writeBytes(intact.copyOf().also { it[100] = (it[100].toInt() xor 1).toByte() })
        expect(KartPadMiiChanges.applyAtLaunch(files) == "Invalid Mii transaction.")
        journal.writeBytes(intact)
        expect(KartPadMiiChanges.applyAtLaunch(files) != null && KartPadMiiStorage.journalFile(files).isFile)
        println("Android Mii interrupted commit passed: journal before writes, blocked until recovery, " +
            "roll-forward without replay, changed-file and damaged-journal refusal")
    } finally {
        root.close()
    }
}

private fun testLegacyFirst(fixtures: File) {
    val root = Root(fixtures)
    try {
        val files = root.files
        val (seed, bob, cat) = upcoming(files).miis
        // An older version's single pending database is what the Miis start from, and nothing new
        // queues until it has applied.
        val legacy = withMii(root.read("mii"), 3, cat.record.withName("Leg").apply { this[0x1b] = 0x21 })
        KartPadMiiStorage.writePending(files, legacy)
        val waiting = upcoming(files)
        expect(waiting.miis.map { it.name } == listOf("KartPad", "Bob", "Cat", "Leg"))
        expect(!waiting.canQueue && waiting.blockedReason == BLOCKED && waiting.pendingCount == 1 && waiting.canDiscard)
        expect(KartPadMiiChanges.renameMii(files, bob.createId, "Ann").refused() == BLOCKED)
        expect(!KartPadMiiStorage.queueFile(files).exists())
        expect(KartPadMiiChanges.applyAtLaunch(files) == null)
        expect((0..3).map { miiName(root.read("mii"), it) } == listOf("KartPad", "Bob", "Cat", "Leg"))
        // So does a pending identity change from the older store.
        val license = KartPadIdentityStorage.records(files, false).first { it.profile == "original" && it.slot == 1 }
        KartPadIdentityStorage.stage(files, license, false, "Idy")
        expect(KartPadMiiChanges.renameMii(files, bob.createId, "Ann").refused() == BLOCKED)
        expect(KartPadMiiChanges.applyAtLaunch(files) == null)
        expect(licenseName(root.read("original"), 1) == "Idy" && miiName(root.read("mii"), 0) == "Idy")
        expect(!KartPadIdentityStorage.hasPending(files))
        // Then the queue takes changes, and the older stores refuse while it waits.
        expect(KartPadMiiChanges.renameMii(files, bob.createId, "Ann").isSuccess)
        expect(runCatching { KartPadIdentityStorage.stage(files, license.copy(name = "Idy"), false, "Other") }.isFailure)
        expect(runCatching { KartPadMiiStorage.writePending(files, legacy) }.isFailure)
        expect(runCatching { KartPadSaveStorage.writePending(files, root.read("original"), "original") }.isFailure)
        // An older version's pending database left beside a queue applies first, then the queue over it.
        val older = withMii(root.read("mii"), 4, cat.record.withName("Old").apply { this[0x1b] = 0x22 })
        KartPadMiiStorage.pendingFile(files).writeBytes(older)
        expect(KartPadMiiChanges.applyAtLaunch(files) == null)
        val database = root.read("mii")
        expect(miiName(database, 1) == "Ann" && miiName(database, 4) == "Old" && !KartPadMiiStorage.hasPending(files))
        expect(seed.slot == 0)
        println("Android Mii legacy changes passed: older pending database and identity change apply first, " +
            "nothing queues until then, and older stores refuse while the queue waits")
    } finally {
        root.close()
    }
}

private fun testStaleQueueAndDiscard(fixtures: File) {
    val root = Root(fixtures)
    try {
        val files = root.files
        val (_, bob, cat) = upcoming(files).miis
        expect(KartPadMiiChanges.importMii(files, cat.record.withName("Dan").apply { this[0x1b] = 9 }).isSuccess)
        expect(KartPadMiiChanges.renameMii(files, cat.createId, "Kit").isSuccess)
        // Another tool replaces Cat meanwhile: the waiting rename no longer fits, so nothing applies.
        val replaced = withMii(root.read("mii"), 2, cat.record.copyOf().apply { this[0x1b] = 0x30 })
        root.write("mii", replaced)
        expect(KartPadMiiChanges.upcoming(files) == KartPadMiiChanges.Unavailable(CHANGED, true))
        expect(KartPadMiiChanges.renameMii(files, bob.createId, "Ann").refused() == CHANGED)
        expect(KartPadMiiChanges.applyAtLaunch(files) == CHANGED)
        expect(root.read("mii").contentEquals(replaced) && root.backups("MiiBackups").isEmpty() &&
            !KartPadMiiStorage.journalFile(files).exists() && KartPadMiiStorage.queueFile(files).isFile)
        // Discarding drops every waiting change and leaves the live files alone.
        expect(KartPadMiiChanges.canDiscard(files))
        expect(KartPadMiiChanges.discardAll(files).isSuccess)
        expect(!KartPadMiiChanges.canDiscard(files) && KartPadMiiChanges.pendingCount(files) == 0)
        expect(KartPadMiiChanges.applyAtLaunch(files) == null && root.read("mii").contentEquals(replaced))
        // It drops an older version's pending database and identity request too.
        val license = KartPadIdentityStorage.records(files, false).first { it.profile == "original" }
        KartPadIdentityStorage.stage(files, license, false, "Idy")
        KartPadMiiStorage.pendingFile(files).writeBytes(replaced)
        expect(KartPadMiiChanges.pendingCount(files) == 1 && KartPadMiiChanges.canDiscard(files))
        expect(KartPadMiiChanges.discardAll(files).isSuccess)
        expect(!KartPadIdentityStorage.hasPending(files) && !KartPadMiiStorage.hasPending(files))
        expect(KartPadMiiChanges.applyAtLaunch(files) == null && licenseName(root.read("original"), 0) == "Player")
        // An unreadable queue can be discarded.
        KartPadMiiStorage.queueFile(files).writeBytes(ByteArray(12))
        expect(KartPadMiiChanges.upcoming(files) == KartPadMiiChanges.Unavailable("The pending Mii changes can’t be read.", true))
        expect(KartPadMiiChanges.pendingCount(files) == 1 && KartPadMiiChanges.latestDescription(files) == null)
        expect(KartPadMiiChanges.applyAtLaunch(files) == "The pending Mii changes can’t be read.")
        expect(KartPadMiiChanges.discardAll(files).isSuccess && KartPadMiiChanges.applyAtLaunch(files) == null)
        println("Android Mii stale queue passed: whole-queue rejection with nothing written, discard of " +
            "queued, older and unreadable changes")
    } finally {
        root.close()
    }
}

private fun testNamesAndFiles(fixtures: File) {
    val root = Root(fixtures)
    try {
        val files = root.files
        val (_, bob, cat) = upcoming(files).miis
        val length = "A player name must contain 1 to 10 characters."
        expect(KartPadMiiChanges.renameMii(files, bob.createId, "   ").refused() == length)
        expect(KartPadMiiChanges.renameMii(files, bob.createId, "ABCDEFGHIJK").refused() == length)
        expect(KartPadMiiChanges.renameMii(files, bob.createId, "Bad\uD800").refused() ==
            "The player name contains an unsupported character.")
        expect(KartPadMiiChanges.renameMii(files, "not an id", "Ann").refused() == CHANGED)
        expect(KartPadMiiChanges.deleteLicense(files, "elsewhere", 0, bob.createId).refused() ==
            "The selected license location is invalid.")
        // An editor record's name is stored trimmed, as its licenses get it, and never blank.
        expect(KartPadMiiChanges.saveMii(files, 1, bob.record, bob.record.withName("  ")).refused() == length)
        expect(KartPadMiiChanges.saveMii(files, 1, null, bob.record).refused() == "Invalid Mii selection.")
        expect(KartPadMiiChanges.saveMii(files, 1, bob.record, bob.record.withName(" Zoë ")).ok() ==
            "“Bob” will be updated and renamed “Zoë”.")
        val zoe = upcoming(files).miis[1]
        expect(zoe.name == "Zoë" && name(zoe.record, 2) == "Zoë" && zoe.licenses.all { it.name == "Zoë" })
        expect(KartPadMiiStorage.queueFile(files).isFile && KartPadMiiChanges.discardAll(files).isSuccess)

        // A license whose Mii is missing is listed as such, and can be moved to a Mii.
        val orphan = fixSave(root.read("original").also { it[8 + 0x28] = (it[8 + 0x28].toInt() xor 1).toByte() })
        root.write("original", orphan)
        val missing = upcoming(files).orphanedLicenses.single()
        expect(missing.profile == "original" && missing.slot == 0 && missing.missingLinkedMii)
        expect(KartPadMiiChanges.setLicenseMii(files, "original", 0, missing.createId, cat.createId).isSuccess)
        expect(upcoming(files).orphanedLicenses.isEmpty())
        expect(KartPadMiiChanges.discardAll(files).isSuccess)
        // A save of another size can't be read: the listing says so, and changes that touch it fail.
        val retro = root.read("retro_rewind")
        root.write("retro_rewind", retro.copyOf(1000))
        val damaged = upcoming(files)
        expect(damaged.saveProblem == "The Mario Kart Wii save has an unexpected size.")
        expect(KartPadMiiChanges.renameMii(files, bob.createId, "Ann").refused() == damaged.saveProblem)
        root.write("retro_rewind", retro)
        // Without a database there are no Miis to show.
        check(root.target("mii").delete())
        expect(KartPadMiiChanges.upcoming(files) ==
            KartPadMiiChanges.Unavailable("No Mii database exists yet. Start Mario Kart Wii once, then try again.", false))
        expect(KartPadMiiChanges.newMii(files).isFailure)
        println("Android Mii names and files passed: trimming, length and character rules, orphaned " +
            "licenses, unreadable saves and a missing database")
    } finally {
        root.close()
    }
}

fun main(args: Array<String>) {
    System.load(args[0])
    val fixtures = File(args[1])
    testQueueAndLaunch(fixtures)
    testInterruptedCommit(fixtures)
    testLegacyFirst(fixtures)
    testStaleQueueAndDiscard(fixtures)
    testNamesAndFiles(fixtures)
    println("Android Mii change queue host tests passed: $checks checks")
}
