"""EasyCut promo soundtrack: 120 BPM, 53 s, synthesized from scratch (no samples).

Event times match index.html (scene cuts, UI clicks, typing, checkmarks).
"""
import numpy as np, wave, sys

SR = 44100
DUR = 53.0
N = int(SR * DUR)
rng = np.random.default_rng(11)

BUSES = {}
def bus(name):
    if name not in BUSES:
        BUSES[name] = np.zeros((2, N))
    return BUSES[name]

def mtof(m): return 440.0 * 2 ** ((m - 69) / 12)
def tt(n): return np.arange(n) / SR

def place(name, sig, t0, g=1.0, pan=0.0):
    """Mono (1-D) or stereo (2, n) signal into a bus at time t0."""
    b = bus(name)
    i = int(round(t0 * SR))
    if sig.ndim == 1:
        a = (pan + 1) * np.pi / 4
        sig = np.vstack([sig * np.cos(a), sig * np.sin(a)]) * np.sqrt(2)
    if i < 0:
        sig = sig[:, -i:]; i = 0
    if i >= N: return
    j = min(N, i + sig.shape[1])
    b[:, i:j] += sig[:, :j - i] * g

def box(x, k):
    if k <= 1: return x
    return np.convolve(x, np.ones(k) / k, mode="same")

def hp(x, k): return x - box(x, k)

def env_ar(n, a, r, curve=2.0):
    e = np.ones(n)
    na, nr = int(a * SR), int(r * SR)
    if na > 0: e[:na] = np.linspace(0, 1, na) ** 1.5
    if nr > 0: e[-nr:] *= np.linspace(1, 0, nr) ** curve
    return e

# ---------------------------------------------------------------- instruments
def pad_chord(notes, dur, bright):
    n = int(dur * SR); t = tt(n)
    out = np.zeros((2, n))
    for m in notes:
        f0 = mtof(m)
        for dc, pan in ((-11, -0.7), (0, 0.0), (11, 0.7)):
            f = f0 * 2 ** (dc / 1200)
            ph = rng.uniform(0, 2 * np.pi)
            s = np.zeros(n)
            for k in range(1, 18):
                fk = f * k
                if fk > 10000: break
                a = (1.0 / k) * np.exp(-(k - 1) / (0.8 + bright * 7))
                s += a * np.sin(2 * np.pi * fk * t + ph * k)
            a = (pan + 1) * np.pi / 4
            out[0] += s * np.cos(a); out[1] += s * np.sin(a)
    out *= env_ar(n, 0.35, 0.9) / (len(notes) * 2.2)
    return out

def pluck(m, dur=0.7, bright=1.0):
    n = int(dur * SR); t = tt(n); f = mtof(m)
    s = np.zeros(n)
    for k in range(1, 11):
        if f * k > 12000: break
        s += (1 / k ** 1.15) * np.sin(2 * np.pi * f * k * t) * np.exp(-t * (5 + k * 4.0 / bright))
    return s * np.minimum(1, t / 0.002) * 0.6

def bass(m, dur, decay=1.2):
    n = int(dur * SR); t = tt(n); f = mtof(m)
    s = np.sin(2 * np.pi * f * t) + 0.35 * np.sin(4 * np.pi * f * t) + 0.12 * np.sin(6 * np.pi * f * t)
    s = np.tanh(s * 1.4)
    rel = np.clip((dur - t) / 0.04, 0, 1)
    return s * np.minimum(1, t / 0.004) * rel * np.exp(-t * decay) * 0.8

def kick():
    d = 0.5; t = tt(int(d * SR))
    f = 44 + 90 * np.exp(-t * 30)
    s = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 7)
    click = hp(rng.standard_normal(len(t)), 4) * np.exp(-t * 400) * 0.25
    return np.tanh((s + click) * 1.8) * 0.9

def clap():
    d = 0.35; n = int(d * SR); t = tt(n)
    nz = rng.standard_normal(n)
    bp = hp(box(nz, 3), 24)
    e = np.zeros(n)
    for off in (0, 0.009, 0.019):
        tt2 = np.clip(t - off, 0, None)
        e += (t >= off) * np.exp(-tt2 * 60) * 0.5
    e += (t >= 0.02) * np.exp(-np.clip(t - 0.02, 0, None) * 14) * 0.6
    return bp * e * 1.3

