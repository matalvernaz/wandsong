// Checked, recoverable changes confined to the game's Win64 directory.
// The journal and all rollback copies are durable before the first destination changes.
// Keep this independent of the payload format so uninstall uses the same guarantees.
#pragma once

#include <array>
#include <map>
#include <stdexcept>

namespace setup_files {
inline const fs::path transaction_dir = "Wandsong-transaction";

[[noreturn]] inline void fail(const std::string& action, const fs::path& path) {
    DWORD error = GetLastError();
    throw std::runtime_error(action + " " + u8(path) + ": " +
                             std::system_category().message(static_cast<int>(error)));
}

// Windows also aliases trailing dots/spaces, device names and alternate data streams.
// Reject those spellings rather than trying to sanitize an untrusted file name.
inline fs::path relative_path(const std::string& text) {
    if (text.empty() || text.size() > 4096 || text.front() == '#' ||
        !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), (int)text.size(), nullptr, 0))
        throw std::runtime_error("Invalid installation path: " + text);
    std::string rel = text;
    std::replace(rel.begin(), rel.end(), '/', '\\');
    if (rel.front() == '\\' || rel.back() == '\\')
        throw std::runtime_error("Rooted or empty installation path: " + text);
    for (unsigned char c : rel)
        if (c < 32 || c == 127 || std::string(":\"<>|?*").find(c) != std::string::npos)
            throw std::runtime_error("Invalid installation path: " + text);
    std::istringstream parts(rel);
    for (std::string part; std::getline(parts, part, '\\');) {
        std::string stem = lower(part.substr(0, part.find('.')));
        if (part.empty() || part == "." || part == ".." || part.back() == '.' || part.back() == ' ' ||
            stem == "con" || stem == "prn" || stem == "aux" || stem == "nul" ||
            (stem.size() == 4 && (stem.substr(0, 3) == "com" || stem.substr(0, 3) == "lpt") &&
             stem[3] >= '1' && stem[3] <= '9'))
            throw std::runtime_error("Ambiguous installation path: " + text);
    }
    return from_u8(rel);
}

inline DWORD attributes(const fs::path& path) {
    DWORD attr = GetFileAttributesW(path.c_str());
    if (attr == INVALID_FILE_ATTRIBUTES && GetLastError() != ERROR_FILE_NOT_FOUND &&
        GetLastError() != ERROR_PATH_NOT_FOUND) fail("Couldn't inspect", path);
    return attr;
}

// No component may be a junction/symlink. Combined with strict relative components,
// this keeps every read, replacement and removal beneath the chosen root.
inline fs::path checked_path(const fs::path& root, const std::string& rel, bool file = true) {
    fs::path tail = relative_path(rel), current = root;
    DWORD attr = attributes(root);
    if (attr == INVALID_FILE_ATTRIBUTES || !(attr & FILE_ATTRIBUTE_DIRECTORY) ||
        (attr & FILE_ATTRIBUTE_REPARSE_POINT))
        throw std::runtime_error("Unsafe installation directory: " + u8(root));
    for (const auto& component : tail) {
        current /= component;
        attr = attributes(current);
        if (attr == INVALID_FILE_ATTRIBUTES) continue;
        if (attr & FILE_ATTRIBUTE_REPARSE_POINT)
            throw std::runtime_error("Setup won't follow a junction or symbolic link: " + u8(current));
        if (current != root / tail && !(attr & FILE_ATTRIBUTE_DIRECTORY))
            throw std::runtime_error("A file blocks the installation directory: " + u8(current));
    }
    if (file && attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY))
        throw std::runtime_error("A directory blocks the installation file: " + u8(current));
    return current;
}

inline bool present(const fs::path& path) { return attributes(path) != INVALID_FILE_ATTRIBUTES; }

inline void sync_file(const fs::path& path) {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) fail("Couldn't flush", path);
    BOOL ok = FlushFileBuffers(h);
    DWORD error = GetLastError();
    CloseHandle(h);
    if (!ok) { SetLastError(error); fail("Couldn't flush", path); }
}

inline void write_text(const fs::path& path, const std::string& text) {
    fs::create_directories(path.parent_path());
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    out.write(text.data(), static_cast<std::streamsize>(text.size()));
    out.close();
    if (!out) throw std::runtime_error("Couldn't write " + u8(path));
    sync_file(path);
}

inline bool equal_files(const fs::path& a, const fs::path& b) {
    if (!present(a) || !present(b) || fs::file_size(a) != fs::file_size(b)) return false;
    std::ifstream left(a, std::ios::binary), right(b, std::ios::binary);
    if (!left || !right) throw std::runtime_error("Couldn't verify " + u8(a) + " against " + u8(b));
    std::array<char, 65536> x{}, y{};
    do {
        left.read(x.data(), x.size()); right.read(y.data(), y.size());
        if (left.bad() || right.bad()) throw std::runtime_error("Read failed while verifying " + u8(a));
        if (left.gcount() != right.gcount() || !std::equal(x.begin(), x.begin() + left.gcount(), y.begin()))
            return false;
    } while (!left.eof());
    return true;
}

