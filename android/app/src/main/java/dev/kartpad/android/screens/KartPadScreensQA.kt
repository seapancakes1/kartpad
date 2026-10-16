package dev.kartpad.android.screens

import android.app.Activity
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.PixelCopy
import dev.kartpad.android.BuildConfig
import java.io.File
import java.io.FileOutputStream

// Automated checks of the screens on an emulator (debug builds only, never a release): KartPad reads
// files/QA/commands.txt four times a second, one command a line, each run once in order (lines already
// there when KartPad starts are skipped), and logs to files/QA/log.txt (adb shell run-as
// dev.kartpad.android …). The same commands as the iPhone's:
//   home                     the ⋯ button (opens HOME, or closes the screens)
//   screen NAME              opens a screen KartPadScreens.screens names (settings, controllers, ghosts, miis…)
//   tap LABEL                presses the control with that label (or the first starting with it) on the top screen
//   hit X Y                  logs what a touch at X,Y (design points) would land on
//   focus LABEL              moves the focus there
//   pad BUTTON               the QA pad presses and lets go: up down left right a b x y l r start home
//   hold BUTTON MS           the QA pad holds a button that long
//   close / back             closes every screen / goes back one
//   state                    logs the top screen, the focus, the hold and the touch mode
//   controls                 logs every control on the top screen with its frame
//   roster                   logs each controller and the player it plays as
//   shot NAME                writes NAME.png of the window (the game's picture included)
//   drop N                   player N's controller drops out (the reconnect card)
//   restart                  restarts KartPad into the same game
object KartPadScreensQA {
    private var directory: File? = null
    private var done = 0
    private val handler = Handler(Looper.getMainLooper())

    fun start(activity: Activity, overlay: KPOverlay) {
        if (!BuildConfig.DEBUG || directory != null) return
        val qa = File(activity.filesDir, "QA")
        if (!qa.isDirectory) return
        directory = qa
        // Only commands added from now on run: what an earlier run left in the file isn't replayed at launch.
        done = runCatching { File(qa, "commands.txt").readLines().count { it.isNotBlank() } }.getOrDefault(0)
        log("qa=started skipped=$done")
        val poll = object : Runnable {
            override fun run() {
                runCatching { read(activity, overlay) }.onFailure { log("error ${it.javaClass.simpleName}: ${it.message}") }
                handler.postDelayed(this, 250)
            }
        }
        handler.post(poll)
    }

    fun log(line: String) {
        val qa = directory ?: return
        runCatching {
            File(qa, "log.txt").appendText("%.3f %s\n".format(SystemClock.uptimeMillis() / 1000.0, line))
        }
    }

    private fun read(activity: Activity, overlay: KPOverlay) {
        val file = File(directory, "commands.txt")
        if (!file.isFile) return
        val lines = file.readLines().map { it.trim() }.filter { it.isNotEmpty() }
        while (done < lines.size) {
            val line = lines[done++]
            log("> $line")
            run(activity, overlay, line)
        }
    }

    private fun button(overlay: KPOverlay, label: String): KPButton? {
        val buttons = overlay.top?.items?.filterIsInstance<KPButton>()?.filter { !it.hidden } ?: return null
        return buttons.firstOrNull { it.label == label } ?: buttons.firstOrNull { it.label?.lowercase()?.startsWith(label.lowercase()) == true }
    }

    private val padButtons = mapOf(
        "a" to SDLButton.South, "b" to SDLButton.East, "x" to SDLButton.West, "y" to SDLButton.North,
        "up" to SDLButton.DpadUp, "down" to SDLButton.DpadDown, "left" to SDLButton.DpadLeft, "right" to SDLButton.DpadRight,
        "l" to SDLButton.LeftShoulder, "r" to SDLButton.RightShoulder, "start" to SDLButton.Start, "home" to SDLButton.Guide,
    )

    private fun run(activity: Activity, overlay: KPOverlay, line: String) {
        val words = line.split(" ")
        val rest = words.drop(1).joinToString(" ")
        when (words[0]) {
            "home" -> KartPadScreens.toggleHome()
            "screen" -> {
                val make = KartPadScreens.screens[rest]
                if (make == null) log("screen=unknown $rest") else overlay.present(make(overlay))
            }
            "tap" -> button(overlay, rest)?.let {
                overlay.focus(it, false)
                it.fire(true)
                log("tapped=${it.label}")
            } ?: log("tap=missing $rest")
            "focus" -> button(overlay, rest)?.let { overlay.focus(it, true); log("focus=${it.label}") } ?: log("focus=missing $rest")
            "hit" -> {
                val x = words.getOrNull(1)?.toFloatOrNull() ?: 0f
                val y = words.getOrNull(2)?.toFloatOrNull() ?: 0f
                log("hit=${overlay.top?.buttonAt(x, y)?.label ?: "nothing"}")
            }
            "pad", "hold" -> {
                val button = padButtons[words.getOrNull(1)?.lowercase()]
                if (button == null) {
                    log("pad=unknown $rest")
                    return
                }
                val millis = if (words[0] == "hold") words.getOrNull(2)?.toLongOrNull() ?: 1200L else 90L
                KartPadHostScreens.qaPress(button, true)
                handler.postDelayed({ KartPadHostScreens.qaPress(button, false) }, millis)
            }
            "close" -> overlay.closeAll()
            "back" -> overlay.top?.back()
            "state" -> {
                val top = overlay.top
                log("state top=${top?.javaClass?.simpleName ?: "none"} title=${top?.title} depth=${overlay.stack.size} " +
                    "focus=${top?.focus?.label} hold=${KartPadHostScreens.hold} touching=${overlay.touching} scale=${overlay.scale} " +
                    "safe=${overlay.safe.toShortString()}")
            }
            "controls" -> overlay.top?.items?.filterIsInstance<KPButton>()?.forEach {
                log("control label=${it.label} frame=${it.frame.toShortString()} enabled=${it.enabled} hidden=${it.hidden} focused=${it.focused}")
            }
            "roster" -> {
                KartPadPads.refresh(activity)
                for (device in KartPadPads.devices)
                    log("pad instance=${device.instance} name=${device.name} family=${device.family} player=${device.slot} battery=${device.battery}")
                KartPadPads.players().forEachIndexed { player, device -> log("player=${player + 1} ${device?.name ?: "none"}") }
            }
            "shot" -> shot(activity, rest.ifEmpty { "shot" })
            "drop" -> {
                val player = (words.getOrNull(1)?.toIntOrNull() ?: 1) - 1
                KartPadScreens.reconnectFactory?.invoke(overlay, player, -1)?.let { overlay.present(it) } ?: log("drop=unavailable")
            }
            "restart" -> KartPadScreens.host.restart(null)
            else -> log("unknown=$line")
        }
    }

    private fun shot(activity: Activity, name: String) {
        val window = activity.window
        val view = window.decorView
        if (view.width <= 0 || view.height <= 0) return
        val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
        PixelCopy.request(window, bitmap, { result ->
            if (result != PixelCopy.SUCCESS) {
                log("shot=failed $result")
                return@request
            }
            runCatching {
                FileOutputStream(File(directory, "$name.png")).use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                log("shot=$name.png")
            }
        }, handler)
    }
}