def hat(open_=False):
    d = 0.35 if open_ else 0.08; n = int(d * SR); t = tt(n)
    s = hp(hp(rng.standard_normal(n), 2), 3)
    return s * np.exp(-t * (9 if open_ else 55)) * 0.35

def crash(d=2.6):
    n = int(d * SR); t = tt(n)
    s = hp(rng.standard_normal(n), 3) * 0.6
    for f in (3150, 4720, 5930, 7510, 8830):
        s += 0.12 * np.sin(2 * np.pi * f * t + rng.uniform(0, 6))
    return s * np.exp(-t * 1.9) * np.minimum(1, t / 0.002) * 0.35

def boom(d=2.2):
    n = int(d * SR); t = tt(n)
    f = 38 + 70 * np.exp(-t * 9)
    s = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 2.2)
    return np.tanh(s * 1.5) * 0.9

def riser(d, lo=0.0):
    n = int(d * SR); t = tt(n); x = t / d
    nz = rng.standard_normal(n)
    s = hp(nz, 2) * x ** 2 * 0.25 + box(nz, 6) * x ** 3 * 0.3
    sweep = np.sin(2 * np.pi * np.cumsum(300 + 1500 * x ** 2) / SR) * x ** 3 * 0.06
    return s + sweep

def whoosh(d=0.6):
    n = int(d * SR); t = tt(n); x = t / d
    nz = rng.standard_normal(n)
    e = np.sin(np.pi * x) ** 2
    s = (box(nz, 5) * 0.7 + hp(nz, 3) * 0.3) * e
    return s * 0.5

def tick():
    n = int(0.03 * SR); t = tt(n)
    return hp(rng.standard_normal(n), 2) * np.exp(-t * 350) * 0.5 + np.sin(2 * np.pi * 2400 * t) * np.exp(-t * 400) * 0.2

def click():
    n = int(0.08 * SR); t = tt(n)
    return (np.sin(2 * np.pi * 1600 * t) * np.exp(-t * 120) * 0.5
            + hp(rng.standard_normal(n), 2) * np.exp(-t * 250) * 0.4)

def blip(m, d=0.35):
    n = int(d * SR); t = tt(n); f = mtof(m)
    s = np.sin(2 * np.pi * f * t) + 0.3 * np.sin(2 * np.pi * 2 * f * t) * np.exp(-t * 20)
    return s * np.exp(-t * 11) * np.minimum(1, t / 0.002) * 0.45

def bell(m, d=0.9):
    n = int(d * SR); t = tt(n); f = mtof(m)
    s = (np.sin(2 * np.pi * f * t) + 0.5 * np.sin(2 * np.pi * f * 2.76 * t) * np.exp(-t * 6)
         + 0.25 * np.sin(2 * np.pi * f * 5.4 * t) * np.exp(-t * 12))
    return s * np.exp(-t * 4.5) * np.minimum(1, t / 0.002) * 0.35

# ---------------------------------------------------------------- arrangement
BAR, BEAT = 2.0, 0.5
PROG = [  # (bass root, pad voicing)
    (46, [58, 62, 65, 69]),   # Bbmaj7
    (48, [60, 64, 67, 72]),   # C
    (45, [57, 60, 64, 67]),   # Am7
    (50, [57, 60, 62, 65]),   # Dm7
]
ARP = [0, 2, 3, 1, 2, 3, 1, 2]
BASS_PAT = [0, 0, 12, 0, 0, 0, 12, 0]

def section_bright(t):
    if t < 4: return 0.12 + 0.1 * t / 4
    if t < 8: return 0.4
    if 28 <= t < 30: return 0.25
    return 0.6

drum_on = lambda t: (8 <= t < 28) or (30 <= t < 46)
kicks = []

