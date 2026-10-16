#pragma once
#include "appearance.h"
#include <random>
#include <vector>
namespace kartpad::mii {
inline constexpr unsigned BirthdayDays(unsigned month) {
    constexpr unsigned days[]={0,31,29,31,30,31,30,31,31,30,31,30,31};
    return month<=12?days[month]:0;
}
inline constexpr std::array<const char *, 10> EditorCategories = {
    "Profile", "Body", "Face", "Hair", "Eyebrows", "Eyes", "Nose", "Mouth", "Facial hair", "Glasses"};
// Tile IDs are explicit. Presentation and persistence never share an implicit index.
// Lists run in Mii Channel order: page by page, rows left to right, 12 tiles per page.
// Hair, eyebrows, eyes, nose and mouth IDs are not sequential on the Wii; face shape, face
// details, glasses and facial hair are. Orders as documented by MiiJS's Mii Channel page tables
// (https://github.com/Stewared/MiiJS, data.js lookupTables.pages).
inline std::vector<unsigned> FeatureIds(unsigned field) {
    switch (field) {
    case 7: return {0,1,2,3,4,5,6,7};
    case 9: return {0,1,2,3,4,5,6,7,8,9,10,11};
    case 11: return {33,40,51,44,39,70,45,49,59,56,68,31, 32,47,37,48,66,52,58,50,55,64,60,62,
                     43,38,42,23,67,54,36,41,65,30,57,34, 12,13,69,26,4,25,1,19,5,8,27,7,
                     14,3,22,10,6,20,11,63,17,35,21,0, 61,16,46,9,18,2,28,53,71,24,15,29};
    case 14: return {2,4,0,8,39,17,1,26,16,15,27,20, 33,11,19,32,9,12,23,34,21,25,40,35,
                     5,41,13,36,37,6,24,30,31,18,28,46, 7,44,38,42,45,29,3,43,22,10,14,47};
    case 20: return {6,0,12,1,9,19,7,21,8,17,5,4, 11,10,2,3,14,20,15,13,22,18,16,23};
    case 26: return {1,10,2,3,6,0,5,4,8,9,7,11};
    case 29: return {23,1,18,21,22,5,0,8,10,16,6,13, 7,9,2,11,3,4,15,17,20,19,14,12};
    case 33: return {0,1,2,3,4,5,6,7,8};
    case 37: case 38: return {0,1,2,3};
    default: return {};
    }
}
inline constexpr std::array<unsigned,10> PrimaryFeatures = {0,0,7,11,20,14,26,29,37,33};
inline unsigned FeaturePage(unsigned field, unsigned value) {
    auto ids=FeatureIds(field); auto found=std::find(ids.begin(),ids.end(),value);
    return found==ids.end()?0:unsigned(found-ids.begin())/12;
}
// How each feature category edits (Face 2 … Glasses 9, EditorCategories order), as the Apple editor
// lays it out: its colour field, the two grids a two-part switch names, its on/off toggle, and its
// adjustments, each spelling out both directions for screen readers and tooltips.
struct EditorMode { unsigned field; const char *title; };
struct EditorAdjustment { unsigned field; const char *title, *less, *more; };
inline constexpr unsigned NoField = 99;
inline unsigned CategoryColorField(unsigned category) {
    switch (category) {
    case 2: return 8; case 3: return 12; case 4: return 22; case 5: return 17;
    case 7: return 30; case 8: return 39; case 9: return 34; default: return NoField;
    }
}
inline std::vector<EditorMode> CategoryModes(unsigned category) {
    if (category == 2) return {{7, "Shape"}, {9, "Details"}};
    if (category == 8) return {{37, "Mustache"}, {38, "Beard"}};
    return {};
}
// Flip hair (Hair) and Mole (Facial hair); NoField elsewhere.
inline unsigned CategoryToggleField(unsigned category) { return category == 3 ? 13 : category == 8 ? 42 : NoField; }
inline const char *CategoryToggleTitle(unsigned category) { return category == 3 ? "Flip hair" : category == 8 ? "Mole" : ""; }
inline std::vector<EditorAdjustment> CategoryAdjustments(unsigned category, const Appearance &a) {
    const char *up = "Move up", *down = "Move down", *smaller = "Smaller", *larger = "Larger";
    const char *tiltDown = "Tilt outer ends down", *tiltUp = "Tilt outer ends up";
    switch (category) {
    case 4: return {{24, "Position", up, down}, {23, "Size", smaller, larger}, {21, "Tilt", tiltDown, tiltUp},
                    {25, "Spacing", "Closer together", "Farther apart"}};
    case 5: return {{16, "Position", up, down}, {18, "Size", smaller, larger}, {15, "Tilt", tiltDown, tiltUp},
                    {19, "Spacing", "Closer together", "Farther apart"}};
    case 6: return {{28, "Position", up, down}, {27, "Size", smaller, larger}};
    case 7: return {{32, "Position", up, down}, {31, "Size", smaller, larger}};
    case 8: return a.Get(42) ? std::vector<EditorAdjustment>{{44, "Mole position", up, down}, {43, "Mole size", smaller, larger},
                                                             {45, "Mole sideways", "Move left", "Move right"}}
                             : std::vector<EditorAdjustment>{{41, "Position", up, down}, {40, "Size", smaller, larger}};
    case 9: return {{36, "Position", up, down}, {35, "Size", smaller, larger}};
    default: return {};
    }
}
class DraftHistory {
    std::vector<Appearance> undo_, redo_;
    bool grouping_=false, captured_=false;
public:
    void Begin(){grouping_=true; captured_=false;}
    void End(){grouping_=false; captured_=false;}
    void Record(const Appearance& before,const Appearance& after){
        if(before.bytes==after.bytes)return;
        if(!grouping_ || !captured_){undo_.push_back(before);if(undo_.size()>200)undo_.erase(undo_.begin());captured_=true;}
        redo_.clear();
    }
    bool CanUndo()const{return !undo_.empty();} bool CanRedo()const{return !redo_.empty();}
    Appearance Undo(const Appearance& current){
        End();if(!CanUndo())return current;redo_.push_back(current);auto out=undo_.back();undo_.pop_back();return out;
    }
    Appearance Redo(const Appearance& current){
        End();if(!CanRedo())return current;undo_.push_back(current);auto out=redo_.back();redo_.pop_back();return out;
    }
};
struct PreviewRevision {
    uint64_t current=0;
    uint64_t Next(){return ++current;}
    bool Accept(uint64_t revision)const{return current==revision;}
};
// Create Mii's look-alikes, like the Mii Channel's "Choose a Look-Alike": random faces built on a
// draft (its identity, names and birthday stay). RFL's own random tables are not documented, so
// parts are drawn from the Mii Channel lists: eyes, eyebrows and mouths from their first pages,
// where the everyday expressions are. Hair follows the split the defaults suggest (male
// starts on page 1, female on page 4) with some crossover. Positions, sizes and spacing keep their
// defaults so every face stays tidy. One seed always gives the same face.
inline Appearance LookAlike(const Appearance& base, unsigned gender, uint32_t seed) {
    std::mt19937 rng(seed);
    auto pick=[&](unsigned lo,unsigned hi){return std::uniform_int_distribution<unsigned>(lo,hi)(rng);};
    auto chance=[&](unsigned percent){return pick(0,99)<percent;};
    auto from=[&](unsigned field,unsigned first,unsigned last){return FeatureIds(field)[pick(first,last)];};
    Appearance a=base;
    a.Set(0,gender);
    a.Set(3,pick(0,11));
    a.Set(5,pick(40,88));a.Set(6,pick(40,88));
    a.Set(7,pick(0,7));a.Set(8,pick(0,5));a.Set(9,chance(10)?pick(1,11):0);
    bool usual=!chance(15);
    a.Set(11,(gender==0)==usual?from(11,0,35):from(11,36,71));
    unsigned hair=chance(70)?pick(0,3):pick(4,7);
    a.Set(12,hair);a.Set(13,chance(50));
    a.Set(14,from(14,0,17));a.Set(17,pick(0,5));
    a.Set(20,from(20,0,11));a.Set(22,hair);
    a.Set(26,from(26,0,11));
    a.Set(29,from(29,0,11));a.Set(30,pick(0,2));
    a.Set(33,chance(15)?pick(1,8):0);a.Set(34,pick(0,5));
    bool beard=gender==0&&chance(30);
    a.Set(37,beard&&chance(60)?pick(1,3):0);a.Set(38,beard&&chance(50)?pick(1,3):0);a.Set(39,hair);
    a.Set(42,chance(8));
    return a;
}
} // namespace kartpad::mii
