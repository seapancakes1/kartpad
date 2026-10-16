package dev.kartpad.android.screens

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.util.Log
import android.view.HapticFeedbackConstants
import android.view.View
import dev.kartpad.android.KartPadSoundSettings
import dev.kartpad.android.screens.mii.MiiImages
import java.util.concurrent.Executors

/**
 * HOME and Mii screen sounds: Mario Kart Wii's menu cues (runtime/include/kartpad/mii/editor_sounds.h),
 * rendered once per session from the imported revo_kart.brsar on a background thread
 * (kartpad_ui_sounds_jni.cpp). Every sound replaces the one playing, except [HOVER], which never
 * cuts another off. They follow "HOME and Mii sounds" and the game-sound level in Sound settings.
 * Main thread API.
 */
internal object KartPadUISounds {
    // kartpad::mii::EditorSound, in order.
    const val HOVER = 0
    const val TICK = 1
    const val PRESS = 2
    const val TAB = 3
    const val SAME = 4
    const val CONFIRM = 5
    const val LEFT = 6
    const val RIGHT = 7
    const val PAGE_NEXT = 8
    const val PAGE_PREVIOUS = 9
    const val KEY = 10
    const val ERASE = 11
    const val OPEN = 12
    const val CLOSE = 13
    const val DIALOG = 14
    const val SAVED = 15
    const val REJECT = 16
    const val NEW_MII = 17
    private const val COUNT = 18

    private const val TAG = "KartPadUISounds"
    private const val PREFERENCES = "kartpad_sound"
    private const val ENABLED = "home_mii_sounds"
    private const val RATE = 32_000
    private const val VOLUME = .8f
    // A sound asked for while rendering (a screen opening) still plays if the sounds are ready by then.
    private const val PENDING_MS = 1_500L

    private val main = Handler(Looper.getMainLooper())
    private val renderer = Executors.newSingleThreadExecutor { task ->
        Thread(task, "KartPadUISounds").apply { isDaemon = true }
    }
    private val player = Player()
    private var app: Context? = null
    private var clips: Array<ShortArray?>? = null
    private var key: String? = null
    private var loadingKey: String? = null
    private var pending = -1
    private var pendingAt = 0L
    private var current = -1
    private var currentUntil = 0L

    private external fun nativeRender(path: String): Array<ShortArray?>

    private fun preferences(context: Context) = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    fun enabled(context: Context): Boolean = preferences(context).getBoolean(ENABLED, true)

    fun setEnabled(context: Context, enabled: Boolean) {
        preferences(context).edit().putBoolean(ENABLED, enabled).apply()
        if (!enabled) {
            player.stop()
            currentUntil = 0
            pending = -1
        }
    }

    /** Starts rendering (when a screen opens); a reimported archive (new size or date) renders again. */
    fun warm(context: Context) {
        if (Looper.myLooper() != Looper.getMainLooper()) { main.post { warm(context) }; return }
        val app = context.applicationContext
        this.app = app
        val file = MiiImages.gameFiles(app).sounds
        val next = if (file.isFile) "${file.path}|${file.length()}|${file.lastModified()}" else null
        if (next == null) {
            clips = null
            key = null
            loadingKey = null
            return
        }
        if (next == key || next == loadingKey) return
        loadingKey = next
        renderer.execute {
            // Without the archive, or for a sound that fails to render, the screens stay silent.
            val rendered = try {
                nativeRender(file.path).takeIf { it.size == COUNT }
            } catch (error: Throwable) {
                Log.w(TAG, "Sounds unavailable: ${error.message}")
                null
            }
            main.post {
                if (loadingKey != next) return@post
                loadingKey = null
                key = next
                clips = rendered
                val asked = pending
                pending = -1
                if (asked >= 0 && SystemClock.uptimeMillis() - pendingAt < PENDING_MS) play(asked)
            }
        }
    }

