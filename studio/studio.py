#!/usr/bin/env python3
"""studio.py: the Mac as the encoder ("Studio"), Marko 15.11.2026:
"use the power of the Mac since it's connected to the mixer and to the Wi-Fi and use just the phone to deliver the image
from the Sony camera with Wi-Fi to the Mac ... Mac is streaming."

  Picture Link: Manual Camera's NDI HX on the LAN (Bonjour; --extra-ips for Tailscale) -> libndi decodes -> UYVY frames
  Sound:        the mixer straight into the Mac (avfoundation, the device and pair Sound Link uses, or --audio/--pair)
  Master:       ONE stream, 1080p25 H.264 (VideoToolbox) ~5 Mbit/s, GOP 2 s + AAC 160 kbit/s stereo (AudioToolbox)
                -> RTMP over Tailscale to chromium-vm (studio-ladder), which builds the quality ladder for the viewers.

The Mac's uplink is a 4G SIM: it sends only the master; the VM makes 720/480/360 and the Q:80/40 S/M audio.

  python3 studio.py --list                     NDI sources and audio devices
  python3 studio.py                            first Manual Camera source + Sound Link's device/pair (or BlackHole 1-2)
  python3 studio.py --ndi "PIXEL" --audio "CQ" --pair 1 --av-offset-ms 120
  python3 studio.py --test                     test pattern over NDI (ndi_testsend.py) + a test tone: proves the chain
Stop: Ctrl+C (or kill the pid in ~/.cache/studio/studio.pid). Status: ~/.cache/studio/status.json every 2 s.
"""
import argparse, json, os, queue, re, signal, subprocess, sys, threading, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ndi  # noqa: E402

