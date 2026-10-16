package dev.kartpad.android.screens

import java.nio.ByteBuffer
import java.nio.ByteOrder

// The controllers KartPad's screens know, as players see them (after the Mac's
// apple/macos/KartPadControllerRoster.inc.mm): what kind each is, who it plays as, what it's
// pressing. Read from the game thread's snapshot (KartPadHostScreens.nativeReadPads), so a pad's
// instance is the SDL instance aurora assigns to players.

/** The screens' buttons: the D-pad or left stick, A and B (the game's confirm and back), X and Y, LB and RB, Start. */
enum class KPPad { Up, Down, Left, Right, Confirm, Back, Undo, Redo, PreviousTab, NextTab, Start }

enum class KPPadFamily { Touch, Keyboard, Xbox, PlayStation, Switch, JoyCon, WiiRemote, GameCube, Generic }

/** SDL3's gamepad numbering (SDL_GamepadButton), as the snapshot's bits and the drawings use it. */
object SDLButton {
    const val South = 0; const val East = 1; const val West = 2; const val North = 3
    const val Back = 4; const val Guide = 5; const val Start = 6; const val LeftStick = 7; const val RightStick = 8
    const val LeftShoulder = 9; const val RightShoulder = 10
    const val DpadUp = 11; const val DpadDown = 12; const val DpadLeft = 13; const val DpadRight = 14
    const val Misc1 = 15; const val Touchpad = 20
    const val Count = 26
}

/** SDL_GamepadAxis order. */
object SDLAxis {
    const val LeftX = 0; const val LeftY = 1; const val RightX = 2; const val RightY = 3
    const val LeftTrigger = 4; const val RightTrigger = 5
    const val Count = 6
}

/** SDL_GamepadType. */
object SDLType {
    const val Unknown = 0; const val Standard = 1; const val Xbox360 = 2; const val XboxOne = 3
    const val PS3 = 4; const val PS4 = 5; const val PS5 = 6; const val SwitchPro = 7
    const val JoyConLeft = 8; const val JoyConRight = 9; const val JoyConPair = 10; const val GameCube = 11
}

/** SDL_GamepadButtonLabel. */
object SDLLabel {
    const val Unknown = 0; const val A = 1; const val B = 2; const val X = 3; const val Y = 4
    const val Cross = 5; const val Circle = 6; const val Square = 7; const val Triangle = 8
}

/** The buttons a pad confirms, goes back, and does X and Y with (SDLButton numbers). */
data class KPPadFace(val a: Int, val b: Int, val x: Int, val y: Int)

