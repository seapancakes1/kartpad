# Multiplayer and controllers

Open **••• → Multiplayer…** on iPhone/iPad, **Controls → Multiplayer…** on
Mac, or **Multiplayer…** on the Apple TV game chooser. The menu covers
Original Mario Kart Wii and Retro Rewind; available online guidance depends on
the game profile. Apple mobile menu names below follow 0.4.10 and later.

## iPhone and iPad touch and motion controls

These instructions describe the Apple touch interface. Android has its own
[controls and display settings](INSTALL_ANDROID.md); do not assume menu parity.

- **Acceleration lock:** hold A continuously for one second until it turns cyan.
  Release your finger to keep accelerating; tap A to unlock. Opening a modal,
  hiding touch or handing Player 1 to a controller clears the lock.
- **Layout:** open **••• → Touch Control Settings** to move, resize, hide or
  restore controls. The D-pad is hidden by default and can be enabled for tricks
  and wheelies. Existing custom visibility choices are preserved. Phone and
  tablet layouts are stored separately; **Back** returns to touch settings.
- **Floating stick:** touch within its pickup area to place it under your thumb;
  it disappears on release. R is a digital drift control, not an analog trigger.
- **Controller handoff:** the first extended gamepad takes Player 1, clears held
  touch input and hides touch controls by default. Disconnecting restores touch;
  additional controllers retain their Player 2–4 slots.
- **Motion steering:** **••• → Motion Steering…** is off by default. It provides
  recenter, inversion and 0.5×/1×/2× sensitivity. Touch can override motion;
  physical controllers take priority, and backgrounding clears live motion state.

Motion tuning, full race coverage and reconnect behavior still need physical
acceptance on the exact build; the existence of a setting does not prove them.

## Local split-screen

Pair each controller in the operating system, select Multiplayer in the game,
and press the mapped A button on every pad at Register Controllers. iPhone/iPad
Controller Setup lists the four stable player slots and offers face-button
remapping. Touch shares Player 1 with the first physical controller. Disconnecting
a controller leaves the other players in their existing slots.

Issue #85 was caused by WPAD's connection probe consulting keyboard slots while
KPAD input reads also consulted Apple's physical controllers. The probe now
checks the same physical slots without consuming registration button presses.
The callback also samples immediately instead of adding another asynchronous
read that could lose a short press. The regression fixture fails against the
0.4.8 prepared source and passes after the patch. Apple snapshot-controller tests
cover four slots, repeated connection probes, short A presses, disconnect and
reconnect. These tests do not establish a physical three-controller race.

## Phones as controllers (Mac)

Guests can play on a Mac with their own phone and nothing to install. Choose
**Controls → Add Phone Controller…** (or **HOME → Controllers → Connect a
Controller → Phone**), scan the QR code with the phone's camera, open the link
and tap **Join**. A second tab opens for a moment to link the phone to the Mac,
then closes. Choose **Use Tilt** to steer by turning the phone like a wheel, or
**Use the Stick**.

The phone shows the controls for what its player is doing, which KartPad reads
from the game:

- **Menus** (and a paused race, or one that player has finished): a D-pad, **A**
  and **B**.
- **A race:** **Drift** under the right thumb, with **B**, **A+B** and
  **Trick** beside it, and **Item** on the left. With tilt, Item sits alone
  under the left thumb and a wheel shows the steering (a sharp shake also does a
  trick). With the stick, drag anywhere on the left to steer; Item is above it.
- **Item** aims like up or down on the stick: press or slide to its top to
  throw forward, its bottom to throw back, the middle to use it as normal. Hold
  it to keep the item trailing; it's thrown when you let go.
- **Accelerating:** from GO the phone accelerates by itself, so there's no A
  button. Hold **B** to brake and reverse; let go to drive on. Hold **A+B** when
  stopped (after a hit, say) to charge a standstill mini-turbo, then let go to
  launch. The countdown and a fall are the player's: **A** takes Drift's place
  for a rocket start, and from falling off until just after Lakitu sets the kart
  down, for his boost (press A as you land). KartPad reads the fall from the
  game, as it does the race.
- **Accelerate: Hold** in **⚙** puts A beside Drift for the whole race instead:
  hold it to accelerate, or hold it for a second to keep accelerating and tap it
  to stop. A thumb on the edge between **A** and **Drift**, or **A** and **B**,
  presses both.
