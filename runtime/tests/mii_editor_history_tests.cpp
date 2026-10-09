#include "kartpad/mii/editor.h"
#include <cassert>
#include <set>
#include <iostream>
int main(){using namespace kartpad::mii;
    for(unsigned field:{7,9,11,14,20,26,29,33,37,38}){auto ids=FeatureIds(field);assert(ids.size()==AppearanceFields[field].maximum+1);std::set<unsigned> unique(ids.begin(),ids.end());assert(unique.size()==ids.size());for(size_t i=0;i<ids.size();i++){auto a=Appearance::Decode(CreateDefaultMii({2,1,2,3,4,5}));a.Set(field,ids[i]);assert(Appearance::Decode(a.bytes).Get(field)==ids[i]);assert(FeaturePage(field,ids[i])==i/12);}}
    assert(BirthdayDays(0)==0&&BirthdayDays(13)==0&&BirthdayDays(2)==29);
    for(unsigned month:{4,6,9,11})assert(BirthdayDays(month)==30);
    for(unsigned month:{1,3,5,7,8,10,12})assert(BirthdayDays(month)==31);
    auto initial=Appearance::Decode(CreateDefaultMii({2,1,2,3,4,5}));auto draft=initial;DraftHistory h;
    h.Begin();for(unsigned n=0;n<9;n++){auto before=draft;draft.Set(16,n);h.Record(before,draft);}h.End();auto changed=draft;draft=h.Undo(draft);assert(draft.bytes==initial.bytes&&!h.CanUndo());draft=h.Redo(draft);assert(draft.bytes==changed.bytes);
    auto before=draft;draft.Set(17,4);h.Record(before,draft);draft=h.Undo(draft);assert(draft.bytes==changed.bytes);assert(h.CanRedo());before=draft;draft.Set(17,2);h.Record(before,draft);assert(!h.CanRedo());
    auto noop= draft;h.Record(noop,noop);draft=h.Undo(draft);assert(draft.bytes==changed.bytes);
    PreviewRevision r;auto stale=r.Next();auto current=r.Next();assert(!r.Accept(stale)&&r.Accept(current));r.Next();assert(!r.Accept(current));
    std::cout<<"Feature mappings, grouped adjustment undo/redo, branching and stale preview revisions passed.\n";
}
