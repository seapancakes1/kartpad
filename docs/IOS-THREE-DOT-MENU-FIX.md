# Stable iOS three-dot menu buttons

KartPad's own button no longer opens a menu: a tap opens HOME
([HOME and controllers](ios-home-and-controllers.md)). The appearance repair below still
applies to it; the menu lifecycle notes apply to other overlays that keep a `UIMenu`.

This note documents the reusable repair for a UIKit `UIButton` that opens a
`UIMenu` with `showsMenuAsPrimaryAction`. The defect has appeared in multiple
Apple game-port overlays: dismissing the menu can briefly remove the ellipsis,
draw a square around the circular button, or leave the menu control missing
after a background/foreground transition.

## Symptoms and cause

The menu button normally uses a circular layer plus an SF Symbol image. While
the primary-action menu is being dismissed, UIKit temporarily drives the button
through selected and highlighted states. On current iPadOS releases, a button
configured only with legacy `setImage:forState:` and `layer.cornerRadius` can
receive a synthesized rectangular selected appearance. Supplying selected
images alone fixes the blank glyph on some releases but does not reliably stop
the square transition.

The lifecycle symptom is separate. SDL or the owning view controller can
replace or reorder its UIKit surface after foregrounding. An overlay that was
attached only once may remain under the new surface or attached to an obsolete
container.

## Appearance repair

Configure the button once, after its normal image and menu have been created.
Use one explicit `UIButtonConfiguration` for the glyph, foreground, capsule,
fill, and border, and disable automatic configuration updates:

```objective-c
UIImage *image = [button imageForState:UIControlStateNormal];
UIButtonConfiguration *configuration =
    [UIButtonConfiguration plainButtonConfiguration];
configuration.image = image;
configuration.baseForegroundColor = UIColor.whiteColor;
configuration.contentInsets = NSDirectionalEdgeInsetsZero;
configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;

UIBackgroundConfiguration *background =
    [UIBackgroundConfiguration clearConfiguration];
background.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.72];
background.cornerRadius = 20.0;
background.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.30];
background.strokeWidth = 1.0;
configuration.background = background;

button.automaticallyUpdatesConfiguration = NO;
button.configuration = configuration;
button.backgroundColor = UIColor.clearColor;
button.layer.borderWidth = 0.0;
```

Do not mix a configuration-owned background with a second layer-owned border.
Do not depend on a selected-image-only workaround. KartPad's reusable helper is
[`apple/ios/KartPadMenuButton.h`](../apple/ios/KartPadMenuButton.h).

When the overlay is a pinned copy from another project, apply the configuration
from the owning app layer instead of editing the donor snapshot. KartPad does
this from both the Simulator shell and the full runtime host, and its donor
verification remains byte-identical.

## Foreground repair

On `UIApplicationDidBecomeActiveNotification`:

1. Ask SDL for its current `SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER`.
2. Resolve the current root view container.
3. If the overlay's `superview` is not that container, remove and reattach it.
4. Restore `hidden = NO` and `alpha = 1.0`.
5. Call `bringSubviewToFront:` and request layout.
6. Repeat the z-order check once on the next main-queue turn so it runs after
   UIKit/SDL finish rebuilding their surfaces.

The shell equivalent performs the same attachment and z-order checks against
its owning view controller. KartPad's full implementation is in
[`apple/ios/KartPadRuntimeOverlayHost.mm`](../apple/ios/KartPadRuntimeOverlayHost.mm)
and [`apple/ios/KartPadShellViewController.mm`](../apple/ios/KartPadShellViewController.mm).

## Menu organization

Keep the first screen bounded. Group related configuration into submenus and
leave frequently toggled state at the top level. KartPad uses:

- `Multiplayer…`
- `Show FPS Counter`
- `Controls` → controller mapping, touch settings, motion steering
- `Display` → aspect ratio, render resolution
- `Game Data & Saves`
- `Report a Problem…` as the final item

Build app-specific groups in the owning layer. This keeps the reusable donor
component unchanged and prevents game-specific actions from accumulating in a
single long list.

## Required validation

For every project that adopts this repair:

1. Record a baseline dismissal and confirm the defect is reproducible.
2. Open the menu, tap outside, and inspect the complete dismissal frame by
   frame. The glyph and circular border must remain stable.
3. Dismiss by choosing an action as well as by tapping outside.
4. Background and foreground the app at least five times.
5. Confirm the button remains visible, opens the menu, and all submenus/actions
   still work after the fifth cycle.
6. Test both the lightweight Simulator shell and the production runtime target.
7. Run the donor snapshot check when the project pins a shared overlay.
8. Finish with a physical iPhone or iPad pass; Simulator evidence alone does
   not close lifecycle behavior on hardware.

KartPad reproduced the original defect on iPadOS Simulator 26.5, passed the
frame-by-frame candidate comparison, passed five foreground cycles, compiled
the full physical-iOS runtime, and retained its exact pinned SunPad snapshot.
