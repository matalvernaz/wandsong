// audio_bridge: positioned sound for Wandsong, as a Lua C module.
//
// XAudio2 + X3DAudio (built into Windows 10+). The mod tells it where the player is and which
// way they face; every sound has a world position, and X3DAudio works out the panning. Sounds
// behind the listener are muffled and pitched slightly down, so front and back are easy to
// tell apart with stereo headphones. XAudio2 mixes on its own thread; nothing here touches the
// game, and every call is cheap.
//
// Coordinates are Unreal's: centimetres, X forward, Y right, Z up.
//
// Lua API:
//   audio.init() -> ok, message
//   audio.listener(x, y, z, fx, fy, fz)          position and facing (forward vector)
//   audio.play(name, x, y, z [, volume [, pitch]]) -> ok      one-shot at a world position
//   audio.play_ui(name [, volume [, pitch]])                 one-shot, centred, no position
//   audio.loop(id, name, x, y, z [, volume [, pitch]])       start or move a continuous sound
//   audio.stop(id)                                           stop a continuous sound
//   audio.stop_all()                                         every sound, at once
//   audio.playing() -> n                                     one-shot voices still holding a sound
//   audio.sounds() -> { names }
//
// Built-in synthesized sounds: ping, tick, chime, arrive, wall, opening, door, person, item,
// enemy, warn, step_blocked, ledge, hop, climb, note, hum.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <xaudio2.h>
#include <x3daudio.h>

#include <cmath>
#include <map>
#include <string>
#include <vector>

extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

