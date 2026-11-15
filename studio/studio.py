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
import argparse, json, os, re, signal, subprocess, sys, threading, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ndi  # noqa: E402

W, H, FPS = 1920, 1080, 25
CACHE = os.path.expanduser("~/.cache/studio")
DEFAULT_TO = "rtmp://100.102.86.30:1935/studio/master"   # chromium-vm's Tailscale address (studio-ladder)
SOUND_LINK = "http://127.0.0.1:8974/fn/status"
SITE = os.environ.get("STUDIO_SITE", "https://santoshi-band.pages.dev")
TOKEN_FILE = os.path.expanduser("~/.config/studio/camera-token")   # the site's camera token for "Mac Studio" (chmod 600, never printed)


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
    """GO / STOP the band site's live as the paired camera "Mac Studio" with via "studio" (viewers get the ladder and the gear)."""
    try:
        tok = open(TOKEN_FILE).read().strip()
    except OSError:
        log("no camera token in", TOKEN_FILE, "- pair \"Mac Studio\" at /admin (PAIR CAMERA) and save the token there")
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
    """The newest NDI picture, converted to 1920x1080 UYVY (nearest-neighbour letterbox if the camera sends another size)."""
    def __init__(self, source, url):
        self.rx = ndi.Receiver(source, url)
        self.latest = None
        self.got = 0; self.last_at = 0.0; self.size = None
        self._maps = {}
        self.stop = False
        threading.Thread(target=self._run, daemon=True).start()

    def _fit(self, data, w, h, stride):
        if (w, h) == (W, H) and stride == W * 2:
            return data
        import numpy as np
        key = (w, h, stride)
        if key not in self._maps:
            s = min(W / w, H / h)
            ow, oh = max(2, int(w * s) // 2 * 2), max(2, int(h * s))
            x0, y0 = (W - ow) // 2 // 2 * 2, (H - oh) // 2
            ys = (np.arange(oh) * h // oh).astype(np.intp)
            # UYVY: pairs of pixels share U and V; map in macro-pixels of 4 bytes
            xs = (np.arange(ow // 2) * (w // 2) // (ow // 2)).astype(np.intp)
            self._maps[key] = (ys, xs, x0, y0, ow, oh)
        ys, xs, x0, y0, ow, oh = self._maps[key]
        src = np.frombuffer(data, dtype=np.uint8).reshape(h, stride)[:, : w * 2].reshape(h, w // 2, 4)
        out = np.empty((H, W // 2, 4), dtype=np.uint8)
        out[:] = (128, 16, 128, 16)  # black in UYVY
        out[y0:y0 + oh, x0 // 2: x0 // 2 + ow // 2] = src[ys][:, xs]
        return out.tobytes()

    def _run(self):
        while not self.stop:
            f = self.rx.video(1000)
            if f is None:
                continue
            w, h, fourcc, n, d, data, ts, stride = f
            if fourcc != ndi.FOURCC_UYVY:
                continue  # asked for UYVY_BGRA: an alpha frame is skipped
            self.size = (w, h)
            self.latest = self._fit(data, w, h, stride)
            self.got += 1; self.last_at = time.time()


def ffmpeg_cmd(a, audio_in):
    vk = a.video_kbps
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "warning", "-stats_period", "2", "-progress", "pipe:2", "-nostdin",
           "-thread_queue_size", "256", "-f", "rawvideo", "-pix_fmt", "uyvy422", "-s", f"{W}x{H}", "-framerate", str(FPS),
           "-i", "pipe:0"]
    if audio_in == "test":
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
            "-f", "flv", a.to]
    if a.av_offset_ms < 0:   # picture earlier than sound: delay the picture
        i = cmd.index("pipe:0")
        cmd[i - 1:i - 1] = ["-itsoffset", f"{-a.av_offset_ms / 1000:.3f}"]
    return cmd


def main():
    p = argparse.ArgumentParser(description="Studio: Picture Link + mixer -> one master to the VM ladder")
    p.add_argument("--list", action="store_true")
    p.add_argument("--ndi", default="", help="part of the NDI source name (default: the first Manual Camera / MANTRA source)")
    p.add_argument("--extra-ips", default=os.environ.get("STUDIO_NDI_IPS", ""), help="NDI discovery by address (Tailscale)")
    p.add_argument("--audio", default="", help="part of the audio device name (default: Sound Link's, else BlackHole)")
    p.add_argument("--pair", type=int, default=0, help="the channel pair, 1 = 1-2, 2 = 3-4 ...")
    p.add_argument("--av-offset-ms", type=int, default=0, help="+ delays the sound, - delays the picture (clap test)")
    p.add_argument("--video-kbps", type=int, default=5000)
    p.add_argument("--to", default=DEFAULT_TO)
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
    for _ in range(10):
        found = ndi.find(3, a.extra_ips or None)
        want = a.ndi.upper()
        for n, u in found:
            if (want and want in n.upper()) or (not want and re.search(r"MANUAL|MANTRA|PIXEL", n.upper())):
                src = (n, u); break
        if src:
            break
        log("waiting for the camera on NDI:", [n for n, _ in found] or "none seen")
    if not src:
        sys.exit("no NDI source: is Manual Camera's NDI on, on the same Wi-Fi (or --extra-ips <phone>)?")
    log("PICTURE:", src[0], src[1])
    frames = Frames(*src)

    # 2. the sound
    if a.test:
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
            ff = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE, text=False)
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
            while ff.poll() is None and not stopping.is_set() and (not t_end or time.time() < t_end):
                due = t0 + n / FPS
                wait = due - time.monotonic()
                if wait > 0:
                    time.sleep(wait)
                elif wait < -1.0:   # far behind (the Mac slept): skip ahead instead of bursting
                    n = int((time.monotonic() - t0) * FPS)
                fr = frames.latest if frames.latest is not None else black
                try:
                    ff.stdin.write(fr)
                except (BrokenPipeError, ValueError):
                    break
                n += 1
                if a.go_live and not went_live and n == FPS * 8:   # 8 s of master: the ladder has segments
                    went_live = bool(site("go"))
                if time.time() - last_stat > 2:
                    last_stat = time.time()
                    stat.update({"frames_in": frames.got, "camera_size": frames.size,
                                 "camera_age_s": round(time.time() - frames.last_at, 1) if frames.last_at else None,
                                 "frames_out": n, "speed": prog.get("speed"), "out_kbps": prog.get("bitrate"),
                                 "restarts": restarts, "at": time.strftime("%H:%M:%S")})
                    json.dump(stat, open(os.path.join(CACHE, "status.json"), "w"))
            try:
                ff.stdin.close()
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
        frames.stop = True
        if went_live:
            site("stop")
        if tester:
            tester.terminate()
        log("stopped")


if __name__ == "__main__":
    main()
