#pragma once
// Independent bounds-checked reader for NW4R sound archives (.brsar) that renders sequence
// sounds (RSEQ notes played through an RBNK instrument bank and its RWAR/RWAV samples) to PCM.
// Format references: NW4R snd layouts as documented by BrawlLib/BrawlCrate; GameCube/Wii DSP ADPCM.
// This is a preview renderer: volume, pan, transpose, pitch bend, portamento, ADSR and note
// timing follow the sequence, while sweeps apply instantly and LFO, filters and effect sends are
// not modelled. Not thread-safe; render from one thread per archive.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <map>
#include <numbers>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>
namespace kartpad::audio {
struct Pcm {
    unsigned rate = 32000;
    std::vector<int16_t> samples; // Interleaved stereo.
    double Seconds() const { return samples.size() / 2.0 / rate; }
};
class SoundArchive {
    struct Reader {
        std::span<const uint8_t> data;
        void Check(size_t p, size_t n) const {
            if (p > data.size() || n > data.size() - p)
                throw std::invalid_argument("Truncated sound archive.");
        }
        uint8_t U8(size_t p) const { Check(p, 1); return data[p]; }
        int8_t S8(size_t p) const { return int8_t(U8(p)); }
        uint16_t U16(size_t p) const { Check(p, 2); return uint16_t(data[p] << 8 | data[p + 1]); }
        int16_t S16(size_t p) const { return int16_t(U16(p)); }
        uint32_t U24(size_t p) const { return uint32_t(U16(p)) << 8 | U8(p + 2); }
        uint32_t U32(size_t p) const { return uint32_t(U16(p)) << 16 | U16(p + 2); }
        float F32(size_t p) const { uint32_t v = U32(p); float f; std::memcpy(&f, &v, 4); return f; }
        void Magic(size_t p, const char *tag) const {
            Check(p, 4);
            if (std::memcmp(data.data() + p, tag, 4))
                throw std::invalid_argument(std::string("Missing ") + tag + " section.");
        }
    };
    struct Wave {
        unsigned rate = 0;
        std::vector<float> samples;
        std::optional<size_t> loop;
    };
    struct Instrument {
        size_t wave;
        uint8_t attack, decay, sustain, release, key, volume, pan;
        float tune;
    };
    struct Voice {
        uint32_t tick, length;
        int key, startKey;
        Instrument inst;
        float gain, pan, bend;
        std::array<uint8_t, 4> adsr;
        uint8_t portaTime;
    };
    struct Track {
        size_t pc = 0;
        uint32_t wait = 0;
        bool done = false, noteWait = true, portaOn = false;
        unsigned prg = 0;
        uint8_t volume = 127, volume2 = 127, pan = 64, bendRange = 2, portaTime = 0;
        int transpose = 0, bend = 0, portaKey = -1;
        std::array<int, 4> adsr{-1, -1, -1, -1};
        std::vector<size_t> calls;
        std::vector<std::pair<size_t, unsigned>> loops;
    };
    struct Sequence {
        size_t base, bankData;
        std::vector<size_t> waves;
        double tempo = 120, timebase = 48;
        // NW4R sequence variables are 16-bit (SeqSoundHandle::WriteVariable takes an s16).
        std::map<unsigned, int16_t> variables;
        bool flag = true;
        std::vector<Voice> voices;
    };

    std::vector<uint8_t> owned;
    Reader r;
    size_t infoBase = 0;
    std::map<std::string, size_t, std::less<>> sounds;
    mutable std::map<size_t, Wave> waves;

    std::optional<size_t> Ref(size_t p) const {
        if (!r.U8(p))
            return std::nullopt;
        return infoBase + r.U32(p + 4);
    }
    size_t Required(size_t p) const {
        auto v = Ref(p);
        if (!v)
            throw std::invalid_argument("Missing sound archive reference.");
        return *v;
    }
    std::vector<size_t> Table(size_t p, size_t limit) const {
        uint32_t n = r.U32(p);
        if (n > limit)
            throw std::invalid_argument("Sound archive table too large.");
        std::vector<size_t> out;
        for (uint32_t i = 0; i < n; i++)
            out.push_back(Required(p + 4 + 8 * i));
        return out;
    }
    // A file's data and wave-data offsets, from the first group that holds it.
    std::pair<size_t, size_t> FileLocation(uint32_t file) const {
        auto files = Table(Required(infoBase + 0x18), 65536);
        if (file >= files.size())
            throw std::invalid_argument("Sound file index out of range.");
        auto positions = Table(Required(files[file] + 0x14), 1024);
        auto groups = Table(Required(infoBase + 0x20), 65536);
        for (size_t position : positions) {
            uint32_t group = r.U32(position), index = r.U32(position + 4);
            if (group >= groups.size())
                continue;
            auto items = Table(Required(groups[group] + 0x20), 65536);
            if (index >= items.size() || r.U32(items[index]) != file)
                continue;
            return {size_t(r.U32(groups[group] + 0x10)) + r.U32(items[index] + 4),
                    size_t(r.U32(groups[group] + 0x18)) + r.U32(items[index] + 0xC)};
        }
        throw std::invalid_argument("Sound file is not in any group.");
    }

