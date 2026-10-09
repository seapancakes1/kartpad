#include "kartpad/audio/sound_archive.h"
#include "kartpad/mii/editor_sounds.h"
#include <cassert>
#include <fstream>
#include <iostream>
#include <iterator>
// Synthetic archives: one sequence sound, one bank with one instrument, one wave.
namespace {
struct Writer {
    std::vector<uint8_t> d;
    size_t Here() const { return d.size(); }
    void U8(uint32_t v) { d.push_back(uint8_t(v)); }
    void U16(uint32_t v) { U8(v >> 8); U8(v); }
    void U32(uint32_t v) { U16(v >> 16); U16(v); }
    void Tag(const char *t) { d.insert(d.end(), t, t + 4); }
    void Bytes(const std::vector<uint8_t> &b) { d.insert(d.end(), b.begin(), b.end()); }
    void Align(size_t n) { while (d.size() % n) U8(0); }
    void Put32(size_t at, uint32_t v) { for (int i = 0; i < 4; i++) d[at + i] = uint8_t(v >> (24 - 8 * i)); }
    void Ref(uint32_t offset) { U8(1); U8(0); U16(0); U32(offset); }
    void NullRef() { U32(0); U32(0); }
};
struct WaveSpec {
    uint8_t format = 1; // 0 PCM8, 1 PCM16, 2 DSP ADPCM.
    bool loop = false;
    std::vector<int16_t> pcm;          // PCM16 samples.
    std::vector<uint8_t> raw;          // PCM8 bytes or ADPCM frames.
    uint32_t loopStart = 0, loopEnd = 0; // ADPCM: nibble addresses.
};
std::vector<uint8_t> Rwav(const WaveSpec &w) {
    Writer o;
    o.Tag("RWAV"); o.U16(0xfeff); o.U16(0x0102); o.U32(0); o.U16(0x20); o.U16(2);
    o.U32(0x20); o.U32(0); o.U32(0); o.U32(0); // INFO offset/size, DATA offset/size (patched).
    size_t info = o.Here();
    o.Tag("INFO"); o.U32(0);
    // WaveInfo starts here (INFO + 8).
    uint32_t end = w.format == 2 ? w.loopEnd : uint32_t((w.format == 1 ? w.pcm.size() : w.raw.size()) - 1);
    o.U8(w.format); o.U8(w.loop); o.U8(1); o.U8(0); o.U16(32000); o.U8(0); o.U8(0);
    o.U32(w.loopStart); o.U32(end); o.U32(0x1C); o.U32(0); o.U32(0);
    o.U32(0x20);                 // Channel table -> channel info at wi+0x20.
    o.U32(0); o.U32(0x3C);       // Channel data offset, ADPCM info at wi+0x3C.
    for (int i = 0; i < 5; i++) o.U32(0);
    for (int i = 0; i < 24; i++) o.U16(0); // Zero coefficients, gain and history.
    o.Align(0x20);
    size_t data = o.Here();
    o.Put32(info + 4, uint32_t(data - info));
    o.Tag("DATA"); o.U32(0);
    if (w.format == 1) for (int16_t s : w.pcm) o.U16(uint16_t(s));
    else o.Bytes(w.raw);
    o.Align(0x20);
    o.Put32(0x10, uint32_t(info)); o.Put32(0x18, uint32_t(data)); o.Put32(8, uint32_t(o.Here()));
    return o.d;
}
std::vector<uint8_t> Rwar(const WaveSpec &w) {
    auto wav = Rwav(w);
    Writer o;
    o.Tag("RWAR"); o.U16(0xfeff); o.U16(0x0100); o.U32(0); o.U16(0x20); o.U16(2);
    o.U32(0x20); o.U32(0x20); o.U32(0x40); o.U32(0);
    o.Tag("TABL"); o.U32(0x20); o.U32(1); o.U8(1); o.U8(0); o.U16(0); o.U32(0x20); o.U32(uint32_t(wav.size()));
    o.Align(0x20);
    o.Tag("DATA"); o.U32(0); o.Align(0x20);
    o.Bytes(wav);
    return o.d;
}
std::vector<uint8_t> Rbnk(uint8_t release) {
    Writer o;
    o.Tag("RBNK"); o.U16(0xfeff); o.U16(0x0102); o.U32(0); o.U16(0x20); o.U16(1);
    o.U32(0x20); o.U32(0); o.U32(0); o.U32(0);
    o.Tag("DATA"); o.U32(0);
    o.U32(1); o.U8(1); o.U8(1); o.U16(0); o.U32(0x0C); // One direct instrument at DATA+8+0x0C.
    o.U32(0); o.U8(127); o.U8(127); o.U8(127); o.U8(release); o.U32(0);
    o.U8(60); o.U8(127); o.U8(64); o.U8(0); o.U32(0x3f800000); // Key 60, full volume, centre, tune 1.0.
    for (int i = 0; i < 7; i++) o.U32(0);
    return o.d;
}
std::vector<uint8_t> Rseq(const std::vector<uint8_t> &commands) {
    Writer o;
    o.Tag("RSEQ"); o.U16(0xfeff); o.U16(0x0100); o.U32(0); o.U16(0x20); o.U16(2);
    o.U32(0x20); o.U32(0); o.U32(0); o.U32(0);
    o.Tag("DATA"); o.U32(0); o.U32(0x0C);
    o.Bytes(commands);
    o.Align(4);
    return o.d;
}
std::vector<uint8_t> Archive(const std::vector<uint8_t> &commands, const WaveSpec &wave, uint8_t release = 127) {
    auto seq = Rseq(commands), bank = Rbnk(release), war = Rwar(wave);
    Writer o;
    o.Tag("RSAR"); o.U16(0xfeff); o.U16(0x0104); o.U32(0); o.U16(0x40); o.U16(3);
    for (int i = 0; i < 6; i++) o.U32(0);
    o.Align(0x40);
    // Symbols: string table with the sound and bank names.
    size_t symb = o.Here();
    o.Tag("SYMB"); o.U32(0);
    o.U32(4); o.U32(2); o.U32(16); o.U32(24);
    for (const char *name : {"SE_TEST", "BNK_TEST"}) { o.d.insert(o.d.end(), name, name + std::strlen(name) + 1); }
    o.Align(4);
    o.Put32(symb + 4, uint32_t(o.Here() - symb));
    // Info: refs are relative to INFO + 8.
    size_t info = o.Here();
    o.Tag("INFO"); o.U32(0);
    size_t ib = o.Here();
    for (int i = 0; i < 6; i++) o.NullRef();
    auto rel = [&] { return uint32_t(o.Here() - ib); };
    size_t refs = ib;
    // Sound table.
    o.Put32(refs + 0, 0x01000000); o.Put32(refs + 4, rel());
    o.U32(1); size_t soundRef = o.Here(); o.NullRef();
    o.Put32(soundRef, 0x01000000); o.Put32(soundRef + 4, rel());
    o.U32(0); o.U32(0); o.U32(0); o.NullRef(); o.U8(127); o.U8(64); o.U8(1); o.U8(0);
    size_t detailRef = o.Here(); o.NullRef(); o.U32(0); o.U32(0); o.U32(0);
    o.Put32(detailRef, 0x01000000); o.Put32(detailRef + 4, rel());
    o.U32(0); o.U32(0); o.U32(1); o.U32(0);
    // Bank table.
    o.Put32(refs + 8, 0x01000000); o.Put32(refs + 12, rel());
    o.U32(1); size_t bankRef = o.Here(); o.NullRef();
    o.Put32(bankRef, 0x01000000); o.Put32(bankRef + 4, rel());
    o.U32(1); o.U32(1); o.U32(0);
    // File table: file 0 is the sequence, file 1 the bank; both in group 0.
    o.Put32(refs + 0x18, 0x01000000); o.Put32(refs + 0x1C, rel());
    o.U32(2); size_t fileRefs = o.Here(); o.NullRef(); o.NullRef();
    for (uint32_t f = 0; f < 2; f++) {
        o.Put32(fileRefs + 8 * f, 0x01000000); o.Put32(fileRefs + 8 * f + 4, rel());
        o.U32(0); o.U32(0); o.U32(0xffffffff); o.NullRef();
        size_t posRef = o.Here(); o.NullRef();
        o.Put32(posRef, 0x01000000); o.Put32(posRef + 4, rel());
        o.U32(1); size_t pos = o.Here(); o.NullRef();
        o.Put32(pos, 0x01000000); o.Put32(pos + 4, rel());
        o.U32(0); o.U32(f);
    }
    // Group table.
    o.Put32(refs + 0x20, 0x01000000); o.Put32(refs + 0x24, rel());
    o.U32(1); size_t groupRef = o.Here(); o.NullRef();
    o.Put32(groupRef, 0x01000000); o.Put32(groupRef + 4, rel());
    o.U32(0); o.U32(0); o.NullRef();
    size_t groupFields = o.Here(); o.U32(0); o.U32(0); o.U32(0); o.U32(0);
    size_t itemsRef = o.Here(); o.NullRef();
    o.Put32(itemsRef, 0x01000000); o.Put32(itemsRef + 4, rel());
    o.U32(2); size_t itemRefs = o.Here(); o.NullRef(); o.NullRef();
    size_t items[2];
    for (int i = 0; i < 2; i++) {
        o.Put32(itemRefs + 8 * i, 0x01000000); o.Put32(itemRefs + 8 * i + 4, rel());
        items[i] = o.Here();
        o.U32(uint32_t(i)); o.U32(0); o.U32(0); o.U32(0); o.U32(0); o.U32(0);
    }
    o.Align(0x20);
    o.Put32(info + 4, uint32_t(o.Here() - info));
    // File data: the group's files, then its wave data.
    size_t file = o.Here();
    o.Tag("FILE"); o.U32(0); o.Align(0x20);
    size_t group = o.Here();
    o.Put32(items[0] + 4, uint32_t(o.Here() - group)); o.Put32(items[0] + 8, uint32_t(seq.size())); o.Bytes(seq);
    o.Put32(items[1] + 4, uint32_t(o.Here() - group)); o.Put32(items[1] + 8, uint32_t(bank.size())); o.Bytes(bank);
    o.Align(0x20);
    size_t waves = o.Here();
    o.Put32(items[1] + 0xC, 0); o.Put32(items[1] + 0x10, uint32_t(war.size())); o.Bytes(war);
    o.Put32(groupFields, uint32_t(group)); o.Put32(groupFields + 4, uint32_t(waves - group));
    o.Put32(groupFields + 8, uint32_t(waves)); o.Put32(groupFields + 12, uint32_t(war.size()));
    o.Put32(file + 4, uint32_t(o.Here() - file));
    o.Put32(0x08, uint32_t(o.Here()));
    o.Put32(0x10, uint32_t(symb)); o.Put32(0x14, uint32_t(info - symb));
    o.Put32(0x18, uint32_t(info)); o.Put32(0x1C, uint32_t(file - info));
    o.Put32(0x20, uint32_t(file)); o.Put32(0x24, uint32_t(o.Here() - file));
    return o.d;
}
// A looping 1 kHz square wave at 32 kHz.
WaveSpec Square() {
    WaveSpec w;
    w.loop = true;
    for (int i = 0; i < 320; i++) w.pcm.push_back(i % 32 < 16 ? 14336 : -16384);
    return w;
}
unsigned Crossings(const kartpad::audio::Pcm &pcm, double from, double to) {
    unsigned n = 0;
    size_t a = size_t(from * pcm.rate), b = std::min(size_t(to * pcm.rate), pcm.samples.size() / 2);
    for (size_t i = a + 1; i < b; i++)
        n += (pcm.samples[2 * i] >= 0) != (pcm.samples[2 * i - 2] >= 0);
    return n;
}
template <class F> bool Throws(F f) {
    try { f(); } catch (const std::invalid_argument &) { return true; }
    return false;
}
} // namespace
int main(int argc, char **argv) {
    using kartpad::audio::SoundArchive;
    // A note at the instrument's own key lasts its 48 ticks (0.5 s at 120 BPM) and keeps the pitch.
    std::vector<uint8_t> note{0x81, 0x00, 0x3c, 0x7f, 0x30, 0xff};
    auto archive = Archive(note, Square());
    SoundArchive sounds(archive);
    assert(sounds.Has("SE_TEST") && !sounds.Has("SE_MISSING") && sounds.Names().size() == 1);
    auto pcm = sounds.Render("SE_TEST");
    assert(pcm.rate == 32000 && std::abs(pcm.Seconds() - 0.5) < 0.02);
    unsigned base = Crossings(pcm, 0.1, 0.4);
    assert(base >= 590 && base <= 610); // 1 kHz: two crossings per millisecond.
    // Transposing up an octave doubles the frequency.
    SoundArchive octave(Archive({0xc3, 0x0c, 0x81, 0x00, 0x3c, 0x7f, 0x30, 0xff}, Square()));
    unsigned doubled = Crossings(octave.Render("SE_TEST"), 0.1, 0.4);
    assert(doubled >= 2 * base - 12 && doubled <= 2 * base + 12);
    // Notes play one after another, and a release tail extends past the last note.
    SoundArchive two(Archive({0x3c, 0x7f, 0x18, 0x3c, 0x7f, 0x18, 0xff}, Square()));
    assert(std::abs(two.Render("SE_TEST").Seconds() - 0.5) < 0.02);
    SoundArchive tail(Archive(note, Square(), 100));
    assert(tail.Render("SE_TEST").Seconds() > 0.55);
    // DSP ADPCM with zero coefficients decodes nibble × scale: the same square wave as PCM16.
    WaveSpec adpcm;
    adpcm.format = 2;
    adpcm.loop = true;
    for (int frame = 0; frame < 32; frame++) {
        adpcm.raw.push_back(0x0B); // Scale 2^11, coefficient pair 0.
        for (int k = 0; k < 7; k++) adpcm.raw.push_back(frame % 2 ? 0x88 : 0x77);
    }
    adpcm.loopEnd = 32 * 16 - 1;
    adpcm.loopStart = 2;
    SoundArchive dsp(Archive(note, adpcm));
    auto dspPcm = dsp.Render("SE_TEST");
    assert(std::abs(dspPcm.Seconds() - 0.5) < 0.02);
    unsigned dspCrossings = Crossings(dspPcm, 0.1, 0.4); // 14-sample half periods: about 1143 Hz.
    assert(dspCrossings >= 670 && dspCrossings <= 700);
    // PCM8 samples are signed.
    WaveSpec pcm8;
    pcm8.format = 0;
    pcm8.loop = true;
    for (int i = 0; i < 320; i++) pcm8.raw.push_back(i % 32 < 16 ? 0x70 : 0x90);
    unsigned pcm8Crossings = Crossings(SoundArchive(Archive(note, pcm8)).Render("SE_TEST"), 0.1, 0.4);
    assert(pcm8Crossings >= 590 && pcm8Crossings <= 610);
    // A false conditional skips its note; an endless loop stops at the length cap.
    SoundArchive skipped(Archive({0xf0, 0x90, 0x00, 0x00, 0x01, 0xa2, 0x3c, 0x7f, 0x30, 0xff}, Square()));
    assert(skipped.Render("SE_TEST").samples.empty());
    SoundArchive endless(Archive({0xd4, 0x00, 0x3c, 0x7f, 0x30, 0xfc, 0xff}, Square()));
    assert(std::abs(endless.Render("SE_TEST", 1.0).Seconds() - 1.0) < 0.05);
    // A sequence that never waits is rejected rather than spinning.
    assert(Throws([] { SoundArchive(Archive({0x89, 0x00, 0x00, 0x00}, Square())).Render("SE_TEST"); }));
    assert(Throws([] { SoundArchive(Archive({0x9f, 0xff}, Square())).Render("SE_TEST"); }));
    assert(Throws([&] { sounds.Render("SE_MISSING"); }));
    // Truncated and corrupted archives fail cleanly.
    for (size_t n : {size_t(0), size_t(4), size_t(0x40), archive.size() / 3, archive.size() / 2, archive.size() - 64}) {
        assert(Throws([&] { SoundArchive(std::vector<uint8_t>(archive.begin(), archive.begin() + n)).Render("SE_TEST"); }));
    }
    for (size_t offset = 0x10; offset + 4 <= archive.size(); offset += 4) {
        auto corrupt = archive;
        std::fill_n(corrupt.begin() + offset, 4, 0xff);
        try {
            SoundArchive(std::move(corrupt)).Render("SE_TEST");
        } catch (const std::invalid_argument &) {
        }
    }
    // WAV encoding: 44-byte header plus 16-bit stereo samples.
    auto wav = kartpad::audio::EncodeWave(pcm);
    assert(wav.size() == 44 + pcm.samples.size() * 2 && !std::memcmp(wav.data(), "RIFF", 4) && !std::memcmp(wav.data() + 8, "WAVE", 4));
    // Every editor sound renders from a real archive when one is given.
    if (argc > 1) {
        std::ifstream f(argv[1], std::ios::binary);
        assert(f);
        std::vector<uint8_t> d((std::istreambuf_iterator<char>(f)), {});
        SoundArchive game(d);
        for (const char *name : kartpad::mii::EditorSoundNames) {
            auto rendered = game.Render(name);
            int16_t peak = 0;
            for (int16_t s : rendered.samples) peak = std::max<int16_t>(peak, int16_t(std::abs(s)));
            assert(rendered.Seconds() > 0.05 && rendered.Seconds() < 2.5 && peak > 1000);
        }
        std::cout << "Rendered " << std::size(kartpad::mii::EditorSoundNames) << " editor sounds.\n";
    }
    std::cout << "Sound archive tests passed.\n";
}
