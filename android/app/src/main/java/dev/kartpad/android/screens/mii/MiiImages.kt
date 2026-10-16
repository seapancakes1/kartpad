package dev.kartpad.android.screens.mii

import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import dev.kartpad.android.KartPadGameDataStorage
import java.io.File
import java.util.concurrent.Executors

/**
 * Mii head portraits and editor feature tiles, drawn on one background worker from the imported
 * RFL archive (apple/shared/KartPadMiiEditor.inc.mm: KPMiiRequestPortrait, KPMiiTileCache).
 * Requests, caches and callbacks are main-thread only.
 */
internal object MiiImages {
    /** The imported game files the Mii screens and sounds read. */
    class GameFiles(val faces: File, val bodies: File, val sounds: File)

    /** Longest side of the images kept, in pixels; portraits render at up to about 450. */
    const val IMAGE_SIZE = 320
    private const val PORTRAITS = 128 // 100 Miis, plus Create Mii's look-alikes and blank faces.
    private const val TILE_BUDGET = 24L * 1024 * 1024
    private const val UNAVAILABLE = "Mii images are unavailable in this build."

    private val main = Handler(Looper.getMainLooper())
    // Serial, like Apple's preview queue: portraits, tiles and preview scenes share one decoded archive.
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "KartPadMii").apply { isDaemon = true }
    }

    /** Runs [task] on the Mii worker (MiiPreviewView builds its scenes there). */
    fun execute(task: Runnable) = worker.execute(task)

    @Volatile private var files: Pair<String, GameFiles>? = null

    /**
     * Config.toml's dvd_root (relative to Config.toml; GameData by default), read again only
     * when Config.toml changes. Both profiles race on these base files. Any thread.
     */
    fun gameFiles(context: Context): GameFiles {
        val support = KartPadGameDataStorage.root(context.applicationContext.filesDir)
        val config = File(support, "Config.toml")
        val stamp = "${config.length()}|${config.lastModified()}"
        files?.let { if (it.first == stamp) return it.second }
        val text = runCatching { if (config.isFile) config.readText() else "" }.getOrDefault("")
        val root = Regex("(?m)^\\s*dvd_root\\s*=\\s*\"([^\"]+)\"").find(text)?.groupValues?.get(1)
            ?.let { File(it).takeIf(File::isAbsolute) ?: File(support, it) }
            ?: KartPadGameDataStorage.installed(context.applicationContext.filesDir)
        val found = GameFiles(
            File(root, "files/contents/RFLRes01.arc"),
            File(root, "files/Scene/Model/MiiBody.szs"),
            File(root, "files/sound/revo_kart.brsar"),
        )
        files = stamp to found
        return found
    }

    private class Key(val bytes: ByteArray) {
        override fun equals(other: Any?) = other is Key && bytes.contentEquals(other.bytes)
        override fun hashCode() = bytes.contentHashCode()
    }

    private val portraits = object : LinkedHashMap<Key, Bitmap>(PORTRAITS, .75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Key, Bitmap>) = size > PORTRAITS
    }
    private val portraitWaiters = HashMap<Key, MutableList<(Bitmap?) -> Unit>>()
    // Miis whose portrait failed with the current game data aren't tried again until it changes.
    private val portraitFailures = HashMap<Key, String>()

    /** Why the last portrait couldn't be drawn (missing or damaged archive), or null. */
    var portraitProblem: String? = null
        private set

    private var stamp = ""
    private var stampCheckedAt = Long.MIN_VALUE

    // The archive's path, size and date, checked at most once a second. A change forgets failures and tiles.
    private fun resourceStamp(context: Context): String {
        val now = SystemClock.uptimeMillis()
        if (stampCheckedAt == Long.MIN_VALUE || now - stampCheckedAt >= 1000) {
            stampCheckedAt = now
            val faces = gameFiles(context).faces
            val next = if (faces.isFile) "${faces.path}|${faces.length()}|${faces.lastModified()}" else "${faces.path}|missing"
            if (next != stamp) {
                stamp = next
                portraitFailures.clear()
                clearTiles()
            }
        }
        return stamp
    }

    fun cachedPortrait(mii: ByteArray): Bitmap? = portraits[Key(mii)]

    /**
     * For screens that redraw to show portraits (KPMiiSource.portrait): the Mii's head, or null
     * while it renders, starting it if needed. [ready] runs once a render ends. Portraits that
     * failed or are already rendering aren't asked for again, so redraws don't loop.
     */
    fun portrait(context: Context, mii: ByteArray, ready: () -> Unit): Bitmap? {
        val key = Key(mii)
        portraits[key]?.let { return it }
        if (mii.size != MiiNative.MII_SIZE || key in portraitWaiters || portraitFailures[key] == resourceStamp(context)) return null
        requestPortrait(context, mii) { ready() }
        return null
    }

    /** The Mii's head, cropped to the drawn pixels. [ready] runs on the main thread, with null on failure. */
    fun requestPortrait(context: Context, mii: ByteArray, ready: (Bitmap?) -> Unit) {
        val key = Key(mii.copyOf())
        portraits[key]?.let { image -> main.post { ready(image) }; return }
        val current = resourceStamp(context)
        if (mii.size != MiiNative.MII_SIZE || portraitFailures[key] == current) {
            main.post { ready(null) }
            return
        }
        portraitWaiters[key]?.let { it += ready; return }
        portraitWaiters[key] = mutableListOf(ready)
        val faces = gameFiles(context).faces.path
        worker.execute {
            var problem: String? = null
            val image = try {
                MiiNative.nativePortrait(faces, key.bytes, IMAGE_SIZE)
            } catch (error: Throwable) {
                problem = if (error is UnsatisfiedLinkError) UNAVAILABLE else error.message
                null
            }
            main.post {
                val callbacks = portraitWaiters.remove(key).orEmpty()
                if (image != null) {
                    portraits[key] = image
                    portraitFailures.remove(key)
                    portraitProblem = null
                } else {
                    if (portraitFailures.size >= 256) portraitFailures.clear()
                    portraitFailures[key] = current
                    portraitProblem = problem
                }
                callbacks.forEach { it(image) }
            }
        }
    }

    /** Why portraits and the preview can't be drawn (missing or damaged archive), or null; on the main thread. */
    fun requestUnavailableReason(context: Context, ready: (String?) -> Unit) {
        val faces = gameFiles(context).faces.path
        worker.execute {
            val reason = try {
                MiiNative.nativeUnavailableReason(faces)
            } catch (error: UnsatisfiedLinkError) {
                UNAVAILABLE
            }
            main.post { ready(reason) }
        }
    }

    // Feature tiles, most recently used kept within a pixel budget; dropped when the editor closes.
    private val tiles = LinkedHashMap<String, Bitmap>(64, .75f, true)
    private var tileBytes = 0L
    private val tileWaiters = HashMap<String, MutableList<(Bitmap?) -> Unit>>()
    @Volatile private var tileGeneration = 0

    // Field, value, and the face shape and colours that field's tiles are drawn with.
    private fun tileKey(field: Int, value: Int, mii: ByteArray): String? =
        runCatching { "$field:$value:${MiiNative.nativeTileInputs(field, mii)}" }.getOrNull()

    private fun noTile(field: Int, value: Int) = value == 0 && (field == 33 || field == 37 || field == 38)

    fun cachedTile(field: Int, value: Int, mii: ByteArray): Bitmap? =
        if (noTile(field, value)) null else tileKey(field, value, mii)?.let { tiles[it] }

    /**
     * One editor tile showing [value] of appearance [field] in [mii]'s current colours; null for
     * "none" tiles (no glasses, mustache or beard) and failures. [ready] runs on the main thread.
     */
    fun requestTile(context: Context, field: Int, value: Int, mii: ByteArray, ready: (Bitmap?) -> Unit) {
        val key = if (noTile(field, value)) null else tileKey(field, value, mii)
        if (key == null) { main.post { ready(null) }; return }
        resourceStamp(context)
        tiles[key]?.let { image -> main.post { ready(image) }; return }
        tileWaiters[key]?.let { it += ready; return }
        tileWaiters[key] = mutableListOf(ready)
        val faces = gameFiles(context).faces.path
        val draft = mii.copyOf()
        val generation = tileGeneration
        worker.execute {
            if (generation != tileGeneration) return@execute
            val image = runCatching { MiiNative.nativeFeatureTile(faces, field, value, draft, IMAGE_SIZE) }.getOrNull()
            main.post {
                if (generation != tileGeneration) return@post
                val callbacks = tileWaiters.remove(key).orEmpty()
                if (image != null) storeTile(key, image)
                callbacks.forEach { it(image) }
            }
        }
    }

    private fun storeTile(key: String, image: Bitmap) {
        tiles.put(key, image)?.let { tileBytes -= it.allocationByteCount }
        tileBytes += image.allocationByteCount
        val entries = tiles.entries.iterator()
        while (tileBytes > TILE_BUDGET && tiles.size > 1 && entries.hasNext()) {
            val eldest = entries.next()
            if (eldest.key == key) continue
            tileBytes -= eldest.value.allocationByteCount
            entries.remove()
        }
    }

    /** Drops queued tile requests (their callbacks don't run), such as a page the editor left. */
    fun cancelPendingTiles() {
        tileGeneration++
        tileWaiters.clear()
    }

    /** The editor closed: its tiles go. */
    fun clearTiles() {
        cancelPendingTiles()
        tiles.clear()
        tileBytes = 0
    }
}
