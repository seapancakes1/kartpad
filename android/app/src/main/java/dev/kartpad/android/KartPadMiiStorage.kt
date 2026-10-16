package dev.kartpad.android

import java.io.File
import java.util.UUID

/**
 * App-private Mii storage. Older versions staged one database edit (PendingRFL_DB.dat); it still
 * applies first. Current changes wait in KartPadMiiChanges' queue, whose files live here so the
 * identity and save stores can check for them.
 */
internal object KartPadMiiStorage {
    private const val DATABASE_SIZE = 779_968
    private const val CRC_OFFSET = 0x1F1DE
    private const val SUPPORT_ROOT = "KartPad"
    private const val DATABASE = "NAND/shared2/menu/FaceLib/RFL_DB.dat"
    private const val PENDING = "PendingRFL_DB.dat"
    private const val QUEUE = "PendingMiiChanges.bin"
    private const val JOURNAL = "MiiEditorTransaction.bin"

    fun readWorking(filesDir: File): ByteArray {
        val pending = pendingFile(filesDir)
        val source = if (pending.isFile) pending else databaseFile(filesDir)
        require(source.isFile) {
            "No Mii database exists yet. Start Mario Kart Wii once, then try again."
        }
        return runCatching { source.readBytes() }.getOrElse {
            throw IllegalStateException("The Mii database could not be read.")
        }
    }

    /** Any Mii change waiting for the next launch, including an interrupted commit. */
    fun hasPending(filesDir: File): Boolean =
        hasLegacyPending(filesDir) || queueFile(filesDir).isFile || journalFile(filesDir).isFile

    fun hasLegacyPending(filesDir: File): Boolean = pendingFile(filesDir).isFile

    fun writePending(filesDir: File, database: ByteArray) {
        require(!KartPadIdentityStorage.hasPending(filesDir)) { "Apply pending identity edits before changing Mii appearances." }
        require(!queueFile(filesDir).isFile && !journalFile(filesDir).isFile) {
            "Fully close and reopen KartPad to apply the waiting Mii changes first."
        }
        require(isValidDatabase(database)) { "The updated Mii database is invalid." }
        KartPadAtomicFile.write(pendingFile(filesDir), database)
    }

    /** Applies a previously validated edit before SDL starts and retains a backup. */
    fun applyPending(filesDir: File): String? {
        val pending = pendingFile(filesDir)
        if (!pending.isFile) return null
        val data = runCatching { pending.readBytes() }.getOrElse {
            return "The pending Mii database could not be read."
        }
        if (!isValidDatabase(data)) {
            return "The pending Mii database failed validation and was not applied."
        }
        return runCatching {
            val database = databaseFile(filesDir)
            database.parentFile?.mkdirs()
            if (database.isFile) backup(filesDir, "mii", database.readBytes())
            KartPadAtomicFile.write(database, data)
            check(pending.delete()) { "Pending Mii database could not be removed." }
            null
        }.getOrElse { "Pending Mii changes could not be applied safely." }
    }

    internal fun isValidDatabase(database: ByteArray): Boolean {
        if (database.size != DATABASE_SIZE ||
            database[0] != 'R'.code.toByte() ||
            database[1] != 'N'.code.toByte() ||
            database[2] != 'O'.code.toByte() ||
            database[3] != 'D'.code.toByte()
        ) {
            return false
        }
        var crc = 0
        for (index in 0 until CRC_OFFSET) {
            crc = crc xor ((database[index].toInt() and 0xff) shl 8)
            repeat(8) {
                crc = if ((crc and 0x8000) != 0) {
                    ((crc shl 1) xor 0x1021) and 0xffff
                } else {
                    (crc shl 1) and 0xffff
                }
            }
        }
        val stored = ((database[CRC_OFFSET].toInt() and 0xff) shl 8) or
            (database[CRC_OFFSET + 1].toInt() and 0xff)
        return stored == crc
    }

    /**
     * Keeps a copy of a file about to be replaced: the database in MiiBackups, a save (by its
     * KartPadSaveStorage profile) in SaveBackups, named as the save restores name theirs.
     */
    fun backup(filesDir: File, profile: String, bytes: ByteArray,
               stamp: String = "${System.currentTimeMillis()}-${UUID.randomUUID()}") {
        val mii = profile == "mii"
        require(mii || profile in KartPadSaveStorage.profiles) { "Unknown save profile." }
        val backups = File(filesDir, "$SUPPORT_ROOT/${if (mii) "MiiBackups" else "SaveBackups"}")
        check(backups.isDirectory || backups.mkdirs()) { "Backup storage is unavailable." }
        val prefix = if (mii) "RFL_DB" else if (profile == "original") "rksys" else profile
        KartPadAtomicFile.write(File(backups, "$prefix-$stamp.dat"), bytes)
    }

    internal fun databaseFile(filesDir: File) = File(filesDir, "$SUPPORT_ROOT/$DATABASE")
    internal fun pendingFile(filesDir: File) = File(filesDir, "$SUPPORT_ROOT/$PENDING")
    internal fun queueFile(filesDir: File) = File(filesDir, "$SUPPORT_ROOT/$QUEUE")
    internal fun journalFile(filesDir: File) = File(filesDir, "$SUPPORT_ROOT/$JOURNAL")
}
