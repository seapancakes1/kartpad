# KartPad on Mac: HOME, Controllers and Settings

KartPad's own screens on Mac work the way a console's do: they open inside the
game window, look like the Mii editor (silver buttons, pinstripes, Wii-blue
focus, the game's own menu sounds) and can be used with only a controller. The
mouse and keyboard work too: click a button, or use the arrows, Return and esc.
They scale with the window, from a small window at a desk to full screen on a TV.

## For players

**HOME.** Press HOME on a controller (the Xbox button, the PS button, HOME on a
Pro Controller, Joy-Con or Wii Remote) or **esc** on the keyboard. Controllers
without a HOME button hold **View + Menu** for a second. The game holds still
underneath (online the race keeps going, and HOME says so). HOME has:

- **Resume**, and HOME or B again closes it.
- **Switch game**: Mario Kart Wii ⇄ Retro Rewind. KartPad restarts to switch,
  but its window shows a "Starting Retro Rewind" card the whole time, so it
  doesn't look like the app closed.
- **Miis** and **Controllers**.
- **Volume** on a row of its own: left and right change it, A mutes.
- Along the top: **Full Screen** (or **Window**), the ⚙ button for
  **Settings**, **Quit**, and **Restart to apply** when a change needs one
  (switching games, Mii changes, new game files, display settings).
- **Players** along the bottom: each player's colour, Mii, controller and
  battery. X on a player makes their controller buzz and flash; A opens
  Controllers on them, and on an empty player goes straight to "Press Ⓐ on the
  controller for this player".

**Controllers.** Four player cards in the game's player colours (1 yellow,
2 blue, 3 red, 4 green), each showing its Mii and a drawing of the controller
that lights up as you press. Pressing anything on a controller bounces its card,
so you can tell which one is yours.

- A controller that isn't playing joins with **A** here, and **during the game
  with any button**: it takes the first free player (or the keyboard's, while
  the keyboard just follows free players), buzzes, lights up in that player's
  colour and says so. It joins as the button is let go, so that press doesn't
  also act in the game. One taken out with **Stop playing** stays out until
  it's given a player again. Every connected controller can always drive
  KartPad's own screens and open HOME, playing or not.
- Players change controllers by pressing on the one they want, as on a console:
  - **Change controller** (A on a card, or A on an empty card): "Press Ⓐ on
    the controller for Player 2". Whichever controller presses A takes that
    player, and the one already there swaps to where it came from. B cancels,
    and **Use Keyboard** puts the keyboard there.
  - **Player Order**: everyone presses A in turn; the first press is Player 1,
    the next Player 2, and so on. It finishes by itself once every controller
    has pressed (or press Start); controllers that didn't press stop playing.
    B cancels and puts everyone back.
- **Y** makes it buzz and flash its light (in the player's colour on
  controllers with a colour light).
- A on a card: Change controller, Set up buttons, Choose a Mii, Find it, Stop
  playing. A controller in the Not playing tray offers each player directly.
- **Connect** explains pairing mode for each kind, then KartPad finds the
  controller and pairs it right there (PlayStation, Pro Controller, Joy-Con,
  most others, and Wii Remotes). Newer Xbox controllers use Bluetooth LE, which
  KartPad can't pair, so Xbox and Another controller also offer the Mac's
  Bluetooth settings, which KartPad watches. When the new controller turns up
  it celebrates and gives it the first free player. The search stops after
  about a minute, since it slows other Bluetooth while it runs, and automated
  runs (`KARTPAD_BACKGROUND=1`) don't search.
- **The keyboard** is a controller too: by default it plays as the first
  player without a controller, so a pad on Player 1 now works alongside it.
  Settings → Controls → Keyboard plays as pins it to a player.
- Miis on controllers are labels that help players tell them apart. Racers
  and licenses are still picked in the game, and the game's Register
  Controllers screen works as before.

**Button setup.** The game's twelve actions in a list with the buttons they're
on. A changes one ("Press a button for Accelerate"), X adds a second button,
Reset puts them back. Changes save by themselves.

**Settings.** Picture, Sound, Controls, Game and Advanced, as big rows: A flips
a switch or opens a row, left and right step a choice or level, LB and RB change
category. Left from a switch (or a choice already at its first step) goes back
to the categories, and so does B before it leaves Settings.

**The game is silent** while one of these screens holds it, so a setting that
briefly lets the game run to apply (picture quality, volume) doesn't play a blip
of it. KartPad's own menu sounds still play.
Every setting from before is here, under plain names. Advanced keeps the
technical tools (private server, controller compatibility, diagnostics, the
classic Settings window).

**Miis** open inside the game window, and so does the Mii editor.