    static size_t NibblesToSamples(size_t n) { return n / 16 * 14 + (n % 16 > 2 ? n % 16 - 2 : 0); }
    const Wave &DecodeWave(size_t p) const {
        if (auto found = waves.find(p); found != waves.end())
            return found->second;
        r.Magic(p, "RWAV");
        size_t info = p + r.U32(p + 0x10) + 8, data = p + r.U32(p + 0x18) + 8;
        uint8_t format = r.U8(info), looped = r.U8(info + 1);
        Wave w;
        w.rate = r.U16(info + 4);
        size_t loopStart = r.U32(info + 8), loopEnd = r.U32(info + 0xC);
        size_t channel = info + r.U32(info + r.U32(info + 0x10)); // First channel only.
        size_t samples = data + r.U32(channel);
        if (!w.rate || loopEnd > 64 * 1024 * 1024)
            throw std::invalid_argument("Unsupported sound wave.");
        if (format == 2) { // DSP ADPCM: 8-byte frames of a header byte and 14 nibbles.
            size_t count = NibblesToSamples(loopEnd + 1);
            std::array<int16_t, 16> coefs;
            size_t adpcm = info + r.U32(channel + 4);
            for (int i = 0; i < 16; i++)
                coefs[i] = r.S16(adpcm + 2 * i);
            r.Check(samples, (count + 13) / 14 * 8);
            int h1 = 0, h2 = 0;
            for (size_t frame = samples; w.samples.size() < count; frame += 8) {
                uint8_t header = r.data[frame];
                int scale = 1 << (header & 15), index = header >> 4;
                if (index > 7)
                    throw std::invalid_argument("Invalid ADPCM coefficient index.");
                for (int k = 0; k < 14 && w.samples.size() < count; k++) {
                    uint8_t byte = r.data[frame + 1 + k / 2];
                    int nibble = k % 2 ? byte & 15 : byte >> 4;
                    if (nibble >= 8)
                        nibble -= 16;
                    int v = (((nibble * scale) << 11) + 1024 + coefs[index * 2] * h1 + coefs[index * 2 + 1] * h2) >> 11;
                    v = std::clamp(v, -32768, 32767);
                    h2 = h1;
                    h1 = v;
                    w.samples.push_back(v / 32768.f);
                }
            }
            loopStart = NibblesToSamples(loopStart);
        } else if (format == 1) {
            r.Check(samples, (loopEnd + 1) * 2);
            for (size_t i = 0; i <= loopEnd; i++)
                w.samples.push_back(r.S16(samples + 2 * i) / 32768.f);
        } else if (format == 0) {
            r.Check(samples, loopEnd + 1);
            for (size_t i = 0; i <= loopEnd; i++)
                w.samples.push_back(r.S8(samples + i) / 128.f);
        } else
            throw std::invalid_argument("Unsupported sound wave format.");
        if (looped && loopStart + 1 < w.samples.size())
            w.loop = loopStart;
        return waves.emplace(p, std::move(w)).first->second;
    }

