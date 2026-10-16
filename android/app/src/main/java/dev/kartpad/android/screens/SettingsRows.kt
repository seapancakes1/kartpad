package dev.kartpad.android.screens

import android.content.Context
import dev.kartpad.android.BuildConfig
import dev.kartpad.android.KartPadAppIcon
import dev.kartpad.android.KartPadIdentityStorage
import dev.kartpad.android.KartPadMiiStorage
import dev.kartpad.android.KartPadPreferredGame
import dev.kartpad.android.KartPadSaveStorage
import dev.kartpad.android.KartPadSoundSettings
import dev.kartpad.android.KartPadTouchSettings
import kotlin.math.abs

// Settings' rows on Android (the iPhone's apple/ios/KartPadScreensSettingsRows.inc.mm): what the ⋯
// menu held, as rows. Each reads and writes the store the old sheets used and applies at once
// (KartPadScreens.host.apply*); rows that open one of Android's own sheets need touch, and the game
// stays held underneath with Settings still open.

enum class KPRowKind { Switch, Choice, Slider, Action }

/** One row of Settings (the Mac's KPSettingRow). Its blocks read the setting fresh each time. */
class KPSettingRow(val title: String, val detail: String?, val kind: KPRowKind) {
    var choices: List<String> = emptyList()
    var on: () -> Boolean = { false }
    var setOn: (Boolean) -> Unit = {}
    var index: () -> Int = { 0 }
    var setIndex: (Int) -> Unit = {}
    var level: () -> Float = { 0f }
    var setLevel: (Float) -> Unit = {}
    var run: (() -> Unit)? = null
    var value: (() -> String?)? = null
    var restart: (() -> Boolean)? = null
    /** An action row that acts where it is (no chevron). */
    var inPlace = false
    /** A level the Sound switch silences. */
    var soundLevel = false
    /** Shown only while this holds (Music and Game sounds, while they're adjusted). */
    var shown: (() -> Boolean)? = null
    /** What the row opens, for the tests: one of Android's sheets (host.openSheet) or a screen (KartPadScreens.screens). */
    var sheet: String? = null
    var screen: String? = null
}

object SettingsRows {
    val categoryNames = listOf("Picture", "Sound", "Controls", "Game", "Advanced")
    val categoryGlyphs = listOf(KPUIGlyph.Picture, KPUIGlyph.Speaker, KPUIGlyph.Pad, KPUIGlyph.Game, KPUIGlyph.Advanced)

    /**
     * Whether Retro Rewind's files are in place, for Start KartPad with and Retro Rewind files. Set by
     * the setup (the installer's storage is package-private); null skips the check and the value.
     */
    var retroRewindReady: ((Context) -> Boolean)? = null

    // Render Resolution's scales (KartPadActivity.showResolutionSettings).
    private val scales = floatArrayOf(.5f, .75f, 1f, 2f, 3f, 4f)
    private const val ScreensPreferences = "kartpad_screens"
    private const val Vibration = "vibration"
    private const val NintendoLayout = "nintendo_layout"

    private fun host() = KartPadScreens.host

    private fun preferences(context: Context) = context.getSharedPreferences(ScreensPreferences, Context.MODE_PRIVATE)

    private fun row(title: String, kind: KPRowKind, detail: String? = null, build: KPSettingRow.() -> Unit = {}) =
        KPSettingRow(title, detail, kind).apply(build)

    // A row that opens one of Android's sheets over the screens.
    private fun sheet(title: String, name: String, detail: String? = null, build: KPSettingRow.() -> Unit = {}) =
        row(title, KPRowKind.Action, detail) {
            sheet = name
            run = { host().openSheet(name) }
            build()
        }

    // A row that opens one of KartPad's screens (Miis, Time Trial ghosts), registered by name.
    private fun screen(overlay: KPOverlay?, title: String, name: String, build: KPSettingRow.() -> Unit = {}) =
        row(title, KPRowKind.Action) {
            screen = name
            run = { present(overlay, name) }
            build()
        }

    private fun present(overlay: KPOverlay?, name: String) {
        val o = overlay ?: return
        val make = KartPadScreens.screens[name]
        if (make == null) o.play(KPUISound.Reject) else o.present(make(o))
    }

    private fun failed(overlay: KPOverlay?) {
        val o = overlay ?: return
        o.play(KPUISound.Reject)
        o.toast("That setting couldn’t be saved", "KartPad’s settings file can’t be written.", 0,
            { c, r -> KPGlyphs.draw(c, KPUIGlyph.Gear, r, 0xd0342c) })
    }

