# Local Mac Retro Rewind updates

A Mac app you build yourself can keep Retro Rewind current on its own. When the official feed has a newer pack, a helper downloads it, rebuilds KartPad for it on your Mac and installs the result at the next launch. It updates only the Retro Rewind pack, not KartPad itself.

It is opt-in. Only apps packaged with `Contents/Resources/LocalUpdater` (the helper, the maintainers' pinning script it reuses and your settings) do any of this; public builds and ordinary self-builds don't. Builds with it don't offer the in-app Retro Rewind download, because the updater manages the pack.

## Setting it up

You need a working Mac self-build first (see [Build it yourself](INSTALL_MACOS.md#build-it-yourself)): its runtime build is reused for every rebuild.

1. Keep the profile your build used, so later pulls don't change it:
   `cp builder/profiles/mkwii-rmcp01-rev0.json private/retro-rewind-6.13.1-profile.json` (use your version).
2. Copy `scripts/local-updater-settings.example.json` to `private/local-updater-settings.json` and replace the `/Users/YOU/...` paths (keys below).
3. Check it: `python3 scripts/check-local-updater-settings.py private/local-updater-settings.json`.
4. Quit KartPad, move the old app out of the way (the package script won't overwrite it), then package and audit with the settings named:

   ```sh
   export KARTPAD_LOCAL_UPDATER_SETTINGS="$PWD/private/local-updater-settings.json"
   scripts/package-macos-runtime.sh "$PWD/build/self-build-macos-build" /Applications/KartPad.app KartPadDual
   scripts/audit-macos-package.sh /Applications/KartPad.app dual
   ```

   `scripts/macos-local-rebuild.sh ROOT PROFILE APP` does the whole rebuild (translate, build, package, audit) the same way the updater runs it, reading anything not already set from the settings' `environment`.
5. Open KartPad from that path. Its first launch records it as the installed app.

Keep the checkout, the app and the state folder on a local APFS volume, not iCloud Drive: iCloud rewrites files and breaks the app's signature. Always package with `KARTPAD_LOCAL_UPDATER_SETTINGS` set (the audit checks the bundled helper matches the checkout), so a repackaged app can't quietly stop updating.

### Settings

| Key | Meaning |
| --- | --- |
| `python` | Absolute path of the interpreter that runs the helper: Python 3.9 or newer (`/usr/bin/python3` works). |
| `repo` | Your KartPad checkout. Rebuild commands run here. |
| `state` | The updater's state folder, normally `~/Library/Application Support/KartPad/LocalUpdater`. |
| `config` | KartPad's `Config.toml`. Only its `retro_rewind_root` line is ever changed. |
| `initial` | The pack the app was built for: `version`, `root` (its `RetroRewind6` folder) and `profile` (the profile kept in step 1). |
| `buildCommand` | Argument list run to rebuild, with `{root}`, `{profile}` and `{app}` replaced. Nothing from the network is ever run as a command. |
| `environment` | Optional variables for the build command. Apps opened from Finder have a minimal `PATH`, so give every tool the scripts need (`rg`, `dotnet`, `cmake`, `ninja`, `python3`). `scripts/macos-local-rebuild.sh` also reads `KARTPAD_LOCAL_UPDATER_SETTINGS`, `KARTPAD_DISC_IMAGE`, `KARTPAD_RUNTIME_SOURCE`, `KARTPAD_RUNTIME_BUILD`, and optionally `KARTPAD_RETRO_PAYLOAD` and `KARTPAD_TRANSLATE` (a translate script with your own .NET path). |
| `app` | Optional: the installed app's path. Without it, the first copy that launches is taken as the installed one, and it is followed when it moves (see [Which app updates](#which-app-updates)). |
| `reviewedProfile` | Optional: where to read the maintainers' review, on `raw.githubusercontent.com` (for example a fork's). Defaults to `chrissotraidis/kartpad` `main`. |

## What gets installed: the verification model

KartPad's maintainers publish a reviewed pin for each Retro Rewind version they support, in `builder/profiles/mkwii-rmcp01-rev0.json` (see [Updating WiiCompiled and Retro Rewind](UPSTREAM_UPDATES.md)): the version, the official archives' sizes and SHA-256, and the size and SHA-256 of `Code.pul` (the program code KartPad translates) and the Riivolution XML. Each check reads the official version feed and that review. An update installs by itself only when all of these hold:

- The feed's newest version is the reviewed version.
- Every downloaded archive whose URL the review pins has the pinned size and SHA-256. This is checked before it is unpacked.
- After all patches and the official delete list are applied, and before anything is translated or compiled, `Code.pul` and the Riivolution XML have the pinned size and SHA-256.
- The pack's `version.txt` reads the reviewed version, or the review's `packVersion` when the release shipped an older one (Retro Rewind 6.13.3's says 6.13.2). The helper keeps `packVersion` with the pack and checks it again at installation, going back and later checks.

Otherwise nothing is built. The banner says **Retro Rewind VERSION is available** (the feed is ahead of the review; it installs by itself once the review catches up) or **Retro Rewind VERSION wasn’t installed** (files differ from the review). **Install Anyway** asks for confirmation and records the approval for that version and download only (`approved.json`); the checks still run and their results are kept in the build's profile, but no longer stop it. Deletions from the official delete list are applied only in a verified update or after that approval.

A mismatch is remembered against that review, so automatic checks don't download it again until the feed or the review changes; **Retro Rewind Updates…** tries again.

### Trust boundary

- Trusted: GitHub and the reviewed profile on the configured branch (fetched over HTTPS, redirects confined to `raw.githubusercontent.com`); the official feed at `update.rwfc.net` for which versions exist; your checkout, toolchain, settings file and disc image.
- Checked, not trusted: archives from `cdn.update.rwfc.net` (HTTPS only, size and extraction limits, safe paths, pinned hashes when pinned), the resulting program code and patch list (pinned hashes), the rebuilt app (it must contain the new pins, be signed and pass the package audit; its digest is checked again before it is installed).
- Not covered by a pin: other assets from intermediate patches when your pack is more than one release behind the review, and everything after **Install Anyway**.

## Checking

At each launch KartPad starts a background check at utility priority, and checks again every 4 hours while it stays open (after the Mac wakes, within half an hour of the 4 hours passing). Automatic checks are quiet: no banner appears while checking, when the game is current, or when the Mac is offline. A compact, nonactivating banner attaches to the upper-right of the game window when there is news: downloading, preparation, verification, a ready update, an unreviewed version, or a failure. Each distinct failure is shown once. An unreviewed version is shown at every launch until it is installed, from the last check if the Mac is offline. Downloads and the rebuild show a progress bar; the rebuild names its stage (reading the game files, translating, compiling, packaging), which the helper reads from `build.log` every 2 seconds. Dismissing the banner doesn't cancel the update, and **Retro Rewind Updates…** shows it again.

**Game → Retro Rewind Updates…** runs a visible check, which also reports when the game is up to date, and reopens the banner for an update in progress. It ignores the retry rules below.

Failures don't repeat on every launch:

- **Offline:** automatic checks back off, starting at 10 minutes and doubling to at most 6 hours.
- **Not enough space:** the check runs again at the next launch.
- **Build, verification or configuration failure:** remembered for that feed version and download URL. Automatic checks skip it until the feed changes, the checkout's `builder/profiles/mkwii-rmcp01-rev0.json` changes (for example after pulling the maintainers' support for that version), or the player chooses **Try Again**.
- **Checkout behind the release:** a rebuild that fails for a version newer than the one the checkout's own profile supports usually needs the maintainers' changes as well (6.13.3 needed new runtime helpers). The banner says **Retro Rewind VERSION needs a newer KartPad checkout**, and the next check after that profile changes tries again.

## Preparing an update

The helper validates the installed pack, then clones it into a staging directory. APFS clones (`cp -c`) share unchanged files with the installed pack, so staging costs little extra space. It downloads every newer official patch in version order. Downloads retry transient failures and resume from the bytes already received. Each patch is checked against the review, extracted, then its ZIP is deleted.

After each patch the helper applies that version's entries from the official `RetroRewindDelete.txt`, so files a release removes don't survive the update. Only `/RetroRewind6/` paths apply; other entries are the official updater's own downloads at the SD card root. A path that escapes the pack, or an entry that removes the whole pack, rejects the update.

The helper then checks the resulting version and the reviewed hashes. Download and extraction limits reject oversized or unsafe archives. The build command runs under `taskpolicy -b` so it doesn't compete with the game. The helper verifies that the new pack fingerprints are present in the native app and that the app carries the helper, then signs it and runs the Mac package audit.

## Installing

The ready banner offers **Restart** and disappears after five seconds. Restart warns that unsaved progress will be lost and offers **Keep Playing**. A helper waits for KartPad to exit, installs the update, and reopens the updated app once. If the player quits normally instead, KartPad installs the update at the next launch, before opening game files, and reopens itself.

Installation carries the player's saves across, moves the app bundles, rewrites the config and updates the state files as one journaled step. If it is interrupted, the next launch puts every piece back as it was. A pending build that can't be installed (failed integrity check, missing files, an unusable config) is discarded and recorded, so it can't block later updates. A build that only ran out of space stays pending for the next attempt.

### Saves

Retro Rewind keeps saves (`riivolution/save`) and Riivolution's option choices (`riivolution/config`) beside its `RetroRewind6` folder, so each version's pack has its own. At installation, not when the build starts (the player may keep racing in between), the updater copies them from beside the pack the game has been using to beside the new one. Going back copies them the other way, replacing the older version's copies, so progress made on the newer version isn't lost. The copies are APFS clones and part of the journaled step. A pack whose saves are newer than the ones the game now uses is never removed.

### Which app updates

The updater records the installed app's path and runtime digest (`installed.json`). Only that app checks, installs, counts trial launches or confirms an update. A backup or another copy that opens leaves everything alone, and **Retro Rewind Updates…** in it says where updates go.

Moving or renaming the installed app (into `/Applications/Games`, say) doesn't stop updates. When nothing is left at the recorded path and an app with the same runtime digest opens somewhere else, that app is the installed one: its first check records the new path, and updates install there. A copy made while the original is still in place, a different build, a copy in the Trash, one macOS runs from a temporary App Translocation path, and the backups in the state folder are never taken for a moved app. Setting `app` in the settings turns this off.

An app the updater didn't install, such as one you packaged by hand at the installed path, becomes the new starting point at its next launch: any update built for the previous app is discarded, its trial ends, and if its Retro Rewind version differs, the config is pointed (saves included) at that version's pack (the original one from `initial`, or one an earlier update left), then KartPad reopens. If no pack of its version is known, the next check reports that the settings don't match the app; update `initial`.

## Trial and going back

A newly installed app is on trial until it has run for 90 seconds or ends a session cleanly. If two launches end without either, the next launch restores the previous app and game files, reopens KartPad and explains what happened. Automatic checks then skip that version.

**Game → Go Back to Retro Rewind VERSION…** does the same on demand. Afterwards, **Retro Rewind Updates…** shows the skipped version with **Install Anyway**. Going back changes only the `retro_rewind_root` line of the config, so settings changed since the update are kept.

## Disk use

The updater keeps the active version and one previous version: its app in `LocalUpdater/Backups.noindex` (out of Applications, Launchpad and Spotlight; moved there on the same volume, copied otherwise) and its pack. After each installation it removes older staging directories and backups, the spare copy of the new app, and leftovers from interrupted runs. Rebuilds still need at least 8 GB free.

## Requirements

The feature depends on this machine's checkout, user-owned disc extraction, local build scripts, the .NET SDK, Xcode and cached native dependencies. A future incompatible pack may fail to translate or compile; the working app and pack stay in place, and the banner reports the failure. If a Retro Rewind release also changes the online payload pin, update the payload your build command uses.

## State

Files are under `~/Library/Application Support/KartPad/LocalUpdater`:

| File | Purpose |
| --- | --- |
| `status.json` | Latest phase shown by the banner, with the rebuild's `buildStage` and `progress` (0–1) |
| `installed.json` | The installed app's path, Retro Rewind version and runtime digest |
| `pending.json` | A finished build waiting to be installed |
| `active.json` | The installed version, pack and profile, once an update has been installed |
| `rollback.json` | The previous version, its pack and its app backup |
| `trial.json` | Launch count for a newly installed app |
| `failure.json` | The last failure, for retry and backoff decisions |
| `declined.json` | A version the player went back from |
| `approved.json` | A version the player chose to install without a review |
| `activation.json` | Journal of an installation in progress |
| `Backups.noindex/` | The previous app |
| `last-build.log` | Output of the last failed rebuild |

## Validation

`python3 scripts/test-macos-local-updater.py` (the stock macOS `python3` is enough) uses temporary folders and fake downloads only. It covers the ordered patch flow, the live four-column feed format and shared version parsing, delete-list selection and safety, APFS cloning and moves between volumes, resumed downloads, the reviewed, feed-ahead, archive-mismatch, `Code.pul`-mismatch and approved paths, the staged background rebuild, integrity rejection, discarding unusable builds, backups outside Applications, saves carried through updates, pruning and going back, backups and other copies leaving state alone, following a moved app (and not a copy, another build or one in the Trash), a pack whose `version.txt` lags the feed, adopting hand-built packages, failure memory and network backoff, retrying after the checkout catches up, declined versions, trial rollback, manual rollback, unsafe ZIP paths, lock contention, offline behavior and interrupted-installation recovery at every step, including saves. `python3 -m unittest discover -s tests -p 'test_macos_retro_download_recovery.py'` covers the in-app download's recovery after an interrupted install, and `python3 -m unittest tests/test_macos_local_updater_moves.py` compiles the app's side of following a moved app.
