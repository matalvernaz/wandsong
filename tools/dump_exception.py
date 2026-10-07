"""Print a minidump's exception record, faulting registers and nearby memory.

    python -I dumpinfo.py <file.dmp>
"""
import struct
import sys

from minidump.minidumpfile import MinidumpFile


def main():
    mf = MinidumpFile.parse(sys.argv[1])
    reader = mf.get_reader()

    mods = sorted(((m.baseaddress, m.size, m.name.split("\\")[-1]) for m in mf.modules.modules))

    def where(addr):
        for base, size, name in mods:
            if base <= addr < base + size:
                return "%s+%x" % (name, addr - base)
        return "?"

    exc = mf.exception.exception_records[0]
    rec = exc.ExceptionRecord
    print("thread", exc.ThreadId)
    print("code %08x at %x (%s)" % (rec.ExceptionCode_raw if hasattr(rec, "ExceptionCode_raw") else
                                    int(rec.ExceptionCode.value if hasattr(rec.ExceptionCode, "value") else rec.ExceptionCode),
                                    rec.ExceptionAddress, where(rec.ExceptionAddress)))
    print("params", [hex(p) for p in rec.ExceptionInformation[:rec.NumberParameters]])

    # x64 CONTEXT: Rax at 0x78, then Rcx, Rdx, Rbx, Rsp, Rbp, Rsi, Rdi, R8..R15, Rip at 0xF8.
    loc = exc.ThreadContext
    mf.file_handle.seek(loc.Rva)
    ctx = mf.file_handle.read(loc.DataSize)
    names = ["rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
             "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "rip"]
    regs = dict(zip(names, struct.unpack_from("<17Q", ctx, 0x78)))
    for n in names:
        print("%-4s %016x  %s" % (n, regs[n], where(regs[n])))

    def read(addr, n):
        try:
            return reader.read(addr, n)
        except Exception as e:  # not captured in the dump
            return None

    for n in ("rcx", "rdx", "rbx", "rsi", "rdi", "r8", "r14", "r15"):
        data = read(regs[n], 0x40)
        if data:
            q = struct.unpack_from("<8Q", data)
            print("[%s] %s" % (n, " ".join("%016x" % v for v in q)))
            print("      vtable? %s" % where(q[0]))
    stack = read(regs["rsp"], 0x200)
    if stack:
        print("stack words that point into modules:")
        for i in range(0, len(stack), 8):
            v = struct.unpack_from("<Q", stack, i)[0]
            w = where(v)
            if w != "?":
                print("  rsp+%03x %016x %s" % (i, v, w))
    code = read(rec.ExceptionAddress - 0x20, 0x40)
    if code:
        print("code bytes around fault:", code.hex())


if __name__ == "__main__":
    main()