    /**
     * Every category's rows, in order. Building them reads nothing; the rows read their settings when
     * drawn. overlay is null in the tests (rows that present or play then do nothing there).
     */
    fun categories(context: Context, overlay: KPOverlay? = null, dualGame: Boolean = KartPadScreens.host.dualGame,
                   diagnostics: Boolean = BuildConfig.VERSION_NAME.contains("diagnostics")): List<Pair<String, List<KPSettingRow>>> {
        // Picture: applies at once (the game reads it every frame).
        val picture = listOf(
            row("Picture quality", KPRowKind.Choice) {
                choices = listOf("0.5×", "0.75×", "1× (Native)", "2×", "3×", "4×")
                index = {
                    val scale = KartPadTouchSettings.resolutionScale(context)
                    scales.indices.minByOrNull { abs(scales[it] - scale) } ?: 2
                }
                setIndex = { i ->
                    KartPadTouchSettings.setResolutionScale(context, scales[i])
                    host().applyDisplaySettings()
                }
            },
            row("Aspect ratio", KPRowKind.Choice) {
                choices = listOf("Original 4:3", "16:9 (Experimental)", "Fill Screen (Experimental)")
                index = { KartPadTouchSettings.aspectMode(context) }
                setIndex = { i ->
                    KartPadTouchSettings.setAspectMode(context, i)
                    host().applyDisplaySettings()
                }
            },
            row("Show frame rate", KPRowKind.Switch) {
                on = { KartPadTouchSettings.showFps(context) }
                setOn = { isOn ->
                    KartPadTouchSettings.setShowFps(context, isOn)
                    host().applyDisplaySettings()
                }
            },
            row("Frame rate size", KPRowKind.Choice) {
                choices = listOf("Small", "Medium", "Large")
                index = { KartPadTouchSettings.fpsSize(context) }
                setIndex = { i ->
                    KartPadTouchSettings.setFpsSize(context, i)
                    host().applyDisplaySettings()
                }
            },
            // Original KartPad artwork only. Android closes the app to change it, so its sheet asks first.
            sheet("App icon", "app_icon") {
                value = { KartPadAppIcon.titles.getOrNull(KartPadAppIcon.current(context)) }
            },
        )

        // Sound: HOME's volume over the music and game sounds, and the launcher's Sound sheet's levels.
        val sound = listOf(
            row("Sound", KPRowKind.Switch) {
                on = { !KPVolume.muted(context) }
                setOn = { isOn -> KPVolume.set(context, KPVolume.level(context), !isOn) }
            },
            row("Volume", KPRowKind.Slider) {
                soundLevel = true
                level = { KPVolume.level(context) }
                setLevel = { to -> KPVolume.set(context, to, KPVolume.muted(context)) }
            },
            row("Adjust music and game sounds", KPRowKind.Switch) {
                on = { KartPadSoundSettings.enabled(context) }
                setOn = { isOn ->
                    KartPadSoundSettings.set(context, isOn, KartPadSoundSettings.musicPercent(context),
                        KartPadSoundSettings.soundsPercent(context))
                    host().applySoundLevels()
                }
            },
            levelRow(context, "Music", true),
            levelRow(context, "Game sounds", false),
            row("HOME and Mii sounds", KPRowKind.Switch) {
                on = { KartPadUISounds.enabled(context) }
                setOn = { isOn ->
                    KartPadUISounds.setEnabled(context, isOn)
                    if (isOn) overlay?.play(KPUISound.Confirm)
                }
            },
        )

        // Controls.
        val controls = listOf(
            row("Controllers", KPRowKind.Action) {
                screen = "controllers"
                run = {
                    overlay?.let { o ->
                        val make = KartPadScreens.controllersFor
                        if (make == null) o.play(KPUISound.Reject) else o.present(make(o, -1))
                    }
                }
                value = {
                    val playing = KartPadPads.players().count { it != null }
                    when (playing) {
                        0 -> "None"
                        1 -> "1 player"
                        else -> "$playing players"
                    }
                }
            },
            // The button setup screen, or Android's button mapping sheet without it.
            row("Controller buttons", KPRowKind.Action) {
                screen = "buttons"
                run = {
                    if (KartPadScreens.screens["buttons"] != null) present(overlay, "buttons")
                    else host().openSheet("controller_mapping")
                }
            },
            // The host publishes both to the runtime (applyControllerMapping reads them).
            row("Vibration", KPRowKind.Switch) {
                on = { preferences(context).getBoolean(Vibration, true) }
                setOn = { isOn ->
                    preferences(context).edit().putBoolean(Vibration, isOn).apply()
                    if (!isOn) for (device in KartPadPads.devices)
                        if (device.canRumble) KartPadHostScreens.rumble(device.instance, 0, 0, 0)
                    host().applyControllerMapping()
                }
            },
            row("Nintendo button layout", KPRowKind.Switch) {
                on = { preferences(context).getBoolean(NintendoLayout, false) }
                setOn = { isOn ->
                    preferences(context).edit().putBoolean(NintendoLayout, isOn).apply()
                    host().applyControllerMapping()
                }
            },
            row("Auto-accelerate", KPRowKind.Switch) {
                on = { KartPadTouchSettings.controllerAutoAccelerate(context) }
                setOn = { isOn ->
                    KartPadTouchSettings.setControllerAutoAccelerate(context, isOn)
                    host().applyControllerMapping()
                }
            },
            sheet("Touch controls", "touch_settings"),
            sheet("Motion steering", "motion"),
            sheet("Shake to trick", "shake"),
        )

        // Game.
        val game = ArrayList<KPSettingRow>()
        if (dualGame) game += row("Start KartPad with", KPRowKind.Choice) {
            choices = listOf("Ask every time", "Mario Kart Wii", "Retro Rewind")
            index = { KartPadPreferredGame.values.indexOf(KartPadPreferredGame.read(context.filesDir)).coerceAtLeast(0) }
            setIndex = set@{ i ->
                if (i == 2 && retroRewindReady?.invoke(context) == false) {
                    overlay?.play(KPUISound.Reject)
                    overlay?.toast("Retro Rewind isn’t set up yet", "Set up Retro Rewind files below first.", 0,
                        { c, r -> KPGlyphs.draw(c, KPUIGlyph.Disc, r, KP.p.secondaryText) })
                    return@set
                }
                runCatching { KartPadPreferredGame.write(context.filesDir, KartPadPreferredGame.values[i]) }
                    .onFailure { failed(overlay) }
            }
        }
        game += screen(overlay, "Miis", "miis") {
            restart = { KartPadMiiStorage.hasPending(context.filesDir) }
        }
        game += screen(overlay, "Time Trial ghosts", "ghosts") {
            restart = { KartPadSaveStorage.hasPendingGhost(context.filesDir) }
        }
        game += sheet("Saves", "saves") {
            restart = { KartPadSaveStorage.profiles.any { KartPadSaveStorage.hasPending(context.filesDir, it) } }
        }
        game += sheet("Multiplayer", "multiplayer")
        game += sheet("Retro Rewind files", "retro_rewind") {
            val ready = retroRewindReady
            if (ready != null) value = { if (ready(context)) "Ready" else "Not set up" }
        }
        game += row("KartPad menu", KPRowKind.Action) {
            run = {
                overlay?.let { o ->
                    KPAsk.warning(o, "Return to the KartPad menu?", "Unsaved progress will be lost.", listOf("Return", "Cancel"), 0, -1) { choice ->
                        if (choice == 0) host().returnToChooser()
                    }
                }
            }
        }

        // Advanced.
        val advanced = ArrayList<KPSettingRow>()
        advanced += row("Mario Kart Wii files", KPRowKind.Action) {
            run = { overlay?.let { showGameFiles(it) } }
        }
        advanced += sheet("Private Wii server", "private_server")
        advanced += sheet("Wii Remote + Nunchuk", "wiimote")
        advanced += sheet("Console identity", "identity") {
            restart = { KartPadIdentityStorage.hasPending(context.filesDir) }
        }
        advanced += sheet("Graphics diagnostics", "graphics_diagnostics")
        advanced += sheet("Report a problem", "report")
        if (diagnostics) advanced += sheet("Test native crash", "crash_test", "Closes KartPad.")

        return categoryNames.zip(listOf(picture, sound, controls, game, advanced))
    }