- **HOME** needs a half-second hold, so a stray tap doesn't open it mid-race.
  **Pause**, **Tilt**/**Stick** and **⚙** are along the top.

More:

- **Tilt** works like KartPad's iPhone motion steering: it follows the phone's
  angle (from the phone's gyro-steadied gravity), not how hard it's moved, so
  swinging or jolting the phone doesn't steer. Straight is level, like a Wii
  Wheel, so there's nothing to calibrate; **Straight: Set Here** makes the
  current angle straight instead, for playing lying down. **⚙** also has
  sensitivity (0.5×, 1×, 2×), direction, shake for Trick, accelerating, the
  hand (**Left** mirrors the controls) and the link's delay.
- A hard turn can make the phone turn its screen to portrait; the controller
  carries on drawn sideways, but **Rotation Lock** (in Control Centre) keeps the
  screen still. With rotation lock on, tap **Rotation Lock Is On** when the page
  asks for the phone to be turned (and **Screen: Flip** in **⚙** if it comes out
  upside down).
- The tilt page is published over HTTPS (browsers only give motion to such
  pages), so the phone needs internet to open it. After it opens, input goes
  straight from the phone to the Mac over a WebRTC data channel on your Wi‑Fi;
  nothing passes through the internet. If that direct link fails, **Use Touch
  Controls** opens the same controller from the Mac itself, touch only.
- The Mac's phone page lists the phones that have joined, with each one's
  player, how quick its link is, and **Remove**.
- Up to four phones join, each as its own controller (`Phone 1` to `Phone 4`)
  on the first free player (or the keyboard's, while the keyboard just follows
  free players), as a controller does. Controllers and Player Order move them
  like any other controller, and the phone shows its player number and colour.
- The phone must be on the same Wi‑Fi as the Mac. Networks that keep devices
  apart, common on campus, hotel and guest Wi‑Fi, block it.
- A phone that locks or drops keeps its player for a minute. The touch-only page
  rejoins by itself. The tilt page usually carries on after a short lock, and
  otherwise shows **Reconnect** (one tap, since it opens the linking tab again).
  **Leave** in **⚙** frees the player at once.
- The link changes each time KartPad starts, so scan again after a restart.
- Android phones vibrate on presses and when the game rumbles. iPhones (iOS 18
  and later) give a light tick on presses; the game's rumble doesn't reach them.
- A phone's player lasts for that session only; it is never saved, so a phone
  that joined first doesn't take Player 1 from a controller next time.

## DualShock and DualSense

DualShock 4, DualSense and DualSense Edge can pair with supported Apple devices
using [Apple's pairing instructions](https://support.apple.com/en-us/111100).
KartPad's Apple mobile input bridge accepts Extended Gamepads, including these
controller families. The default positions are Cross = A, Circle = B,
Square = X and Triangle = Y. Customize Face Buttons changes those assignments;
the D-pad, sticks, Menu and triggers remain direct. Mac uses its existing SDL
controller setup. Pairing and gameplay with each exact model remain hardware
checks, separate from the snapshot-controller regression tests.

## GameCube controllers on iPad

A GameCube-shaped controller or adapter can use this path **if iPadOS exposes it
as an Extended Gamepad**. An original GameCube controller plugged into a
Nintendo/WUP-028 USB adapter is not supported by KartPad's current iPad input
bridge. This update does not add a raw USB GameCube adapter driver. The original
controller, an adapter's operating mode, and a Bluetooth GameCube-style pad are
not interchangeable support claims.

## Private friend rooms

In iPhone/iPad 0.4.10, **Retro WFC Friend Rooms…** is shown only for Retro
Rewind. Its friend-room flow lives inside the game: **Nintendo WFC → Friends**.
Everyone must use matching Retro Rewind content and a compatible online service.
After a successful service login, exchange friend codes, create a room, and
join through the friend roster. Exact production login and races still need
acceptance for the distributed KartPad build.

Original Nintendo WFC is closed. Original Mario Kart Wii's Multiplayer menu
therefore has no private friend-room instruction action in 0.4.10. The
experimental server setting below does not restore that service by itself.

This is different from MeleePad's Dolphin/ENet synchronized-input rooms.
MeleePad room codes, native host/join controls, traversal, ready state and peer
chat have **not** been ported. A shared menu does not establish that parity.

## Experimental private Wii-server routing

**Experimental Server Settings…** on iPhone/iPad 0.4.10 saves a hostname or
IPv4 address for the next launch. The older Apple builds label it **Private
Wii Server…**.
Quit/fully close and reopen KartPad after saving or restoring the default.
The launch-time route is shared by both game profiles. This is a client route,
not a server installed or hosted by KartPad, and is not a room-code service.

Only game DNS names below `nintendowifi.net` and `play.rwfc.net` are redirected.
Content downloads and peer IP addresses keep their original destination. The
explicit private service uses the legacy plaintext Wii WFC protocol; unrelated
TLS requests retain their normal certificate validation. Use a service you
trust. The setting does not weaken server-side authentication.

A compatible backend must implement the game's NAS authentication, GameSpy
presence/friends/matchmaking, NAT negotiation, and race services. Standard service
ports must be available, including the initial logical HTTPS connection on 443
and legacy HTTP on 80. A generic web server or another player's app IP is not
sufficient. A backend requiring a downloaded PowerPC patch or a different
signature/payload is not automatically compatible: KartPad does not compile or
execute new downloaded game code. In particular, entering a WiiLink/Wiimmfi
address alone does not establish Original Mario Kart Wii compatibility.

The new routing path has host validation, destination-scope and compiled Apple
transport coverage. Login, a hosted/joined friend room, complete races and
reconnect on an exact compatible backend still require acceptance, especially
for Original Mario Kart Wii. Do not describe this setting as verified private
online gameplay or MeleePad parity.

## Android and Razer Kishi

The first Android release, `v0.4.10-android.1`, includes the shared Multiplayer
settings and Android SDL controller path. The maintainer accepted Original
Grand Prix play with Razer Kishi on Pixel 9 Pro XL and confirmed automatic touch
hiding. Retro Rewind Retro WFC login, worldwide matchmaking and live race play
were also owner-reported. Rumble, reconnect, multiple physical pads and complete
online results/reconnect are not established by that session. See
[Android installation and controls](INSTALL_ANDROID.md).