**First launch.** A short guided setup a controller can finish: KartPad looks
for your game files in Downloads, Desktop, Documents and connected drives (your
Mac may ask permission), or you choose the folder; then Retro Rewind (found on
the Mac, chosen, or downloaded where this KartPad can); then "You're ready to
race!". It also comes back if the game files go missing.

**Retro Rewind download.** Where this KartPad's release pins the pack (and no
local auto-updater manages Retro Rewind), Settings → Game → Retro Rewind files
and setup download the exact version, check its size and SHA-256, unpack it
with macOS's own `ditto`, check it as the game does and install it in KartPad's
data folder. It keeps going while you play.

**Discord.** While the Discord app is open on the Mac, your Discord status shows
what you're playing. In Mario Kart Wii that's the course, then the mode and
class ("Luigi Circuit", "Grand Prix · 150cc") during a race, and "In the menus"
otherwise, under WiiCompiled's Discord application. Retro Rewind shows its own
status. Settings → Game → Show on Discord turns it off (`[discord] enabled` in
Config.toml). It only talks to the Discord app on this Mac.

**The first few launches** show a hint, "Press HOME for menus", after your first
button press.

## For developers

### Where things are

| File | What |
|---|---|
| `apple/shared/KartPadStyle.h` | The drawing kit: palettes, button faces, cards, pinstripes, SF Pro Rounded, player colours. Shared with the Mii screens (and iOS) |
| `apple/macos/KartPadOverlay.inc.mm` | The screen host inside the game window, the 1280×720 design canvas, focus navigation, buttons, dialogs, menus, toasts, the key monitor |
| `apple/macos/KartPadHomeScreen.inc.mm` | HOME, the HOME button, hooks the pad reader and runtime call, the hint, connect/battery toasts |
| `apple/macos/KartPadControllerRoster.inc.mm` | Every controller as players see it: kind, player, battery, light colour, Mii, live state; keyboard placement; moves and swaps |
| `apple/macos/KartPadControllersScreen.inc.mm` | Controllers, button setup, Mii picker, Connect a Controller |
| `apple/macos/KartPadControllerArt.inc.mm` | The live controller drawings |
| `apple/macos/KartPadSettingsScreen.inc.mm` | Settings |
| `apple/macos/KartPadMiisScreen.inc.mm` | The shared Miis screen hosted in the game window (the editor embeds itself, `KPMiiEmbedEditor` in `KartPadMiiEditor.inc.mm`) |
| `apple/macos/KartPadCurtain.inc.mm` | Restarts behind a curtain |
| `apple/macos/KartPadSetup.inc.mm` | First-run setup |
| `apple/macos/KartPadRetroDownload.inc.mm` | Retro Rewind download (dual builds) |
| `apple/macos/KartPadDiscordPresence.inc.mm` | What Discord shows during a Mario Kart Wii race (`kartpad/discord/race_presence.h`); the runtime's `DiscordPresence` sends it from its own thread |
| `apple/macos/KartPadQA.inc.mm` | Automated checks (below) |

### How it fits together

- **Inside the game window.** The host view sits in SDL's content view above
  the Metal view (re-raised if SDL re-creates it). Screens draw in design
  points scaled to the window, so text stays sharp; bars and backgrounds run to
  the window's edges while content stays in the centred 16:9 area.
- **Holding the game still.** `KartPadOverlayPauseWanted()` tells the runtime
  a screen is open. `settings_overlay::WaitWhileOverlayOpen` (submodule) then
  holds the game at the VI retrace while still taking Aurora's events and
  calling `KartPadControllersTick`, so controllers can connect and the window
  can change. A settings change lets one frame through to apply. It doesn't
  hold while loading or online.
- **Input.** While a screen is open the game gets nothing: the GameCube pad
  layer was already blocked; the keyboard's Wii Remote path and real Wii
  Remotes now honour `InputBindings::InputBlocked()` too (`kpad.cpp`,
  `wii_remote_input.cpp`). A Wii Remote's HOME never reaches the game (its
  HOME Menu would end the process). Esc is no longer the keyboard's Wii A.
  Confirm acts on release (pads) or key-up (keyboard), so nothing is held when
  the game carries on.
- **Pads** are read by the existing reader in `KartPadMacMiis.inc.mm`, which
  now covers Wii Remotes, uses each pad's own A/B as confirm and back, and
  hands presses to the screen on top. While Controllers waits for a press on a
  particular controller (Change controller, Player Order) it reads each pad's
  A, B and Start itself and sets `KPPadListening`, which keeps the reader quiet.
- **Sound.** `WaitWhileOverlayOpen` holds the game's audio output
  (`AudioBackend::SetHeld`: gain 0, and what queued meanwhile is dropped on
  release) for as long as a screen holds the game, including the frames a
  settings change lets through. The menu sounds use their own AVAudioEngine.