class KPPadDevice(
    val instance: Int,
    var slot: Int,             // 0–3, -1 when not playing
    var buttons: Long,         // SDL buttons held (bits)
    var pressed: Long,         // pressed since the last read, even if let go since
    val axes: FloatArray,      // -1…1 (triggers 0…1), SDLAxis order
    val vendor: Int,
    val product: Int,
    val type: Int,
    val labels: IntArray,      // SDLLabel of the south, east, west and north buttons
    val canRumble: Boolean,
    val hasLight: Boolean,
    val virtual: Boolean,      // the QA hook's pad
    val guid: String,
    val systemName: String,
    familyOverride: KPPadFamily? = null,
) {
    var battery = -1           // percent, -1 unknown (Android's own InputDevice battery)
    var charging = false
    var lastInput = 0L         // uptime millis of the last press
    val family: KPPadFamily = familyOverride ?: familyFor(systemName, vendor, product, type)
    val isTouch get() = family == KPPadFamily.Touch
    val isKeyboard get() = family == KPPadFamily.Keyboard

    /** What a person calls it. Model names are only words; nothing borrows a maker's logo. */
    val name: String get() = friendlyName(systemName, family, type, vendor)

    /** Stays the same while the controller reconnects under a new instance. */
    val profileKey: String get() = "$guid:$systemName"

    companion object {
        fun familyFor(name: String, vendor: Int, product: Int, type: Int): KPPadFamily {
            if (name.startsWith("Nintendo Wii Remote")) return KPPadFamily.WiiRemote
            if (name.contains("GameCube") || name.contains("Gamecube")) return KPPadFamily.GameCube
            if (vendor == 0x057e && (product == 0x0337 || product == 0x2073)) return KPPadFamily.GameCube
            return when (type) {
                SDLType.Xbox360, SDLType.XboxOne -> KPPadFamily.Xbox
                SDLType.PS3, SDLType.PS4, SDLType.PS5 -> KPPadFamily.PlayStation
                SDLType.SwitchPro -> KPPadFamily.Switch
                SDLType.JoyConLeft, SDLType.JoyConRight, SDLType.JoyConPair -> KPPadFamily.JoyCon
                SDLType.GameCube -> KPPadFamily.GameCube
                else -> KPPadFamily.Generic
            }
        }

        fun friendlyName(name: String, family: KPPadFamily, type: Int, vendor: Int): String {
            val lower = name.lowercase()
            return when (family) {
                KPPadFamily.Touch -> "Touch screen"
                KPPadFamily.Keyboard -> "Keyboard"
                KPPadFamily.Xbox -> "Xbox controller"
                KPPadFamily.PlayStation -> when {
                    lower.contains("dualsense") -> if (lower.contains("edge")) "DualSense Edge" else "DualSense"
                    lower.contains("dualshock") || type == SDLType.PS4 -> "DualShock 4"
                    else -> "PlayStation controller"
                }
                KPPadFamily.Switch -> "Pro Controller"
                KPPadFamily.JoyCon -> when (type) {
                    SDLType.JoyConLeft -> "Joy‑Con (L)"
                    SDLType.JoyConRight -> "Joy‑Con (R)"
                    else -> "Joy‑Con pair"
                }
                KPPadFamily.WiiRemote -> when {
                    name.contains("Nunchuk") -> "Wii Remote + Nunchuk"
                    name.contains("Classic") -> "Wii Remote + Classic"
                    name.contains("Wii U Pro") -> "Wii U Pro Controller"
                    else -> "Wii Remote"
                }
                KPPadFamily.GameCube -> "GameCube controller"
                KPPadFamily.Generic -> when {
                    vendor == 0x2dc8 -> "8BitDo controller"
                    name.isNotEmpty() && name.length <= 24 && name != "Controller" -> name
                    else -> "Controller"
                }
            }
        }

        /** The button that opens HOME, as the controller in hand shows it. */
        fun homeButtonName(family: KPPadFamily): String = when (family) {
            KPPadFamily.Keyboard -> "esc"
            KPPadFamily.Xbox -> "the Xbox button"
            KPPadFamily.PlayStation -> "the PS button"
            KPPadFamily.GameCube -> "Start"
            else -> "HOME"
        }

        /** A touch-screen entry for Player 1 while no controller is (it can't change player or stop). */
        fun touchScreen(slot: Int) = KPPadDevice(-1, slot, 0, 0, FloatArray(SDLAxis.Count), 0, 0, 0, IntArray(4),
            false, false, false, "", "Touch screen", KPPadFamily.Touch)

        /** The keyboard (a hardware one, or a TV remote) driving the screens; it plays as nobody here. */
        fun keyboard() = KPPadDevice(-2, -1, 0, 0, FloatArray(SDLAxis.Count), 0, 0, 0, IntArray(4),
            false, false, false, "", "Keyboard", KPPadFamily.Keyboard)

        internal const val RecordBytes = 112

        /** Parses the snapshot records kartpad::android::screens::PadRecord lays out. */
        fun parse(buffer: ByteBuffer, count: Int): List<KPPadDevice> {
            buffer.order(ByteOrder.LITTLE_ENDIAN)
            val out = ArrayList<KPPadDevice>(count)
            for (index in 0 until count) {
                val at = index * RecordBytes
                val axes = FloatArray(SDLAxis.Count) { axis ->
                    val raw = buffer.getShort(at + 16 + axis * 2).toFloat()
                    (raw / if (raw < 0) 32768f else 32767f).coerceIn(-1f, 1f)
                }
                val labels = IntArray(4) { buffer.get(at + 36 + it).toInt() and 0xff }
                val flags = buffer.getInt(at + 40)
                val guid = StringBuilder()
                for (byte in 0 until 16) guid.append("%02x".format(buffer.get(at + 44 + byte).toInt() and 0xff))
                val nameBytes = ByteArray(52)
                for (byte in 0 until 52) nameBytes[byte] = buffer.get(at + 60 + byte)
                val end = nameBytes.indexOf(0).let { if (it < 0) 52 else it }
                out += KPPadDevice(
                    instance = buffer.getInt(at),
                    slot = buffer.getInt(at + 4).let { if (it in 0..3) it else -1 },
                    buttons = buffer.getInt(at + 8).toLong() and 0xffffffffL,
                    pressed = buffer.getInt(at + 12).toLong() and 0xffffffffL,
                    axes = axes,
                    vendor = buffer.getShort(at + 28).toInt() and 0xffff,
                    product = buffer.getShort(at + 30).toInt() and 0xffff,
                    type = buffer.getInt(at + 32),
                    labels = labels,
                    canRumble = flags and 1 != 0,
                    hasLight = flags and 2 != 0,
                    virtual = flags and 4 != 0,
                    guid = guid.toString(),
                    systemName = String(nameBytes, 0, end, Charsets.UTF_8),
                )
            }
            return out
        }
    }

    fun held(button: Int) = (buttons shr button) and 1L != 0L

    /**
     * The buttons this pad confirms, goes back and does X and Y with: the game's A, B, X and Y as
     * Controller buttons maps them (mapping[game] = physical, 0 south, 1 east, 2 west, 3 north), on
     * Nintendo's labelled layout for a Switch Pro, Joy-Cons in the grip and a Wii U Pro when
     * nintendoLayout is on and the mapping is the default (A on the right, B at the bottom).
     */
    fun face(mapping: IntArray?, nintendoLayout: Boolean): KPPadFace {
        if (family == KPPadFamily.WiiRemote && !systemName.contains("Wii U Pro"))
            return KPPadFace(SDLButton.East, SDLButton.South, SDLButton.West, SDLButton.North)
        val labelled = nintendoLayout && ((type == SDLType.SwitchPro && product != 0x2073) || type == SDLType.JoyConPair ||
            systemName.contains("Wii U Pro Controller"))
        val standard = if (labelled) KPPadFace(SDLButton.East, SDLButton.South, SDLButton.North, SDLButton.West)
            else KPPadFace(SDLButton.South, SDLButton.East, SDLButton.West, SDLButton.North)
        if (mapping == null || mapping.size < 4 || mapping.withIndex().all { (game, physical) -> game == physical }) return standard
        fun native(physical: Int) = if (physical in 0..3) physical else -1
        val a = native(mapping[0]); val b = native(mapping[1])
        if (a < 0 || b < 0 || a == b) return standard
        return KPPadFace(a, b, native(mapping[2]).takeIf { it >= 0 } ?: standard.x, native(mapping[3]).takeIf { it >= 0 } ?: standard.y)
    }

    /** What its button for a screen input is called: "A", "Cross", "LB", "+"; null when it has none. */
    fun label(button: KPPad, face: KPPadFace): String? {
        if (isKeyboard) return when (button) {
            KPPad.Confirm -> "enter"; KPPad.Back -> "esc"; KPPad.PreviousTab, KPPad.NextTab -> "tab"
            KPPad.Left -> "Left"; KPPad.Right -> "Right"; else -> null
        }
        val nintendo = family == KPPadFamily.Switch || family == KPPadFamily.JoyCon
        fun faceLabel(native: Int): String? = when (native) {
            in 0..3 -> when (labels[native]) {
                SDLLabel.A -> "A"; SDLLabel.B -> "B"; SDLLabel.X -> "X"; SDLLabel.Y -> "Y"
                SDLLabel.Cross -> "Cross"; SDLLabel.Circle -> "Circle"; SDLLabel.Square -> "Square"; SDLLabel.Triangle -> "Triangle"
                else -> arrayOf("A", "B", "X", "Y")[native]
            }
            else -> null
        }
        fun other(native: Int) = if (native == face.a || native == face.b) null else faceLabel(native)
        return when (button) {
            KPPad.Confirm -> faceLabel(face.a)
            KPPad.Back -> faceLabel(face.b)
            KPPad.Undo -> other(face.x)
            KPPad.Redo -> other(face.y)
            KPPad.PreviousTab -> if (family == KPPadFamily.WiiRemote) null else if (nintendo) "L" else if (family == KPPadFamily.PlayStation) "L1" else "LB"
            KPPad.NextTab -> if (family == KPPadFamily.WiiRemote) null else if (nintendo) "R" else if (family == KPPadFamily.PlayStation) "R1" else "RB"
            KPPad.Start -> when {
                family == KPPadFamily.WiiRemote || nintendo -> "+"
                family == KPPadFamily.GameCube -> "Start"
                family == KPPadFamily.PlayStation -> "Options"
                family == KPPadFamily.Xbox -> "Menu"
                else -> "Start"
            }
            KPPad.Left -> "Left"
            KPPad.Right -> "Right"
            else -> null
        }
    }
}