for b in range(23):              # bars 0..22 -> 0..46 s
    t0 = b * BAR
    root, voicing = PROG[b % 4]
    place("pad", pad_chord(voicing, BAR + 0.9, section_bright(t0)), t0, g=0.55)
    # arpeggio (starts at 2 s, quiet in the intro)
    if t0 >= 2:
        tones = sorted(voicing)
        g = 0.18 if t0 < 4 else (0.2 if 28 <= t0 < 30 else 0.3)
        br = 0.5 if t0 < 4 else 1.0
        for k in range(8):
            m = tones[ARP[k]] + 12
            tk = t0 + k * 0.25
            pan = -0.35 if k % 2 else 0.35
            place("pluck", pluck(m, 0.6, br), tk, g=g, pan=pan)
            place("pluck", pluck(m, 0.6, br * 0.7), tk + 0.375, g=g * 0.35, pan=-pan)  # dotted-8th echo
    # bass
    if 4 <= t0 < 8:
        place("bass", bass(root - 12, BAR, decay=0.6), t0, g=0.55)
    elif drum_on(t0):
        for k in range(8):
            place("bass", bass(root - 12 + BASS_PAT[k], 0.22, decay=3.0), t0 + k * 0.25, g=0.6)
    # drums
    if drum_on(t0):
        for k in range(4):
            tb = t0 + k * BEAT
            place("drums", kick(), tb, g=0.9); kicks.append(tb)
            if k in (1, 3): place("drums", clap(), tb, g=0.55, pan=0.05)
            place("drums", hat(), tb + 0.25, g=0.5, pan=0.25)
            if t0 >= 16:
                place("drums", hat(), tb + 0.125, g=0.18, pan=-0.2)
                place("drums", hat(), tb + 0.375, g=0.18, pan=-0.2)
            if 36 <= t0 < 46:
                place("drums", hat(True), tb + 0.25, g=0.22, pan=0.3)
    elif 28 <= t0 < 30:
        for k in range(8):
            place("drums", hat(), t0 + k * 0.25, g=0.22 if k % 2 else 0.12, pan=0.2)

# builds / fills
for i in range(8):                      # into drums at 8 s
    place("drums", clap(), 7.0 + i * 0.125, g=0.12 + 0.05 * i, pan=0.05)
for i in range(4):                      # small fill into AI section
    place("drums", clap(), 27.5 + i * 0.125, g=0.25 + 0.08 * i)
for i in range(16):                     # snare roll into the finale
    place("drums", clap(), 45.0 + i * 0.0625, g=0.08 + 0.03 * i)
place("fx", riser(2.0), 2.0, g=0.8)
place("fx", riser(1.0), 29.0, g=0.5)
place("fx", riser(2.0), 44.0, g=0.7)

# impacts
for t0, g in ((4.0, 1.0), (8.0, 0.5), (30.0, 0.35), (46.0, 1.0)):
    place("fx", crash(), t0, g=g)
for t0 in (4.0, 46.0):
    place("drums", boom(), t0, g=0.9)
    kicks.append(t0)
place("drums", kick(), 8.0, g=0.3)

# finale: F add9 ringing out
place("pad", pad_chord([53, 57, 60, 67, 69], 7.0, 0.55), 46.0, g=0.65)
place("bass", bass(29, 5.0, decay=0.5), 46.0, g=0.6)
for i, m in enumerate([65, 69, 72, 76, 79, 84, 81, 79]):
    place("pluck", pluck(m, 1.2, 0.9), 46.1 + i * 0.19, g=0.26, pan=(-0.4 if i % 2 else 0.4))
    place("pluck", pluck(m, 1.2, 0.6), 46.1 + i * 0.19 + 0.375, g=0.09, pan=(0.4 if i % 2 else -0.4))

# ---------------------------------------------------------------- UI sound effects
for tb in (15.75, 21.75, 27.75, 35.75, 41.75):    # scene transitions
    place("fx", whoosh(0.6), tb - 0.1, g=0.45)
place("fx", whoosh(0.8), 3.4, g=0.5)

place("fx", click(), 11.14, g=0.6)                  # S3: backspace key
place("fx", whoosh(0.35), 11.75, g=0.35)            # S3: cut
place("fx", blip(84), 12.55, g=0.35)                # S3: toast