namespace {

constexpr UINT32 kRate = 44100;
constexpr int kOneShotVoices = 24;
constexpr float kPi = 3.14159265f;
// Distance (cm) at which a sound is at full volume; it fades beyond this.
constexpr float kNearCm = 150.0f;
constexpr float kFarCm = 6000.0f;

struct Sound {
    std::vector<int16_t> pcm;
    bool loops = false;
};

IXAudio2* g_xa = nullptr;
IXAudio2MasteringVoice* g_master = nullptr;
X3DAUDIO_HANDLE g_x3d;
UINT32 g_channels = 2;
DWORD g_channel_mask = 0;
bool g_ready = false;

std::map<std::string, Sound> g_sounds;

X3DAUDIO_LISTENER g_listener = {};
float g_lx = 0, g_ly = 0, g_lz = 0, g_fx = 1, g_fy = 0, g_fz = 0;

struct Voice {
    IXAudio2SourceVoice* src = nullptr;
    bool busy_loop = false;  // owned by a looping id
};
std::vector<Voice> g_oneshots;
std::map<std::string, Voice> g_loops;

WAVEFORMATEX mono_format() {
    WAVEFORMATEX f = {};
    f.wFormatTag = WAVE_FORMAT_PCM;
    f.nChannels = 1;
    f.nSamplesPerSec = kRate;
    f.wBitsPerSample = 16;
    f.nBlockAlign = 2;
    f.nAvgBytesPerSec = kRate * 2;
    return f;
}

// --- Synthesis -------------------------------------------------------------------------

float envelope(float t, float len, float attack, float release) {
    if (t < attack) return t / attack;
    if (t > len - release) return std::max(0.0f, (len - t) / release);
    return 1.0f;
}

Sound tone(std::initializer_list<std::pair<double, double>> notes, float note_len, float amp,
           float harmonics = 0.25f) {
    Sound s;
    for (auto [freq_d, gain_d] : notes) {
        float freq = static_cast<float>(freq_d), gain = static_cast<float>(gain_d);
        int n = static_cast<int>(note_len * kRate);
        for (int i = 0; i < n; ++i) {
            float t = static_cast<float>(i) / kRate;
            float v = std::sin(2 * kPi * freq * t) + harmonics * std::sin(4 * kPi * freq * t);
            v *= envelope(t, note_len, 0.005f, note_len * 0.6f) * amp * gain;
            s.pcm.push_back(static_cast<int16_t>(std::max(-1.0f, std::min(1.0f, v)) * 32000));
        }
    }
    return s;
}

// Soft continuous noise band, used for walls and openings (loops seamlessly).
Sound noise_loop(float lowpass, float amp, float wobble_hz) {
    Sound s;
    s.loops = true;
    int n = kRate;  // one second
    uint32_t seed = 12345;
    float y = 0;
    for (int i = 0; i < n; ++i) {
        seed = seed * 1664525u + 1013904223u;
        float white = ((seed >> 9) & 0xFFFF) / 32768.0f - 1.0f;
        y += lowpass * (white - y);
        float t = static_cast<float>(i) / kRate;
        float mod = 0.75f + 0.25f * std::sin(2 * kPi * wobble_hz * t);
        s.pcm.push_back(static_cast<int16_t>(y * amp * mod * 32000));
    }
    return s;
}

// A soft steady tone that loops seamlessly (a whole number of cycles in one second).
Sound tone_loop(float freq, float amp) {
    Sound s;
    s.loops = true;
    int n = kRate;
    for (int i = 0; i < n; ++i) {
        float t = static_cast<float>(i) / kRate;
        float v = std::sin(2 * kPi * freq * t) + 0.2f * std::sin(4 * kPi * freq * t);
        s.pcm.push_back(static_cast<int16_t>(v * amp * 32000));
    }
    return s;
}

// One-shot noise burst: footsteps, landings, the rush of air at an opening.
Sound noise_burst(float len, float lowpass, float amp, float attack, uint32_t seed) {
    Sound s;
    int n = static_cast<int>(len * kRate);
    float y = 0;
    for (int i = 0; i < n; ++i) {
        seed = seed * 1664525u + 1013904223u;
        float white = ((seed >> 9) & 0xFFFF) / 32768.0f - 1.0f;
        y += lowpass * (white - y);
        float t = static_cast<float>(i) / kRate;
        float v = y * amp * envelope(t, len, attack, len * 0.7f);
        s.pcm.push_back(static_cast<int16_t>(std::max(-1.0f, std::min(1.0f, v * 3.0f)) * 32000));
    }
    return s;
}

void build_sounds() {
    g_sounds["ping"] = tone({{880, 1}}, 0.07f, 0.6f);
    g_sounds["tick"] = tone({{1600, 1}}, 0.02f, 0.5f, 0);
    g_sounds["chime"] = tone({{660, 1}, {990, 0.8f}}, 0.12f, 0.5f);
    g_sounds["arrive"] = tone({{523, 1}, {659, 1}, {784, 1}}, 0.1f, 0.5f);
    g_sounds["door"] = tone({{180, 1}, {140, 0.8f}}, 0.09f, 0.7f, 0.6f);
    g_sounds["person"] = tone({{440, 1}, {554, 0.7f}}, 0.08f, 0.35f);
    g_sounds["item"] = tone({{1320, 1}, {1760, 0.7f}}, 0.05f, 0.35f, 0);
    g_sounds["enemy"] = tone({{220, 1}, {208, 1}}, 0.1f, 0.6f, 0.8f);
    g_sounds["warn"] = tone({{1200, 1}, {1500, 1}}, 0.06f, 0.7f, 0.5f);
    g_sounds["step_blocked"] = tone({{150, 1}}, 0.08f, 0.6f, 1.0f);
    g_sounds["wall"] = noise_loop(0.05f, 0.5f, 0.0f);
    g_sounds["wall_preview"] = noise_loop(0.05f, 0.5f, 0.0f);  // one second, not looping
    g_sounds["wall_preview"].loops = false;
    g_sounds["opening"] = noise_burst(0.35f, 0.35f, 0.35f, 0.12f, 777);
    g_sounds["step"] = noise_burst(0.045f, 0.12f, 0.45f, 0.003f, 4242);
    g_sounds["land"] = noise_burst(0.12f, 0.06f, 0.8f, 0.004f, 9001);
    g_sounds["ledge"] = tone({{660, 1}, {440, 1}, {300, 1}}, 0.06f, 0.45f, 0.3f);
    // Something low to jump or vault over: a quick two-note hop up.
    g_sounds["hop"] = tone({{520, 1}, {780, 1}}, 0.05f, 0.5f, 0.3f);
    // A ledge you can climb: four rising notes.
    g_sounds["climb"] = tone({{330, 1}, {440, 1}, {587, 1}, {784, 1}}, 0.05f, 0.45f, 0.3f);
    // Statue puzzles: a clear bell-like note whose pitch carries meaning (the knight's note
    // and its reflection's), and a soft hum for standing on a knight's hint line.
    g_sounds["note"] = tone({{523.25, 1}}, 0.35f, 0.5f, 0.15f);
    g_sounds["hum"] = tone_loop(220.0f, 0.35f);
    g_sounds["hum_preview"] = tone_loop(220.0f, 0.35f);  // one second, not looping
    g_sounds["hum_preview"].loops = false;
}

// --- Spatialisation --------------------------------------------------------------------

// Unreal (X forward, Y right, Z up) -> X3DAudio (X right, Y up, Z forward), metres.
X3DAUDIO_VECTOR to_x3d(float x, float y, float z) { return {y / 100.0f, z / 100.0f, x / 100.0f}; }

void update_listener() {
    g_listener.Position = to_x3d(g_lx, g_ly, g_lz);
    X3DAUDIO_VECTOR f = to_x3d(g_fx, g_fy, 0);
    float len = std::sqrt(f.x * f.x + f.z * f.z);
    if (len < 1e-4f) { f = {0, 0, 1}; len = 1; }
    g_listener.OrientFront = {f.x / len, 0, f.z / len};
    g_listener.OrientTop = {0, 1, 0};
}

// Position a source voice at a world point: pan matrix, distance fade, and a muffled,
// slightly lower sound when it is behind the listener.
void place(IXAudio2SourceVoice* v, float x, float y, float z, float volume, float pitch) {
    X3DAUDIO_EMITTER e = {};
    e.Position = to_x3d(x, y, z);
    e.OrientFront = {0, 0, 1};
    e.OrientTop = {0, 1, 0};
    e.ChannelCount = 1;
    e.CurveDistanceScaler = 1.0f;

    float matrix[8] = {};
    X3DAUDIO_DSP_SETTINGS dsp = {};
    dsp.SrcChannelCount = 1;
    dsp.DstChannelCount = g_channels;
    dsp.pMatrixCoefficients = matrix;
    X3DAudioCalculate(g_x3d, &g_listener, &e, X3DAUDIO_CALCULATE_MATRIX, &dsp);
    // X3DAudio's matrix also attenuates with distance; normalise it to pure panning and
    // apply our own gentler fade so far sounds stay audible.
    float sum = 0;
    for (UINT32 i = 0; i < g_channels; ++i) sum += matrix[i];
    if (sum > 1e-4f) for (UINT32 i = 0; i < g_channels; ++i) matrix[i] /= sum;

    float dx = x - g_lx, dy = y - g_ly, dz = z - g_lz;
    float dist = std::sqrt(dx * dx + dy * dy + dz * dz);
    float fade = dist <= kNearCm ? 1.0f
               : std::max(0.08f, 1.0f - std::log(dist / kNearCm) / std::log(kFarCm / kNearCm));

    float flen = std::sqrt(g_fx * g_fx + g_fy * g_fy);
    float hlen = std::sqrt(dx * dx + dy * dy);
    float facing = (flen > 1e-4f && hlen > 1e-4f) ? (g_fx * dx + g_fy * dy) / (flen * hlen) : 1.0f;
    bool behind = facing < -0.2f;

    v->SetOutputMatrix(g_master, 1, g_channels, matrix);
    v->SetVolume(volume * fade * (behind ? 0.8f : 1.0f));
    v->SetFrequencyRatio(pitch * (behind ? 0.85f : 1.0f));
    XAUDIO2_FILTER_PARAMETERS filt = {LowPassFilter, behind ? 0.25f : 1.0f, 1.0f};
    v->SetFilterParameters(&filt);
}

IXAudio2SourceVoice* make_voice() {
    WAVEFORMATEX f = mono_format();
    IXAudio2SourceVoice* v = nullptr;
    if (FAILED(g_xa->CreateSourceVoice(&v, &f, XAUDIO2_VOICE_USEFILTER, 4.0f))) return nullptr;
    return v;
}

void submit(IXAudio2SourceVoice* v, const Sound& s) {
    XAUDIO2_BUFFER b = {};
    b.AudioBytes = static_cast<UINT32>(s.pcm.size() * 2);
    b.pAudioData = reinterpret_cast<const BYTE*>(s.pcm.data());
    b.Flags = XAUDIO2_END_OF_STREAM;
    if (s.loops) b.LoopCount = XAUDIO2_LOOP_INFINITE;
    v->SubmitSourceBuffer(&b);
}

IXAudio2SourceVoice* free_oneshot() {
    for (auto& slot : g_oneshots) {
        XAUDIO2_VOICE_STATE st;
        slot.src->GetState(&st, XAUDIO2_VOICE_NOSAMPLESPLAYED);
        if (st.BuffersQueued == 0) return slot.src;
    }
    return nullptr;  // all busy: drop this sound rather than cut another off
}

// --- Lua -------------------------------------------------------------------------------

int l_init(lua_State* L) {
    if (g_ready) { lua_pushboolean(L, 1); lua_pushstring(L, "ready"); return 2; }
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);  // harmless if the thread already has COM
    if (FAILED(XAudio2Create(&g_xa, 0, XAUDIO2_DEFAULT_PROCESSOR)) ||
        FAILED(g_xa->CreateMasteringVoice(&g_master))) {
        lua_pushboolean(L, 0); lua_pushstring(L, "XAudio2 unavailable"); return 2;
    }
    XAUDIO2_VOICE_DETAILS d;
    g_master->GetVoiceDetails(&d);
    g_channels = std::min<UINT32>(d.InputChannels, 8);
    g_master->GetChannelMask(&g_channel_mask);
    X3DAudioInitialize(g_channel_mask, X3DAUDIO_SPEED_OF_SOUND, g_x3d);
    build_sounds();
    for (int i = 0; i < kOneShotVoices; ++i) {
        Voice v; v.src = make_voice();
        if (v.src) { v.src->Start(); g_oneshots.push_back(v); }
    }
    update_listener();
    g_ready = true;
    lua_pushboolean(L, 1);
    lua_pushfstring(L, "ready, %d channels", static_cast<int>(g_channels));
    return 2;
}

