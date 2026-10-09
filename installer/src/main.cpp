// Wandsong setup.
//
// One file: the whole mod (UE4SS and Wandsong) rides appended to this program, so a player
// downloads one file and runs it. A plain console program, so screen readers read it naturally;
// when no screen reader is running it also speaks each line itself through Windows' own voice.
//
// It finds Hogwarts Legacy (Steam or Epic), says which Wandsong is installed, and on Enter
// installs or updates it: copies UE4SS and the mod, applies the UE4SS settings the game needs,
// removes files an older version had that this one doesn't, and leaves the player's own settings
// alone. It records what it installed so it can remove it again, and backs up the files it
// replaces in a game that had someone else's UE4SS.
//
// Usage: WandsongSetup.exe [--install | --uninstall | --vanilla | --check] [--game "<dir>"]
//   --check   says what it found and what's installed, and changes nothing.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <sapi.h>
#include <shellapi.h>
#include <tlhelp32.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <optional>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "version.h"

namespace fs = std::filesystem;

namespace {

constexpr char kVersion[] = WANDSONG_VERSION_STR;
constexpr char kSteamAppId[] = "990080";
const fs::path kBinRel = fs::path("Phoenix") / "Binaries" / "Win64";
const fs::path kBackupDir = "Wandsong-backup";
const fs::path kManifest = "Wandsong-manifest.txt";
const fs::path kModDir = fs::path("Mods") / "Wandsong";
const char kPackMagic[8] = {'H', 'W', 'A', 'P', 'A', 'C', 'K', '1'};

std::string u8(const fs::path& p) {
    auto s = p.u8string();
    return std::string(s.begin(), s.end());
}
fs::path from_u8(const std::string& s) { return fs::path(std::u8string(s.begin(), s.end())); }
std::wstring widen(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), w.data(), n);
    return w;
}
std::string lower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return (char)::tolower(c); });
    return s;
}
// Paths compared the way Windows does: case-insensitive, backslashes.
std::string key_of(const std::string& rel) {
    std::string k = lower(rel);
    std::replace(k.begin(), k.end(), '/', '\\');
    return k;
}

// --- Output: print, and speak only when no screen reader is there to read the console. ---

ISpVoice* g_voice = nullptr;  // non-null only when we should speak ourselves

void init_speech() {
    BOOL screen_reader = FALSE;
    SystemParametersInfoW(SPI_GETSCREENREADER, 0, &screen_reader, 0);
    if (screen_reader) return;  // it reads the console
    if (GetEnvironmentVariableW(L"WANDSONG_SETUP_QUIET", nullptr, 0) > 0) return;  // tests
    if (FAILED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) return;
    if (FAILED(CoCreateInstance(CLSID_SpVoice, nullptr, CLSCTX_ALL, IID_ISpVoice, (void**)&g_voice)))
        g_voice = nullptr;
}

void say(const std::string& line, bool interrupt = false) {
    std::cout << line << std::endl;
    if (g_voice && !line.empty())
        g_voice->Speak(widen(line).c_str(), SPF_ASYNC | SPF_IS_NOT_XML | (interrupt ? SPF_PURGEBEFORESPEAK : 0),
                       nullptr);
}

void wait_for_speech() {
    if (g_voice) g_voice->WaitUntilDone(30000);
}

// The typed line; nothing when input has ended (a closed console), which never counts as Enter.
std::optional<std::string> ask(const std::string& prompt) {
    say(prompt);
    wait_for_speech();
    std::string answer;
    if (!std::getline(std::cin, answer)) return std::nullopt;
    answer.erase(0, answer.find_first_not_of(" \t\r"));
    answer.erase(answer.find_last_not_of(" \t\r") + 1);
    return answer;
}

// --- Finding the game. ---

std::optional<std::string> reg_string(HKEY root, const wchar_t* key, const wchar_t* value, REGSAM view = 0) {
    HKEY h;
    if (RegOpenKeyExW(root, key, 0, KEY_READ | view, &h) != ERROR_SUCCESS) return std::nullopt;
    wchar_t buf[MAX_PATH * 2];
    DWORD size = sizeof(buf), type = 0;
    LSTATUS st = RegQueryValueExW(h, value, nullptr, &type, (LPBYTE)buf, &size);
    RegCloseKey(h);
    if (st != ERROR_SUCCESS || type != REG_SZ) return std::nullopt;
    return u8(fs::path(buf));
}

