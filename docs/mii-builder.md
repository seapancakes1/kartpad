# Native Mii editor

Mac: Settings → Data → Mii Appearance → Create Mii / Edit Mii.
iPhone/iPad: Player Identity → Create Mii / Edit Mii.

The editor uses the Wii category order: Profile, Body, Face, Hair, Eyebrows, Eyes, Nose, Mouth, Facial Hair, Glasses. All 46 appearance fields remain available. Visual tiles map explicitly to binary IDs; opening a category reveals the selected feature's page. Face details, beard, mustache and mole controls use secondary choices within their categories.

Shared vector artwork supplies silver and teal tabs, category silhouettes, adjustment arrows, color swatches and selected states. AppKit and UIKit retain native text fields, scroll views and body sliders. Male and Female are separate choices. Mac birthdays use named month and day menus; iPhone/iPad use a month/day wheel without a year. February allows 29 days because the Mii record has no birth year. Selecting Not set clears both fields. Name entry preserves the ten UTF-16-unit storage limit and waits for composed input to finish before validation. Emoji may consume multiple units.

Create Mii starts with Male/Female and Start from scratch, then opens Face. Existing Miis open directly. Save & Quit and Discard are visible below the editing panel; they activate when the draft changes. Discard, Reset Changes and closing an edited draft require confirmation. Export and Reset are in the secondary menu. Saving explains that KartPad must fully restart. New Miis remain unassigned until selected in License Settings → Change Mii.

Buttons have accessible labels, selected states and visible keyboard focus. Mac supports arrow navigation, Return/Space, Cmd-Z, Cmd-Shift-Z and Escape; iPad hardware keyboards support undo, redo and Escape. Continuous button adjustments and slider drags produce one history entry. Adjustment buttons disable at the field limits. UIKit selection activates on release so scrolling does not select a choice on touch-down. The preview does not animate automatically.

Mac defaults to 960 × 720 with an 800 × 600 minimum. Wide layouts show preview and editing panel side by side. Portrait iPhone places the preview above controls and splits category tabs across two rows. Editing panels scroll when needed. Regular adjustments update the affected controls and preview without rebuilding the form.

## Persistence

Save stages changes for the next cold launch. Export and discarded drafts leave live data untouched. Standard `.mii` records remain exactly 74 bytes. Hidden console identifiers, creation flags and reserved bits remain intact on edits. New identities use the runtime console MAC and a unique regular-Mii creation ID. Renaming an existing Mii updates matching licenses in Original and both Retro Rewind save locations.

`PendingMiiEditor.plist` holds one validated combined edit. On restart every target is checked before backups are written to `MiiEditorBackups`. Linked-name patches are rebased onto newer race progress if the license identity and previous name still match. A stale Mii or changed linked identity rejects the edit.

`MiiEditorTransaction.plist` is written before any live file changes. Atomic replacements apply the combined edit. An interrupted transaction rolls forward on the next launch; gameplay is blocked until recovery succeeds. Backups retain the pre-application database and saves. Pending changes prevent another import, removal, creation or edit. There is no save-format migration.

## Imported resources and rendering

`files/contents/RFLRes01.arc` supplies original head meshes and feature textures. `files/Scene/Model/MiiBody.szs` supplies original male/female body meshes, standing animation, diffuse textures, light maps, highlight maps, material assignments and attachment data. These are the game package's racing outfits. No invented body geometry or replacement facial-feature artwork is used. Mii Channel clothing and interface assets are not present in this imported package; toolbar artwork is reconstructed as vectors from the Wii manual.

A shared Metal renderer in `MTKView` supports drag rotation, rotation buttons, front reset, viewport fitting and full-body/head framing. Resource readers validate bounds, primitives, matrix indices, finite geometry, texture dimensions and cache data. Positions, normals and UV coordinates use their separate original scales. Mirrored meshes preserve normals and winding. Face-mask composition uses original feature textures and recoloring. Transparent overlays do not write depth; filtering handles alpha without black fringes. Body vertex alpha is a light-map coefficient, while diffuse alpha masks highlights. Material IDs come from the original draw bytecode. Original attachment offsets align the collar and head.

Glasses textures use the original GX addressing modes, including mirrored U coordinates spanning both lenses. The GPU sampler and CPU thumbnail renderer preserve clamp/repeat/mirror metadata. Accessory thumbnails show both sides of the imported mesh; shared triangle edges are not blended twice.

Resources load on a serial background queue. Decoded resources and thumbnails are cached; stale revisions are discarded before installation. Archive SHA-256 and cache version invalidate replaced or incompatible data. Missing head/body resources or Metal availability produce a readable state, while editing and export remain available. Imported resources and decoded caches are not shipped in app packages.

## Validation and limits

Run `scripts/test-mii-builder.sh /absolute/path/to/RFLRes01.arc /absolute/path/to/MiiBody.szs`. Without resources, binary, history and Apple persistence tests still run. Tests use disposable databases and synthetic saves. Coverage includes all 46 field boundaries, Unicode, reserved/identity preservation, capacity, unique IDs, linked-name/progress preservation, stale records, backups, interrupted recovery, creation, explicit feature mappings, selected pagination, grouped undo/redo, stale preview revisions, month lengths, decoded resources, addressing modes and malformed archives/caches.

Local verification artifacts are recorded in `outputs/Wii-Mii-Editor-Review` outside the repository. The Metal catalog renders 870 front/side/back checks across every feature ID and palette, body extremes and hair reversal. Native screenshots and package audit results are recorded separately in that review folder.

Exact visual parity remains unverified. Feature IDs are mapped explicitly in numeric catalog order; canonical Wii tile ordering has not been established. Body height/weight scaling and the lighting environment are approximations around imported geometry and textures. Larger text scales within fixed controls; a full accessibility-size reflow is not implemented. Physical-device verification, every adjustment combination and an in-game rendering comparison are outstanding. These limits must not be presented as completed release gates.

## References

- [Nintendo Wii editing screens](https://assets.nintendo.eu/image/upload/v1635389389/NAL/Support/WiiOperationsManualChannelsAndSettings.pdf).
- [Wii Mii record layout](https://wiibrew.org/wiki/Mii_data).
- [RFL archive reader reference](https://gist.github.com/ariankordi/15c713e1208d7a5d534152dc276bab4a).
- [Petari RFL model reconstruction](https://github.com/SMGCommunity/Petari/blob/master/src/RVLFaceLib/RFL_Model.c) and [texture composition](https://github.com/SMGCommunity/Petari/blob/master/src/RVLFaceLib/RFL_MakeTex.c).

The PAL RMCP01 revision-0 local main DOL contains verified skin, hair, glasses and favorite-color tables at offsets `0x2479b0`, `0x2479c8`, `0x247a08` and `0x247a20`. These checks use numeric format/color metadata; no disc resources are included in source or packages.
