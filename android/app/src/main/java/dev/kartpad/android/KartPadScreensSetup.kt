package dev.kartpad.android

import android.view.ViewGroup
import dev.kartpad.android.screens.ButtonSetupScreen
import dev.kartpad.android.screens.GhostsScreen
import dev.kartpad.android.screens.HomeScreen
import dev.kartpad.android.screens.KPMiiInfo
import dev.kartpad.android.screens.KPMiiSource
import dev.kartpad.android.screens.KartPadPads
import dev.kartpad.android.screens.KartPadScreens
import dev.kartpad.android.screens.KartPadUISounds
import dev.kartpad.android.screens.SettingsRows
import dev.kartpad.android.screens.SettingsScreen
import dev.kartpad.android.screens.makeControllersScreen
import dev.kartpad.android.screens.makeReconnectScreen
import dev.kartpad.android.screens.mii.MiiImages
import dev.kartpad.android.screens.mii.MiisScreen

// Which screens there are and what feeds them, for KartPadActivity (dev.kartpad.android.screens holds
// the screens themselves).
internal object KartPadScreensSetup {
    fun install(activity: KartPadActivity, layout: ViewGroup) {
        val context = activity.applicationContext
        KartPadScreens.homeFactory = { HomeScreen(it) }
        KartPadScreens.screens["home"] = { HomeScreen(it) }
        KartPadScreens.screens["settings"] = { SettingsScreen(it) }
        KartPadScreens.screens["ghosts"] = { GhostsScreen(it) }
        KartPadScreens.screens["miis"] = { MiisScreen(it) }
        KartPadScreens.controllersFor = { o, slot -> makeControllersScreen(o, slot) }
        KartPadScreens.screens["controllers"] = { makeControllersScreen(it, -1) }
        KartPadScreens.screens["buttons"] = { ButtonSetupScreen(it) }
        KartPadScreens.reconnectFactory = { o, player, instance -> makeReconnectScreen(o, player, instance) }
        // Retro Rewind's storage is package-private Java, so its check is handed over from here.
        SettingsRows.retroRewindReady = { c ->
            runCatching {
                RetroRewindInstallStorage.installedRoot(c.filesDir).resolve(RetroRewindRelease.ROOT)
                    .resolve("version.txt").toFile().readText().trim() == RetroRewindRelease.VERSION
            }.getOrDefault(false)
        }
        KPMiiSource.portrait = { mii, ready -> MiiImages.portrait(context, mii, ready) }
        // The Miis as they'll be after any waiting change (the queue keeps its replay cached).
        KPMiiSource.loader = { ctx ->
            when (val upcoming = KartPadMiiChanges.upcoming(ctx.filesDir)) {
                is KartPadMiiChanges.Upcoming -> upcoming.miis.map { KPMiiInfo(it.slot, it.createId, it.name, it.creator, it.favoriteColor, it.record) }
                else -> emptyList()
            }
        }
        activity.applyControllerMapping()
        KartPadPads.mapping = KartPadControllerMapping.load(activity)
        KartPadScreens.install(activity, layout, activity)
        KartPadScreens.overlay?.soundPlayer = { KartPadUISounds.play(it.ordinal) }
        KartPadScreens.overlay?.portraitProvider = { mii, ready -> MiiImages.portrait(context, mii, ready) }
        // The menu sounds render from the game's own sound archive; start now so the first one is ready.
        KartPadUISounds.warm(context)
    }
}
