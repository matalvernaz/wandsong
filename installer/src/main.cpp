// Wandsong installer.
//
// A plain console program, so screen readers read it naturally. When no screen reader is
// running it also speaks each line itself (through Prism's system voices), so a blind
// player without one still gets every prompt.
//
// It finds Hogwarts Legacy (Steam or Epic), copies UE4SS and the Wandsong mod from
// the "payload" folder next to it, applies the UE4SS settings the game needs, and records
// what it installed so it can be removed again. Existing files it replaces are backed up.
//
// Usage: WandsongSetup.exe [--install | --uninstall | --vanilla] [--game "<dir>"]

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <tlhelp32.h>

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <optional>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

#include "prism.h"

namespace fs = std::filesystem;

namespace {

constexpr char kVersion[] = "0.3.0";
constexpr char kSteamAppId[] = "990080";
const fs::path kBinRel = fs::path("Phoenix") / "Binaries" / "Win64";
const fs::path kBackupDir = "Wandsong-backup";
const fs::path kManifest = "Wandsong-manifest.txt";

// --- Output: print, and speak only when no screen reader is there to read the console. ---

PrismContext* g_prism = nullptr;
PrismBackend* g_voice = nullptr;  // non-null only when we should speak ourselves

void init_speech() {
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    PrismConfig cfg = prism_config_init();
    g_prism = prism_init(&cfg);
    if (!g_prism) return;
    PrismBackend* best = prism_registry_acquire_best(g_prism);
    if (!best) return;
    std::string name = prism_backend_name(best);
    std::string lower = name;
    std::transform(lower.begin(), lower.end(), lower.begin(), ::tolower);
    bool system_voice = lower.find("sapi") != std::string::npos ||
                        lower.find("onecore") != std::string::npos ||
                        lower.find("one core") != std::string::npos;
    if (system_voice) g_voice = best;
    else prism_backend_free(best);
}

void say(const std::string& line, bool interrupt = false) {
    std::cout << line << std::endl;
    if (g_voice && !line.empty()) (void)prism_backend_speak(g_voice, line.c_str(), interrupt);
}

void wait_for_speech() {
    if (!g_voice) return;
    for (int i = 0; i < 300; ++i) {  // up to 30 s
        bool speaking = false;
        if (prism_backend_is_speaking(g_voice, &speaking) != PRISM_OK || !speaking) return;
        Sleep(100);
    }
}

std::string ask(const std::string& prompt) {
    say(prompt);
    wait_for_speech();
    std::string answer;
    std::getline(std::cin, answer);
    return answer;
}

// --- Finding the game. ---

std::optional<std::string> reg_string(HKEY root, const wchar_t* key, const wchar_t* value) {
    wchar_t buf[MAX_PATH * 2];
    DWORD size = sizeof(buf);
    if (RegGetValueW(root, key, value, RRF_RT_REG_SZ, nullptr, buf, &size) != ERROR_SUCCESS)
        return std::nullopt;
    return fs::path(buf).string();
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
    auto steam = reg_string(HKEY_CURRENT_USER, L"Software\\Valve\\Steam", L"SteamPath");
    if (!steam) return std::nullopt;
    std::vector<fs::path> libraries{fs::path(*steam)};
    std::string vdf = read_file(fs::path(*steam) / "steamapps" / "libraryfolders.vdf");
    std::regex path_re("\"path\"\\s+\"([^\"]+)\"");
    for (std::sregex_iterator it(vdf.begin(), vdf.end(), path_re), end; it != end; ++it) {
        std::string p = (*it)[1];
        // VDF escapes backslashes.
        p = std::regex_replace(p, std::regex("\\\\\\\\"), "\\");
        libraries.emplace_back(p);
    }
    for (const auto& lib : libraries) {
        std::error_code ec;
        if (!fs::exists(lib / "steamapps" / (std::string("appmanifest_") + kSteamAppId + ".acf"), ec))
            continue;
        fs::path dir = lib / "steamapps" / "common" / "Hogwarts Legacy";
        if (looks_like_game(dir)) return dir;
    }
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
        if (looks_like_game(p)) return fs::path(p);
    }
    return std::nullopt;
}

