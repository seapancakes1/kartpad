#include "kartpad/mii/editor.h"
#include <cassert>
#include <set>
#include <iostream>
int main(){using namespace kartpad::mii;
    for(unsigned field:{7,9,11,14,20,26,29,33,37,38}){
        auto ids=FeatureIds(field);assert(ids.size()==AppearanceFields[field].maximum+1);
        std::set<unsigned> unique(ids.begin(),ids.end());assert(unique.size()==ids.size());
        for(size_t i=0;i<ids.size();i++){
            auto a=Appearance::Decode(CreateDefaultMii({2,1,2,3,4,5}));a.Set(field,ids[i]);
            assert(Appearance::Decode(a.bytes).Get(field)==ids[i]);assert(FeaturePage(field,ids[i])==i/12);
        }
    }
    // Mii Channel order spot checks: first tile of each page, and the last hair tile.
    assert(FeatureIds(11)[0]==33&&FeatureIds(11)[12]==32&&FeatureIds(11)[71]==29&&FeaturePage(11,0)==4);
    assert(FeatureIds(14)[0]==2&&FeatureIds(14)[47]==47&&FeatureIds(20)[0]==6&&FeatureIds(26)[0]==1&&FeatureIds(29)[0]==23);
    assert(BirthdayDays(0)==0&&BirthdayDays(13)==0&&BirthdayDays(2)==29);
    for(unsigned month:{4,6,9,11})assert(BirthdayDays(month)==30);
    for(unsigned month:{1,3,5,7,8,10,12})assert(BirthdayDays(month)==31);
    auto initial=Appearance::Decode(CreateDefaultMii({2,1,2,3,4,5}));auto draft=initial;DraftHistory h;
    h.Begin();for(unsigned n=0;n<9;n++){auto before=draft;draft.Set(16,n);h.Record(before,draft);}h.End();
    auto changed=draft;draft=h.Undo(draft);assert(draft.bytes==initial.bytes&&!h.CanUndo());draft=h.Redo(draft);
    assert(draft.bytes==changed.bytes);
    auto before=draft;draft.Set(17,4);h.Record(before,draft);draft=h.Undo(draft);assert(draft.bytes==changed.bytes);
    assert(h.CanRedo());before=draft;draft.Set(17,2);h.Record(before,draft);assert(!h.CanRedo());
    auto noop= draft;h.Record(noop,noop);draft=h.Undo(draft);assert(draft.bytes==changed.bytes);
    PreviewRevision r;auto stale=r.Next();auto current=r.Next();assert(!r.Accept(stale)&&r.Accept(current));r.Next();
    assert(!r.Accept(current));
    // Look-alikes keep the draft's identity and names, are valid, repeat per seed and vary across seeds.
    std::set<std::vector<uint8_t>> faces;
    for(unsigned gender:{0u,1u})
        for(uint32_t seed=0;seed<200;seed++){
            auto face=LookAlike(initial,gender,seed);assert(face.Validate().ok&&face.Get(0)==gender);
        assert(face.Get(1)==initial.Get(1)&&face.Get(2)==initial.Get(2)
            &&std::equal(face.bytes.begin()+2,face.bytes.begin()+22,initial.bytes.begin()+2)
            &&std::equal(face.bytes.begin()+24,face.bytes.begin()+32,initial.bytes.begin()+24)
            &&std::equal(face.bytes.begin()+54,face.bytes.end(),initial.bytes.begin()+54));
        assert(LookAlike(initial,gender,seed).bytes==face.bytes);if(gender)assert(face.Get(37)==0&&face.Get(38)==0);
        faces.insert({face.bytes.begin(),face.bytes.end()});}
    assert(faces.size()>380);
    std::cout<<"Feature mappings, grouped adjustment undo/redo, branching, stale preview revisions and look-alikes passed.\n";
}