int l_listener(lua_State* L) {
    g_lx = (float)luaL_checknumber(L, 1); g_ly = (float)luaL_checknumber(L, 2); g_lz = (float)luaL_checknumber(L, 3);
    g_fx = (float)luaL_checknumber(L, 4); g_fy = (float)luaL_checknumber(L, 5); g_fz = (float)luaL_optnumber(L, 6, 0);
    update_listener();
    return 0;
}

const Sound* find_sound(lua_State* L, int idx) {
    auto it = g_sounds.find(luaL_checkstring(L, idx));
    return it == g_sounds.end() ? nullptr : &it->second;
}

int l_play(lua_State* L) {
    const Sound* s = find_sound(L, 1);
    if (!g_ready || !s) { lua_pushboolean(L, 0); return 1; }
    IXAudio2SourceVoice* v = free_oneshot();
    if (!v) { lua_pushboolean(L, 0); return 1; }
    place(v, (float)luaL_checknumber(L, 2), (float)luaL_checknumber(L, 3), (float)luaL_checknumber(L, 4),
          (float)luaL_optnumber(L, 5, 1.0), (float)luaL_optnumber(L, 6, 1.0));
    submit(v, *s);
    v->Start();  // stop_all leaves pool voices stopped
    lua_pushboolean(L, 1);
    return 1;
}