- **Moving the focus** (`KPUINearest`) follows TV menus: only controls clearly
  that way count, left and right stay on their row, one in line beats one off
  to the side, then the nearest wins. Pressing back the opposite way returns to
  where the focus came from, and a run of moves up or down keeps to the column
  it started in. A control with left/right of its own (a slider) takes them
  instead.
- **The mouse** is the Wii pointer: hovering moves the focus once the pointer
  really moves (a pointer resting where a screen opens doesn't take it), and a
  click presses. Screens hit-test their controls directly; `KPUIView` itself
  ignores the mouse, so decoration never takes a click.
- **Launching.** KartPad finishes launching and takes the focus as soon as it
  starts (`KartPadMacShellPrepareGameData`), before the update check and Retro
  Rewind's file checks. Left to the game window, macOS may no longer bring a
  starting app forward.
- **Restarts.** The game can't be torn down in-process, so
  `KPRestartWithCurtain` shows the card, starts the same app with
  `KARTPAD_CURTAIN` (no Dock icon) holding the card in a window at the same
  place, and quits. The curtain reopens KartPad (`open -n`) and fades when the
  new process says its game is up (`KPCurtainDone`), or before any alert.
- **Setup** runs before the runtime in its own window (it has a window
  controller, so it's never taken for the game window), with SDL's gamepad
  subsystem started for it and shut down again before the game, so Aurora sees
  the controllers fresh.

### Automated checks

Run a packaged copy muted and in the background with a command file:

```sh
KARTPAD_MUTED=1 KARTPAD_BACKGROUND=1 KARTPAD_QA_DIR=/path/to/qa \
  KartPad.app/Contents/MacOS/KartPad &
echo "wait 28" >> /path/to/qa/commands.txt   # one command per line, added any time
echo "home" >> /path/to/qa/commands.txt
echo "shot home" >> /path/to/qa/commands.txt # /path/to/qa/home.png
```

Commands: `home`, `close`, `screen settings|controllers|miis|pair-wii`,
`pad up|down|left|right|a|b|x|y|lb|rb|start`, `focus LABEL`, `click LABEL` (a
mouse click on a control: what the window's hit test finds, then the click),
`where` (the focused control), `navmap` (where each direction leads from every
control on the screen), `vpad add|press N BUTTON|release N BUTTON|remove N`
(SDL virtual controllers, to check choosing controllers by pressing and joining),
`move IDENTIFIER|vpadN SLOT` (put a controller on a player, or take it off with
-1, without benching it), `key NAME` (a key the game reads as typed, by SDL's
name: `key return` is A for the keyboard's player; a backgrounded game ignores
controllers but takes these), `shot NAME`,
`shotwindow NAME`, `resize W H`, `appearance light|dark|system`, `frames` (the
presented-frame counter, to check the game holds still), `roster` (every
controller's player and Aurora port), `toast`, `hint`,
`editmii SLOT`, `closewindows`, `setupuse PATH`, `rrtest`, `rrstatus [screen]`,
`restart`, `quit`, `wait SECONDS`. Every Objective-C exception is logged with
its stack in `log.txt`. A `focus` that finds nothing skips the `pad a`, `x` or `y`
after it, so a script can't press whatever happened to be focused instead. Use a portable copy (a `portable.txt` beside the app)
so checks never touch your own settings and saves. Start the program directly
rather than with `open`: a copy opened by LaunchServices asks for its own
permission to read Documents, and `screen pair-wii` (Wii Remote pairing) asks for
Bluetooth.

A run with `KARTPAD_BACKGROUND=1` never takes the background pause and never
takes the focus. Real controllers don't drive its screens while it's in the
background (only the `pad` command does), so a player using the same controller
in another app doesn't steer the run. A portable copy keeps its own saves and
Config.toml, but macOS preferences (`dev.kartpad.app`: the keyboard's player,
the HOME hint count and the like) are shared with any other KartPad on the Mac.
Export them first (`defaults export dev.kartpad.app before.plist`), and put back
anything a run changed.

### Known limits

- Real controllers, HOME/Guide on each kind, the Bluetooth hand-off and
  the Wii Remote flow need checking with physical hardware.
- Pairing inside KartPad needs checking with each kind of controller in
  pairing mode. Newer Xbox controllers (Bluetooth LE) still pair in the Mac's
  Bluetooth settings.
- The game itself still restarts to switch games; the curtain covers the gap.
  The Dock icon disappears for that moment.
- Taking the focus at launch can only be checked by opening KartPad from the
  Dock or Finder; automated runs never take the focus.
- Retro Rewind download needs the release header to pin the update archive too
  (local auto-update builds clear it; those builds leave Retro Rewind to the
  updater).
