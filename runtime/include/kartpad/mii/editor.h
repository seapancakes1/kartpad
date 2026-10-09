#pragma once
#include "appearance.h"
#include <vector>
namespace kartpad::mii {
inline constexpr unsigned BirthdayDays(unsigned month) {
    constexpr unsigned days[]={0,31,29,31,30,31,30,31,31,30,31,30,31};
    return month<=12?days[month]:0;
}
enum class EditorCategory { Profile, Body, Face, Hair, Eyebrows, Eyes, Nose, Mouth, FacialHair, Glasses };
inline constexpr std::array<const char *, 10> EditorCategories = {
    "Profile", "Body", "Face", "Hair", "Eyebrows", "Eyes", "Nose", "Mouth", "Facial hair", "Glasses"};
inline constexpr std::array<unsigned, 46> EditorFieldCategories = {
    0,0,0,0,0,1,1,2,2,2,0,3,3,3,5,5,5,5,5,5,4,4,4,4,4,4,6,6,6,7,7,7,7,9,9,9,9,8,8,8,8,8,8,8,8,8};
// Tile IDs are explicit. Presentation and persistence never share an implicit index.
inline std::vector<unsigned> FeatureIds(unsigned field) {
    switch (field) {
    case 7: return {0,1,2,3,4,5,6,7};
    case 9: return {0,1,2,3,4,5,6,7,8,9,10,11};
    case 11: return {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,64,65,66,67,68,69,70,71};
    case 14: return {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47};
    case 20: case 29: return {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23};
    case 26: return {0,1,2,3,4,5,6,7,8,9,10,11};
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
    Appearance Undo(const Appearance& current){End();if(!CanUndo())return current;redo_.push_back(current);auto out=undo_.back();undo_.pop_back();return out;}
    Appearance Redo(const Appearance& current){End();if(!CanRedo())return current;undo_.push_back(current);auto out=redo_.back();redo_.pop_back();return out;}
};
struct PreviewRevision {
    uint64_t current=0;
    uint64_t Next(){return ++current;}
    bool Accept(uint64_t revision)const{return current==revision;}
};
} // namespace kartpad::mii
