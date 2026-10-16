package dev.kartpad.android.screens

import android.content.Context
import android.hardware.input.InputManager
import android.os.Build
import android.os.SystemClock
import android.view.InputDevice
import kotlin.math.abs
import kotlin.math.max

// The controllers driving KartPad's screens (the iPhone's KartPadScreensPads.inc.mm): every connected
// controller counts. The D-pad or left stick moves, A and B confirm and go back (on Nintendo's own pads
// with Nintendo button layout, A on the right), X and Y, LB and RB, and Start. Directions repeat while
// held; buttons already down when a screen opens aren't presses for it. Read once a frame while the
// screens are open, from the game thread's snapshot.
object KartPadPads {
    /** The SDL pads connected now, in instance order. */
    var devices: List<KPPadDevice> = emptyList()
        private set
    /** The pads that disconnected at the last refresh (the reconnect card names the one that left). */
    var gone: List<KPPadDevice> = emptyList()
        private set
    /** The one used last (the hints follow it). */
    var lastActive: KPPadDevice? = null
        private set
    /** Controller buttons (KartPadControllerMapping) and Nintendo button layout, set from the settings. */
    var mapping: IntArray? = null
    // Off on Android until checked on real pads (see KartPadActivity.applyControllerMapping).
    var nintendoLayout = false
    /** The touch controls play as Player 1 while no controller does. */
    var touchControlsPlay = true

    var overlay: KPOverlay? = null
    val touching: Boolean get() = overlay?.touching ?: true

    private const val DirectionBits = (1 shl 0) or (1 shl 1) or (1 shl 2) or (1 shl 3)  // KPPad Up…Right
    private var held = 0
    private var owned = false
    private var quiet = false
    private var repeatAt = Long.MAX_VALUE
    private var turnedAt = 0L
    private var batteryAt = 0L
    private val batteries = HashMap<String, Pair<Int, Boolean>>()

    fun faceFor(device: KPPadDevice): KPPadFace = device.face(mapping, nintendoLayout)

    /** The controller the screens' hints are for: the last one used, else a connected pad. */
    fun hintDevice(): KPPadDevice? = lastActive ?: devices.firstOrNull { !it.virtual } ?: devices.firstOrNull()

    /** The pad someone joins with ("Press A to join"): the last pad used, else any connected one. */
    fun joinDevice(): KPPadDevice? = lastActive?.takeIf { !it.isKeyboard && !it.isTouch } ?: devices.firstOrNull()

    fun device(instance: Int): KPPadDevice? = devices.firstOrNull { it.instance == instance }

    /** Who plays as whom: each player's controller, or the touch screen for Player 1 while no controller is. */
    fun players(): Array<KPPadDevice?> {
        val out = arrayOfNulls<KPPadDevice>(4)
        for (device in devices) if (device.slot in 0..3 && out[device.slot] == null) out[device.slot] = device
        if (out[0] == null && touchControlsPlay) out[0] = KPPadDevice.touchScreen(0)
        return out
    }

    /** Reads the snapshot without acting on it (HOME's strip as it opens, the roster after a change). */
    fun refresh(context: Context? = null) {
        val previous = devices.associateBy { it.instance }
        val read = KartPadHostScreens.readPads()
        for (device in read) {
            previous[device.instance]?.let {
                device.lastInput = it.lastInput
                device.battery = it.battery
                device.charging = it.charging
            }
            batteries[device.profileKey]?.let { (level, charging) ->
                device.battery = level
                device.charging = charging
            }
        }
        gone = devices.filter { old -> read.none { it.instance == old.instance } }
        devices = read
        lastActive = lastActive?.let { last -> read.firstOrNull { it.instance == last.instance } }
        if (context != null) readBatteries(context)
    }

    // SDL's Android driver reports no battery; Android's own InputDevice does from API 31, matched to
    // the SDL pad by vendor, product and name. Once a second is plenty.
    private fun readBatteries(context: Context) {
        val now = SystemClock.uptimeMillis()
        if (Build.VERSION.SDK_INT < 31 || now - batteryAt < 1000) return
        batteryAt = now
        val input = context.getSystemService(InputManager::class.java) ?: return
        for (id in input.inputDeviceIds) {
            val device = input.getInputDevice(id) ?: continue
            if (device.sources and InputDevice.SOURCE_GAMEPAD != InputDevice.SOURCE_GAMEPAD &&
                device.sources and InputDevice.SOURCE_JOYSTICK != InputDevice.SOURCE_JOYSTICK) continue
            val state = device.batteryState
            if (!state.isPresent) continue
            val level = if (state.capacity.isNaN()) -1 else (state.capacity * 100).toInt()
            val charging = state.status == android.hardware.BatteryState.STATUS_CHARGING
            for (pad in devices) {
                if (pad.vendor != device.vendorId || pad.product != device.productId) continue
                if (pad.systemName.isNotEmpty() && device.name != null && !device.name.contains(pad.systemName) &&
                    !pad.systemName.contains(device.name)) continue
                pad.battery = level
                pad.charging = charging
                batteries[pad.profileKey] = level to charging
            }
        }
    }

