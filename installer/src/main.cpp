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
// Usage: WandsongSetup.exe [--install | --uninstall | --vanilla | --check] [--game "<dir>"] [--offline]
//   --check   says what it found, what's installed and what's online, and changes nothing.
//   --offline doesn't look online for a newer version (nor does --install).

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <sapi.h>
#include <bcrypt.h>
#include <winhttp.h>
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

} // namespace
#include "file_transaction.h"
namespace {

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
    if (!f || std::memcmp(magic, kPackMagic, 8) != 0) return items;
    const uint64_t payload_end = end - 24;
    if (offset > payload_end || count == 0 || count > 100000 || count > (payload_end - offset) / 13)
        throw std::runtime_error("Invalid setup payload bounds.");
    f.seekg(offset);
    for (uint64_t i = 0; i < count; ++i) {
        uint64_t cursor = static_cast<uint64_t>(f.tellg());
        if (cursor > payload_end || payload_end - cursor < 4)
            throw std::runtime_error("Truncated setup payload.");
        uint32_t len = 0;
        f.read((char*)&len, 4);
        if (!f || len == 0 || len > 4096 || payload_end - cursor - 4 < uint64_t(len) + 8)
            throw std::runtime_error("Invalid setup payload path length.");
        std::string rel(len, '\0');
        f.read(rel.data(), len);
        uint64_t size = 0;
        f.read((char*)&size, 8);
        if (!f) throw std::runtime_error("Truncated setup payload entry.");
        Item it;
        it.rel = rel;
        std::replace(it.rel.begin(), it.rel.end(), '/', '\\');
        it.offset = (uint64_t)f.tellg();
        it.size = size;
        if (it.offset > payload_end || size > payload_end - it.offset)
            throw std::runtime_error("Invalid setup payload file size.");
        items.push_back(it);
        f.seekg(it.offset + size);
    }
    if (static_cast<uint64_t>(f.tellg()) != payload_end)
        throw std::runtime_error("Unexpected data at the end of the setup payload.");
    return items;
}

std::vector<Item> read_folder(const fs::path& payload) {
    std::vector<Item> items;
    if (!setup_files::present(payload)) return items;
    for (const auto& entry : fs::recursive_directory_iterator(payload)) {
        setup_files::checked_path(payload, u8(entry.path().lexically_relative(payload)), false);
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
    if (ec) { why = ec; return false; }
    if (!it.file.empty()) {
        fs::copy_file(it.file, dest, fs::copy_options::overwrite_existing, why);
        return !why;
    }
    std::ifstream in(exe, std::ios::binary);
    in.seekg(it.offset);
    std::ofstream out(dest, std::ios::binary | std::ios::trunc);
    if (!out) { why = std::make_error_code(std::errc::io_error); return false; }
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
    out.close();
    if (!out) throw std::runtime_error("Couldn't save settings: " + u8(ini));
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
    out.close();
    if (!out) throw std::runtime_error("Couldn't save mod list: " + u8(mods_txt));
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

void validate_install_path(const std::string& rel) {
    setup_files::relative_path(rel);
    std::string key = key_of(rel);
    if (key == "hogwartslegacy.exe" || key == key_of(u8(kManifest)) ||
        key == "wandsong-setup.lock" || key == "wandsong-write-test.tmp" ||
        key == key_of(u8(kBackupDir)) || key.rfind(key_of(u8(kBackupDir)) + "\\", 0) == 0 ||
        key == key_of(u8(setup_files::transaction_dir)) ||
        key.rfind(key_of(u8(setup_files::transaction_dir)) + "\\", 0) == 0)
        throw std::runtime_error("Reserved installation path: " + rel);
}

std::vector<std::string> manifest_files(const fs::path& bin) {
    std::vector<std::string> v;
    fs::path path = setup_files::checked_path(bin, u8(kManifest));
    if (!setup_files::present(path)) return v;
    std::ifstream in(path);
    std::string line;
    if (!std::getline(in, line) || line.rfind("# Wandsong ", 0) != 0)
        throw std::runtime_error("Invalid installation record: " + u8(path));
    std::set<std::string> seen;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty() || line.front() == '#') continue;
        validate_install_path(line);
        if (!seen.insert(key_of(line)).second) throw std::runtime_error("Duplicate installation record: " + line);
        v.push_back(line);
    }
    if (in.bad() || v.empty()) throw std::runtime_error("Incomplete installation record: " + u8(path));
    return v;
}

