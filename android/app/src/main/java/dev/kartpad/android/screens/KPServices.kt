package dev.kartpad.android.screens

import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import dev.kartpad.android.KartPadIdentityStorage
import dev.kartpad.android.KartPadMiiStorage
import dev.kartpad.android.KartPadSaveStorage
import dev.kartpad.android.KartPadSoundSettings
import java.io.File

// What the screens share about the players and the game, after the Mac's KPControllerRoster and the
// Mii manager: each controller's Mii, finding a controller, the Miis, the volume and a waiting restart.

/** A Mii as the screens show it. createId is the record's 8 identity bytes in hex (0x18–0x1f). */
class KPMiiInfo(val slot: Int, val createId: String, val name: String, val creator: String, val favoriteColor: Int, val record: ByteArray)

object KPMiiSource {
    /** Reads the Miis as they will be after any waiting change, off the main thread (the setup sets the queue's). */
    var loader: (Context) -> List<KPMiiInfo> = { context -> readDatabase(File(context.filesDir, "KartPad/NAND/shared2/menu/FaceLib/RFL_DB.dat")) }
    private val worker = java.util.concurrent.Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var cached: List<KPMiiInfo>? = null

    /** The Miis last read (drawing asks every frame); the first ask starts a read. */
    fun list(context: Context): List<KPMiiInfo> = cached ?: emptyList<KPMiiInfo>().also { refresh(context) }

    /** Reads them again (a screen opened, a change was queued); done runs on the main thread. */
    fun refresh(context: Context, done: (() -> Unit)? = null) {
        val app = context.applicationContext
        worker.execute {
            val read = runCatching { loader(app) }.getOrDefault(emptyList())
            main.post {
                cached = read
                done?.invoke()
                KartPadScreens.overlay?.invalidate()
            }
        }
    }
    /** A Mii's head, or null while it renders; ready runs on the main thread once it's there. */
    var portrait: (ByteArray, () -> Unit) -> Bitmap? = { _, _ -> null }

    // A Mii's favourite colour (Red, Orange, Yellow, Light green, Green, Blue, Light blue, Pink, Purple,
    // Brown, White, Black), for its silhouette before the portrait is drawn.
    private val favorites = intArrayOf(0xd21e14, 0xff6e19, 0xffd820, 0x78d220, 0x007830, 0x0a48b4, 0x3caade, 0xf55a7d,
        0x7328ad, 0x483818, 0xe0e0e0, 0x181814)
    fun favoriteHex(index: Int) = favorites[if (index in 0..11) index else 0]

    private const val RecordBytes = 74
    private const val Slots = 100

    /** The live database's Miis (RFL_DB.dat: "RNOD", then 100 records of 74 bytes). */
    fun readDatabase(file: File): List<KPMiiInfo> {
        val bytes = runCatching { file.readBytes() }.getOrNull() ?: return emptyList()
        if (bytes.size < 4 + Slots * RecordBytes || String(bytes, 0, 4, Charsets.US_ASCII) != "RNOD") return emptyList()
        val out = ArrayList<KPMiiInfo>()
        for (slot in 0 until Slots) {
            val at = 4 + slot * RecordBytes
            val record = bytes.copyOfRange(at, at + RecordBytes)
            if (record.all { it == 0.toByte() }) continue
            val id = (0x18 until 0x20).joinToString("") { "%02x".format(record[it].toInt() and 0xff) }
            if (id.all { it == '0' }) continue
            val flags = ((record[0].toInt() and 0xff) shl 8) or (record[1].toInt() and 0xff)
            out += KPMiiInfo(slot, id, utf16(record, 0x02), utf16(record, 0x36), (flags shr 1) and 0xf, record)
        }
        return out
    }

    fun utf16(record: ByteArray, at: Int): String {
        val text = StringBuilder()
        for (i in 0 until 10) {
            val unit = ((record[at + i * 2].toInt() and 0xff) shl 8) or (record[at + i * 2 + 1].toInt() and 0xff)
            if (unit == 0) break
            text.append(unit.toChar())
        }
        return text.toString()
    }
}

