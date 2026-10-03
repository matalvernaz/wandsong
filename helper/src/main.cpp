// Wandsong speech helper.
//
// The UE4SS Lua mod can't load native libraries, so it starts this windowless helper and
// writes lines to a named pipe. Each line is "I|text" (interrupt), "Q|text" (queue), "S|"
// (stop speech) or "C|text" (copy to clipboard, \x1f between lines). The helper speaks them
// through the user's screen reader, or a system voice when none is running, using Prism
// (https://github.com/ethindp/prism). Prism's output call also sends the text to a braille
// display where the screen reader supports it.
//
// One instance at a time (named mutex). Exits when Hogwarts Legacy exits, or after two
// minutes if the game never appears.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <tlhelp32.h>
#include <share.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdarg>
#include <cstdio>
#include <deque>
#include <mutex>
#include <string>
#include <thread>

#include "prism.h"

namespace {

constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\wandsong";
constexpr wchar_t kMutexName[] = L"Local\\WandsongHelper";
constexpr wchar_t kGameExe[] = L"HogwartsLegacy.exe";
constexpr DWORD kPipeBuffer = 64 * 1024;
constexpr auto kBackendRecheck = std::chrono::seconds(5);
constexpr auto kGameWaitLimit = std::chrono::minutes(2);

struct Message {
    enum Kind { Speak, Stop } kind;
    bool interrupt;
    std::string text;
};

std::mutex g_queue_mutex;
std::condition_variable g_queue_cv;
std::deque<Message> g_queue;
std::atomic<bool> g_quit{false};
FILE* g_log = nullptr;

void log(const char* fmt, ...) {
    if (!g_log) return;
    SYSTEMTIME t;
    GetLocalTime(&t);
    std::fprintf(g_log, "[%02d:%02d:%02d] ", t.wHour, t.wMinute, t.wSecond);
    va_list args;
    va_start(args, fmt);
    std::vfprintf(g_log, fmt, args);
    va_end(args);
    std::fputc('\n', g_log);
    std::fflush(g_log);
}

void push(Message m) {
    {
        std::lock_guard<std::mutex> lock(g_queue_mutex);
        // An interrupting message makes anything still waiting pointless.
        if (m.kind == Message::Stop || m.interrupt) g_queue.clear();
        g_queue.push_back(std::move(m));
    }
    g_queue_cv.notify_one();
}

// Put UTF-8 text on the clipboard; the mod uses \x1f (unit separator) between lines.
void set_clipboard(const std::string& text) {
    std::string crlf;
    for (char c : text) {
        if (c == '\x1f') crlf += "\r\n";
        else crlf += c;
    }
    int wlen = MultiByteToWideChar(CP_UTF8, 0, crlf.c_str(), -1, nullptr, 0);
    if (wlen <= 0) return;
    HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, wlen * sizeof(wchar_t));
    if (!mem) return;
    MultiByteToWideChar(CP_UTF8, 0, crlf.c_str(), -1, static_cast<wchar_t*>(GlobalLock(mem)), wlen);
    GlobalUnlock(mem);
    for (int attempt = 0; attempt < 5; ++attempt) {
        if (OpenClipboard(nullptr)) {
            EmptyClipboard();
            if (SetClipboardData(CF_UNICODETEXT, mem)) mem = nullptr;  // clipboard owns it now
            CloseClipboard();
            break;
        }
        Sleep(20);
    }
    if (mem) GlobalFree(mem);
}

// Parse one protocol line from the Lua mod.
void handle_line(std::string line) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.size() < 2 || line[1] != '|') return;
    switch (line[0]) {
        case 'I': push({Message::Speak, true, line.substr(2)}); break;
        case 'Q': push({Message::Speak, false, line.substr(2)}); break;
        case 'S': push({Message::Stop, true, {}}); break;
        case 'C': set_clipboard(line.substr(2)); break;
        default: break;
    }
}

// --- Speech thread: owns the Prism context and backend (backends aren't thread-safe). ---