std::optional<fs::path> locate_game(const std::optional<std::string>& given) {
    if (given) {
        if (looks_like_game(*given)) return fs::path(*given);
        say("That folder doesn't contain Hogwarts Legacy: " + *given);
        return std::nullopt;
    }
    if (auto p = find_steam()) { say("Found the Steam copy of Hogwarts Legacy in " + p->string()); return p; }
    if (auto p = find_epic()) { say("Found the Epic copy of Hogwarts Legacy in " + p->string()); return p; }
    say("I couldn't find Hogwarts Legacy automatically. Game Pass and Microsoft Store copies aren't supported.");
    std::string typed = ask("Type the game's install folder (the one containing Phoenix), or press Enter to cancel:");
    if (typed.empty()) return std::nullopt;
    typed.erase(std::remove(typed.begin(), typed.end(), '"'), typed.end());
    if (looks_like_game(typed)) return fs::path(typed);
    say("That folder doesn't contain Hogwarts Legacy.");
    return std::nullopt;
}

// --- Install pieces. ---

void unblock(const fs::path& file) {
    // Remove the "downloaded from the internet" mark so Windows doesn't block the DLLs.
    DeleteFileW((file.wstring() + L":Zone.Identifier").c_str());
}

// Set key = value inside [section] of an ini, adding either if missing.
void ini_set(const fs::path& ini, const std::string& section, const std::string& key,
             const std::string& value) {
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

// Is this copy of the game running? (The installer replaces files the running game has open.)
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

bool install(const fs::path& game, const fs::path& payload) {
    fs::path bin = game / kBinRel;
    if (!fs::exists(payload / "dwmapi.dll")) {
        say("The payload folder is missing. Keep the installer next to its payload folder.");
        return false;
    }
    say("Installing Wandsong into " + bin.string());

    // Back up anything we're about to replace (only the first time).
    fs::path backup = bin / kBackupDir;
    std::error_code ec;
    if (!fs::exists(backup, ec)) {
        fs::create_directories(backup, ec);
        for (const char* f : {"dwmapi.dll", "UE4SS.dll", "UE4SS-settings.ini", "Mods\\mods.txt"}) {
            if (fs::exists(bin / f, ec)) {
                fs::create_directories((backup / f).parent_path(), ec);
                fs::copy_file(bin / f, backup / f, fs::copy_options::overwrite_existing, ec);
            }
        }
    }

    std::vector<std::string> installed;
    bool had_settings = fs::exists(bin / "UE4SS-settings.ini", ec);
    bool had_mods_txt = fs::exists(bin / "Mods" / "mods.txt", ec);
    for (const auto& entry : fs::recursive_directory_iterator(payload, ec)) {
        if (!entry.is_regular_file()) continue;
        fs::path rel = fs::relative(entry.path(), payload);
        // Don't clobber a player's existing UE4SS config; we patch it below instead.
        if (rel == "UE4SS-settings.ini" && had_settings) continue;
        if (rel == fs::path("Mods") / "mods.txt" && had_mods_txt) continue;
        fs::path dest = bin / rel;
        fs::create_directories(dest.parent_path(), ec);
        if (!fs::copy_file(entry.path(), dest, fs::copy_options::overwrite_existing, ec)) {
            say("Couldn't copy " + rel.string() + ": " + ec.message());
            return false;
        }
        unblock(dest);
        installed.push_back(rel.string());
    }

    // Settings Hogwarts Legacy needs with UE4SS 3.0.1 (found the hard way).
    fs::path ini = bin / "UE4SS-settings.ini";
    ini_set(ini, "EngineVersionOverride", "MajorVersion", "4");
    ini_set(ini, "EngineVersionOverride", "MinorVersion", "27");
    ini_set(ini, "Debug", "GuiConsoleEnabled", "0");
    ini_set(ini, "Debug", "ConsoleEnabled", "0");
    ini_set(ini, "General", "bUseUObjectArrayCache", "false");
    enable_in_mods_txt(bin / "Mods" / "mods.txt");

    // Keep files recorded by earlier installs (e.g. a settings file we created back then).
    if (fs::exists(bin / kManifest, ec)) {
        for (const auto& rel : read_lines(bin / kManifest))
            if (rel[0] != '#' && std::find(installed.begin(), installed.end(), rel) == installed.end())
                installed.push_back(rel);
    }
    std::ofstream manifest(bin / kManifest, std::ios::binary);
    manifest << "# Wandsong " << kVersion << " installed files (relative to Win64)\r\n";
    for (const auto& f : installed) manifest << f << "\r\n";

    say("Done. Wandsong is installed.");
    say("Start Hogwarts Legacy from Steam or Epic as usual. You'll hear \"Wandsong ready\" "
        "once the game loads; press semicolon in game for help.");
    return true;
}

bool uninstall(const fs::path& game) {
    fs::path bin = game / kBinRel;
    std::error_code ec;
    if (!fs::exists(bin / kManifest, ec)) {
        say("Wandsong doesn't appear to be installed here.");
        return false;
    }
    for (const auto& rel : read_lines(bin / kManifest)) {
        if (rel[0] == '#') continue;
        fs::remove(bin / rel, ec);
        // Remove folders this left empty, up to (not including) Win64.
        for (fs::path dir = (bin / rel).parent_path(); dir != bin && dir.string().size() > bin.string().size();
             dir = dir.parent_path()) {
            if (!fs::is_empty(dir, ec) || !fs::remove(dir, ec)) break;
        }
    }
    fs::remove_all(bin / "Mods" / "Wandsong", ec);
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
    say("Wandsong has been removed and your previous files restored.");
    return true;
}

bool toggle_vanilla(const fs::path& game) {
    fs::path bin = game / kBinRel;
    std::error_code ec;
    if (fs::exists(bin / "dwmapi.dll", ec)) {
        fs::rename(bin / "dwmapi.dll", bin / "dwmapi.dll.off", ec);
        say(ec ? "Couldn't switch mods off: " + ec.message()
               : "Vanilla mode on: the game will start without any UE4SS mods. Run this again to switch them back on.");
    } else if (fs::exists(bin / "dwmapi.dll.off", ec)) {
        fs::rename(bin / "dwmapi.dll.off", bin / "dwmapi.dll", ec);
        say(ec ? "Couldn't switch mods on: " + ec.message() : "Vanilla mode off: Wandsong is active again.");
    } else {
        say("UE4SS isn't installed here, so there's nothing to switch.");
        return false;
    }
    return !ec;
}

fs::path exe_dir() {
    wchar_t path[MAX_PATH];
    GetModuleFileNameW(nullptr, path, MAX_PATH);
    return fs::path(path).parent_path();
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleTitleW(L"Wandsong setup");
    init_speech();

    std::string action;
    std::optional<std::string> game_arg;
    for (int i = 1; i < argc; ++i) {
        std::wstring a = argv[i];
        if (a == L"--install") action = "install";
        else if (a == L"--uninstall") action = "uninstall";
        else if (a == L"--vanilla") action = "vanilla";
        else if (a == L"--game" && i + 1 < argc) game_arg = fs::path(argv[++i]).string();
    }

    say(std::string("Wandsong setup, version ") + kVersion + ".", true);

    auto game = locate_game(game_arg);
    if (!game) {
        ask("Setup cancelled. Press Enter to close.");
        return 1;
    }
    if (game_running(*game)) {
        say("Hogwarts Legacy is running. Please quit the game first, then run setup again.");
        ask("Press Enter to close.");
        return 1;
    }

    bool interactive = action.empty();
    if (interactive) {
        bool present = fs::exists(*game / kBinRel / kManifest);
        say(present ? "Wandsong is already installed." : "Wandsong is not installed yet.");
        say("1: " + std::string(present ? "Update" : "Install") + " Wandsong");
        say("2: Uninstall Wandsong");
        say("3: Switch vanilla mode on or off (play without mods)");
        say("4: Exit");
        std::string choice = ask("Type a number and press Enter:");
        if (choice == "1") action = "install";
        else if (choice == "2") action = "uninstall";
        else if (choice == "3") action = "vanilla";
        else return 0;
    }

    bool ok = false;
    if (action == "install") ok = install(*game, exe_dir() / "payload");
    else if (action == "uninstall") ok = uninstall(*game);
    else if (action == "vanilla") ok = toggle_vanilla(*game);

    if (interactive) ask("Press Enter to close.");
    wait_for_speech();
    if (g_voice) prism_backend_free(g_voice);
    if (g_prism) prism_shutdown(g_prism);
    CoUninitialize();
    return ok ? 0 : 1;
}
