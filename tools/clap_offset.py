#!/usr/bin/env python3
"""clap_offset.py: A/V offset of hand claps in a live HLS/RTMP stream, read from a pipe (no recording).
   python3 clap_offset.py [URL] [--seconds 40]
Video: frame-difference (signalstats YDIF) peaks; audio: per-40ms peak level. Both carry the stream's own pts,
so each clap gives audio_time - video_time. Positive = sound LATE -> studio.py --av-offset-ms -N (delay picture);
negative = sound EARLY -> --av-offset-ms +N (delay sound)."""
import re, subprocess, sys, argparse
p = argparse.ArgumentParser(); p.add_argument("url", nargs="?", default="https://relay.ples-duse.org:2053/studio/master.m3u8")
p.add_argument("--seconds", type=int, default=40); a = p.parse_args()
fc = ("[0:v]scale=160:90,format=gray,signalstats,metadata=print:key=lavfi.signalstats.YDIF:file=-[v];"
      "[0:a]aresample=8000,asetnsamples=320,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.Peak_level:file=-[a]")
cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-t", str(a.seconds), "-i", a.url, "-filter_complex", fc,
       "-map", "[v]", "-f", "null", "-", "-map", "[a]", "-f", "null", "-"]
try: out = subprocess.run(cmd, capture_output=True, text=True, timeout=a.seconds + 30).stdout
except subprocess.TimeoutExpired as e: out = (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or "")
v, au, t = [], [], None
for line in out.splitlines():
    m = re.search(r"pts_time:([\d.]+)", line)
    if m: t = float(m.group(1)); continue
    m = re.match(r"lavfi\.signalstats\.YDIF=([\d.]+)", line)
    if m and t is not None: v.append((t, float(m.group(1)))); continue
    m = re.match(r"lavfi\.astats\.Overall\.Peak_level=(-?[\d.inf]+)", line)
    if m and t is not None:
        try: au.append((t, float(m.group(1))))
        except ValueError: pass
if not v or not au: sys.exit(f"no data (video {len(v)}, audio {len(au)}): is the stream live?")
def onsets(s, thr, gap=0.6):
    r, last = [], -9
    for t, x in s:
        if x >= thr and t - last > gap: r.append(t)
        if x >= thr: last = t
    return r
vs = sorted(x for _, x in v); vthr = max(vs[int(len(vs) * .98)], vs[len(vs) // 2] * 4 + 1)
amax = max(x for _, x in au); athr = amax - 6
A, V = onsets(au, athr), onsets(v, vthr)
print(f"audio claps {len(A)}, video peaks {len(V)} (YDIF thr {vthr:.1f}, peak thr {athr:.1f} dBFS)")
ds = []
for ta in A:
    tv = min(V, key=lambda x: abs(x - ta)) if V else None
    if tv is not None and abs(ta - tv) < 0.5: ds.append((ta - tv) * 1000); print(f"  clap at {ta:7.2f}s: sound - picture = {ds[-1]:+.0f} ms")
if ds:
    ds.sort(); med = ds[len(ds) // 2]
    print(f"MEDIAN {med:+.0f} ms -> studio.py --av-offset-ms {-round(med/10)*10:+d}")