    /** The screens' buttons a pad holds now, as KPPad bits, and the ones it tapped since the last read. */
    private fun menuBits(device: KPPadDevice, buttons: Long): Int {
        val face = faceFor(device)
        var bits = 0
        fun down(button: Int) = (buttons shr button) and 1L != 0L
        fun set(pad: KPPad, on: Boolean) { if (on) bits = bits or (1 shl pad.ordinal) }
        // The stick moves along its stronger axis once past half way (SDL's y runs down).
        val x = device.axes[SDLAxis.LeftX]
        val y = device.axes[SDLAxis.LeftY]
        val horizontal = abs(x) >= abs(y)
        val tilted = max(abs(x), abs(y)) > .5f && buttons == device.buttons
        set(KPPad.Up, down(SDLButton.DpadUp) || (tilted && !horizontal && y < 0))
        set(KPPad.Down, down(SDLButton.DpadDown) || (tilted && !horizontal && y > 0))
        set(KPPad.Left, down(SDLButton.DpadLeft) || (tilted && horizontal && x < 0))
        set(KPPad.Right, down(SDLButton.DpadRight) || (tilted && horizontal && x > 0))
        set(KPPad.Confirm, down(face.a))
        set(KPPad.Back, down(face.b))
        set(KPPad.Undo, face.x != face.a && face.x != face.b && down(face.x))
        set(KPPad.Redo, face.y != face.a && face.y != face.b && down(face.y))
        set(KPPad.PreviousTab, down(SDLButton.LeftShoulder))
        set(KPPad.NextTab, down(SDLButton.RightShoulder))
        set(KPPad.Start, down(SDLButton.Start))
        return bits
    }

    /** The screens closed: the next open starts quiet again. */
    fun release() {
        owned = false
        held = 0
        repeatAt = Long.MAX_VALUE
    }

    /** Once a frame while the screens are open. */
    fun poll(context: Context, now: Long) {
        val overlay = overlay ?: return
        refresh(context)
        var holding = 0
        var tapped = 0
        var anyHeld = false
        var turn = 0f
        var home = false
        val screen = overlay.top
        for (device in devices) {
            val mine = menuBits(device, device.buttons)
            val taps = menuBits(device, device.pressed) and mine.inv()
            holding = holding or mine
            tapped = tapped or taps
            anyHeld = anyHeld || device.buttons != 0L || max(abs(device.axes[SDLAxis.LeftX]), abs(device.axes[SDLAxis.LeftY])) > .5f
            if (abs(device.axes[SDLAxis.RightX]) > abs(turn)) turn = device.axes[SDLAxis.RightX]
            if (device.pressed != 0L) {
                device.lastInput = now
                if (lastActive?.instance != device.instance) {
                    lastActive = device
                    overlay.invalidate()
                }
                if (owned) screen?.padActivity(device, device.pressed)
                if (owned && screen?.listening == true) screen.rawPress(device, device.pressed)
                if ((device.pressed shr SDLButton.Guide) and 1L != 0L) home = true
            }
        }
        if (screen == null) return
        val listening = screen.listening
        // Buttons already down when a screen opens aren't presses for it, and don't repeat.
        if (!owned) {
            owned = true
            quiet = anyHeld
            held = holding
            repeatAt = Long.MAX_VALUE
            return
        }
        if (quiet && !anyHeld) quiet = false
        val acting = !quiet && !listening
        val pressed = if (acting) (holding and held.inv()) or tapped else 0
        val released = if (acting) (held and holding.inv()) or (tapped and holding.inv()) else 0
        var fire = pressed
        if (pressed and DirectionBits != 0) {
            repeatAt = now + 400
        } else if (acting && holding and DirectionBits != 0 && now >= repeatAt) {
            fire = fire or (holding and DirectionBits)
            repeatAt = now + 110
        }
        held = holding
        // Past a dead zone, scaled from there to full tilt.
        val past = ((abs(turn) - .25f) / .75f).coerceIn(0f, 1f)
        if (acting && past > 0) screen.turn(if (turn < 0) -past else past, (now - turnedAt) / 1000f)
        turnedAt = now
        if (home && acting) {
            overlay.closeAll()
            return
        }
        for (button in KPPad.values()) {
            val bit = 1 shl button.ordinal
            if (fire and bit != 0) {
                overlay.padPress(button, true)
                if (overlay.top == null) return
            }
            if (button == KPPad.Confirm && released and bit != 0) overlay.padPress(KPPad.Confirm, false)
        }
    }
}