std::map<std::string, std::string> backup_files(const fs::path& bin) {
    std::map<std::string, std::string> result;
    for (const auto& rel : setup_files::tree_files(bin, u8(kBackupDir))) {
        validate_install_path(rel);
        result.emplace(key_of(rel), rel);
    }
    return result;
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
    fs::path probe = bin / ("Wandsong-write-test-" + std::to_string(GetCurrentProcessId()) + ".tmp");
    HANDLE h = CreateFileW(probe.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
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

bool install(const fs::path& game, const fs::path& exe, const std::vector<Item>& items) {
    fs::path bin = game / kBinRel;
    std::set<std::string> packaged;
    for (const auto& item : items) {
        validate_install_path(item.rel);
        std::string key = key_of(item.rel);
        if (key == "dwmapi.dll.off" || !packaged.insert(key).second)
            throw std::runtime_error("Duplicate or inactive loader in payload: " + item.rel);
        setup_files::checked_path(bin, item.rel);
    }
    if (!packaged.count("dwmapi.dll") || !packaged.count("ue4ss.dll") ||
        !packaged.count("mods\\wandsong\\scripts\\main.lua")) {
        say("This setup is missing the mod's files. Download it again.");
        return false;
    }
    auto before = installed_version(bin);
    auto prior = manifest_files(bin);
    auto backups = backup_files(bin);
    if (prior.empty() && !backups.empty())
        throw std::runtime_error("Backups exist without an installation record. Keep Wandsong-backup for recovery.");
    bool active = setup_files::present(setup_files::checked_path(bin, "dwmapi.dll"));
    bool inactive = setup_files::present(setup_files::checked_path(bin, "dwmapi.dll.off"));
    if (active && inactive)
        throw std::runtime_error("Both dwmapi.dll and dwmapi.dll.off exist. Keep both and resolve the loader conflict before updating.");
    const std::string loader = inactive ? "dwmapi.dll.off" : "dwmapi.dll";
    std::set<std::string> owned;
    for (const auto& rel : prior) {
        setup_files::checked_path(bin, rel);
        owned.insert(key_of(rel) == "dwmapi.dll.off" ? "dwmapi.dll" : key_of(rel));
    }
    say(before ? "Updating Wandsong in " + u8(bin) + "." : "Installing Wandsong into " + u8(bin) + ".");
    setup_files::Transaction transaction(bin);
    std::map<std::string, std::pair<std::string, fs::path>> outputs;
    for (const auto& it : items) {
        std::string key = key_of(it.rel), rel = key == "dwmapi.dll" ? loader : it.rel;
        fs::path staged = transaction.stage(rel);
        fs::path current = setup_files::checked_path(bin, rel);
        if ((key == "ue4ss-settings.ini" || key == "mods\\mods.txt") && setup_files::present(current)) {
            setup_files::copy_verified(current, staged);
            outputs[key] = {rel, staged};
            continue;
        }
        std::error_code why;
        if (!write_item(it, exe, staged, why))
            throw std::runtime_error("Couldn't stage " + it.rel + ": " + why.message());
        outputs[key] = {rel, staged};
    }
    for (const std::string rel : {"UE4SS-settings.ini", "Mods\\mods.txt"}) {
        std::string key = key_of(rel);
        if (!outputs.count(key)) {
            fs::path staged = transaction.stage(rel), current = setup_files::checked_path(bin, rel);
            if (setup_files::present(current)) setup_files::copy_verified(current, staged);
            else setup_files::write_text(staged, "");
            outputs[key] = {rel, staged};
        }
    }
    fs::path ini = outputs.at("ue4ss-settings.ini").second;
    ini_set(ini, "EngineVersionOverride", "MajorVersion", "4");
    ini_set(ini, "EngineVersionOverride", "MinorVersion", "27");
    ini_set(ini, "Debug", "GuiConsoleEnabled", "0");
    ini_set(ini, "Debug", "ConsoleEnabled", "0");
    ini_set(ini, "General", "bUseUObjectArrayCache", "false");
    enable_in_mods_txt(outputs.at("mods\\mods.txt").second);
    std::map<std::string, std::string> installed;
    // Every previously unowned destination gets its own verified original, even in a
    // hand-installed copy. Never guess that a shared file belongs to this mod.
    for (const auto& [key, output] : outputs) {
        const auto& [rel, staged] = output;
        fs::path dest = setup_files::checked_path(bin, rel);
        if (!owned.count(key) && !backups.count(key_of(rel)) && setup_files::present(dest)) {
            std::string backup = u8(kBackupDir / from_u8(rel));
            setup_files::checked_path(bin, backup);
            fs::path original = transaction.stage(backup);
            setup_files::copy_verified(dest, original);
            transaction.put(backup, original);
        }
        installed[key] = key == "dwmapi.dll" ? "dwmapi.dll" : rel;
    }
    std::string mod_prefix = key_of(u8(kModDir)) + "\\";
    for (const auto& rel : prior) {
        std::string key = key_of(rel);
        if (key == "dwmapi.dll.off") key = "dwmapi.dll";
        if (outputs.count(key)) continue;
        if (key.rfind(mod_prefix, 0) != 0) { installed[key] = rel; continue; }
        if (backups.count(key)) {
            std::string backup = u8(kBackupDir / from_u8(backups.at(key)));
            fs::path restored = transaction.stage(rel);
            setup_files::copy_verified(setup_files::checked_path(bin, backup), restored);
            transaction.put(rel, restored);
            transaction.erase(backup);
        } else transaction.erase(rel);
    }
    for (const auto& [key, output] : outputs)
        if (key != "dwmapi.dll") transaction.put(output.first, output.second);
    std::string manifest = std::string("# Wandsong ") + kVersion + " installed files (relative to Win64)\r\n";
    for (const auto& [key, rel] : installed) manifest += rel + "\r\n";
    fs::path staged_manifest = transaction.stage(u8(kManifest));
    setup_files::write_text(staged_manifest, manifest);
    transaction.put(u8(kManifest), staged_manifest);
    // Commit the loader only after all payload, settings and ownership records are in place.
    transaction.put(loader, outputs.at("dwmapi.dll").second);
    transaction.commit();
    say(std::string("Done. Wandsong ") + kVersion + (before ? " is updated." : " is installed."));
    if (before) say("Your Wandsong settings and keys are kept.");
    if (inactive) { say("Vanilla mode is still on. Use setup's vanilla toggle when you want mods again."); return true; }
    say("Start Hogwarts Legacy as usual. Once it has loaded you'll hear \"Wandsong ready\"; "
        "press F6 in the game for the guide and every key.");
    return true;
}

bool uninstall(const fs::path& game) {
    fs::path bin = game / kBinRel;
    if (!setup_files::present(setup_files::checked_path(bin, u8(kManifest)))) {
        say(setup_files::present(setup_files::checked_path(bin, u8(kModDir), false))
                ? "This copy of Wandsong has no install record, so I can't tell its files from others. "
                  "Install it with this setup first (press Enter at the start), then uninstall."
                : "Wandsong isn't installed here.");
        return false;
    }
    auto prior = manifest_files(bin);
    auto backups = backup_files(bin);
    std::map<std::string, std::string> affected;
    bool inactive = !setup_files::present(setup_files::checked_path(bin, "dwmapi.dll")) &&
                    setup_files::present(setup_files::checked_path(bin, "dwmapi.dll.off"));
    for (auto rel : prior) {
        if (key_of(rel) == "dwmapi.dll" || key_of(rel) == "dwmapi.dll.off")
            rel = inactive ? "dwmapi.dll.off" : "dwmapi.dll";
        setup_files::checked_path(bin, rel);
        affected[key_of(rel)] = rel;
    }
    for (const auto& [key, rel] : backups) {
        setup_files::checked_path(bin, rel);
        affected[key] = rel; // includes legacy backups omitted from the old manifest
    }
    setup_files::Transaction transaction(bin);
    for (const auto& [key, rel] : affected) {
        if (!backups.count(key)) { transaction.erase(rel); continue; }
        fs::path original = setup_files::checked_path(bin, u8(kBackupDir / from_u8(backups.at(key))));
        fs::path staged = transaction.stage(rel);
        setup_files::copy_verified(original, staged);
        transaction.put(rel, staged);
    }
    // Backups and the ownership record are removed only in the same recoverable commit.
    for (const auto& [key, rel] : backups) transaction.erase(u8(kBackupDir / from_u8(rel)));
    transaction.erase(u8(kManifest));
    transaction.commit();
    say("Wandsong's installed files are removed and backed-up files are restored. Your settings, logs and other unrecorded files are kept.");
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

// --- Newer versions online: the public repo's latest release. ---
//
// Each release carries WandsongSetup-<version>.exe and its SHA-256 in
// WandsongSetup-<version>.exe.sha256 (tools/publish_release.ps1). This setup downloads the newer
// one over HTTPS, checks it against that checksum, and runs it; the newer setup carries
// everything and does the install itself.

constexpr wchar_t kLatestRelease[] = L"https://api.github.com/repos/matalvernaz/wandsong/releases/latest";

// "0.4.1" or "v0.4.1" -> {0, 4, 1}; empty for anything else ("dev").
std::vector<int> version_parts(std::string v) {
    if (!v.empty() && (v[0] == 'v' || v[0] == 'V')) v.erase(0, 1);
    std::vector<int> parts;
    std::stringstream ss(v);
    for (std::string p; std::getline(ss, p, '.');) {
        if (p.empty() || p.find_first_not_of("0123456789") != std::string::npos) return {};
        parts.push_back(std::stoi(p));
    }
    return parts;
}
bool newer_than(const std::string& a, const std::string& b) {
    auto x = version_parts(a), y = version_parts(b);
    if (x.empty() || y.empty()) return false;
    x.resize(std::max(x.size(), y.size())), y.resize(x.size());
    return x > y;
}

// One HTTPS GET (redirects followed); the body, or nothing with the reason in `why`.
std::optional<std::string> http_get(const std::wstring& url, size_t max_bytes, std::string& why) {
    URL_COMPONENTS uc{sizeof(uc)};
    wchar_t host[256], path[4096], extra[2048];
    uc.lpszHostName = host, uc.dwHostNameLength = 256;
    uc.lpszUrlPath = path, uc.dwUrlPathLength = 4096;
    uc.lpszExtraInfo = extra, uc.dwExtraInfoLength = 2048;
    if (!WinHttpCrackUrl(url.c_str(), 0, 0, &uc)) { why = "bad address"; return std::nullopt; }
    std::string body;
    bool ok = false;
    std::wstring agent = L"WandsongSetup/" + widen(kVersion);
    HINTERNET s = WinHttpOpen(agent.c_str(), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                              WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    HINTERNET c = s ? WinHttpConnect(s, host, uc.nPort, 0) : nullptr;
    HINTERNET r = c ? WinHttpOpenRequest(c, L"GET", (std::wstring(path) + extra).c_str(), nullptr,
                                         WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                                         uc.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0)
                    : nullptr;
    if (r) {
        WinHttpSetTimeouts(s, 8000, 8000, 15000, 60000);
        DWORD status = 0, len = sizeof(status);
        if (WinHttpSendRequest(r, L"Accept: application/vnd.github+json\r\n", (DWORD)-1, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) &&
            WinHttpReceiveResponse(r, nullptr) &&
            WinHttpQueryHeaders(r, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                                &status, &len, WINHTTP_NO_HEADER_INDEX)) {
            if (status == 200) {
                ok = true;
                for (DWORD avail = 0; WinHttpQueryDataAvailable(r, &avail) && avail > 0;) {
                    size_t at = body.size();
                    body.resize(at + avail);
                    DWORD got = 0;
                    if (!WinHttpReadData(r, body.data() + at, avail, &got)) { ok = false; why = "the download broke off"; break; }
                    body.resize(at + got);
                    if (body.size() > max_bytes) { ok = false; why = "it was larger than expected"; break; }
                }
            } else {
                why = "the server answered " + std::to_string(status);
            }
        } else {
            why = "no connection";
        }
    } else {
        why = "no connection";
    }
    if (r) WinHttpCloseHandle(r);
    if (c) WinHttpCloseHandle(c);
    if (s) WinHttpCloseHandle(s);
    if (!ok) return std::nullopt;
    return body;
}

std::string sha256_hex(const std::string& data) {
    BCRYPT_ALG_HANDLE alg = nullptr;
    BCRYPT_HASH_HANDLE h = nullptr;
    unsigned char digest[32] = {};
    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0) != 0) return {};
    if (BCryptCreateHash(alg, &h, nullptr, 0, nullptr, 0, 0) == 0) {
        BCryptHashData(h, (PUCHAR)data.data(), (ULONG)data.size(), 0);
        BCryptFinishHash(h, digest, sizeof(digest), 0);
        BCryptDestroyHash(h);
    }
    BCryptCloseAlgorithmProvider(alg, 0);
    static const char* hex = "0123456789abcdef";
    std::string out;
    for (unsigned char b : digest) out += hex[b >> 4], out += hex[b & 15];
    return out;
}

struct Online {
    std::string version;   // "0.4.1"
    std::string setup;     // download address of the setup
    std::string checksum;  // download address of its .sha256
};

// The latest release, if it has a setup and a checksum; nothing when offline or unclear.
std::optional<Online> latest_online(std::string& why) {
    auto json = http_get(kLatestRelease, 1 << 20, why);
    if (!json) return std::nullopt;
    std::smatch m;
    if (!std::regex_search(*json, m, std::regex("\"tag_name\"\\s*:\\s*\"([^\"]+)\""))) { why = "no version listed"; return std::nullopt; }
    Online o;
    o.version = m[1].str();
    if (!o.version.empty() && (o.version[0] == 'v' || o.version[0] == 'V')) o.version.erase(0, 1);
    std::regex url_re("\"browser_download_url\"\\s*:\\s*\"([^\"]+)\"");
    for (std::sregex_iterator it(json->begin(), json->end(), url_re), end; it != end; ++it) {
        std::string u = (*it)[1];
        if (std::regex_search(u, std::regex("WandsongSetup-[^/]*\\.exe$"))) o.setup = u;
        if (std::regex_search(u, std::regex("WandsongSetup-[^/]*\\.exe\\.sha256$"))) o.checksum = u;
    }
    if (o.setup.empty() || o.checksum.empty()) { why = "the release has no setup or checksum"; return std::nullopt; }
    return o;
}

// Download the newer setup, check it, and run it to install into `game`. Its exit code, or 1.
int run_online(const Online& o, const fs::path& game, bool pause) {
    say("Downloading Wandsong " + o.version + ".");
    std::string why;
    auto sum = http_get(widen(o.checksum), 4096, why);
    auto data = sum ? http_get(widen(o.setup), 512u << 20, why) : std::nullopt;
    if (!sum || !data) {
        say("Couldn't download it: " + why + ". Nothing was changed.");
        return 1;
    }
    std::string want = lower(sum->substr(0, sum->find_first_of(" \t\r\n")));
    if (want.size() != 64 || sha256_hex(*data) != want) {
        say("The download doesn't match its checksum, so it wasn't run. Nothing was changed.");
        return 1;
    }
    wchar_t tmp[MAX_PATH];
    GetTempPathW(MAX_PATH, tmp);
    fs::path file = fs::path(tmp) / ("WandsongSetup-" + o.version + ".exe");
    {
        std::ofstream out(file, std::ios::binary | std::ios::trunc);
        out.write(data->data(), (std::streamsize)data->size());
        out.close();
        if (!out) { say("Couldn't save the download. Nothing was changed."); return 1; }
    }
    say("Downloaded and checked. Starting Wandsong " + o.version + "'s setup.");
    wait_for_speech();
    std::wstring cmd = L"\"" + file.wstring() + L"\" --install --allow-elevation" + (pause ? L" --pause" : L"") + L" --game \"" +
                       game.wstring() + L"\"";
    STARTUPINFOW si{sizeof(si)};
    PROCESS_INFORMATION pi{};
    if (!CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, TRUE, 0, nullptr, nullptr, &si, &pi)) {
        say("Couldn't start the downloaded setup. Nothing was changed.");
        return 1;
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    std::error_code ec;
    fs::remove(file, ec);
    return (int)code;
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
    bool allow_elevation = false; // interactive download may ask for Windows' permission
    bool offline = GetEnvironmentVariableW(L"WANDSONG_SETUP_OFFLINE", nullptr, 0) > 0;  // tests
    for (int i = 1; i < argc; ++i) {
        std::wstring a = argv[i];
        if (a == L"--install") action = "install";
        else if (a == L"--uninstall") action = "uninstall";
        else if (a == L"--vanilla") action = "vanilla";
        else if (a == L"--check") action = "check";
        else if (a == L"--pause") pause_at_end = true;
        else if (a == L"--allow-elevation") allow_elevation = true;
        else if (a == L"--offline") offline = true;
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

    auto game = locate_game(game_arg, interactive);
    if (!game) {
        say("Setup stopped without changing anything.");
        return finish(1);
    }
    fs::path bin = *game / kBinRel;
    auto version = installed_version(bin);
    say(describe_installed(version));
    // A newer Wandsong online is offered first; --install alone (and the setup that update
    // starts) never looks.
    std::optional<Online> online;
    if (!offline && (interactive || action == "check")) {
        say("Checking online for a newer version.");
        std::string why;
        auto o = latest_online(why);
        if (!o) say("Couldn't check online (" + why + ").");
        else if (newer_than(o->version, kVersion)) { online = o; say("Wandsong " + o->version + " is available online."); }
        else say("This is the newest version.");
    }
    if (action == "check") return finish(0);
    // Said before any question: nothing can be changed while the game has its files open.
    if (game_running(*game)) {
        say("Hogwarts Legacy is running. Quit the game, then run setup again.");
        return finish(1);
    }

    if (interactive && online) {
        say("Press Enter to download Wandsong " + online->version + " and install it.");
        auto choice = ask(std::string("Or type 1 to install this setup's own ") + kVersion + " instead, 2 to uninstall, "
                          "3 to switch vanilla mode (play without mods) on or off, or 4 to leave.");
        if (!choice) return finish(0);
        if (choice->empty()) {
            // The newer setup asks its own last question; this one just ends.
            int code = run_online(*online, *game, true);
            wait_for_speech();
            if (g_voice) g_voice->Release();
            CoUninitialize();
            return code;
        }
        if (*choice == "1") action = "install";
        else if (*choice == "2") action = "uninstall";
        else if (*choice == "3") action = "vanilla";
        else { say("Nothing was changed."); return finish(0); }
    } else if (interactive) {
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
        if (!interactive && !allow_elevation) return finish(1);
        auto go = ask("Press Enter to ask for it (Windows will show its permission prompt), or type 4 to leave.");
        if (!go || !go->empty()) { say("Nothing was changed."); return finish(1); }
        std::wstring args = L"--" + widen(action) + L" --pause --game \"" + game->wstring() + L"\"";
        bool ok = run_elevated(args);
        say(ok ? "Setup finished with permission." : "Setup didn't finish: Windows' permission wasn't given, or it failed.");
        return finish(ok ? 0 : 1);
    }

    bool ok = false;
    try {
        setup_files::Lock lock(bin);
        setup_files::recover(bin);
        try {
            if (action == "install") {
                std::vector<Item> items = read_pack(exe);
                if (items.empty()) items = read_folder(exe.parent_path() / "payload");
                ok = install(*game, exe, items);
            } else if (action == "uninstall") ok = uninstall(*game);
            else if (action == "vanilla") ok = toggle_vanilla(*game);
        } catch (const std::exception& e) {
            say(std::string("Setup couldn't finish: ") + e.what());
            try { setup_files::recover(bin); }
            catch (const std::exception& recovery) {
                say(std::string("Recovery couldn't finish: ") + recovery.what());
                say("Keep Wandsong-backup, Wandsong-transaction and Wandsong-manifest.txt. Close programs using these files, then run setup again to retry recovery.");
            }
        }
    } catch (const std::exception& e) { say(std::string("Setup stopped: ") + e.what()); }
    return finish(ok ? 0 : 1);
}
