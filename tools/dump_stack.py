"""List the crashing thread's likely return addresses (stack scan) by module, for a minidump.

    python tools/dump_stack.py <file.dmp> [max lines]     (needs: pip install minidump)

Works on UE4SS's own dumps (Win64\\crash_*.dmp). Symbolize the UE4SS.dll offsets it prints
with llvm-symbolizer --obj=symbols/UE4SS.dll --relative-address 0x<offset>. A scan, not an
unwind: entries are candidates, newest first; the dump writer's own frames come first.
"""
import struct
import sys
import logging

logging.disable(logging.CRITICAL)
from minidump.minidumpfile import MinidumpFile

mf = MinidumpFile.parse(sys.argv[1])
reader = mf.get_reader()
mods = sorted(((m.baseaddress, m.size, m.name.split("\\")[-1]) for m in mf.modules.modules))


def where(addr):
    for base, size, name in mods:
        if base <= addr < base + size:
            return name, addr - base
    return None, None


exc = mf.exception.exception_records[0]
rec = exc.ExceptionRecord
print("exception", rec.ExceptionCode, "thread", exc.ThreadId)
params = [p for p in rec.ExceptionInformation[:rec.NumberParameters]]
for p in params:
    n, off = where(p)
    print("  param", hex(p), n and ("%s+%x" % (n, off)) or "")
# Find the thread's stack and scan it for code addresses.
thread = [t for t in mf.threads.threads if t.ThreadId == exc.ThreadId][0]
ctx_rsp = None
try:
    ctx = thread.ContextObject
    ctx_rsp = ctx.Rsp
except Exception:
    pass
stack_start = thread.Stack.StartOfMemoryRange
stack_size = thread.Stack.MemoryLocation.DataSize
start = ctx_rsp if ctx_rsp and stack_start <= ctx_rsp < stack_start + stack_size else stack_start
size = stack_start + stack_size - start
data = reader.read(start, min(size, 0x20000))
seen = 0
for i in range(0, len(data) - 8, 8):
    v = struct.unpack_from("<Q", data, i)[0]
    n, off = where(v)
    if n and not n.lower().startswith(("ntdll", "kernelbase", "kernel32")):
        print("  %08x  %s+%x" % (i, n, off))
        seen += 1
        if seen > int(sys.argv[2] if len(sys.argv) > 2 else 60):
            break
