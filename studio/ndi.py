"""ndi.py: the NDI runtime (libndi.dylib from NDI Tools) through ctypes. No compiling: Python only.

Picture Link (Marko, 15.11.2026): Manual Camera already sends NDI HX (H.264/HEVC) on the LAN; the Mac receives it here,
decoded by libndi, and hands raw UYVY frames to ffmpeg (studio.py), which encodes the master with VideoToolbox.
"""
import ctypes as C, ctypes.util, os, time

LIB = os.environ.get("NDI_LIB", "/usr/local/lib/libndi.dylib")
ndi = C.CDLL(LIB)

class Source(C.Structure):
    _fields_ = [("p_ndi_name", C.c_char_p), ("p_url_address", C.c_char_p)]

class FindCreate(C.Structure):
    _fields_ = [("show_local_sources", C.c_bool), ("p_groups", C.c_char_p), ("p_extra_ips", C.c_char_p)]

class RecvCreateV3(C.Structure):
    _fields_ = [("source_to_connect_to", Source), ("color_format", C.c_int), ("bandwidth", C.c_int),
                ("allow_video_fields", C.c_bool), ("p_ndi_recv_name", C.c_char_p)]

class VideoFrameV2(C.Structure):
    _fields_ = [("xres", C.c_int), ("yres", C.c_int), ("FourCC", C.c_uint32), ("frame_rate_N", C.c_int),
                ("frame_rate_D", C.c_int), ("picture_aspect_ratio", C.c_float), ("frame_format_type", C.c_int),
                ("timecode", C.c_int64), ("p_data", C.POINTER(C.c_uint8)), ("line_stride_in_bytes", C.c_int),
                ("p_metadata", C.c_char_p), ("timestamp", C.c_int64)]

class AudioFrameV2(C.Structure):
    _fields_ = [("sample_rate", C.c_int), ("no_channels", C.c_int), ("no_samples", C.c_int), ("timecode", C.c_int64),
                ("p_data", C.POINTER(C.c_float)), ("channel_stride_in_bytes", C.c_int), ("p_metadata", C.c_char_p),
                ("timestamp", C.c_int64)]

FRAME_NONE, FRAME_VIDEO, FRAME_AUDIO, FRAME_META, FRAME_ERROR, FRAME_STATUS = 0, 1, 2, 3, 4, 100
COLOR_UYVY_BGRA, COLOR_FASTEST = 1, 100
BW_HIGHEST, BW_LOWEST = 100, 0
FOURCC_UYVY = int.from_bytes(b"UYVY", "little")

ndi.NDIlib_initialize.restype = C.c_bool
ndi.NDIlib_find_create_v2.restype = C.c_void_p
ndi.NDIlib_find_create_v2.argtypes = [C.POINTER(FindCreate)]
ndi.NDIlib_find_wait_for_sources.argtypes = [C.c_void_p, C.c_uint32]
ndi.NDIlib_find_get_current_sources.restype = C.POINTER(Source)
ndi.NDIlib_find_get_current_sources.argtypes = [C.c_void_p, C.POINTER(C.c_uint32)]
ndi.NDIlib_find_destroy.argtypes = [C.c_void_p]
ndi.NDIlib_recv_create_v3.restype = C.c_void_p
ndi.NDIlib_recv_create_v3.argtypes = [C.POINTER(RecvCreateV3)]
ndi.NDIlib_recv_capture_v2.restype = C.c_int
ndi.NDIlib_recv_capture_v2.argtypes = [C.c_void_p, C.POINTER(VideoFrameV2), C.POINTER(AudioFrameV2), C.c_void_p, C.c_uint32]
ndi.NDIlib_recv_free_video_v2.argtypes = [C.c_void_p, C.POINTER(VideoFrameV2)]
ndi.NDIlib_recv_free_audio_v2.argtypes = [C.c_void_p, C.POINTER(AudioFrameV2)]
ndi.NDIlib_recv_destroy.argtypes = [C.c_void_p]
if not ndi.NDIlib_initialize():
    raise SystemExit("NDI could not start (CPU not supported?)")


def find(wait_s=5.0, extra_ips=None):
    """[(name, url)] of the NDI sources seen within wait_s (Bonjour on the LAN; extra_ips for Tailscale/other subnets)."""
    fc = FindCreate(True, None, extra_ips.encode() if extra_ips else None)
    f = ndi.NDIlib_find_create_v2(C.byref(fc))
    end = time.time() + wait_s
    while time.time() < end:
        ndi.NDIlib_find_wait_for_sources(f, 500)
    n = C.c_uint32(0)
    arr = ndi.NDIlib_find_get_current_sources(f, C.byref(n))
    out = [(arr[i].p_ndi_name.decode(), (arr[i].p_url_address or b"").decode()) for i in range(n.value)]
    ndi.NDIlib_find_destroy(f)
    return out


class Receiver:
    def __init__(self, name, url="", recv_name="Studio (Mantra)"):
        self._src = Source(name.encode(), url.encode() if url else None)
        rc = RecvCreateV3(self._src, COLOR_UYVY_BGRA, BW_HIGHEST, False, recv_name.encode())
        self.r = ndi.NDIlib_recv_create_v3(C.byref(rc))
        if not self.r:
            raise RuntimeError("NDI receiver could not be made")

    def video(self, timeout_ms=1000):
        """One video frame as (xres, yres, fourcc, n, d, bytes, timestamp_100ns) or None; audio frames are dropped."""
        v, a = VideoFrameV2(), AudioFrameV2()
        t = ndi.NDIlib_recv_capture_v2(self.r, C.byref(v), C.byref(a), None, timeout_ms)
        if t == FRAME_VIDEO:
            try:
                size = v.line_stride_in_bytes * v.yres
                data = C.string_at(v.p_data, size)
                return (v.xres, v.yres, v.FourCC, v.frame_rate_N, v.frame_rate_D, data, v.timestamp, v.line_stride_in_bytes)
            finally:
                ndi.NDIlib_recv_free_video_v2(self.r, C.byref(v))
        if t == FRAME_AUDIO:
            ndi.NDIlib_recv_free_audio_v2(self.r, C.byref(a))
        return None

    def close(self):
        if self.r:
            ndi.NDIlib_recv_destroy(self.r); self.r = None


if __name__ == "__main__":
    for n, u in find(6):
        print(f"{n}\t{u}")