SEGS = [("v", 4.0), ("s", 1.6), ("v", 5.1), ("s", 2.3), ("v", 5.6), ("s", 1.4),
        ("v", 4.4), ("s", 2.8), ("v", 4.9), ("s", 1.6), ("v", 5.59)]
TOTAL = sum(d for _, d in SEGS)
acc = 0.0; notes = [72, 74, 76, 79, 81]; si = 0
for kind, d in SEGS:                                # S4: scan finds each gap
    if kind == "s":
        place("fx", blip(notes[si]), 17.4 + acc / TOTAL * 1.0, g=0.35); si += 1
    acc += d
place("fx", click(), 18.58, g=0.6)                  # S4: button
place("fx", whoosh(0.7), 18.85, g=0.4)              # S4: collapse
place("fx", bell(84), 19.72, g=0.3)

for tc in (23.0, 24.6, 26.0):                       # S5: caption pops
    place("fx", blip(79, 0.25), tc, g=0.25)
    place("fx", click(), tc - 0.02, g=0.25)

for i in range(26):                                 # S6: typing
    place("fx", tick(), 28.8 + i * 1.8 / 26 + rng.uniform(-0.008, 0.008), g=0.35, pan=rng.uniform(-0.2, 0.2))
place("fx", blip(77, 0.3), 30.8, g=0.4)             # send
for i, tc in enumerate((32.0, 32.35, 32.7)):
    place("fx", bell(79 + 2 * i, 0.7), tc, g=0.28)
place("fx", bell(86, 1.2), 33.2, g=0.22)

for i, m in enumerate([65, 67, 69, 72, 74, 77, 79, 81]):   # S7: tiles
    place("fx", blip(m + 12, 0.3), 36.3 + i * 0.12, g=0.22, pan=-0.5 + i / 7)

for tc in (43.35, 44.65):                           # S8: screen swaps
    place("fx", whoosh(0.4), tc - 0.2, g=0.25)

# ---------------------------------------------------------------- mix
sc = np.ones(N)                                     # sidechain from kicks
for tk in kicks:
    i = int(tk * SR); n = int(0.45 * SR); j = min(N, i + n)
    seg = 1 - 0.6 * np.exp(-tt(j - i) / 0.12)
    sc[i:j] = np.minimum(sc[i:j], seg)

def reverb(x, sec=2.6, decay=2.6, seed=3):
    r = np.random.default_rng(seed)
    n = int(sec * SR); t = tt(n)
    out = np.zeros_like(x)
    size = 1 << int(np.ceil(np.log2(N + n)))
    for ch in range(2):
        ir = box(r.standard_normal(n), 3) * np.exp(-t * decay)
        ir[: int(0.012 * SR)] = 0                   # pre-delay
        ir /= np.sqrt(np.sum(ir ** 2))
        y = np.fft.irfft(np.fft.rfft(x[ch], size) * np.fft.rfft(ir, size), size)[:N]
        out[ch] = y
    return out

pad = bus("pad") * sc; bas = bus("bass") * sc; plk = bus("pluck") * (0.55 + 0.45 * sc)
drm = bus("drums"); fx = bus("fx")
dry = pad * 0.9 + bas * 0.8 + plk * 0.9 + drm * 0.85 + fx * 0.9
send = pad * 0.35 + plk * 0.45 + fx * 0.35 + drm * 0.08
mix = dry + reverb(send) * 0.45

# master: gentle high-cut on the noisiest bits, fade, soft limiter
t = tt(N)
mix *= np.clip(t / 0.03, 0, 1) * np.clip((DUR - t) / 2.5, 0, 1) ** 1.5
mix /= np.percentile(np.abs(mix), 99.9) + 1e-9
mix = np.tanh(mix * 1.1) / np.tanh(1.1)
mix *= 0.89 / np.max(np.abs(mix))

pcm = (mix.T * 32767).astype(np.int16)
out = sys.argv[1] if len(sys.argv) > 1 else "music.wav"
with wave.open(out, "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(pcm.tobytes())
print("wrote", out, f"{DUR}s")
