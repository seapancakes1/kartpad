package dev.kartpad.android.screens

import android.os.Looper
import android.os.MessageQueue
import android.os.ParcelFileDescriptor
import java.nio.ByteBuffer
import java.nio.ByteOrder

// The game thread's side of the screens (runtime/src/android/host_screens.cpp; the fixture app has a
// stand-in): holding the game, the controllers as SDL sees them, and what happened while the screens
// were closed (HOME pressed, a player's controller gone). Native calls are thread-safe; the game
// thread wakes the main thread through an event fd, never by calling into Java.
object KartPadHostScreens {
    enum class Hold { Running, Held, Online, Starting }

    sealed class Event {
        class OpenHome(val instance: Int) : Event()
        class PlayerLost(val player: Int, val instance: Int) : Event()
        object PadsChanged : Event()
        class HoldChanged(val hold: Hold) : Event()
    }

    private external fun nativeSetOpen(open: Boolean)
    private external fun nativeHoldState(): Int
    private external fun nativeGameState(): Int
    private external fun nativeReadPads(buffer: ByteBuffer): Int
    private external fun nativeEventFd(): Int
    private external fun nativeTakeEvents(): IntArray?
    private external fun nativeRumble(instance: Int, low: Int, high: Int, millis: Int)
    private external fun nativeSetLight(instance: Int, rgb: Int)
    private external fun nativeAssign(instance: Int, player: Int): Boolean
    private external fun nativeClearPlayer(player: Int): Boolean
    private external fun nativeQaPress(button: Int, down: Boolean)

    private const val MaxPads = 16
    private val buffer: ByteBuffer = ByteBuffer.allocateDirect(MaxPads * KPPadDevice.RecordBytes).order(ByteOrder.LITTLE_ENDIAN)
    private var eventFd: ParcelFileDescriptor? = null

    /** Native code isn't there (a build without the screens' JNI): everything is a no-op. */
    var available = true
        private set

    private inline fun <T> guarded(fallback: T, block: () -> T): T {
        if (!available) return fallback
        return try {
            block()
        } catch (_: UnsatisfiedLinkError) {
            available = false
            fallback
        }
    }

    fun setOpen(open: Boolean) = guarded(Unit) { nativeSetOpen(open) }
    val hold: Hold get() = guarded(Hold.Running) { Hold.values().getOrElse(nativeHoldState()) { Hold.Running } }
    /** The game is online (the screens won't hold it) or still starting, as of its last event pump. */
    val gameOnline: Boolean get() = guarded(false) { nativeGameState() and 1 != 0 }
    val gameStarting: Boolean get() = guarded(false) { nativeGameState() and 2 != 0 }

    fun readPads(): List<KPPadDevice> = guarded(emptyList()) {
        val count = nativeReadPads(buffer)
        KPPadDevice.parse(buffer, count)
    }

    fun rumble(instance: Int, low: Int, high: Int, millis: Int) = guarded(Unit) { nativeRumble(instance, low, high, millis) }
    fun setLight(instance: Int, rgb: Int) = guarded(Unit) { nativeSetLight(instance, rgb) }
    fun assign(instance: Int, player: Int): Boolean = guarded(false) { nativeAssign(instance, player) }
    fun clearPlayer(player: Int): Boolean = guarded(false) { nativeClearPlayer(player) }
    fun qaPress(button: Int, down: Boolean) = guarded(Unit) { nativeQaPress(button, down) }

    /** Listens on the main thread for what the game thread has to say. */
    fun listen(handle: (Event) -> Unit) {
        if (eventFd != null) return
        val fd = guarded(-1) { nativeEventFd() }
        if (fd < 0) return
        val descriptor = ParcelFileDescriptor.fromFd(fd)
        eventFd = descriptor
        Looper.getMainLooper().queue.addOnFileDescriptorEventListener(descriptor.fileDescriptor,
            MessageQueue.OnFileDescriptorEventListener.EVENT_INPUT) { _, _ ->
            drain(handle)
            MessageQueue.OnFileDescriptorEventListener.EVENT_INPUT
        }
        drain(handle)
    }

    private fun drain(handle: (Event) -> Unit) {
        val pairs = guarded<IntArray?>(null) { nativeTakeEvents() } ?: return
        var i = 0
        while (i + 1 < pairs.size) {
            val arg = pairs[i + 1]
            when (pairs[i]) {
                1 -> handle(Event.OpenHome(arg))
                2 -> handle(Event.PlayerLost(arg and 0xff, arg ushr 8))
                3 -> handle(Event.PadsChanged)
                4 -> handle(Event.HoldChanged(Hold.values().getOrElse(arg) { Hold.Running }))
            }
            i += 2
        }
    }
}