    // Instrument references: 1 is a parameter block, 2 a key-range split, 3 a key-indexed table.
    std::optional<Instrument> Resolve(const Sequence &s, size_t ref, int key, int depth) const {
        if (depth > 4)
            return std::nullopt;
        uint8_t kind = r.U8(ref + 1);
        size_t p = s.bankData + r.U32(ref + 4);
        if (kind == 1) {
            int32_t wave = int32_t(r.U32(p));
            float tune = r.F32(p + 0x10);
            if (wave < 0 || size_t(wave) >= s.waves.size() || !std::isfinite(tune) || tune <= 0 || tune > 16)
                return std::nullopt;
            return Instrument{s.waves[wave], r.U8(p + 4), r.U8(p + 5), r.U8(p + 6), r.U8(p + 7),
                              r.U8(p + 0xC), r.U8(p + 0xD), r.U8(p + 0xE), tune};
        }
        if (kind == 2) {
            unsigned n = r.U8(p);
            size_t refs = p + ((1 + n + 3) & ~size_t(3));
            for (unsigned i = 0; i < n; i++)
                if (key <= r.U8(p + 1 + i))
                    return Resolve(s, refs + 8 * i, key, depth + 1);
        }
        if (kind == 3) {
            int low = r.U8(p), high = r.U8(p + 1);
            if (key >= low && key <= high)
                return Resolve(s, p + 4 + 8 * (key - low), key, depth + 1);
        }
        return std::nullopt;
    }

    static double EnvelopeTime(int v, double longest) { return std::pow((127 - v) / 127.0, 2) * longest; }
    static float Curve(int v) { return float(v * v) / (127 * 127); }

    void NoteOn(Sequence &s, Track &t, uint32_t tick, int key, int velocity, uint32_t length) const {
        int k = std::clamp(key + t.transpose, 0, 127);
        if (t.prg >= r.U32(s.bankData) || s.voices.size() >= 1024)
            return;
        auto inst = Resolve(s, s.bankData + 4 + 8 * t.prg, k, 0);
        if (!inst)
            return;
        std::array<uint8_t, 4> adsr{inst->attack, inst->decay, inst->sustain, inst->release};
        for (int i = 0; i < 4; i++)
            if (t.adsr[i] >= 0)
                adsr[i] = uint8_t(t.adsr[i]);
        int start = t.portaOn && t.portaKey >= 0 ? t.portaKey : k;
        s.voices.push_back({tick, length, k, start, *inst,
                            Curve(velocity) * Curve(t.volume) * Curve(t.volume2) * Curve(inst->volume),
                            (t.pan - 64) / 64.f + (inst->pan - 64) / 64.f, t.bend / 128.f * t.bendRange, adsr,
                            t.portaTime});
        t.portaKey = t.portaOn ? k : -1;
        if (t.portaOn && !t.portaTime)
            t.portaOn = false;
    }

    static int16_t Wrap16(int v) { return int16_t(uint16_t(unsigned(v))); }

    static uint32_t VarLen(const Reader &r, size_t &p) {
        uint32_t v = 0;
        for (int i = 0; i < 4; i++) {
            uint8_t b = r.U8(p++);
            v = v << 7 | (b & 127);
            if (!(b & 128))
                return v;
        }
        throw std::invalid_argument("Invalid sequence length.");
    }

