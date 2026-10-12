# HOME and controllers on iPhone and iPad

KartPad for iPhone and iPad has the Mac's own screens over the game: HOME, Controllers,
Settings, Time Trial Ghosts and the card that waits for a disconnected player
([the Mac's design](macos-home-and-controllers.md)). They work by touch and with any
controller, and the game holds still while one is open.

## Opening HOME

- **Touch:** tap **•••** (top corner). Tap it again, or **Resume**, to go back to the game.
- **Controller:** hold **Menu** (Options, +) for a second. A short press is still the game's
  pause. Where iOS lets a controller's HOME button through, it opens HOME at once.
- While the game is still starting, HOME says so and opens once the game is up.

Closing a screen hands the controllers back once the buttons that closed it are let go,
so the press doesn't also act in the game.

## HOME

Resume, **Miis**, **Controllers**, the volume, the game switch (Mario Kart Wii or Retro
Rewind) and **Settings** (the gear). The players' strip shows who plays with which
controller; the touch screen is Player 1 while no controller is. A waiting change shows
**Restart to Apply**: iOS can't restart an app, so the card says to close KartPad in the app
switcher and open it again. There is no Quit or full-screen button on iPhone and iPad.

## Settings

| Category | Rows |
| --- | --- |
| Picture | Picture quality; Aspect ratio; Show frame rate; Frame rate size; App icon |
| Sound | Sound; Volume; Adjust music and game sounds; Music; Game sounds; HOME and Mii sounds |
| Controls | Controllers; Controller buttons; Vibration; Nintendo button layout; Touch controls; Motion steering; Shake to trick |
| Game | Start KartPad with; Miis; Time Trial ghosts; Saves; Multiplayer; Retro Rewind files; KartPad menu |
| Advanced | Mario Kart Wii files; Private Wii server; Wii Remote + Nunchuk; Report a problem (and Test native crash in diagnostic builds) |

Picture settings apply at once. **Touch controls** closes the screens and opens the touch
layout editor over the game. Rows that open one of iOS's own sheets (Saves, Multiplayer,
Motion steering and the others) need touch; the game stays held underneath.

## Controllers

- Cards for the four players, each with its Mii, a live drawing of the controller and its
  battery. Press a button and its card bounces. **X** (Find) buzzes a controller and flashes
  its light.
- **Change controller** on a card, or A on an empty one, waits for A on the controller that
  should be that player; **Player Order** has everyone press A in turn. Other players swap so
  each keeps one controller. **Stop playing** takes a controller out until it's given a player
  again or reconnects.
- DualShock 4 and DualSense lights glow in the player's colour (or their Mii's favourite colour).
- **Connect** explains pairing: put the controller in pairing mode, then choose it in
  Settings › Bluetooth. Apps can't pair controllers on iOS. The page closes once a new
  controller shows up.
- **Nintendo button layout** (on by default): Switch Pro Controllers and Joy-Cons play with the
  letters printed on them, A on the right, B at the bottom, in races and in KartPad's screens.
  KartPad reads the layout from the button symbols iOS reports.
- **Vibration**: the game's rumble on the player's controller, or on the iPhone itself for a
  player on the touch screen.

If a player's controller disconnects mid-game, the game waits on a card until it's back, or
another controller takes that player with A, or **Continue** carries on without. Online the race
can't wait, so there it's only a toast.

## Miis

HOME › Miis opens the shared Miis screen ([the Mii editor](mii-builder.md)) full screen, as
before. With a controller, a focus ring moves with the D-pad; A presses, B goes back, LB and RB
change category, X and Y undo and redo, Start saves and the right stick turns the Mii. Names are
typed on a pad keyboard, and leaving with unsaved changes asks on a card of KartPad's own, since
iOS's keyboard and alerts don't take a controller. A touch takes the ring away.

## Not on iPhone and iPad

Phones as controllers, Discord status, Wii Remote pairing, pairing other controllers inside
KartPad, the local updater, Retro Rewind's in-app download (its own installer stays), first-run
Setup, restarting behind the curtain, the background pause, full screen and the Mac-only
settings rows (VSync, the pointer, the notch area).

## For developers

The screens are the Mac's files (`apple/macos/KartPad*Screen.inc.mm`, the overlay kit, glyphs,
hints and controller drawings), built for iOS by `apple/ios/KartPadScreens.mm`:

- `KartPadAppKitShim.h` says their AppKit in UIKit; `KartPadAppKitShimNames.h` renames the AppKit
  methods that could meet UIKit's own. Window coordinates keep AppKit's sense (y up) wherever a
  screen converts to the window.
- `KartPadScreensPlatform.inc.mm` stands in for the Mac shell; `KartPadScreensRoster.inc.mm` is the
  controller roster on GameController, with buttons in SDL's gamepad numbering.
- Where the platforms differ, the Mac files have `#if TARGET_OS_OSX … #else #include
  "../ios/…" #endif` blocks, so the Mac compiles exactly what it did. `tests/test_ios_home_contract.py`
  checks that with `unifdef`.
- `KartPadScreensGlue.inc.mm` takes touches, hosts the Miis screen, drives vibration and
  implements `KartPadScreens.h` for `KartPadRuntimeOverlayHost.mm`, which holds the game in
  `runScreensHold` and answers `KartPadScreensHost`.
- `KartPadScreensPads.inc.mm` reads the controllers for the screens; `KartPadMiiGamepadIOS.inc.mm`
  drives the Mii screens.
- Who plays as whom is `KartPadPhysicalControllers` with `apple/mobile/KartPadControllerSlots.h`
  (tested by `runtime/tests/kartpad_controller_slots_tests.cpp`).
- The iOS runtime supplies `KartPadGameStarting`, `Network_HLE_HasOpenSockets` and the
  `KartPadMobileSetRumble` hook.

**Automated checks** (Simulator builds only): launch with `SIMCTL_CHILD_KARTPAD_QA_DIR=QA` and
append commands to `Documents/QA/commands.txt` in the app's data container; results go to
`log.txt`. The commands are listed at the top of `apple/ios/KartPadScreensQA.inc.mm`
(`home`, `screen`, `tap`, `hit`, `focus`, `pad`, `state`, `controls`, `roster`, `presented`,
`dismiss`, `drop`, `restart`, `close`, `back`, `shot`).