object KPRoster {
    private const val Preferences = "kartpad_screens"
    private const val ControllerMiis = "controller_mii_"   // + profile key → Mii create ID
    private const val PlayerMiis = "player_mii_"           // + 0–3, for the touch screen and twin pads
    private val handler = Handler(Looper.getMainLooper())

    fun deviceInSlot(slot: Int): KPPadDevice? = KartPadPads.players().getOrNull(slot)

    private fun preferences(context: Context) = context.getSharedPreferences(Preferences, Context.MODE_PRIVATE)

    private fun key(device: KPPadDevice) = if (device.isTouch) "$PlayerMiis${device.slot}" else "$ControllerMiis${device.profileKey}"

    /** The Mii someone chose for this controller (a label that helps players tell them apart). */
    fun miiInfoFor(context: Context, device: KPPadDevice): KPMiiInfo? {
        val id = preferences(context).getString(key(device), null) ?: return null
        return KPMiiSource.list(context).firstOrNull { it.createId == id }
    }

    fun miiFor(context: Context, device: KPPadDevice): ByteArray? = miiInfoFor(context, device)?.record

    fun setMii(context: Context, device: KPPadDevice, mii: KPMiiInfo?) {
        preferences(context).edit().apply {
            if (mii == null) remove(key(device)) else putString(key(device), mii.createId)
        }.apply()
    }

    /** X on a player: their controller buzzes and its light flashes, so they can tell which it is. */
    fun identify(device: KPPadDevice) {
        if (device.isTouch || device.isKeyboard) return
        if (device.canRumble) KartPadHostScreens.rumble(device.instance, 0xc000, 0xc000, 260)
        if (device.hasLight) {
            KartPadHostScreens.setLight(device.instance, 0xffffff)
            handler.postDelayed({ keepLight(device) }, 180)
        }
    }

    /** A pad's light in its player's colour (DualShock 4, DualSense); dim while it plays as nobody. */
    fun keepLight(device: KPPadDevice) {
        if (!device.hasLight) return
        KartPadHostScreens.setLight(device.instance, if (device.slot in 0..3) KP.PlayerLights[device.slot] else 0x202020)
    }

    /**
     * Gives a controller a player. The one already there moves to where this one came from, so each keeps
     * one controller (a swap); from the tray, aurora moves it to a free player, if there is one.
     */
    fun move(device: KPPadDevice, slot: Int): Boolean {
        if (device.isTouch || device.isKeyboard || slot !in 0..3) return false
        val from = device.slot
        val occupant = KartPadPads.devices.firstOrNull { it.slot == slot && it.instance != device.instance }
        if (!KartPadHostScreens.assign(device.instance, slot)) return false
        if (occupant != null && from in 0..3) KartPadHostScreens.assign(occupant.instance, from)
        KartPadPads.refresh()
        KartPadPads.devices.forEach(::keepLight)
        return true
    }

    /** Stop playing: the controller plays as nobody until it's given a player again. */
    fun stopPlaying(device: KPPadDevice): Boolean {
        if (device.slot !in 0..3) return false
        val done = KartPadHostScreens.clearPlayer(device.slot)
        KartPadPads.refresh()
        KartPadPads.devices.forEach(::keepLight)
        return done
    }
}

object KPRestart {
    /** A setting that applies only from the next start changed (the private server, say). */
    var settingsChanged = false

    /** Something waits for a restart: Mii, license, save, ghost or rating changes, or a setting. */
    fun waiting(context: Context): Boolean {
        val files = context.filesDir
        return settingsChanged || runCatching {
            KartPadMiiStorage.hasPending(files) || KartPadSaveStorage.hasPending(files) || KartPadIdentityStorage.hasPending(files)
        }.getOrDefault(false)
    }
}

/** HOME's volume and Settings' Sound and Volume: over the music and game sounds, applied at once. */
object KPVolume {
    fun level(context: Context) = KartPadSoundSettings.masterPercent(context) / 100f
    fun muted(context: Context) = KartPadSoundSettings.muted(context)
    fun set(context: Context, level: Float, muted: Boolean) {
        KartPadSoundSettings.setMaster(context, Math.round(level.coerceIn(0f, 1f) * 100), muted)
        KartPadScreens.host.applySoundLevels()
    }
}
