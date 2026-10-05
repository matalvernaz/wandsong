"""Turn Hogwarts Legacy crash reports into UE4SS function names.

The game's crash reporter writes Saved\\Crashes\\<id>\\CrashContext.runtime-xml with a call
stack of "UE4SS 0x... + offset" entries. UE4SS.pdb from the matching zDEV release (its
UE4SS.dll is byte-identical to the normal release) resolves those offsets, via LLVM's
llvm-symbolizer.

    python symbolize_crash.py <folder with UE4SS.dll and UE4SS.pdb> [crash folder ...]

With no crash folders, the four newest crashes are symbolized.
"""
import os, re, subprocess, sys, time

SYMBOLIZER = os.environ.get("LLVM_SYMBOLIZER", r"C:\Program Files\LLVM\bin\llvm-symbolizer.exe")


def frames(xml):
    """The crashed thread's call stack, as (module, offset) pairs."""
    m = re.search(r"<CallStack>([^<]*)</CallStack>\s*<IsCrashed>true", xml)
    stack = m.group(1) if m else (re.search(r"<PCallStack>([^<]*)</PCallStack>", xml) or [None, ""])[1]
    return [(mod, int(off, 16)) for mod, off in re.findall(r"(\S+) 0x[0-9a-fA-F]+ \+ ([0-9a-fA-F]+)", stack)]


def symbolize(dll, offsets):
    out = subprocess.run([SYMBOLIZER, "--obj=" + dll, "--relative-address", "--functions=short"]
                         + [hex(o) for o in offsets], capture_output=True, text=True).stdout
    blocks = [b.strip().splitlines() for b in out.strip().split("\n\n")]
    names = {}
    for off, b in zip(offsets, blocks):
        fn = b[0] if b else "?"
        src = os.path.basename(b[1].replace("\\", "/")) if len(b) > 1 else ""
        names[off] = f"{fn}  ({src})" if src else fn
    return names


def main():
    dll = os.path.join(os.path.abspath(sys.argv[1]), "UE4SS.dll")
    crashes = sys.argv[2:]
    if not crashes:
        root = os.path.join(os.environ["LOCALAPPDATA"], "Hogwarts Legacy", "Saved", "Crashes")
        crashes = sorted((os.path.join(root, d) for d in os.listdir(root)), key=os.path.getmtime, reverse=True)[:4]
    for c in crashes:
        xml = open(os.path.join(c, "CrashContext.runtime-xml"), encoding="utf-8", errors="replace").read()
        secs = re.search(r"<SecondsSinceStart>(\d+)", xml)
        fr = frames(xml)
        names = symbolize(dll, sorted({o for m, o in fr if m.upper() == "UE4SS"}))
        when = time.strftime("%Y-%m-%d %H:%M", time.localtime(os.path.getmtime(c)))
        print(f"== {os.path.basename(c)}  ({when}, {secs.group(1) if secs else '?'} s after start)")
        last = None
        for mod, off in fr:
            s = names.get(off, "?") if mod.upper() == "UE4SS" else f"+{off:x}"
            line = f"   {mod:<15} {s}"
            if line != last:
                print(line)
            last = line
        print()


if __name__ == "__main__":
    main()
