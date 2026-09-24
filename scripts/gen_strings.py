#!/usr/bin/env python3
"""LocTable.swift(한국어 → 영어)에서 en.lproj/Localizable.strings 를 만든다.
SwiftUI 문구의 키는 보간값 종류에 따라 %@ / %lld / %lf 로 바뀌므로 자리표시마다 세 가지를 모두 만든다."""
import itertools, json, re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "Sources/EasyCut/App/LocTable.swift").read_text(encoding="utf-8")
pairs = []
for line in src.splitlines():
    line = line.strip()
    if not line.startswith('"'):
        continue
    m = re.match(r'^("(?:[^"\\]|\\.)*")\s*:\s*("(?:[^"\\]|\\.)*"),$', line)
    if not m:
        continue
    pairs.append((json.loads(m.group(1)), json.loads(m.group(2))))

ph = re.compile(r'\{\}|%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfFeEgGcCsSaA]')

def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

out = {}
for k, v in pairs:
    kp = ph.findall(k)
    if not kp:
        out[k] = v
        continue
    if all(p != "{}" for p in kp):
        out[k] = v  # String(format:) 문구: 그대로
        continue
    # {} 자리 → SwiftUI 보간 종류들
    kparts = ph.split(k)
    vparts = ph.split(v)
    vph = ph.findall(v)
    n = len(kp)
    for combo in itertools.product(["%@", "%lld", "%lf"], repeat=min(n, 4)):
        combo = list(combo) + ["%@"] * (n - len(combo))
        def build(parts, placeholders):
            s = ""
            for i, part in enumerate(parts):
                s += part.replace("%", "%%")
                if i < len(placeholders):
                    s += placeholders[i]
            return s
        key = build(kparts, [combo[i] if p == "{}" else p for i, p in enumerate(kp)])
        val = build(vparts, [combo[i] if i < n else p for i, p in enumerate(vph)])
        out[key] = val

dest = root / "Resources/en.lproj/Localizable.strings"
dest.parent.mkdir(parents=True, exist_ok=True)
dest.write_text("".join(f'"{esc(k)}" = "{esc(v)}";\n' for k, v in sorted(out.items())), encoding="utf-8")
print(f"{len(out)} entries -> {dest.relative_to(root)}")