    // Runs one command. Prefixes: A0 random (last argument becomes a range), A1 variable (last
    // argument names a variable), A2 conditional, A3-A5 sweep time (consumed, applied instantly).
    void Step(Sequence &s, std::map<unsigned, Track> &tracks, Track &t, uint32_t tick) const {
        size_t p = t.pc;
        uint8_t op = r.U8(p++);
        int prefix = 0;
        if (op >= 0xA0 && op <= 0xA5) {
            prefix = op;
            op = r.U8(p++);
        }
        bool skip = prefix == 0xA2 && !s.flag;
        auto last = [&](auto normal) -> int {
            int v;
            if (prefix == 0xA0) {
                int low = r.S16(p), high = r.S16(p + 2);
                p += 4;
                v = (low + high) / 2;
            } else if (prefix == 0xA1) {
                auto found = s.variables.find(r.U8(p++));
                v = found == s.variables.end() ? 0 : found->second;
            } else
                v = normal();
            p += prefix == 0xA3 ? 2 : prefix == 0xA4 ? 4 : prefix == 0xA5 ? 1 : 0;
            return v;
        };
        auto u8 = [&] { return int(r.U8(p++)); };
        auto s8 = [&] { return int(r.S8(p++)); };
        auto s16 = [&] { int v = r.S16(p); p += 2; return v; };
        auto var = [&] { return int(VarLen(r, p)); };
        auto jump = [&](uint32_t offset) {
            r.Check(s.base + offset, 1);
            return s.base + offset;
        };
        if (op < 0x80) {
            int velocity = u8();
            uint32_t length = uint32_t(std::max(0, last(var)));
            if (!skip) {
                NoteOn(s, t, tick, op, velocity, length);
                if (t.noteWait)
                    t.wait = length;
            }
        } else if (op == 0x80 || op == 0x81) {
            int v = std::max(0, last(var));
            if (!skip && op == 0x80)
                t.wait = uint32_t(v);
            if (!skip && op == 0x81)
                t.prg = unsigned(v);
        } else if (op == 0x88) {
            unsigned n = unsigned(u8());
            uint32_t offset = r.U24(p);
            p += 3;
            if (!skip && n < 16) {
                Track child;
                child.pc = jump(offset);
                tracks[n] = child;
            }
        } else if (op == 0x89 || op == 0x8A) {
            uint32_t offset = r.U24(p);
            p += 3;
            if (!skip) {
                if (op == 0x8A) {
                    if (t.calls.size() >= 8)
                        throw std::invalid_argument("Sequence calls nest too deeply.");
                    t.calls.push_back(p);
                }
                p = jump(offset);
            }
        } else if (op >= 0xB0 && op <= 0xDF) {
            int v = last([&] { return op == 0xC3 || op == 0xC4 ? s8() : u8(); });
            if (!skip)
                switch (op) {
                case 0xB0: s.timebase = std::max(1, v); break;
                case 0xC0: t.pan = uint8_t(v); break;
                case 0xC1: t.volume = uint8_t(std::clamp(v, 0, 127)); break;
                case 0xC3: t.transpose = v; break;
                case 0xC4: t.bend = v; break;
                case 0xC5: t.bendRange = uint8_t(v); break;
                case 0xC7: t.noteWait = v != 0; break;
                case 0xC9: t.portaKey = v; t.portaOn = true; break;
                case 0xCE: t.portaOn = v != 0; break;
                case 0xCF: t.portaTime = uint8_t(v); break;
                case 0xD0: case 0xD1: case 0xD2: case 0xD3: t.adsr[op - 0xD0] = std::clamp(v, 0, 127); break;
                case 0xD4:
                    if (t.loops.size() >= 8)
                        throw std::invalid_argument("Sequence loops nest too deeply.");
                    t.loops.push_back({p, unsigned(v)});
                    break;
                case 0xD5: t.volume2 = uint8_t(std::clamp(v, 0, 127)); break;
                }
        } else if (op >= 0xE0 && op <= 0xE3) {
            int v = last(s16);
            if (!skip && op == 0xE1)
                s.tempo = std::max(1, v);
        } else if (op == 0xF0) {
            int sub = u8();
            unsigned index = unsigned(u8());
            int v = last(s16);
            if (sub < 0x80 || sub > 0x95)
                throw std::invalid_argument("Unsupported sequence command.");
            // As on the Wii, the operands are 16-bit, the arithmetic is done in int (where two
            // 16-bit values can't overflow, and -32768 / -1 is 32768) and the result wraps back to
            // 16 bits. Dividing by zero leaves the variable unchanged.
            v = Wrap16(v);
            const int current = s.variables.count(index) ? s.variables[index] : 0;
            if (!skip) {
                if (sub == 0x80) s.variables[index] = int16_t(v);
                else if (sub == 0x81) s.variables[index] = Wrap16(current + v);
                else if (sub == 0x82) s.variables[index] = Wrap16(current - v);
                else if (sub == 0x83) s.variables[index] = Wrap16(current * v);
                else if (sub == 0x84 && v) s.variables[index] = Wrap16(current / v);
                else if (sub >= 0x90) {
                    const bool result[] = {current == v, current >= v, current > v, current <= v, current < v, current != v};
                    s.flag = result[sub - 0x90];
                }
            }
        } else if (op == 0xFC) {
            if (!skip && !t.loops.empty()) {
                auto &loop = t.loops.back();
                if (loop.second == 0) // Endless; the render length cap ends it.
                    p = loop.first;
                else if (--loop.second > 0)
                    p = loop.first;
                else
                    t.loops.pop_back();
            }
        } else if (op == 0xFD) {
            if (!skip) {
                if (t.calls.empty())
                    throw std::invalid_argument("Sequence returns without a call.");
                p = t.calls.back();
                t.calls.pop_back();
            }
        } else if (op == 0xFE) {
            p += 2;
        } else if (op == 0xFF) {
            if (!skip)
                t.done = true;
        } else
            throw std::invalid_argument("Unsupported sequence command.");
        t.pc = p;
    }