int l_play_ui(lua_State* L) {
    const Sound* s = find_sound(L, 1);
    if (!g_ready || !s) { lua_pushboolean(L, 0); return 1; }
    IXAudio2SourceVoice* v = free_oneshot();
    if (!v) { lua_pushboolean(L, 0); return 1; }
    float centre[8];
    for (UINT32 i = 0; i < g_channels; ++i) centre[i] = i < 2 ? 0.7f : 0.0f;
    v->SetOutputMatrix(g_master, 1, g_channels, centre);
    v->SetVolume((float)luaL_optnumber(L, 2, 1.0));
    v->SetFrequencyRatio((float)luaL_optnumber(L, 3, 1.0));
    XAUDIO2_FILTER_PARAMETERS filt = {LowPassFilter, 1.0f, 1.0f};
    v->SetFilterParameters(&filt);
    submit(v, *s);
    v->Start();  // stop_all leaves pool voices stopped
    lua_pushboolean(L, 1);
    return 1;
}

int l_loop(lua_State* L) {
    std::string id = luaL_checkstring(L, 1);
    const Sound* s = find_sound(L, 2);
    if (!g_ready || !s) { lua_pushboolean(L, 0); return 1; }
    Voice& lv = g_loops[id];
    if (!lv.src) {
        lv.src = make_voice();
        if (!lv.src) { g_loops.erase(id); lua_pushboolean(L, 0); return 1; }
        place(lv.src, (float)luaL_checknumber(L, 3), (float)luaL_checknumber(L, 4), (float)luaL_checknumber(L, 5),
              (float)luaL_optnumber(L, 6, 1.0), (float)luaL_optnumber(L, 7, 1.0));
        submit(lv.src, *s);
        lv.src->Start();
    } else {
        place(lv.src, (float)luaL_checknumber(L, 3), (float)luaL_checknumber(L, 4), (float)luaL_checknumber(L, 5),
              (float)luaL_optnumber(L, 6, 1.0), (float)luaL_optnumber(L, 7, 1.0));
    }
    lua_pushboolean(L, 1);
    return 1;
}