W, H, FPS = 1920, 1080, 25
CACHE = os.path.expanduser("~/.cache/studio")
DEFAULT_TO = "rtmp://100.102.86.30:1935/studio/master"   # chromium-vm's Tailscale address (studio-ladder)
SOUND_LINK = "http://127.0.0.1:8974/fn/status"
SITE = os.environ.get("STUDIO_SITE", "https://santoshi-band.pages.dev")
TOKEN_FILE = os.path.expanduser("~/.config/studio/camera-token")   # the site's camera token for "MacBook Pro" (chmod 600, never printed)


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def audio_devices():
    r = subprocess.run(["ffmpeg", "-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""],
                       capture_output=True, text=True)
    out, on = [], False
    for line in r.stderr.splitlines():
        if "audio devices" in line:
            on = True; continue
        m = re.search(r"\]\s*\[(\d+)\]\s*(.+)$", line)
        if on and m:
            out.append((int(m.group(1)), m.group(2).strip()))
    return out


def site(action):
    """GO / STOP the band site's live as the paired camera "MacBook Pro" with via "studio" (viewers get the ladder and the gear)."""
    try:
        tok = open(TOKEN_FILE).read().strip()
    except OSError:
        log("no camera token in", TOKEN_FILE, "- pair \"MacBook Pro\" at /admin (PAIR CAMERA) and save the token there")
        return None
    req = urllib.request.Request(SITE + "/api/live", method="POST", data=json.dumps({"action": action, "via": "studio"}).encode(),
                                 headers={"content-type": "application/json", "authorization": "Bearer " + tok})
    try:
        j = json.load(urllib.request.urlopen(req, timeout=10))
        log(f"SITE {action}: live={j.get('live')} via={j.get('via')}")
        return j
    except Exception as e:
        log(f"SITE {action} failed: {e}")
        return None


def sound_link_choice():
    """(device name, pair index 1-based) from Sound Link (Mantra) if it runs, else None."""
    try:
        req = urllib.request.Request(SOUND_LINK, data=b"{}", method="POST")
        j = json.load(urllib.request.urlopen(req, timeout=1.5))
        dev = j.get("device") or (j.get("source") or {}).get("device")
        pair = j.get("pair") or (j.get("source") or {}).get("pair")
        if dev:
            return dev, int(pair or 1)
    except Exception:
        pass
    return None


class Frames:
    """The NDI picture through the frame sync (review #8, as DistroAV): pull() is called at the output's own clock
    (25 fps) and gives the frame the frame sync chose for this tick (repeated when the source is slower or sends only
    on change, dropped when faster), converted to 1920x1080 UYVY (letterboxed if the source is another size).
    The source is connected by its NAME (review #6); url only for an address typed by hand.
    UYVY, UYVA, BGRA, BGRX, RGBA, RGBX are converted (review #1); any other FourCC is logged once and skipped."""
    def __init__(self, source, url=""):
        self.rx = ndi.Receiver(source, url)
        self.fs = ndi.FrameSync(self.rx)
        self.latest = None
        self.got = 0; self.repeats = 0; self.last_at = 0.0; self.size = None; self.fourcc = None
        self._maps = {}
        self._last_ts = None
        self._skipped = set()
        self.stop = False

    def _fit(self, data, w, h, stride):
        w = w // 2 * 2
        if (w, h) == (W, H):
            return data
        import numpy as np
        key = (w, h)
        if key not in self._maps:
            s = min(W / w, H / h)
            ow, oh = max(2, int(w * s) // 2 * 2), max(2, int(h * s))
            x0, y0 = (W - ow) // 2 // 2 * 2, (H - oh) // 2
            ys = (np.arange(oh) * h // oh).astype(np.intp)
            # UYVY: pairs of pixels share U and V; map in macro-pixels of 4 bytes
            xs = (np.arange(ow // 2) * (w // 2) // (ow // 2)).astype(np.intp)
            self._maps[key] = (ys, xs, x0, y0, ow, oh)
        ys, xs, x0, y0, ow, oh = self._maps[key]
        src = np.frombuffer(data, dtype=np.uint8).reshape(h, w // 2, 4)
        out = np.empty((H, W // 2, 4), dtype=np.uint8)
        out[:] = (128, 16, 128, 16)  # black in UYVY
        out[y0:y0 + oh, x0 // 2: x0 // 2 + ow // 2] = src[ys][:, xs]
        return out.tobytes()

    def pull(self):
        """One tick of the output clock: the frame sync's frame as 1920x1080 UYVY, or None before the first frame."""
        f = self.fs.video()
        if f is None:
            return self.latest
        w, h, fourcc, data, stride, ts = f
        if ts == self._last_ts and self.latest is not None:
            self.repeats += 1                 # the same frame again: the source is slower or static
            return self.latest
        uy = ndi.to_uyvy(data, w, h, stride, fourcc)
        if uy is None:
            if fourcc not in self._skipped:
                self._skipped.add(fourcc)
                log(f"PICTURE: FourCC {ndi.fourcc_name(fourcc)} is not converted, its frames are skipped")
            return self.latest
        if fourcc != self.fourcc:
            self.fourcc = fourcc
            log(f"PICTURE: {w}x{h} {ndi.fourcc_name(fourcc)}" + ("" if fourcc == ndi.FOURCC_UYVY else ", converting to UYVY"))
        self._last_ts = ts
        self.size = (w, h)
        self.latest = self._fit(uy, w, h, stride)
        self.got += 1; self.last_at = time.time()
        return self.latest

    def sound(self, n):
        """n samples of the source's own sound, stereo 48 kHz float32 interleaved, through the frame sync (resampled to
        our clock; silence before the first audio)."""
        import numpy as np
        a = self.fs.audio(48000, 2, n)
        if a is None:
            return bytes(n * 8)
        if a.shape[0] == 1:
            a = np.vstack([a, a])
        return np.ascontiguousarray(a[:2].T, dtype=np.float32).tobytes()

    def close(self):
        self.fs.close(); self.rx.close()


def ffmpeg_cmd(a, audio_in):
    vk = a.video_kbps
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "warning", "-stats_period", "2", "-progress", "pipe:2", "-nostdin",
           "-thread_queue_size", "256", "-f", "rawvideo", "-pix_fmt", "uyvy422", "-s", f"{W}x{H}", "-framerate", str(FPS),
           "-i", "pipe:0"]
    if audio_in == "ndi":     # the picture source's own sound, from the frame sync on a second pipe
        cmd += ["-thread_queue_size", "1024", "-probesize", "32", "-analyzeduration", "0", "-f", "f32le", "-ar", "48000", "-ac", "2", "-i", "pipe:AUDIO"]
        af = "aresample=48000"
    elif audio_in == "test":
        cmd += ["-re", "-f", "lavfi", "-i", "sine=f=440:sample_rate=48000,aformat=channel_layouts=mono[l];"
                "sine=f=660:sample_rate=48000,aformat=channel_layouts=mono[r];[l][r]amerge=inputs=2"]
        af = "aresample=48000"
    else:
        cmd += ["-thread_queue_size", "1024", "-f", "avfoundation", "-i", f":{audio_in}"]
        l, r = (a.pair - 1) * 2, (a.pair - 1) * 2 + 1
        af = f"pan=stereo|c0=c{l}|c1=c{r},aresample=48000:async=1000:first_pts=0"
    if a.av_offset_ms > 0:   # sound earlier than picture: delay the sound
        af += f",adelay={a.av_offset_ms}:all=1"
    cmd += ["-filter_complex", f"[0:v]format=nv12[v];[1:a]{af}[a]", "-map", "[v]", "-map", "[a]",
            "-c:v", "h264_videotoolbox", "-realtime", "1", "-profile:v", "high", "-b:v", f"{vk}k",
            "-maxrate", f"{int(vk * 1.2)}k", "-bufsize", f"{vk * 2}k", "-g", str(FPS * 2),
            "-force_key_frames", "expr:gte(t,n_forced*2)",
            "-c:a", "aac_at", "-aac_at_mode", "cbr", "-b:a", "160k", "-ar", "48000", "-ac", "2",
            *(["-f", "null", "-"] if a.to == "null" else ["-f", "flv", a.to])]
    if a.av_offset_ms < 0:   # picture earlier than sound: delay the picture
        i = cmd.index("pipe:0")
        cmd[i - 1:i - 1] = ["-itsoffset", f"{-a.av_offset_ms / 1000:.3f}"]
    return cmd


def main():
    p = argparse.ArgumentParser(description="Studio: Picture Link + mixer -> one master to the VM ladder")
    p.add_argument("--list", action="store_true")
    p.add_argument("--ndi", default="", help="part of the NDI source name (default: the first Manual Camera / MANTRA source)")
    p.add_argument("--extra-ips", default=os.environ.get("STUDIO_NDI_IPS", ""), help="NDI discovery by address (Tailscale)")
    p.add_argument("--audio", default="", help="part of the audio device name (default: Sound Link's, else BlackHole); "
                   "'ndi' = the picture source's own sound through the frame sync")
    p.add_argument("--ndi-url", default="", help="connect to this address typed by hand (no discovery); default: by name")
    p.add_argument("--pair", type=int, default=0, help="the channel pair, 1 = 1-2, 2 = 3-4 ...")
    p.add_argument("--av-offset-ms", type=int, default=0, help="+ delays the sound, - delays the picture (clap test)")
    p.add_argument("--video-kbps", type=int, default=5000)
    p.add_argument("--to", default=DEFAULT_TO, help="rtmp://... ; 'null' encodes and throws the master away (tests, no data)")
    p.add_argument("--test", action="store_true", help="NDI test pattern from this Mac + a test tone")
    p.add_argument("--seconds", type=int, default=0, help="stop after N seconds (tests on the 4G SIM)")
    p.add_argument("--go-live", action="store_true", help="also GO LIVE on the band site (via studio), STOP at the end")
    a = p.parse_args()

    if a.list:
        print("NDI sources:")
        for n, u in ndi.find(5, a.extra_ips or None):
            print("  ", n, u)
        print("Audio devices:")
        for i, n in audio_devices():
            print(f"   [{i}] {n}")
        return

    os.makedirs(CACHE, exist_ok=True)
    open(os.path.join(CACHE, "studio.pid"), "w").write(str(os.getpid()))
    tester = None
    if a.test:
        tester = subprocess.Popen([sys.executable, os.path.join(HERE, "ndi_testsend.py")])
        a.ndi = a.ndi or "STUDIO TEST"
        time.sleep(2)

    # 1. the picture
    src = None
    if a.ndi_url:
        src = (a.ndi or "", a.ndi_url)
    for _ in range(0 if src else 10):
        found = ndi.find(3, a.extra_ips or None)
        want = a.ndi.upper()
        for n, u in found:
            if (want and want in n.upper()) or (not want and re.search(r"MANUAL|MANTRA|PIXEL", n.upper())):
                src = (n, ""); break   # by name (review #6): the cached URL goes stale when the tether moves
        if src:
            break
        log("waiting for the camera on NDI:", [n for n, _ in found] or "none seen")
    if not src:
        sys.exit("no NDI source: is Manual Camera's NDI on, on the same Wi-Fi (or --extra-ips <phone>)?")
    log("PICTURE:", src[0], "(by name)" if not src[1] else f"at {src[1]} (typed by hand)")
    frames = Frames(*src)

    # 2. the sound
    if a.audio.lower() == "ndi":
        audio_in = "ndi"; a.pair = 1
        log("SOUND: the picture source's own NDI sound (frame sync)")
    elif a.test:
        audio_in = "test"; a.pair = a.pair or 1
        log("SOUND: test tone 440/660 Hz")
    else:
        devs = audio_devices()
        choice = sound_link_choice()
        name = a.audio or (choice[0] if choice else "BlackHole")
        a.pair = a.pair or (choice[1] if choice else 1)
        hit = [d for d in devs if name.lower() in d[1].lower()]
        if not hit:
            sys.exit(f"no audio device like '{name}': {[d[1] for d in devs]}")
        audio_in = str(hit[0][0])
        log(f"SOUND: {hit[0][1]}, channels {a.pair * 2 - 1}-{a.pair * 2}" + (" (from Sound Link)" if choice and not a.audio else ""))

    # 3. the master, restarted if the network drops it; the camera keeps being read meanwhile
    stopping = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stopping.set())
    t_end = time.time() + a.seconds if a.seconds else None
    stat = {"source": src[0], "to": a.to, "started": time.strftime("%Y-%m-%d %H:%M:%S")}
    black = bytes([128, 16, 128, 16]) * (W * H // 2)
    restarts = 0
    went_live = False
    try:
        while not stopping.is_set() and (not t_end or time.time() < t_end):
            cmd = ffmpeg_cmd(a, audio_in)
            afd = None
            if audio_in == "ndi":
                r_fd, afd = os.pipe()
                cmd[cmd.index("pipe:AUDIO")] = f"pipe:{r_fd}"
                ff = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE, text=False, pass_fds=(r_fd,))
                os.close(r_fd)
            else:
                ff = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE, text=False)
            # each pipe has its own writer: ffmpeg's demuxers wait for each other, so a blocking write of the picture must
            # never hold back the sound (a deadlock after 2 frames, 15.11.2026). At most 2 s queued per pipe.
            broken = threading.Event()
            vq = queue.Queue(maxsize=FPS * 2)
            aq = queue.Queue(maxsize=FPS * 2) if afd is not None else None

            def writer(q, put):
                while True:
                    blk = q.get()
                    if blk is None:
                        break
                    try:
                        put(blk)
                    except (BrokenPipeError, ValueError, OSError):
                        broken.set(); break
            threading.Thread(target=writer, args=(vq, ff.stdin.write), daemon=True).start()
            if aq is not None:
                threading.Thread(target=writer, args=(aq, lambda b, fd=afd: os.write(fd, b)), daemon=True).start()
            prog = {}

            def reader():
                for raw in ff.stderr:
                    line = raw.decode(errors="replace").strip()
                    if "=" in line and " " not in line:
                        k, v = line.split("=", 1); prog[k] = v
                    elif line:
                        log("ffmpeg:", line)
            threading.Thread(target=reader, daemon=True).start()
            log(f"MASTER -> {a.to} ({a.video_kbps} kbit/s video + AAC 160 stereo)" + (f", restart {restarts}" if restarts else ""))
            t0 = time.monotonic(); n = 0; last_stat = 0
            while ff.poll() is None and not broken.is_set() and not stopping.is_set() and (not t_end or time.time() < t_end):
                due = t0 + n / FPS
                wait = due - time.monotonic()
                if wait > 0:
                    time.sleep(wait)
                elif wait < -1.0:   # far behind (the Mac slept): skip ahead instead of bursting
                    n = int((time.monotonic() - t0) * FPS)
                fr = frames.pull()               # the frame sync, at this clock (25 fps)
                try:
                    if aq is not None:           # the source's sound, pulled at the same clock (the frame sync resamples)
                        aq.put_nowait(frames.sound(48000 // FPS))
                    vq.put_nowait(fr if fr is not None else black)
                except queue.Full:
                    log("ffmpeg does not take the frames (2 s queued): restarting the master")
                    break
                n += 1
                if a.go_live and not went_live and n == FPS * 8:   # 8 s of master: the ladder has segments
                    went_live = bool(site("go"))
                if time.time() - last_stat > 2:
                    last_stat = time.time()
                    stat.update({"frames_in": frames.got, "repeats": frames.repeats, "camera_size": frames.size,
                                 "fourcc": ndi.fourcc_name(frames.fourcc) if frames.fourcc else None,
                                 "camera_age_s": round(time.time() - frames.last_at, 1) if frames.last_at else None,
                                 "frames_out": n, "speed": prog.get("speed"), "out_kbps": prog.get("bitrate"),
                                 "restarts": restarts, "at": time.strftime("%H:%M:%S")})
                    json.dump(stat, open(os.path.join(CACHE, "status.json"), "w"))
            for q in (vq, aq):
                if q is not None:
                    while True:
                        try:
                            q.put_nowait(None); break
                        except queue.Full:
                            q.get_nowait()
            time.sleep(0.2)
            for close in (ff.stdin.close, (lambda: os.close(afd)) if afd is not None else None):
                try:
                    close and close()
                except Exception:
                    pass
            try:
                ff.wait(5)
            except subprocess.TimeoutExpired:
                ff.kill()
            if stopping.is_set() or (t_end and time.time() >= t_end):
                break
            restarts += 1
            log("master stopped (network?), again in 2 s")
            time.sleep(2)
    except KeyboardInterrupt:
        pass
    finally:
        frames.close()
        if went_live:
            site("stop")
        if tester:
            tester.terminate()
        log("stopped")


if __name__ == "__main__":
    main()