void speech_thread() {
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    PrismConfig cfg = prism_config_init();
    PrismContext* ctx = prism_init(&cfg);
    if (!ctx) {
        log("prism_init failed");
        CoUninitialize();
        return;
    }
    log("prism %s, %zu backends registered", prism_version_string(), prism_registry_count(ctx));

    PrismBackend* backend = nullptr;
    auto last_check = std::chrono::steady_clock::time_point{};

    // Re-pick the best backend now and then, so starting NVDA mid-game is noticed.
    auto refresh_backend = [&] {
        auto now = std::chrono::steady_clock::now();
        if (backend && now - last_check < kBackendRecheck) return;
        last_check = now;
        PrismBackend* best = prism_registry_acquire_best(ctx);
        if (!best) return;
        const char* new_name = prism_backend_name(best);
        const char* old_name = backend ? prism_backend_name(backend) : "";
        if (backend && std::string(new_name) == old_name) {
            prism_backend_free(best);
            return;
        }
        if (backend) prism_backend_free(backend);
        backend = best;
        log("speaking through %s", new_name);
    };

    while (!g_quit) {
        Message m;
        {
            std::unique_lock<std::mutex> lock(g_queue_mutex);
            g_queue_cv.wait(lock, [] { return g_quit || !g_queue.empty(); });
            if (g_quit) break;
            m = std::move(g_queue.front());
            g_queue.pop_front();
        }
        refresh_backend();
        if (!backend) continue;
        if (m.kind == Message::Stop) {
            (void)prism_backend_stop(backend);
            continue;
        }
        PrismError err = prism_backend_output(backend, m.text.c_str(), m.interrupt);
        if (err != PRISM_OK) {
            err = prism_backend_speak(backend, m.text.c_str(), m.interrupt);
            if (err != PRISM_OK) log("speak failed: %s", prism_error_string(err));
        }
    }

    if (backend) prism_backend_free(backend);
    prism_shutdown(ctx);
    CoUninitialize();
}

// --- Pipe server: one reader thread per connected client. ---

void client_thread(HANDLE pipe) {
    std::string pending;
    char buf[4096];
    DWORD got = 0;
    while (!g_quit && ReadFile(pipe, buf, sizeof(buf), &got, nullptr) && got > 0) {
        pending.append(buf, got);
        size_t nl;
        while ((nl = pending.find('\n')) != std::string::npos) {
            handle_line(pending.substr(0, nl));
            pending.erase(0, nl + 1);
        }
    }
    if (!pending.empty()) handle_line(pending);
    DisconnectNamedPipe(pipe);
    CloseHandle(pipe);
    log("client disconnected");
}

void pipe_server_thread() {
    while (!g_quit) {
        HANDLE pipe = CreateNamedPipeW(kPipeName, PIPE_ACCESS_INBOUND,
                                       PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
                                       PIPE_UNLIMITED_INSTANCES, kPipeBuffer, kPipeBuffer, 0,
                                       nullptr);
        if (pipe == INVALID_HANDLE_VALUE) {
            log("CreateNamedPipe failed: %lu", GetLastError());
            Sleep(1000);
            continue;
        }
        BOOL ok = ConnectNamedPipe(pipe, nullptr) ? TRUE : (GetLastError() == ERROR_PIPE_CONNECTED);
        if (!ok) {
            CloseHandle(pipe);
            continue;
        }
        log("client connected");
        std::thread(client_thread, pipe).detach();
    }
}

// --- Lifetime: follow the game process. ---

bool game_running() {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return true;  // can't tell; stay alive
    PROCESSENTRY32W pe{sizeof(pe)};
    bool found = false;
    for (BOOL more = Process32FirstW(snap, &pe); more; more = Process32NextW(snap, &pe)) {
        if (_wcsicmp(pe.szExeFile, kGameExe) == 0) {
            found = true;
            break;
        }
    }
    CloseHandle(snap);
    return found;
}

void open_log() {
    wchar_t path[MAX_PATH];
    DWORD n = GetModuleFileNameW(nullptr, path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return;
    wchar_t* slash = wcsrchr(path, L'\\');
    if (!slash) return;
    wcscpy_s(slash + 1, MAX_PATH - (slash + 1 - path), L"wandsong_helper.log");
    g_log = _wfsopen(path, L"w", _SH_DENYNO);  // readable while the helper runs
}

}  // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR cmdline, int) {
    HANDLE mutex = CreateMutexW(nullptr, TRUE, kMutexName);
    if (GetLastError() == ERROR_ALREADY_EXISTS) return 0;

    open_log();
    log("Wandsong helper starting");

    std::thread speech(speech_thread);
    std::thread(pipe_server_thread).detach();

    // "--say text" speaks once and exits (used by the installer and for testing).
    if (cmdline && wcsncmp(cmdline, L"--say ", 6) == 0) {
        int len = WideCharToMultiByte(CP_UTF8, 0, cmdline + 6, -1, nullptr, 0, nullptr, nullptr);
        std::string text(len > 0 ? len - 1 : 0, '\0');
        WideCharToMultiByte(CP_UTF8, 0, cmdline + 6, -1, text.data(), len, nullptr, nullptr);
        push({Message::Speak, true, text});
        Sleep(4000);
    } else {
        auto started = std::chrono::steady_clock::now();
        bool seen_game = false;
        for (;;) {
            Sleep(2000);
            bool running = game_running();
            if (running) seen_game = true;
            if (seen_game && !running) break;
            if (!seen_game && std::chrono::steady_clock::now() - started > kGameWaitLimit) break;
        }
        log("game gone, exiting");
    }

    g_quit = true;
    g_queue_cv.notify_all();
    speech.join();
    if (g_log) std::fclose(g_log);
    if (mutex) CloseHandle(mutex);
    return 0;
}