    void Mix(const Sequence &s, std::vector<float> &left, std::vector<float> &right, unsigned rate, double cap) const {
        double secondsPerTick = 60 / s.tempo / s.timebase;
        size_t limit = size_t((cap + 3) * rate);
        for (const auto &v : s.voices) {
            const Wave &w = DecodeWave(v.inst.wave);
            if (w.samples.size() < 2)
                continue;
            double attack = EnvelopeTime(v.adsr[0], 1), decay = EnvelopeTime(v.adsr[1], 3);
            double release = EnvelopeTime(v.adsr[3], 3), sustain = Curve(v.adsr[2]);
            double on = v.tick * secondsPerTick, duration = v.length * secondsPerTick;
            if (!v.length) // A zero-length note plays a one-shot sample out; looped samples ring for 1 s.
                duration = w.loop ? 1.0 : 1e9;
            double glide = v.portaTime ? v.portaTime * 0.01 : duration;
            float pan = std::clamp(v.pan, -1.f, 1.f);
            float gainLeft = std::cos((pan + 1) * std::numbers::pi_v<float> / 4) * v.gain, gainRight = std::sin((pan + 1) * std::numbers::pi_v<float> / 4) * v.gain;
            size_t start = size_t(on * rate);
            double position = 0;
            for (size_t i = 0; start + i < limit; i++) {
                double time = double(i) / rate;
                if (time >= duration + release)
                    break;
                double key = v.key + v.bend;
                if (v.startKey != v.key && time < glide)
                    key = v.startKey + (v.key - v.startKey) * time / glide + v.bend;
                double step = double(w.rate) / rate * v.inst.tune * std::pow(2.0, (key - v.inst.key) / 12);
                size_t index = size_t(position);
                if (index + 1 >= w.samples.size()) {
                    if (!w.loop)
                        break;
                    position -= double(w.samples.size() - 1 - *w.loop);
                    index = size_t(position);
                    if (index + 1 >= w.samples.size())
                        break;
                }
                double x = w.samples[index] + (w.samples[index + 1] - w.samples[index]) * (position - index);
                position += step;
                double envelope = time < attack ? time / attack
                                  : time < attack + decay ? 1 - (1 - sustain) * (time - attack) / decay
                                                          : sustain;
                if (time >= duration)
                    envelope *= release > 0 ? std::max(0.0, 1 - (time - duration) / release) : 0;
                size_t j = start + i;
                if (j >= left.size()) {
                    left.resize(j + 1);
                    right.resize(j + 1);
                }
                left[j] += float(x * envelope) * gainLeft;
                right[j] += float(x * envelope) * gainRight;
            }
        }
    }

    void Parse(std::span<const uint8_t> data) {
        r.data = data;
        r.Magic(0, "RSAR");
        size_t symbols = r.U32(0x10), info = r.U32(0x18);
        r.Magic(symbols, "SYMB");
        r.Magic(info, "INFO");
        size_t base = symbols + 8, strings = base + r.U32(base);
        uint32_t stringCount = r.U32(strings);
        if (stringCount > 1 << 20)
            throw std::invalid_argument("Sound archive table too large.");
        infoBase = info + 8;
        for (size_t entry : Table(Required(infoBase), 1 << 20)) {
            uint32_t id = r.U32(entry);
            if (id >= stringCount)
                continue;
            size_t name = base + r.U32(strings + 4 + 4 * id), end = name;
            while (r.U8(end))
                end++;
            sounds.emplace(std::string(reinterpret_cast<const char *>(r.data.data() + name), end - name), entry);
        }
    }

