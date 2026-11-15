#!/usr/bin/env python3
"""ndi_testsend.py: an NDI test source on this Mac (ffmpeg testsrc2 with a running clock), so the Studio chain and the
NDI receivers can be proven without the phone.

  python3 ndi_testsend.py [seconds]                       "STUDIO TEST", 1920x1080 25p UYVY, picture only
  python3 ndi_testsend.py 30 --fourcc BGRA --size 1280x720  as Meditation Room sends (BGRA; BGRX next)
  python3 ndi_testsend.py 30 --fourcc NV12                 a FourCC the receivers do not convert (logged once, skipped)
  python3 ndi_testsend.py 60 --on-change 5                 a send-on-change source: one frame every 5 s
  python3 ndi_testsend.py 30 --tone                        with a 440/660 Hz tone at -20 dBFS as NDI sound
  python3 ndi_testsend.py 30 --tone --stop-video-after 10  a real stall (picture stops, sound goes on), for ndi_probe

The name never has parentheses (ndi-best-practice.md §1). The published name is printed (NDIlib_send_get_source_name).
"""
import argparse, ctypes as C, math, subprocess, sys, time
import ndi

class SendCreate(C.Structure):
    _fields_ = [("p_ndi_name", C.c_char_p), ("p_groups", C.c_char_p), ("clock_video", C.c_bool), ("clock_audio", C.c_bool)]

ap = argparse.ArgumentParser()
ap.add_argument("seconds", nargs="?", type=float, default=0)
ap.add_argument("--name", default="STUDIO TEST")
ap.add_argument("--fourcc", default="UYVY", choices=["UYVY", "UYVA", "BGRA", "BGRX", "RGBA", "NV12"])
ap.add_argument("--size", default="1920x1080")
ap.add_argument("--on-change", type=float, default=0, help="send only one frame every N seconds (a static source)")
ap.add_argument("--tone", action="store_true", help="also send a quiet stereo tone as NDI sound")
ap.add_argument("--stop-video-after", type=float, default=0, help="a real stall: the picture stops after N s, the sound goes on")
a = ap.parse_args()
if "(" in a.name or ")" in a.name:
    sys.exit("no parentheses in an NDI name (NDI Video Monitor cannot connect to it)")

L = ndi.ndi
L.NDIlib_send_create.restype = C.c_void_p
L.NDIlib_send_create.argtypes = [C.POINTER(SendCreate)]
L.NDIlib_send_send_video_v2.argtypes = [C.c_void_p, C.POINTER(ndi.VideoFrameV2)]
L.NDIlib_send_send_audio_v2.argtypes = [C.c_void_p, C.POINTER(ndi.AudioFrameV2)]
L.NDIlib_send_get_source_name.restype = C.POINTER(ndi.Source)
L.NDIlib_send_get_source_name.argtypes = [C.c_void_p]
L.NDIlib_send_destroy.argtypes = [C.c_void_p]
W, H = (int(x) for x in a.size.split("x"))
PIX = {"UYVY": "uyvy422", "UYVA": "uyvy422", "BGRA": "bgra", "BGRX": "bgr0", "RGBA": "rgba", "NV12": "nv12"}[a.fourcc]
size = {"uyvy422": W * H * 2, "nv12": W * H * 3 // 2}.get(PIX, W * H * 4)
stride = {"uyvy422": W * 2, "nv12": W}.get(PIX, W * 4)
# clock_video paces a steady source; a send-on-change source is paced by ffmpeg's -re instead
s = L.NDIlib_send_create(C.byref(SendCreate(a.name.encode(), None, not a.on_change and not a.tone, False)))
print("NDI test source:", L.NDIlib_send_get_source_name(s).contents.p_ndi_name.decode(), a.fourcc, a.size,
      f"one frame every {a.on_change} s" if a.on_change else "25p", "+ tone" if a.tone else "", flush=True)
src = subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error", "-re", "-f", "lavfi", "-i",
                        f"testsrc2=s={W}x{H}:r=25", "-pix_fmt", PIX, "-f", "rawvideo", "pipe:1"], stdout=subprocess.PIPE)
t0 = time.time(); n = 0; last_sent = -1e9
alpha = bytes([255]) * (W * H) if a.fourcc == "UYVA" else b""
N = 48000 // 25
try:
    while not a.seconds or time.time() - t0 < a.seconds:
        buf = src.stdout.read(size)
        if len(buf) < size:
            break
        now = time.time()
        stalled = a.stop_video_after and now - t0 > a.stop_video_after
        if not stalled and (not a.on_change or now - last_sent >= a.on_change):
            last_sent = now
            b = C.create_string_buffer(buf + alpha, size + len(alpha))
            f = ndi.VideoFrameV2(W, H, ndi.fourcc(a.fourcc.encode()), 25, 1, W / H, 1, 0x7FFFFFFFFFFFFFFF,
                                 C.cast(b, C.POINTER(C.c_uint8)), stride, None, 0)
            L.NDIlib_send_send_video_v2(s, C.byref(f))
        if a.tone:
            pcm = (C.c_float * (2 * N))()
            for i in range(N):
                k = n * N + i
                pcm[i] = 0.1 * math.sin(2 * math.pi * 440 * k / 48000)
                pcm[N + i] = 0.1 * math.sin(2 * math.pi * 660 * k / 48000)
            af = ndi.AudioFrameV2(48000, 2, N, 0x7FFFFFFFFFFFFFFF, C.cast(pcm, C.POINTER(C.c_float)), N * 4, None, 0)
            L.NDIlib_send_send_audio_v2(s, C.byref(af))
        n += 1
finally:
    src.kill(); L.NDIlib_send_destroy(s)
