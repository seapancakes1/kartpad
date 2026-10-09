#pragma once
// Mario Kart Wii menu sounds the Mii editor plays. They are rendered at run time from the
// player's imported files/sound/revo_kart.brsar; no game audio is stored or shipped.
#include <cstddef>
#include <iterator>
namespace kartpad::mii {
enum class EditorSound {
    Hover,        // Pointer over a button. Never cuts off another sound.
    Tick,         // Held-adjustment repeats and slider notches. Same clip as Hover.
    Press,        // Part tiles, the More menu.
    Tab,          // Categories, page modes, colour swatches, face front, Mac birthday menus.
    Same,         // Choosing what is already chosen; toggling off; nothing to undo or redo.
    Confirm,      // Gender, toggling on, Done, Animate Preview, the sound checkbox.
    Left,         // Decreasing adjustment, turn left.
    Right,        // Increasing adjustment, turn right.
    PageNext,     // Next page, redo.
    PagePrevious, // Previous page, undo, discarding or resetting changes.
    Key,          // Typing a name.
    Erase,        // Deleting from a name.
    Open,         // Editor or birthday sheet opens.
    Close,        // Leaving without changes, Keep Editing, Cancel.
    Dialog,       // A confirmation appears.
    Saved,        // Save or export succeeded.
    Reject,       // Not allowed: limits, invalid names, errors.
    NewMii,       // Start from scratch, or pick a look-alike.
    Count
};
// Indexed by EditorSound.
inline constexpr const char *EditorSoundNames[] = {
    "SE_UI_BTN_IN",
    "SE_UI_BTN_IN",
    "SE_UI_BTN_OK",
    "SE_UI_TAB_OK",
    "SE_UI_TAB_OK_NONE",
    "SE_UI_RADIO_OK",
    "SE_UI_UD_LEFT",
    "SE_UI_UD_RIGHT",
    "SE_UI_PAGE_NEXT",
    "SE_UI_PAGE_PREV",
    "SE_UI_TENKEY_OK",
    "SE_UI_TENKEY_ERASE",
    "SE_UI_CTRL_WIN_POPUP",
    "SE_UI_CTRL_WIN_POPDOWN",
    "SE_UI_YESNO_POPUP",
    "SE_UI_DATA_SEND_OK",
    "SE_UI_CTRL_REJECT",
    "SE_UI_MATCH_CAPSULE_MII",
};
static_assert(std::size(EditorSoundNames) == size_t(EditorSound::Count));
} // namespace kartpad::mii