  public:
    // Takes ownership of a buffer; use the span overload to read memory the caller keeps alive.
    explicit SoundArchive(std::vector<uint8_t> &&data) : owned(std::move(data)) { Parse(owned); }
    explicit SoundArchive(std::span<const uint8_t> view) { Parse(view); }
    SoundArchive(const SoundArchive &) = delete;
    SoundArchive &operator=(const SoundArchive &) = delete;
    bool Has(std::string_view name) const { return sounds.find(name) != sounds.end(); }
    std::vector<std::string> Names() const {
        std::vector<std::string> out;
        for (const auto &entry : sounds)
            out.push_back(entry.first);
        return out;
    }
    // Renders a sequence sound. Endless sequences stop after maxSeconds of sequence time; the
    // result is trimmed of trailing silence and only scaled down if it would clip.
    Pcm Render(std::string_view name, double maxSeconds = 4, unsigned rate = 32000) const {
        auto found = sounds.find(name);
        if (found == sounds.end())
            throw std::invalid_argument("Unknown sound.");
        size_t entry = found->second;
        if (r.U8(entry + 0x16) != 1)
            throw std::invalid_argument("Only sequence sounds can be rendered.");
        size_t detail = Required(entry + 0x18);
        uint32_t offset = r.U32(detail), bank = r.U32(detail + 4);
        size_t sequenceFile = FileLocation(r.U32(entry + 4)).first;
        r.Magic(sequenceFile, "RSEQ");
        size_t sequenceData = sequenceFile + r.U32(sequenceFile + 0x10);
        r.Magic(sequenceData, "DATA");
        Sequence s;
        s.base = sequenceData + r.U32(sequenceData + 8);
        auto banks = Table(Required(infoBase + 8), 4096);
        if (bank >= banks.size())
            throw std::invalid_argument("Sound bank index out of range.");
        auto [bankFile, waveArchive] = FileLocation(r.U32(banks[bank] + 4));
        r.Magic(bankFile, "RBNK");
        s.bankData = bankFile + r.U32(bankFile + 0x10);
        r.Magic(s.bankData, "DATA");
        s.bankData += 8;
        r.Magic(waveArchive, "RWAR");
        size_t table = waveArchive + r.U32(waveArchive + 0x10), waveData = waveArchive + r.U32(waveArchive + 0x18);
        r.Magic(table, "TABL");
        uint32_t waveCount = r.U32(table + 8);
        if (waveCount > 65536)
            throw std::invalid_argument("Sound archive table too large.");
        for (uint32_t i = 0; i < waveCount; i++)
            s.waves.push_back(waveData + r.U32(table + 0xC + 12 * i + 4));

        std::map<unsigned, Track> tracks;
        tracks[0].pc = s.base + offset;
        r.Check(tracks[0].pc, 1);
        for (uint32_t tick = 0; tick * 60 / s.tempo / s.timebase < maxSeconds; tick++) {
            bool running = false;
            for (auto &[index, track] : tracks) {
                for (int budget = 0; !track.done && !track.wait; budget++) {
                    if (budget > 4096)
                        throw std::invalid_argument("Sequence does not advance.");
                    Step(s, tracks, track, tick);
                }
                if (track.wait)
                    track.wait--;
                running |= !track.done;
            }
            if (!running)
                break;
        }

        std::vector<float> left, right;
        Mix(s, left, right, rate, maxSeconds);
        float peak = 0;
        for (size_t i = 0; i < left.size(); i++)
            peak = std::max({peak, std::abs(left[i]), std::abs(right[i])});
        size_t end = left.size();
        while (end && std::abs(left[end - 1]) <= peak * 1e-4f && std::abs(right[end - 1]) <= peak * 1e-4f)
            end--;
        float gain = peak > .95f ? .95f / peak : 1;
        Pcm out;
        out.rate = rate;
        out.samples.reserve(end * 2);
        for (size_t i = 0; i < end; i++) {
            out.samples.push_back(int16_t(std::lround(std::clamp(left[i] * gain, -1.f, 1.f) * 32767)));
            out.samples.push_back(int16_t(std::lround(std::clamp(right[i] * gain, -1.f, 1.f) * 32767)));
        }
        return out;
    }
};
// A 16-bit stereo RIFF/WAVE file for platform players.
inline std::vector<uint8_t> EncodeWave(const Pcm &pcm) {
    std::vector<uint8_t> out;
    auto u16 = [&](uint32_t v) { out.push_back(uint8_t(v)); out.push_back(uint8_t(v >> 8)); };
    auto u32 = [&](uint32_t v) { u16(v & 0xffff); u16(v >> 16); };
    auto tag = [&](const char *t) { out.insert(out.end(), t, t + 4); };
    uint32_t bytes = uint32_t(pcm.samples.size() * 2);
    tag("RIFF"); u32(36 + bytes); tag("WAVE");
    tag("fmt "); u32(16); u16(1); u16(2); u32(pcm.rate); u32(pcm.rate * 4); u16(4); u16(16);
    tag("data"); u32(bytes);
    for (int16_t s : pcm.samples)
        u16(uint16_t(s));
    return out;
}
} // namespace kartpad::audio