    /** Plays [sound] (one of the constants above). Silent until [warm] has run once. */
    fun play(sound: Int) {
        if (Looper.myLooper() != Looper.getMainLooper()) { main.post { play(sound) }; return }
        val app = app ?: return
        if (sound !in 0 until COUNT || !enabled(app)) return
        val level = KartPadSoundSettings.effective(app).second
        if (level <= 0f) return
        val now = SystemClock.uptimeMillis()
        val clips = clips ?: run {
            if (loadingKey != null) {
                pending = sound
                pendingAt = now
            }
            return
        }
        val clip = clips[sound] ?: return
        // Pointer hover never cuts off another sound; anything else replaces whatever is playing.
        if (sound == HOVER && now < currentUntil && current != HOVER) return
        current = sound
        currentUntil = now + clip.size * 1000L / (RATE * 2)
        player.play(clip, VOLUME * level)
    }

    /** [haptic] and [play] together, as the iPhone and iPad screens pair them. */
    fun play(view: View, sound: Int) {
        if (app == null) warm(view.context)
        haptic(view, sound)
        play(sound)
    }

    /**
     * Light haptics, whether or not sound is on: a tick for choosing, stepping, paging and slider
     * notches, a confirmation for a save and a rejection at a limit or error. Opening, closing,
     * dialogs, typing, hover and choosing what is already chosen have none.
     */
    fun haptic(view: View, sound: Int) {
        val feedback = when (sound) {
            TICK, PRESS, TAB, CONFIRM, LEFT, RIGHT, PAGE_NEXT, PAGE_PREVIOUS, NEW_MII ->
                if (Build.VERSION.SDK_INT >= 34) HapticFeedbackConstants.SEGMENT_TICK else HapticFeedbackConstants.CLOCK_TICK
            SAVED -> if (Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.VIRTUAL_KEY
            REJECT -> if (Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.REJECT else HapticFeedbackConstants.LONG_PRESS
            else -> return
        }
        view.performHapticFeedback(feedback)
    }

    /**
     * One streaming AudioTrack fed by its own thread, so the main thread only hands over a clip.
     * A new clip flushes the one playing. The track is released after a while without sounds.
     */
    private class Player {
        private val lock = Object()
        private var request: ShortArray? = null
        private var volume = 1f
        private var running = false

        fun play(clip: ShortArray, level: Float) = synchronized(lock) {
            request = clip
            volume = level
            if (!running) {
                running = true
                Thread({ feed() }, "KartPadUISoundsOut").apply { isDaemon = true }.start()
            }
            lock.notifyAll()
        }

        fun stop() = synchronized(lock) {
            if (running) {
                request = ShortArray(0)
                lock.notifyAll()
            }
        }

        private fun feed() {
            Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
            val track = runCatching { createTrack() }.onFailure { Log.w(TAG, "No audio track: ${it.message}") }.getOrNull()
            if (track == null) {
                synchronized(lock) { running = false; request = null }
                return
            }
            try {
                var clip: ShortArray? = null
                var position = 0
                while (true) {
                    val next: ShortArray?
                    val level: Float
                    synchronized(lock) {
                        if (clip == null && request == null) {
                            lock.wait(IDLE_MS)
                            if (request == null) { running = false; return }
                        }
                        next = request
                        level = volume
                        request = null
                    }
                    next?.let {
                        track.pause()
                        track.flush()
                        track.setVolume(level)
                        clip = it.takeIf(ShortArray::isNotEmpty)
                        position = 0
                    }
                    val samples = clip ?: continue
                    val written = track.write(samples, position, minOf(CHUNK, samples.size - position))
                    if (written <= 0) { clip = null; continue }
                    position += written
                    if (track.playState != AudioTrack.PLAYSTATE_PLAYING) track.play()
                    // Plays out what was written, then idles until the next clip.
                    if (position >= samples.size) { track.stop(); clip = null }
                }
            } catch (error: Exception) {
                Log.w(TAG, "Sound playback stopped", error)
                synchronized(lock) { running = false; request = null }
            } finally {
                track.release()
            }
        }

        private fun createTrack(): AudioTrack {
            val minimum = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
            val track = AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_GAME)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build())
                .setAudioFormat(AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .build())
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(maxOf(minimum * 2, RATE / 10 * 4, CHUNK * 4))
                .build()
            if (track.state != AudioTrack.STATE_INITIALIZED) {
                track.release()
                error("AudioTrack not initialized")
            }
            return track
        }

        private companion object {
            const val CHUNK = 1024 // Shorts per write: 16 ms, so a new clip waits at most that long.
            const val IDLE_MS = 10_000L
        }
    }
}