    // Music or game sounds, 0 to 1, while they're adjusted.
    private fun levelRow(context: Context, title: String, music: Boolean) = row(title, KPRowKind.Slider) {
        soundLevel = true
        shown = { KartPadSoundSettings.enabled(context) }
        level = {
            (if (music) KartPadSoundSettings.musicPercent(context) else KartPadSoundSettings.soundsPercent(context)) / 100f
        }
        setLevel = { to ->
            val percent = Math.round(to.coerceIn(0f, 1f) * 100)
            KartPadSoundSettings.set(context, true,
                if (music) percent else KartPadSoundSettings.musicPercent(context),
                if (music) KartPadSoundSettings.soundsPercent(context) else percent)
            host().applySoundLevels()
        }
    }

    // Mario Kart Wii files: importing a new copy or removing the stored one (iPhone's action sheet).
    private fun showGameFiles(overlay: KPOverlay) {
        val menu = KPMenuScreen(overlay)
        menu.heading = "Mario Kart Wii files"
        menu.message = "Import a new copy, or remove the stored one. Saves and control settings are kept."
        menu.add("Import from Extracted Folder…", glyph = KPUIGlyph.Folder) { host().openSheet("import_folder") }
        menu.add("Import or Reimport Wii Disc Image…", glyph = KPUIGlyph.Disc) { host().openSheet("import_disc") }
        menu.add("Remove Stored Game Data…", glyph = KPUIGlyph.Close) { host().openSheet("remove_data") }
        overlay.present(menu)
    }
}
