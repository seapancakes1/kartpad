# KartPad app icon provenance

## iPhone, iPad and Mac red K icon

Since 2026-09-15 (commit `4e3c1e1a`, the native iOS racing launcher) the
iPhone and iPad icon is the red K on a charcoal background. It is original
project artwork, approved with that launcher's design (see `design-qa.md`):

- `apple/ios/Assets.xcassets/AppIcon.appiconset/KartPadIcon-1024.png`, the
  opaque 1024×1024 AppIcon; SHA-256
  `ff8b36acf5ebc062148d5d57bd4b2fc5bd49a945252581b3b32d1f2f456f8ddf`.
- `apple/ios/Assets.xcassets/KartPadLogo.imageset/KartPadIcon-1024.png`, the
  same K on a transparent background, used in the launcher; SHA-256
  `53be7c67667070a28d5e8937364ae5178a631a2c7e236fa74a79733ed18d39b6`.

Both were downsampled from a higher-resolution original that is not in the
repository.

The Mac icon uses the same art. `scripts/generate-macos-icon-assets.sh` places
the AppIcon in an 824×824 rounded-square body on a 1024×1024 transparent canvas
with a soft drop shadow (the macOS Big Sur icon grid). At 16 and 32 pixels it
draws the transparent K larger and without its thin diagonal cut, so the
letter stays legible. It writes `branding/exports/macos/KartPadIcon-<size>.png`
(16 to 1024 pixels) and `branding/exports/KartPad.icns`, whose ten standard and
Retina members cover 16 to 1024 pixels; the ICNS SHA-256 is
`c49267527a6ef56ff4bc5ff23e49a703be1fd71c7d44afb13e2234be998388ef`. The package
audit compares the bundled ICNS with this export, so an old icon can't ship.

## Earlier K-circuit icon (historical)

From 2026-09-01 to 2026-09-15 the iPhone and iPad icon, and from 2026-09-07 to
2026-10-12 the Mac icon, was a kart on a K-shaped circuit. OpenAI's built-in
image-generation tool produced its raster master at
`branding/KartPadIcon-k-circuit-ai.png`; its SHA-256 is
`94f5dc82a3e53bb6dd7d157449b2f2881c1747de23061f8ba6c924a92ab7df01`.

The prompt requested a generic top-down kart on a broad K-shaped circuit,
midnight-navy surroundings, cyan track lighting, and an orange kart. It
expressly excluded text, logos, characters, recognizable Mario Kart vehicles
or items, controllers, Apple branding, watermarks, and trademarked trade dress.

`scripts/generate-ios-icon-assets.sh` crops and downsamples that master to an
opaque 1024×1024 AppIcon. It predates the red K: running it would replace the
current iPhone and iPad icon with the K-circuit art. The AppIcon it produced
had SHA-256
`eb2a9f0c4fdfc78d78f9ab6052104c66a9c7a405336cda70e6f6b2dcd78300bd`.

## tvOS layered icon

The tvOS icon and Top Shelf image are original KartPad project artwork derived
from the repository-owned abstract K-circuit SVG described below. The tvOS
catalog separates the opaque midnight background, circuit rings, and K mark
into three layers so Apple TV can apply its native focus and parallax effects.
It contains no extracted Wii banner, Nintendo image, game screenshot, course,
character, vehicle, item, or other user-supplied game data.

The editable tvOS layer masters are under `branding/tvos/`; their compiled PNG
counterparts are under `apple/tvos/Assets.xcassets/`. The background layer is
opaque, foreground layers preserve transparency, and the primary icon content
is kept inside the wide-icon safe area.

## Original abstract icon and SVG sources

The first KartPad icon is original project artwork created on 2026-08-28. OpenAI's built-in image-generation tool produced the initial concept at `branding/KartPadIcon-concept-ai.png`; its SHA-256 is `9e0b4a62d1be64e5108b2b5d9fa2a5611683c0709b1d5baf2c8685afd383ed60`.

The prompt requested a generic abstract wheel/track ring, a geometric K-shaped track curve, and forward-motion marks on a midnight background. It expressly excluded Nintendo and Mario Kart logos, characters, karts, game wheels, courses, items, textures, screenshots, checkerboard flags, controllers, Apple branding, watermarks, and trademarked trade dress.

`KartPadIcon.svg` is the editable original master authored for this repository
from that concept. `KartPadIcon-Dark.svg` and `KartPadIcon-Tinted.svg` are its
appearance variants. `scripts/generate-icon-assets.sh` renders them to the
opaque `branding/exports/KartPadIcon-1024.png`, `KartPadIcon-Dark-1024.png` and
`KartPadIcon-Tinted-1024.png`. Neither the current iPhone/iPad AppIcon nor the
Mac icon uses them; the tvOS layers above are derived from the same design.
