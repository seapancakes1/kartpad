# Install KartPad on Mac

On Apple Silicon Macs (M1 or newer) with macOS 14 or newer,
[PadMint](https://github.com/chrissotraidis/padmint) builds KartPad from your
own disc. You add your own Mario Kart Wii game data the first time you open it.
(0.7.9 to 0.7.13 also had a ready-to-play Mac download; it won't get updates.)
The Mac version is experimental: it's tested less than Android and
iPhone/iPad.

## Install

1. In [PadMint](https://github.com/chrissotraidis/padmint), choose **KartPad**,
   your disc image and **Mac**, and move the **KartPad** app it makes to
   Applications. To update, build the new version with PadMint, quit KartPad
   and replace the app; your settings and saves stay.
2. If macOS says it can't check the app, choose **Done**, then
   open **System Settings → Privacy & Security** and choose **Open Anyway**.
   The app isn't notarized by Apple, which is why macOS asks. Don't turn off
   Gatekeeper.
   If macOS says **KartPad is damaged**, the app's signature broke, usually
   because it was copied through iCloud Drive. Build it again, or copy it from
   a local folder, rather than turning off Gatekeeper.
3. When KartPad asks for game data, choose your extracted Mario Kart Wii
   `DATA` folder (PAL **RMCP01**, revision 0). To make it, in
   [Dolphin](https://dolphin-emu.org) right-click the game, choose
   **Properties → Filesystem**, right-click the disc and choose
   **Extract Entire Disc**. You can change it later with
   **Data → Choose Mario Kart Wii Data…**.

## Retro Rewind

KartPad downloads Retro Rewind for you: switch to it from **HOME**, or open
**Settings → Game → Retro Rewind files**, and choose **Download**. It gets the
exact pack this KartPad was built for (about 2 GB), checks it and installs it
in KartPad's data folder while you keep playing. When it's ready, switch to it
from **HOME**. To use a pack you already have, choose **Use a Folder** there
(or **Data → Choose Retro Rewind Data…**) and select its `RetroRewind6` folder.
**Game → Mario Kart Wii** switches back.

KartPad needs the exact Retro Rewind version it was built for. If it says the
data is unsupported, use the version it names; a newer pack needs a KartPad
update. A Mac app you build yourself can instead
[update Retro Rewind on its own](macos-local-auto-update.md).

## HOME

Press **HOME** on a controller (the Xbox button, the PS button, or HOME on a
Pro Controller, Joy-Con or Wii Remote) or **esc** on the keyboard for KartPad's
menus over the game. The game holds still underneath (online it keeps going).
From HOME: resume, switch between Mario Kart Wii and Retro Rewind, Miis,
Controllers, volume, window or full screen, Settings and Quit. Holding
**Menu** (Start, +) for a second also opens HOME, on any controller. Everything works with
a controller, the keyboard or the mouse. See
[KartPad on Mac: HOME, Controllers and Settings](macos-home-and-controllers.md).

The first time KartPad opens it walks you through finding your game files.

## Menus and input

- **Game** opens HOME, switches the game and opens **Miis…** (⇧⌘M; also
  **HOME → Miis**). **KartPad → Settings…** (⌘,) or **HOME → Settings** opens
  Settings. Changes that need a restart (switching games, game data, VSync,
  the online service) offer **Restart**; choose **Not Now** and **Game →
  Restart to Apply** stays until you do.
- **Control-Command-F** (or **Window → Enter Full Screen**, Option-Return or
  the green window button) switches between a window and full screen.
  KartPad remembers which for the next launch.
- The game pauses while another app is in front, except while it loads and
  while you're online. Turn off **Settings → Game → Pause when you switch
  apps** to keep playing with a controller behind another app.
- **Data** changes the game data folders, opens **Time Trial Ghosts…** and shows
  KartPad's files in Finder.
- **Controls → Controllers…** detects and maps controllers for up to four
  players. **Keyboard Controls** (⌘/) lists every keyboard binding.
- Keyboard defaults: `WASD` to steer, `U` or Return to accelerate and
  confirm, `M` or Delete to brake and go back, `E` to drift, Left Shift for
  items, arrow keys for tricks, Space to pause and Tab for select.
- The mouse works in KartPad's menus but doesn't drive; use the keyboard or a
  controller in races.
- On a controller without a HOME button, hold **Menu** for a second to open
  HOME. The D-pad moves around Settings, left and right change a choice or
  slider, A presses, LB and RB change tab, and B closes it.
- Controllers that can vibrate do when the game rumbles. **Settings →
  Controls → Vibration** sets the strength (Off, Light, Medium or Strong) and
  **Test vibration** checks a controller.

Settings and saves are in `~/Library/Application Support/KartPad`, graphics
caches in `~/Library/Caches/KartPad`. Replacing the app keeps both.

## Phones as controllers

**Controls → Add Phone Controller…** shows a QR code that any phone on the same
Wi‑Fi can scan to play, with nothing to install, steering by tilt or touch. See
[Phones as controllers](MULTIPLAYER.md#phones-as-controllers-mac). If the macOS
firewall is on, allow KartPad to accept incoming connections when asked.

## Experimental Wii Remote and Nunchuk

In **HOME → Controllers → Connect → Wii Remote** (or **Controls → Pair Wii
Remote…**), press the red **SYNC** button on the Wii Remote to pair,
then attach the Nunchuk. It works with an
original `RVL-CNT-01` or Wii Remote Plus `RVL-CNT-01-TR`, without a
DolphinBar. It uses private macOS Bluetooth interfaces and needs more hardware
testing; reconnecting and long sessions may not work yet. A Classic Controller
Pro on a Wii Remote has open problems ([#306](https://github.com/chrissotraidis/kartpad/issues/306)).

## Build it yourself

Developers can build the Mac app from their own disc image. Install the
[Apple build prerequisites](BUILDING.md#prerequisites), then run:

```sh
./scripts/self-build-macos.sh /path/to/your/Mario-Kart-Wii.wbfs
open build/KartPad.app
```

It accepts only the exact pinned development image (checked by SHA-256), fetches
and verifies the pinned dependencies and Retro Rewind inputs, translates both
games, builds and audits the app, and sets `dvd_root` and
`retro_rewind_root` in your KartPad configuration. Back up that configuration
and your saves first if you already use the Mac app. The result stays a private
local build; see [`RIGHTS_AND_LICENSES.md`](../RIGHTS_AND_LICENSES.md) and the
[Apple source-build guide](BUILDING.md#mac-self-build).

Report problems with your macOS version and Mac model; see the
[reporting guide](REPORTING.md).