inline void copy_verified(const fs::path& source, const fs::path& dest) {
    fs::create_directories(dest.parent_path());
    std::ifstream in(source, std::ios::binary);
    if (!in) throw std::runtime_error("Couldn't read " + u8(source));
    std::ofstream out(dest, std::ios::binary | std::ios::trunc);
    std::array<char, 65536> bytes{};
    while (in) {
        in.read(bytes.data(), bytes.size());
        out.write(bytes.data(), in.gcount());
    }
    out.close();
    if (!in.eof() || in.bad() || !out) throw std::runtime_error("Couldn't copy " + u8(source) + " to " + u8(dest));
    sync_file(dest);
    if (!equal_files(source, dest)) throw std::runtime_error("Copy verification failed: " + u8(dest));
}

inline void move_file(const fs::path& source, const fs::path& dest) {
    if (!MoveFileExW(source.c_str(), dest.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
        fail("Couldn't replace", dest);
}

inline std::vector<std::string> tree_files(const fs::path& bin, const std::string& rel) {
    fs::path root = checked_path(bin, rel, false);
    std::vector<std::string> result;
    if (!present(root)) return result;
    if (!fs::is_directory(root)) throw std::runtime_error("Expected a directory: " + u8(root));
    for (const auto& entry : fs::recursive_directory_iterator(root)) {
        std::string name = u8(entry.path().lexically_relative(bin));
        checked_path(bin, name, false);
        if (entry.is_regular_file()) result.push_back(u8(entry.path().lexically_relative(root)));
    }
    return result;
}

inline void prune_empty(fs::path path, const fs::path& bin) {
    // Only empty directories under bin; never remove bin itself or follow reparse points.
    while (path != bin && !path.empty()) {
        checked_path(bin, u8(path.lexically_relative(bin)), false);
        if (!present(path) || !fs::is_directory(path) || !fs::is_empty(path)) break;
        fs::remove(path);
        path = path.parent_path();
    }
}

inline void remove_file(const fs::path& bin, const std::string& rel) {
    fs::path dest = checked_path(bin, rel);
    if (present(dest)) fs::remove(dest); // throws on failure; a missing file is already removed
    prune_empty(dest.parent_path(), bin);
}

inline void clear_transaction(const fs::path& bin) {
    fs::path root = checked_path(bin, u8(transaction_dir), false);
    if (!present(root)) return;
    // Validate the entire tree first. Never recursively delete a junction or an unchecked path.
    auto files = tree_files(bin, u8(transaction_dir));
    std::vector<fs::path> directories;
    for (const auto& entry : fs::recursive_directory_iterator(root))
        if (entry.is_directory()) directories.push_back(entry.path());
    // Keep the completion marker until the journal and every rollback copy are gone.
    // A locked temporary file must not turn a committed change into a later rollback.
    for (const auto& rel : files)
        if (key_of(rel) != "committed") fs::remove(checked_path(root, rel));
    std::sort(directories.begin(), directories.end(), [](const fs::path& a, const fs::path& b) {
        return a.native().size() > b.native().size();
    });
    for (const auto& dir : directories) fs::remove(dir);
    fs::remove(checked_path(root, "committed"));
    fs::remove(root);
}

inline void replace_from(const fs::path& bin, const fs::path& source, const std::string& rel) {
    fs::path dest = checked_path(bin, rel);
    if (equal_files(source, dest)) return;
    fs::create_directories(dest.parent_path());
    fs::path swap = checked_path(bin, u8(transaction_dir / "swap.tmp"));
    copy_verified(source, swap);
    checked_path(bin, rel);
    move_file(swap, dest);
    if (!equal_files(source, dest)) throw std::runtime_error("Replacement verification failed: " + u8(dest));
}

struct Record { std::string rel; bool existed; };

inline void recover(const fs::path& bin) {
    fs::path root = checked_path(bin, u8(transaction_dir), false);
    if (!present(root)) return;
    tree_files(bin, u8(transaction_dir));
    fs::path journal = checked_path(root, "journal.txt");
    fs::path committed = checked_path(root, "committed");
    if (present(committed)) {
        if (read_file(committed) != "committed\n")
            throw std::runtime_error("Invalid setup completion record; keep " + u8(root) + " for recovery.");
        clear_transaction(bin);
        return;
    }
    if (!present(journal)) { clear_transaction(bin); return; } // staging never changed destinations
    std::ifstream in(journal);
    std::string line;
    if (!std::getline(in, line) || line != "Wandsong transaction 1")
        throw std::runtime_error("Invalid setup journal; keep " + u8(root) + " for recovery.");
    std::vector<Record> records;
    std::set<std::string> seen;
    bool complete = false;
    while (std::getline(in, line)) {
        if (line == "END\t" + std::to_string(records.size())) { complete = true; break; }
        if (line.size() < 3 || line[1] != '\t' || (line[0] != 'R' && line[0] != 'N'))
            throw std::runtime_error("Invalid setup journal entry.");
        std::string rel = line.substr(2), key = key_of(rel);
        checked_path(bin, rel);
        if (key == "hogwartslegacy.exe" || key == "wandsong-setup.lock" ||
            key == "wandsong-transaction" || key.rfind("wandsong-transaction\\", 0) == 0 || !seen.insert(key).second)
            throw std::runtime_error("Unsafe setup journal entry: " + rel);
        if (line[0] == 'R' && !present(checked_path(root, "old\\" + rel)))
            throw std::runtime_error("Missing recovery copy for " + rel);
        records.push_back({rel, line[0] == 'R'});
    }
    if (!complete || std::getline(in, line) || in.bad())
        throw std::runtime_error("Incomplete setup journal; keep " + u8(root) + " for recovery.");
    in.close(); // Windows cannot remove the journal while this reader is open.
    // Validate everything before touching anything. Repeating recovery is safe.
    bool changed = false, owns_loader = false;
    for (const auto& record : records) {
        fs::path dest = checked_path(bin, record.rel);
        if (key_of(record.rel) == "dwmapi.dll") owns_loader = true;
        if (record.existed ? !equal_files(root / "old" / from_u8(record.rel), dest) : present(dest))
            changed = true;
    }
    // An interrupted update must not leave an active loader over mixed versions. Restore
    // it only after everything else. If no write happened, leave even a locked original alone.
    if (changed && owns_loader) remove_file(bin, "dwmapi.dll");
    for (auto it = records.rbegin(); it != records.rend(); ++it) {
        if (key_of(it->rel) == "dwmapi.dll") continue;
        if (it->existed) replace_from(bin, root / "old" / from_u8(it->rel), it->rel);
        else remove_file(bin, it->rel);
    }
    for (const auto& record : records) {
        if (key_of(record.rel) != "dwmapi.dll") continue;
        if (record.existed) replace_from(bin, root / "old" / from_u8(record.rel), record.rel);
        else remove_file(bin, record.rel);
    }
    // Mark a completed rollback too, before deleting its only copies.
    write_text(root / "complete.tmp", "committed\n");
    move_file(root / "complete.tmp", committed);
    clear_transaction(bin);
    say("The interrupted setup was rolled back. Your previous files were restored.");
}

class Lock {
    HANDLE handle;
public:
    explicit Lock(const fs::path& bin) {
        fs::path path = checked_path(bin, "Wandsong-setup.lock");
        handle = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                             FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, nullptr);
        if (handle == INVALID_HANDLE_VALUE) fail("Couldn't lock setup (another setup may be running):", path);
    }
    ~Lock() { CloseHandle(handle); }
    Lock(const Lock&) = delete;
    Lock& operator=(const Lock&) = delete;
};

class Transaction {
    struct Change { std::string rel; fs::path source; };
    fs::path bin, root;
    std::vector<Change> changes;
    std::set<std::string> destinations;
public:
    explicit Transaction(const fs::path& directory) : bin(directory), root(directory / transaction_dir) {
        checked_path(bin, u8(transaction_dir), false);
        if (!fs::create_directory(root)) throw std::runtime_error("A pending setup needs recovery first.");
    }
    fs::path stage(const std::string& rel) {
        fs::path dest = checked_path(root, "new\\" + rel);
        fs::create_directories(dest.parent_path());
        return dest;
    }
    void put(const std::string& rel, const fs::path& source) {
        checked_path(bin, rel);
        if (!destinations.insert(key_of(rel)).second) throw std::runtime_error("Repeated setup destination: " + rel);
        changes.push_back({rel, source});
    }
    void erase(const std::string& rel) { put(rel, {}); }
    void commit() {
        std::string journal = "Wandsong transaction 1\n";
        for (const auto& change : changes) {
            fs::path dest = checked_path(bin, change.rel);
            bool existed = present(dest);
            if (existed) copy_verified(dest, checked_path(root, "old\\" + change.rel));
            if (!change.source.empty()) sync_file(change.source);
            journal += std::string(existed ? "R\t" : "N\t") + change.rel + "\n";
        }
        journal += "END\t" + std::to_string(changes.size()) + "\n";
        write_text(root / "journal.tmp", journal);
        move_file(root / "journal.tmp", root / "journal.txt");
        if (destinations.count("dwmapi.dll")) remove_file(bin, "dwmapi.dll");
        for (const auto& change : changes) {
            if (key_of(change.rel) == "dwmapi.dll") continue;
            if (change.source.empty()) remove_file(bin, change.rel);
            else replace_from(bin, change.source, change.rel);
        }
        for (const auto& change : changes) {
            if (key_of(change.rel) != "dwmapi.dll") continue;
            if (change.source.empty()) remove_file(bin, change.rel);
            else replace_from(bin, change.source, change.rel);
        }
        write_text(root / "complete.tmp", "committed\n");
        move_file(root / "complete.tmp", root / "committed");
        try { clear_transaction(bin); }
        catch (const std::exception& e) {
            say(std::string("Files are committed. Setup will retry temporary-file cleanup next time: ") + e.what());
        }
    }
};
} // namespace setup_files
