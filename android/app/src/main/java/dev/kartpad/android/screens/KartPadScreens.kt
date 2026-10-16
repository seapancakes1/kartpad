package dev.kartpad.android.screens

import android.app.Activity
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.InputDevice
import android.view.KeyEvent
import android.view.PixelCopy
import android.view.SurfaceView
import android.view.ViewGroup

/**
 * What the screens need from the game's activity: Android's own sheets behind some Settings rows (they
 * need touch; the game stays held underneath), restarting, and the touch controls under the screens.
 */
interface KartPadScreensHost {
    /** The game playing: "base" or "retro_rewind". */
    val gameProfile: String
    /** The two-game build: the game switch on HOME and Settings › Start KartPad with. */
    val dualGame: Boolean
    val gameSurface: SurfaceView?
    /** The screens opened or closed: the touch controls, the ⋯ button and motion steering step aside. */
    fun screensShown(shown: Boolean)
    /** Restart KartPad into a game ("base", "retro_rewind"), or the same one for null. */
    fun restart(profile: String?)
    /** Back to KartPad's own game chooser. */
    fun returnToChooser()
    /** Opens one of Android's sheets by name (SettingsRows names them), once the screens have closed if asked. */
    fun openSheet(name: String)
    /**
     * Android's file picker: create (save as name) or open a document of a type; done gets its Uri, or
     * null when the player backed out. Needs touch, as Android's sheets do.
     */
    fun pickDocument(create: Boolean, name: String?, mime: String, done: (android.net.Uri?) -> Unit)
    /** Settings that apply at once, after a change. */
    fun applyDisplaySettings()
    fun applySoundLevels()
    fun applyControllerMapping()
}

// KartPad's screens in the game's activity, after the iPhone's KartPadScreensGlue.inc.mm: HOME from
// the ⋯ button, a controller's HOME button or Start held a second; the controllers each frame; the
// game held underneath; and the reconnect card when a player's controller drops out.
object KartPadScreens {
    private const val TAG = "KartPadScreens"
    var overlay: KPOverlay? = null
        private set
    lateinit var host: KartPadScreensHost
        private set
    lateinit var activity: Activity
        private set
    /** HOME's own screen, so a second ⋯ press closes everything. */
    var homeFactory: ((KPOverlay) -> KPScreen)? = null
    /** The screens by name, for the QA hook's `screen` command and Settings' rows. */
    val screens = LinkedHashMap<String, (KPOverlay) -> KPScreen>()
    /** Controllers, with the focus on a player's card (-1 for the first). */
    var controllersFor: ((KPOverlay, Int) -> KPScreen)? = null
    /** The reconnect card for a player and the controller that dropped out (-1 when unknown). */
    var reconnectFactory: ((KPOverlay, Int, Int) -> KPScreen?)? = null
    /** The hold the game thread reports (Held: the backdrop stands in for the surface). */
    var hold = KartPadHostScreens.Hold.Running
        private set

    fun install(activity: Activity, layout: ViewGroup, host: KartPadScreensHost) {
        if (overlay != null && this.activity === activity) return
        // A recreated activity gets screens of its own; the old ones go with the old window.
        overlay?.closeAll()
        this.activity = activity
        this.host = host
        KP.installFonts(activity)
        KPOverlayTheme.dark = activity.getSharedPreferences("kartpad_launcher", Activity.MODE_PRIVATE).getBoolean("dark_mode", true)
        val overlay = KPOverlay(activity, layout)
        this.overlay = overlay
        KartPadPads.overlay = overlay
        overlay.onHoldWanted = { wanted ->
            KartPadHostScreens.setOpen(wanted)
            if (wanted) captureBackdrop()
        }
        overlay.onActiveChanged = { active ->
            if (!active) KartPadPads.release()
            else KartPadPads.refresh(activity)
            host.screensShown(active)
        }
        overlay.onFrame = { now -> KartPadPads.poll(activity, now) }
        KartPadHostScreens.listen(::handle)
        KartPadScreensQA.start(activity, overlay)
    }

    private fun handle(event: KartPadHostScreens.Event) {
        val overlay = overlay ?: return
        when (event) {
            is KartPadHostScreens.Event.OpenHome -> if (!overlay.active) {
                overlay.touching = false
                openHome()
            }
            is KartPadHostScreens.Event.PlayerLost -> {
                KartPadPads.refresh(activity)
                reconnectFactory?.invoke(overlay, event.player, event.instance)?.let { card ->
                    if (!overlay.active) overlay.present(card)
                }
            }
            is KartPadHostScreens.Event.PadsChanged -> {
                KartPadPads.refresh(activity)
                overlay.top?.padsChanged()
                overlay.invalidate()
            }
            is KartPadHostScreens.Event.HoldChanged -> {
                hold = event.hold
                overlay.showBackdrop = event.hold == KartPadHostScreens.Hold.Held
                Log.i(TAG, "hold=${event.hold}")
            }
        }
    }

    /** ⋯: opens HOME, or closes the screens when they're open. */
    fun toggleHome() {
        val overlay = overlay ?: return
        if (overlay.active) overlay.closeAll() else openHome()
    }

    fun openHome() {
        val overlay = overlay ?: return
        val home = homeFactory?.invoke(overlay) ?: return
        if (overlay.active) overlay.closeAll()
        overlay.present(home)
    }

    val active: Boolean get() = overlay?.active == true

    /**
     * A key while the screens are open. A pad SDL reads reaches the screens through the game thread's
     * snapshot, so its keys go on to SDL untouched (false); keyboards, TV remotes, Back and the pads SDL
     * doesn't read drive the screens here.
     */
    fun dispatchKey(event: KeyEvent, sdlReadsDevice: Boolean): Boolean {
        val overlay = overlay ?: return false
        if (!overlay.active) return false
        if (sdlReadsDevice && event.source and InputDevice.SOURCE_GAMEPAD == InputDevice.SOURCE_GAMEPAD) return false
        return overlay.handleKey(event)
    }

    // The game's last frame, for when its surface goes (the app leaves and comes back while held).
    private fun captureBackdrop() {
        val overlay = overlay ?: return
        val surface = host.gameSurface ?: return
        if (surface.width <= 0 || surface.height <= 0 || !surface.holder.surface.isValid) return
        val bitmap = runCatching { Bitmap.createBitmap(surface.width, surface.height, Bitmap.Config.ARGB_8888) }.getOrNull() ?: return
        runCatching {
            PixelCopy.request(surface, bitmap, { result ->
                if (result == PixelCopy.SUCCESS && overlay.active) overlay.backdrop = bitmap
            }, Handler(Looper.getMainLooper()))
        }
    }

    /** The activity is going (recreated or finishing): nothing may stay held without its screens. */
    fun destroy() {
        overlay?.closeAll()
        KartPadHostScreens.setOpen(false)
    }
}
