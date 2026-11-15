#!/usr/bin/env python3
"""ndi_testsend.py: an NDI test source "STUDIO TEST" on this Mac (ffmpeg testsrc2 1080p25 with a running clock), so the
Studio chain can be proven without the phone. python3 ndi_testsend.py [seconds]"""
import ctypes as C, subprocess, sys, time
import ndi

class SendCreate(C.Structure):
    _fields_ = [("p_ndi_name", C.c_char_p), ("p_groups", C.c_char_p), ("clock_video", C.c_bool), ("clock_audio", C.c_bool)]

L = ndi.ndi
L.NDIlib_send_create.restype = C.c_void_p
L.NDIlib_send_create.argtypes = [C.POINTER(SendCreate)]
L.NDIlib_send_send_video_v2.argtypes = [C.c_void_p, C.POINTER(ndi.VideoFrameV2)]
L.NDIlib_send_destroy.argtypes = [C.c_void_p]
W, H = 1920, 1080
secs = float(sys.argv[1]) if len(sys.argv) > 1 else 0
s = L.NDIlib_send_create(C.byref(SendCreate(b"STUDIO TEST", None, True, False)))
src = subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error", "-re", "-f", "lavfi", "-i",
                        f"testsrc2=s={W}x{H}:r=25",
                        "-pix_fmt", "uyvy422", "-f", "rawvideo", "pipe:1"], stdout=subprocess.PIPE)
size = W * H * 2; t0 = time.time()
try:
    while not secs or time.time() - t0 < secs:
        buf = src.stdout.read(size)
        if len(buf) < size:
            break
        b = C.create_string_buffer(buf, size)
        f = ndi.VideoFrameV2(W, H, ndi.FOURCC_UYVY, 25, 1, 16 / 9, 1, 0x7FFFFFFFFFFFFFFF,
                             C.cast(b, C.POINTER(C.c_uint8)), W * 2, None, 0)
        L.NDIlib_send_send_video_v2(s, C.byref(f))   # clock_video: paced to 25 fps by NDI
finally:
    src.kill(); L.NDIlib_send_destroy(s)