int l_stop(lua_State* L) {
    auto it = g_loops.find(luaL_checkstring(L, 1));
    if (it != g_loops.end()) {
        if (it->second.src) { it->second.src->Stop(); it->second.src->DestroyVoice(); }
        g_loops.erase(it);
    }
    return 0;
}

int l_stop_all(lua_State* L) {
    for (auto& [id, v] : g_loops) if (v.src) { v.src->Stop(); v.src->DestroyVoice(); }
    g_loops.clear();
    // A started voice keeps the buffer it's playing through FlushSourceBuffers, so a sound
    // already under way played on through a mute or a scene change. Stopped first, a voice
    // loses every buffer; it's started again when its next sound is submitted, and
    // free_oneshot only hands it out once the flush has emptied it.
    for (auto& v : g_oneshots) { v.src->Stop(); v.src->FlushSourceBuffers(); }
    return 0;
}

// How many one-shot voices still hold a sound (tests and diagnostics).
int l_playing(lua_State* L) {
    int n = 0;
    for (auto& slot : g_oneshots) {
        XAUDIO2_VOICE_STATE st;
        slot.src->GetState(&st, XAUDIO2_VOICE_NOSAMPLESPLAYED);
        if (st.BuffersQueued > 0) ++n;
    }
    lua_pushinteger(L, n);
    return 1;
}

int l_sounds(lua_State* L) {
    lua_newtable(L);
    int i = 1;
    for (auto& [name, s] : g_sounds) { lua_pushstring(L, name.c_str()); lua_rawseti(L, -2, i++); }
    return 1;
}

const luaL_Reg kFuncs[] = {
    {"init", l_init}, {"listener", l_listener}, {"play", l_play}, {"play_ui", l_play_ui},
    {"loop", l_loop}, {"stop", l_stop}, {"stop_all", l_stop_all}, {"sounds", l_sounds},
    {"playing", l_playing},
    {nullptr, nullptr}};

}  // namespace

extern "C" __declspec(dllexport) int luaopen_audio_bridge(lua_State* L) {
    luaL_newlib(L, kFuncs);
    return 1;
}