std::string read_file(const fs::path& p) {
    std::ifstream f(p, std::ios::binary);
    std::stringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

bool looks_like_game(const fs::path& dir) {
    std::error_code ec;
    return fs::exists(dir / kBinRel / "HogwartsLegacy.exe", ec);
}

std::optional<fs::path> find_steam() {
    std::vector<fs::path> roots;
    if (auto s = reg_string(HKEY_CURRENT_USER, L"Software\\Valve\\Steam", L"SteamPath")) roots.push_back(from_u8(*s));
    if (auto s = reg_string(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Valve\\Steam", L"InstallPath", KEY_WOW64_32KEY))
        roots.push_back(from_u8(*s));
    std::vector<fs::path> libraries;
    for (const auto& root : roots) {
        libraries.push_back(root);
        std::string vdf = read_file(root / "steamapps" / "libraryfolders.vdf");
        std::regex path_re("\"path\"\\s+\"([^\"]+)\"");
        for (std::sregex_iterator it(vdf.begin(), vdf.end(), path_re), end; it != end; ++it) {
            std::string p = (*it)[1];
            p = std::regex_replace(p, std::regex("\\\\\\\\"), "\\");  // VDF escapes backslashes
            libraries.push_back(from_u8(p));
        }
    }
    for (const auto& lib : libraries) {
        fs::path dir = lib / "steamapps" / "common" / "Hogwarts Legacy";
        if (looks_like_game(dir)) return dir;
    }
    // Steam's own uninstall entry for the game names its folder too.
    const wchar_t* uninstall = L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Steam App 990080";
    for (REGSAM view : {KEY_WOW64_64KEY, KEY_WOW64_32KEY})
        if (auto s = reg_string(HKEY_LOCAL_MACHINE, uninstall, L"InstallLocation", view))
            if (looks_like_game(from_u8(*s))) return from_u8(*s);
    return std::nullopt;
}

std::optional<fs::path> find_epic() {
    fs::path manifests = "C:\\ProgramData\\Epic\\EpicGamesLauncher\\Data\\Manifests";
    std::error_code ec;
    if (!fs::exists(manifests, ec)) return std::nullopt;
    std::regex name_re("\"DisplayName\"\\s*:\\s*\"Hogwarts Legacy\"");
    std::regex loc_re("\"InstallLocation\"\\s*:\\s*\"([^\"]+)\"");
    for (const auto& entry : fs::directory_iterator(manifests, ec)) {
        if (entry.path().extension() != ".item") continue;
        std::string json = read_file(entry.path());
        std::smatch m;
        if (!std::regex_search(json, name_re) || !std::regex_search(json, m, loc_re)) continue;
        std::string p = std::regex_replace(m[1].str(), std::regex("\\\\\\\\"), "\\");
        if (looks_like_game(from_u8(p))) return from_u8(p);
    }
    return std::nullopt;
}

// The folder as Windows names it (Steam's registry gives "c:/program files (x86)/steam").
fs::path tidy(const fs::path& p) {
    std::error_code ec;
    fs::path c = fs::canonical(p, ec);
    if (ec) c = p;
    return c.make_preferred();
}

std::optional<fs::path> locate_game(const std::optional<fs::path>& given, bool interactive) {
    if (given) {
        if (looks_like_game(*given)) return tidy(*given);
        say("That folder doesn't contain Hogwarts Legacy: " + u8(*given));
        return std::nullopt;
    }
    if (auto p = find_steam()) { say("Found Hogwarts Legacy from Steam, in " + u8(tidy(*p)) + "."); return tidy(*p); }
    if (auto p = find_epic()) { say("Found Hogwarts Legacy from Epic, in " + u8(tidy(*p)) + "."); return tidy(*p); }
    say("I couldn't find Hogwarts Legacy by myself. Copies from Game Pass or the Microsoft Store can't be modded this way.");
    if (!interactive) return std::nullopt;
    auto typed = ask("Type or paste the game's folder (the one with the Phoenix folder in it) and press Enter, "
                     "or just press Enter to cancel.");
    if (!typed || typed->empty()) return std::nullopt;
    std::string t = *typed;
    t.erase(std::remove(t.begin(), t.end(), '"'), t.end());
    fs::path p = from_u8(t);
    if (looks_like_game(p)) return tidy(p);
    // The Win64 folder itself, or anything inside the game folder, will do.
    for (fs::path up = p; !up.empty() && up != up.parent_path(); up = up.parent_path())
        if (looks_like_game(up)) return tidy(up);
    say("That folder doesn't contain Hogwarts Legacy.");
    return std::nullopt;
}

// --- What this setup carries: appended to the program, or a payload folder beside it. ---
//
// tools/build_release.ps1 appends, per file: uint32 path length, the path (UTF-8, relative to
// Win64), uint64 size, the bytes; then a footer: "HWAPACK1", uint64 offset of the first file,
// uint64 number of files.

struct Item {
    std::string rel;       // relative to Win64, backslashes
    fs::path file;         // a loose payload file, or
    uint64_t offset = 0;   // where the bytes start in this program
    uint64_t size = 0;
};

fs::path self_path() {
    wchar_t path[MAX_PATH * 2];
    GetModuleFileNameW(nullptr, path, MAX_PATH * 2);
    return fs::path(path);
}

std::vector<Item> read_pack(const fs::path& exe) {
    std::vector<Item> items;
    std::ifstream f(exe, std::ios::binary);
    if (!f) return items;
    f.seekg(0, std::ios::end);
    uint64_t end = (uint64_t)f.tellg();
    if (end < 24) return items;
    f.seekg(end - 24);
    char magic[8];
    uint64_t offset = 0, count = 0;
    f.read(magic, 8);
    f.read((char*)&offset, 8);
    f.read((char*)&count, 8);
    if (!f || std::memcmp(magic, kPackMagic, 8) != 0 || offset >= end || count > 100000) return items;
    f.seekg(offset);
    for (uint64_t i = 0; i < count; ++i) {
        uint32_t len = 0;
        f.read((char*)&len, 4);
        if (!f || len == 0 || len > 4096) return {};
        std::string rel(len, '\0');
        f.read(rel.data(), len);
        uint64_t size = 0;
        f.read((char*)&size, 8);
        if (!f) return {};
        Item it;
        it.rel = rel;
        std::replace(it.rel.begin(), it.rel.end(), '/', '\\');
        it.offset = (uint64_t)f.tellg();
        it.size = size;
        if (it.offset + size > end) return {};
        items.push_back(it);
        f.seekg(it.offset + size);
    }
    return items;
}

std::vector<Item> read_folder(const fs::path& payload) {
    std::vector<Item> items;
    std::error_code ec;
    for (const auto& entry : fs::recursive_directory_iterator(payload, ec)) {
        if (!entry.is_regular_file()) continue;
        Item it;
        it.rel = u8(fs::relative(entry.path(), payload));
        it.file = entry.path();
        items.push_back(it);
    }
    return items;
}

// Write one item to dest; false with the reason in `why`.
bool write_item(const Item& it, const fs::path& exe, const fs::path& dest, std::error_code& why) {
    std::error_code ec;
    fs::create_directories(dest.parent_path(), ec);
    if (!it.file.empty()) {
        fs::copy_file(it.file, dest, fs::copy_options::overwrite_existing, why);
        return !why;
    }
    std::ifstream in(exe, std::ios::binary);
    in.seekg(it.offset);
    std::ofstream out(dest, std::ios::binary | std::ios::trunc);
    if (!out) { why = std::error_code((int)GetLastError(), std::system_category()); return false; }
    std::vector<char> buf(1 << 20);
    uint64_t left = it.size;
    while (left > 0) {
        size_t n = (size_t)std::min<uint64_t>(left, buf.size());
        in.read(buf.data(), n);
        if (!in) { why = std::make_error_code(std::errc::io_error); return false; }
        out.write(buf.data(), n);
        left -= n;
    }
    out.close();
    if (!out) { why = std::make_error_code(std::errc::io_error); return false; }
    return true;
}

// --- Install pieces. ---

void unblock(const fs::path& file) {
    // Remove the "downloaded from the internet" mark so Windows doesn't block the DLLs.
    DeleteFileW((file.wstring() + L":Zone.Identifier").c_str());
}

// Set key = value inside [section] of an ini, adding either if missing.
void ini_set(const fs::path& ini, const std::string& section, const std::string& key, const std::string& value) {
    std::vector<std::string> lines;
    {
        std::ifstream in(ini);
        for (std::string l; std::getline(in, l);) {
            if (!l.empty() && l.back() == '\r') l.pop_back();
            lines.push_back(l);
        }
    }
    std::string header = "[" + section + "]";
    auto sec = std::find(lines.begin(), lines.end(), header);
    if (sec == lines.end()) {
        lines.push_back("");
        lines.push_back(header);
        lines.push_back(key + " = " + value);
    } else {
        auto it = sec + 1;
        bool done = false;
        for (; it != lines.end() && !(it->size() && (*it)[0] == '['); ++it) {
            std::string k = it->substr(0, it->find('='));
            k.erase(k.find_last_not_of(" \t") + 1);
            if (k == key) {
                *it = key + " = " + value;
                done = true;
                break;
            }
        }
        if (!done) lines.insert(sec + 1, key + " = " + value);
    }
    std::ofstream out(ini, std::ios::binary);
    for (const auto& l : lines) out << l << "\r\n";
}

// Make sure mods.txt enables Wandsong (and keeps the UE4SS keybind helper last).
void enable_in_mods_txt(const fs::path& mods_txt) {
    std::vector<std::string> lines;
    {
        std::ifstream in(mods_txt);
        for (std::string l; std::getline(in, l);) {
            if (!l.empty() && l.back() == '\r') l.pop_back();
            if (l.rfind("\xEF\xBB\xBF", 0) == 0) l = l.substr(3);  // BOM
            if (l.rfind("Wandsong", 0) == 0) continue;
            lines.push_back(l);
        }
    }
    auto keybinds = std::find_if(lines.begin(), lines.end(),
                                 [](const std::string& l) { return l.rfind("Keybinds", 0) == 0; });
    // Keep the "; Built-in keybinds, do not move up!" comment attached to its line.
    if (keybinds != lines.end() && keybinds != lines.begin() && !(keybinds - 1)->empty() &&
        (*(keybinds - 1))[0] == ';')
        --keybinds;
    lines.insert(keybinds, "Wandsong : 1");
    std::ofstream out(mods_txt, std::ios::binary);
    for (const auto& l : lines) out << l << "\r\n";
}

std::vector<std::string> read_lines(const fs::path& p) {
    std::vector<std::string> v;
    std::ifstream in(p);
    for (std::string l; std::getline(in, l);) {
        if (!l.empty() && l.back() == '\r') l.pop_back();
        if (!l.empty()) v.push_back(l);
    }
    return v;
}

std::vector<std::string> manifest_files(const fs::path& bin) {
    std::vector<std::string> v;
    for (const auto& l : read_lines(bin / kManifest))
        if (l[0] != '#') v.push_back(l);
    return v;
}

// Which Wandsong is installed: its version, "" for one too old to say, nothing for none.
std::optional<std::string> installed_version(const fs::path& bin) {
    std::error_code ec;
    auto v = read_lines(bin / kModDir / "version.txt");
    if (!v.empty()) return v[0];
    auto m = read_lines(bin / kManifest);
    std::smatch sm;
    if (!m.empty() && std::regex_search(m[0], sm, std::regex("Wandsong (\\S+)"))) return sm[1].str();
    if (fs::exists(bin / kModDir / "Scripts" / "main.lua", ec)) return std::string();
    return std::nullopt;
}

// Is this copy of the game running? (Setup replaces files the running game has open.)
bool game_running(const fs::path& game) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return false;
    std::wstring root = fs::weakly_canonical(game).wstring();
    PROCESSENTRY32W pe{sizeof(pe)};
    bool found = false;
    for (BOOL more = Process32FirstW(snap, &pe); more && !found; more = Process32NextW(snap, &pe)) {
        if (_wcsicmp(pe.szExeFile, L"HogwartsLegacy.exe") != 0) continue;
        HANDLE proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pe.th32ProcessID);
        if (!proc) { found = true; continue; }  // can't tell; be safe
        wchar_t image[MAX_PATH * 2];
        DWORD len = MAX_PATH * 2;
        if (QueryFullProcessImageNameW(proc, 0, image, &len))
            found = _wcsnicmp(image, root.c_str(), root.size()) == 0;
        else
            found = true;
        CloseHandle(proc);
    }
    CloseHandle(snap);
    return found;
}

// Can we write into the game's folder? Steam's folder usually allows it; elsewhere Windows may
// want permission first.
bool can_write(const fs::path& bin) {
    fs::path probe = bin / "Wandsong-write-test.tmp";
    HANDLE h = CreateFileW(probe.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, nullptr);
    if (h == INVALID_HANDLE_VALUE) return GetLastError() != ERROR_ACCESS_DENIED;
    CloseHandle(h);
    return true;
}

// Run this setup again with Windows' permission (an administrator), waiting for it to finish.
bool run_elevated(const std::wstring& args) {
    std::wstring exe = self_path().wstring();
    SHELLEXECUTEINFOW sei{sizeof(sei)};
    sei.fMask = SEE_MASK_NOCLOSEPROCESS;
    sei.lpVerb = L"runas";
    sei.lpFile = exe.c_str();
    sei.lpParameters = args.c_str();
    sei.nShow = SW_SHOWNORMAL;
    if (!ShellExecuteExW(&sei) || !sei.hProcess) return false;
    WaitForSingleObject(sei.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(sei.hProcess, &code);
    CloseHandle(sei.hProcess);
    return code == 0;
}

// Remove a file and the folders it leaves empty, up to (not including) `stop`.
void remove_with_empty_parents(const fs::path& file, const fs::path& stop) {
    std::error_code ec;
    fs::remove(file, ec);
    for (fs::path dir = file.parent_path(); dir != stop && u8(dir).size() > u8(stop).size(); dir = dir.parent_path())
        if (!fs::is_empty(dir, ec) || !fs::remove(dir, ec)) break;
}

bool install(const fs::path& game, const fs::path& exe, const std::vector<Item>& items) {
    fs::path bin = game / kBinRel;
    bool has_loader = std::any_of(items.begin(), items.end(), [](const Item& i) { return key_of(i.rel) == "dwmapi.dll"; });
    if (!has_loader) {
        say("This setup is missing the mod's files. Download it again.");
        return false;
    }
    std::error_code ec;
    auto before = installed_version(bin);
    std::vector<std::string> prior = manifest_files(bin);
    say(before ? "Updating Wandsong in " + u8(bin) + "." : "Installing Wandsong into " + u8(bin) + ".");

    // Someone else's UE4SS (no Wandsong yet): keep its files to put back on uninstall.
    fs::path backup = bin / kBackupDir;
    if (!before && !fs::exists(backup, ec)) {
        for (const char* f : {"dwmapi.dll", "UE4SS.dll", "UE4SS-settings.ini", "Mods\\mods.txt"}) {
            if (!fs::exists(bin / f, ec)) continue;
            fs::create_directories((backup / f).parent_path(), ec);
            fs::copy_file(bin / f, backup / f, fs::copy_options::overwrite_existing, ec);
        }
    }

    bool had_settings = fs::exists(bin / "UE4SS-settings.ini", ec);
    bool had_mods_txt = fs::exists(bin / "Mods" / "mods.txt", ec);
    std::vector<std::string> installed;
    std::set<std::string> now;
    for (const auto& it : items) {
        // A player's existing UE4SS configuration is patched below, never replaced.
        if (key_of(it.rel) == "ue4ss-settings.ini" && had_settings) continue;
        if (key_of(it.rel) == "mods\\mods.txt" && had_mods_txt) continue;
        fs::path dest = bin / from_u8(it.rel);
        std::error_code why;
        if (!write_item(it, exe, dest, why)) {
            say("Couldn't write " + it.rel + ": " + why.message());
            return false;
        }
        unblock(dest);
        installed.push_back(it.rel);
        now.insert(key_of(it.rel));
    }

    // Files an earlier version installed in the mod's folder that this one doesn't have. Only
    // what the record lists: the player's settings and logs live there too and stay.
    int removed = 0;
    std::string mod_prefix = key_of(u8(kModDir)) + "\\";
    for (const auto& rel : prior) {
        std::string k = key_of(rel);
        if (k.rfind(mod_prefix, 0) == 0 && !now.count(k) && fs::exists(bin / from_u8(rel), ec)) {
            remove_with_empty_parents(bin / from_u8(rel), bin / kModDir);
            ++removed;
        }
    }
    // Earlier records outside the mod's folder (a settings file this setup created back then)
    // stay recorded, so uninstalling still removes them.
    for (const auto& rel : prior) {
        std::string k = key_of(rel);
        if (k.rfind(mod_prefix, 0) != 0 && !now.count(k)) { installed.push_back(rel); now.insert(k); }
    }

    // Settings Hogwarts Legacy needs with UE4SS 3.0.1 (found the hard way).
    fs::path ini = bin / "UE4SS-settings.ini";
    ini_set(ini, "EngineVersionOverride", "MajorVersion", "4");
    ini_set(ini, "EngineVersionOverride", "MinorVersion", "27");
    ini_set(ini, "Debug", "GuiConsoleEnabled", "0");
    ini_set(ini, "Debug", "ConsoleEnabled", "0");
    ini_set(ini, "General", "bUseUObjectArrayCache", "false");
    enable_in_mods_txt(bin / "Mods" / "mods.txt");

    std::ofstream manifest(bin / kManifest, std::ios::binary);
    manifest << "# Wandsong " << kVersion << " installed files (relative to Win64)\r\n";
    for (const auto& f : installed) manifest << f << "\r\n";
    manifest.close();

    if (removed > 0) say("Removed " + std::to_string(removed) + " files the earlier version needed and this one doesn't.");
    say(std::string("Done. Wandsong ") + kVersion + (before ? " is updated." : " is installed."));
    if (before) say("Your Wandsong settings and keys are kept.");
    say("Start Hogwarts Legacy as usual. Once it has loaded you'll hear \"Wandsong ready\"; "
        "press F6 in the game for the guide and every key.");
    return true;
}

bool uninstall(const fs::path& game) {
    fs::path bin = game / kBinRel;
    std::error_code ec;
    if (!fs::exists(bin / kManifest, ec)) {
        say(fs::exists(bin / kModDir, ec)
                ? "This copy of Wandsong has no install record, so I can't tell its files from others. "
                  "Install it with this setup first (press Enter at the start), then uninstall."
                : "Wandsong isn't installed here.");
        return false;
    }
    for (const auto& rel : manifest_files(bin)) remove_with_empty_parents(bin / from_u8(rel), bin);
    fs::remove_all(bin / kModDir, ec);
    fs::remove(bin / "dwmapi.dll.off", ec);
    // Put back whatever was there before.
    fs::path backup = bin / kBackupDir;
    if (fs::exists(backup, ec)) {
        for (const auto& entry : fs::recursive_directory_iterator(backup, ec)) {
            if (!entry.is_regular_file()) continue;
            fs::path dest = bin / fs::relative(entry.path(), backup);
            fs::create_directories(dest.parent_path(), ec);
            fs::copy_file(entry.path(), dest, fs::copy_options::overwrite_existing, ec);
        }
        fs::remove_all(backup, ec);
    }
    fs::remove(bin / kManifest, ec);
    say("Wandsong is removed, with its settings, and the game's folder is as it was before.");
    return true;
}

bool toggle_vanilla(const fs::path& game) {
    fs::path bin = game / kBinRel;
    std::error_code ec;
    if (fs::exists(bin / "dwmapi.dll", ec)) {
        fs::rename(bin / "dwmapi.dll", bin / "dwmapi.dll.off", ec);
        say(ec ? "Couldn't switch mods off: " + ec.message()
               : "Vanilla mode is on: the game starts without any mods. Run setup again and choose 3 to switch them back on.");
    } else if (fs::exists(bin / "dwmapi.dll.off", ec)) {
        fs::rename(bin / "dwmapi.dll.off", bin / "dwmapi.dll", ec);
        say(ec ? "Couldn't switch mods on: " + ec.message() : "Vanilla mode is off: Wandsong is active again.");
    } else {
        say("No mods are installed here, so there's nothing to switch.");
        return false;
    }
    return !ec;
}

std::string describe_installed(const std::optional<std::string>& v) {
    if (!v) return "Wandsong isn't installed yet.";
    if (v->empty()) return "An earlier Wandsong is installed.";
    if (*v == kVersion) return std::string("Wandsong ") + kVersion + " is installed, the same as this setup.";
    if (v->rfind("dev", 0) == 0) return "A development build of Wandsong is installed (" + *v + ").";
    return "Wandsong " + *v + " is installed.";
}

std::string main_action(const std::optional<std::string>& v) {
    if (!v) return "Press Enter to install it.";
    if (*v == kVersion) return "Press Enter to install it again.";
    return std::string("Press Enter to update it to ") + kVersion + ".";
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCP(CP_UTF8);
    SetConsoleTitleW(L"Wandsong setup");
    init_speech();

    std::string action;
    std::optional<fs::path> game_arg;
    bool pause_at_end = false;
    for (int i = 1; i < argc; ++i) {
        std::wstring a = argv[i];
        if (a == L"--install") action = "install";
        else if (a == L"--uninstall") action = "uninstall";
        else if (a == L"--vanilla") action = "vanilla";
        else if (a == L"--check") action = "check";
        else if (a == L"--pause") pause_at_end = true;
        else if (a == L"--game" && i + 1 < argc) game_arg = fs::path(argv[++i]);
    }
    bool interactive = action.empty();
    auto finish = [&](int code) {
        if (interactive || pause_at_end) ask("Press Enter to close.");
        wait_for_speech();
        if (g_voice) g_voice->Release();
        CoUninitialize();
        return code;
    };

    say(std::string("Wandsong setup, version ") + kVersion + ".", true);

    fs::path exe = self_path();
    std::vector<Item> items = read_pack(exe);
    if (items.empty()) items = read_folder(exe.parent_path() / "payload");

    auto game = locate_game(game_arg, interactive);
    if (!game) {
        say("Setup stopped without changing anything.");
        return finish(1);
    }
    fs::path bin = *game / kBinRel;
    auto version = installed_version(bin);
    say(describe_installed(version));
    if (action == "check") return finish(0);
    // Said before any question: nothing can be changed while the game has its files open.
    if (game_running(*game)) {
        say("Hogwarts Legacy is running. Quit the game, then run setup again.");
        return finish(1);
    }

    if (interactive) {
        say(main_action(version));
        auto choice = ask("Or type 2 and press Enter to uninstall, 3 to switch vanilla mode (play without mods) on or off, "
                          "or 4 to leave.");
        if (!choice) return finish(0);
        if (choice->empty() || *choice == "1") action = "install";
        else if (*choice == "2") action = "uninstall";
        else if (*choice == "3") action = "vanilla";
        else { say("Nothing was changed."); return finish(0); }
    }

    if (game_running(*game)) {
        say("Hogwarts Legacy is running. Quit the game, then run setup again.");
        return finish(1);
    }
    if (!can_write(bin)) {
        say("Windows needs your permission to change the game's folder.");
        if (!interactive) return finish(1);
        auto go = ask("Press Enter to ask for it (Windows will show its permission prompt), or type 4 to leave.");
        if (!go || !go->empty()) { say("Nothing was changed."); return finish(1); }
        std::wstring args = L"--" + widen(action) + L" --pause --game \"" + game->wstring() + L"\"";
        bool ok = run_elevated(args);
        say(ok ? "Setup finished with permission." : "Setup didn't finish: Windows' permission wasn't given, or it failed.");
        return finish(ok ? 0 : 1);
    }

    bool ok = false;
    if (action == "install") ok = install(*game, exe, items);
    else if (action == "uninstall") ok = uninstall(*game);
    else if (action == "vanilla") ok = toggle_vanilla(*game);
    return finish(ok ? 0 : 1);
}
