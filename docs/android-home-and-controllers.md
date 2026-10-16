# HOME and controllers on Android

KartPad for Android has the Mac's and iPhone's screens over the game: HOME, Controllers,
Settings, Time Trial Ghosts, the Miis screen and the Mii editor, and the card that waits for a
disconnected player ([the Mac's design](macos-home-and-controllers.md), [iPhone and
iPad](ios-home-and-controllers.md)). They work by touch, with any controller Android connects, and
with a keyboard or TV remote, and the game holds still while one is open.

## Opening HOME

- **Touch:** tap **⋯** (top corner). **Resume** or B goes back to the game.
- **Controller:** press HOME (the Xbox button, the PS button, HOME) where Android passes it on, or hold
  **Start** (Menu, Options, +) for a second. A short press of Start is still the game's pause.
- While the game is still starting, HOME opens over the starting screen and the game holds once it's up.

Closing a screen hands the controllers back with whatever is still held quieted until it's let go,
so the press that closed it doesn't also act in the game. Online the race can't wait: the screens
have the controllers, and the game carries on underneath.

## HOME

Resume, **Miis**, **Controllers**, the volume, the game switch (Mario Kart Wii or Retro Rewind) and
**Settings** (the gear). The players' strip shows who plays with which controller; the touch screen is
Player 1 while no controller is. A waiting change shows **Restart to Apply**, which restarts KartPad
into the same game; the game switch restarts it into the other. There is no Quit or full-screen button.

## Settings

| Category | Rows |
| --- | --- |
| Picture | Picture quality; Aspect ratio; Show frame rate; Frame rate size; App icon |
| Sound | Sound; Volume; Adjust music and game sounds; Music; Game sounds; HOME and Mii sounds |
| Controls | Controllers; Controller buttons; Vibration; Nintendo button layout; Auto-accelerate; Touch controls; Motion steering; Shake to trick |
| Game | Start KartPad with; Miis; Time Trial ghosts; Saves; Multiplayer; Retro Rewind files; KartPad menu |
| Advanced | Mario Kart Wii files; Private Wii server; Wii Remote + Nunchuk; Console identity; Graphics diagnostics; Report a problem (and Test native crash in diagnostic builds) |

Picture and sound settings apply at once. Rows that open one of Android's own sheets (Touch controls,
Motion steering, Saves, Multiplayer and the others) need touch; the game stays held underneath.
**Nintendo button layout** is off by default on Android until it has been checked with real
Nintendo controllers.

## Controllers

Four player cards with each player's Mii, a live drawing of the controller and its battery (where
Android reports one). Press a button and its card bounces; **X** (Find) buzzes a controller and flashes
its light. **Change controller** or A on an empty card waits for A on the controller that should be
that player; **Player Order** has everyone press A in turn; **Stop playing** takes a controller out
until it's given a player again. **Controller buttons** sets which button does what, for every
controller. **Connect** explains pairing and opens Android's Bluetooth settings.

If a player's controller disconnects mid-game, the game waits on a card until it's back, or another
controller takes that player with A, or **Continue** carries on without. Online it's only a toast.

## Miis

HOME › Miis opens the Miis screen and the editor ([the Mii editor](mii-builder.md)). With a controller,
the focus ring moves with the D-pad; A presses, B goes back, LB and RB change category, X and Y undo
and redo, Start saves and the right stick turns the Mii. Names are typed on a pad keyboard with a
controller and on Android's keyboard by touch. Changes wait for a restart, as on Mac and iPhone.

## Not on Android

Phones as controllers, Discord status, Wii Remote pairing, pairing controllers inside KartPad,
first-run Setup changes, joining with any button during the game, and phone vibration for a player on
the touch screen.

## For developers

- `android/app/src/main/java/dev/kartpad/android/screens/` holds the screens and their kit: a port of
  the Mac's overlay kit (`apple/macos/KartPadOverlay.inc.mm`), style, glyphs, hints and controller
  drawings to `android.graphics`, laid out on the same 1280×720 design canvas. The host view is never
  focusable, so SDL's surface keeps the gamepads' key events.
- `runtime/src/android/host_screens.cpp` is the game thread's side: the runtime calls
  `KartPadAndroidServiceHostScreens` from both event-pump paths (`aurora_events.h`). While a screen is
  open it holds the game there, pumping events (so the Android lifecycle, the surface and hotplug keep
  working), and resyncs the retrace clock afterwards; aurora's pads are host-owned meanwhile
  (`set_standard_gamepads_host_owned`). It snapshots the SDL pads for the screens and wakes the main
  thread through an event fd. The fixture app uses `android/app/src/main/cpp/host_screens_fixture.cpp`.
- Restarting goes through the game chooser, which waits for the old process (`EXTRA_WAIT_PID`).
- `tests/test_android_home_contract.py` checks the hold hook, the focus rule, key routing and the
  audits.

**Automated checks** (debug builds only): create `files/QA` in the app's data and append commands to
`files/QA/commands.txt` (`adb shell run-as dev.kartpad.android …`); results go to `log.txt`. Only lines
added after KartPad starts run, so an earlier run's commands don't replay at launch. The
commands are listed at the top of `KartPadScreensQA.kt` (`home`, `screen`, `tap`, `hit`, `focus`, `pad`,
`hold`, `state`, `controls`, `roster`, `close`, `back`, `shot`, `drop`, `restart`); `pad` presses a
virtual controller through the same native path as a real one.
