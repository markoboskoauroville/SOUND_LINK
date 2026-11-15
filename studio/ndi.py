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
def fourcc(tag):
    return int.from_bytes(tag, "little")


def fourcc_name(v):
    try:
        return int(v).to_bytes(4, "little").decode("ascii")
    except Exception:
        return hex(v)


FOURCC_UYVY, FOURCC_UYVA = fourcc(b"UYVY"), fourcc(b"UYVA")
FOURCC_BGRA, FOURCC_BGRX = fourcc(b"BGRA"), fourcc(b"BGRX")
FOURCC_RGBA, FOURCC_RGBX = fourcc(b"RGBA"), fourcc(b"RGBX")

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
ndi.NDIlib_recv_get_no_connections.restype = C.c_int
ndi.NDIlib_recv_get_no_connections.argtypes = [C.c_void_p]
# the frame sync (DistroAV's way): the receiver fills it, we pull at our own clock; it repeats or drops frames and
# resamples the sound to the rate we ask for (NDI SDK "Frame Synchronization").
ndi.NDIlib_framesync_create.restype = C.c_void_p
ndi.NDIlib_framesync_create.argtypes = [C.c_void_p]
ndi.NDIlib_framesync_destroy.argtypes = [C.c_void_p]
ndi.NDIlib_framesync_capture_video.argtypes = [C.c_void_p, C.POINTER(VideoFrameV2), C.c_int]
ndi.NDIlib_framesync_free_video.argtypes = [C.c_void_p, C.POINTER(VideoFrameV2)]
ndi.NDIlib_framesync_capture_audio.argtypes = [C.c_void_p, C.POINTER(AudioFrameV2), C.c_int, C.c_int, C.c_int]
ndi.NDIlib_framesync_free_audio.argtypes = [C.c_void_p, C.POINTER(AudioFrameV2)]
ndi.NDIlib_framesync_audio_queue_depth.restype = C.c_int
ndi.NDIlib_framesync_audio_queue_depth.argtypes = [C.c_void_p]
PROGRESSIVE = 1
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
    """Connects by the source NAME (review #6): the runtime resolves it through discovery every time, so a phone whose
    USB tether moved to a new subnet is found again. url only for an address typed by hand (no discovery)."""
    def __init__(self, name, url="", recv_name="Studio"):   # no parentheses in NDI names (ndi-best-practice.md §1)
        self._src = Source(name.encode() if name else None, url.encode() if url else None)
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

    def connections(self):
        return ndi.NDIlib_recv_get_no_connections(self.r) if self.r else 0

    def close(self):
        if self.r:
            ndi.NDIlib_recv_destroy(self.r); self.r = None


class FrameSync:
    """NDIlib_framesync_* on a Receiver (review #8). video() at the output's clock returns the newest frame (repeated
    when the source is slower, dropped when faster) as (xres, yres, fourcc, data, stride, timestamp) or None before the
    first frame; audio(n) returns n samples x ch float32 planar resampled to the rate asked (silence when none)."""
    def __init__(self, rx):
        self.rx = rx
        self.fs = ndi.NDIlib_framesync_create(rx.r)
        if not self.fs:
            raise RuntimeError("NDI frame sync could not be made")

    def video(self):
        v = VideoFrameV2()
        ndi.NDIlib_framesync_capture_video(self.fs, C.byref(v), PROGRESSIVE)
        try:
            if not v.p_data or v.xres <= 0:
                return None
            size = v.line_stride_in_bytes * v.yres   # UYVA: the UYVY plane comes first, its alpha plane is not read
            return (v.xres, v.yres, v.FourCC, C.string_at(v.p_data, size), v.line_stride_in_bytes,
                    v.timestamp or v.timecode)
        finally:
            ndi.NDIlib_framesync_free_video(self.fs, C.byref(v))

    def audio(self, rate, ch, n):
        a = AudioFrameV2()
        ndi.NDIlib_framesync_capture_audio(self.fs, C.byref(a), rate, ch, n)
        try:
            if not a.p_data or a.no_samples <= 0:
                return None
            stride = a.channel_stride_in_bytes // 4
            import numpy as np
            buf = np.ctypeslib.as_array(a.p_data, shape=(a.no_channels * stride,))
            return buf.reshape(a.no_channels, stride)[:, :a.no_samples].copy()
        finally:
            ndi.NDIlib_framesync_free_audio(self.fs, C.byref(a))

    def queue_depth(self):
        return ndi.NDIlib_framesync_audio_queue_depth(self.fs)

    def close(self):
        if self.fs:
            ndi.NDIlib_framesync_destroy(self.fs); self.fs = None


# BT.709, video range (Y 16-235, C 16-240), fixed point: Y in 1/65536, chroma of a pixel PAIR sum in 1/32768
_YR, _YG, _YB = (int(k * 219 / 255 * 65536) for k in (0.2126, 0.7152, 0.0722))
_UR, _UG, _UB = (int(k * 224 / 255 * 32768) for k in (-0.1146, -0.3854, 0.5))
_VR, _VG, _VB = (int(k * 224 / 255 * 32768) for k in (0.5, -0.4542, -0.0458))


def to_uyvy(data, w, h, stride, fourcc_v):
    """Any frame the receiver may hand us (review #1) as packed UYVY, w x h (w even), bytes. UYVY/UYVA: the UYVY plane;
    BGRA/BGRX/RGBA/RGBX: BT.709 video range with numpy (1080p ~37 ms, 720p ~9 ms). None for a FourCC we do not convert (the caller logs it)."""
    import numpy as np
    w2 = w // 2 * 2
    if fourcc_v in (FOURCC_UYVY, FOURCC_UYVA):
        if stride == w2 * 2:
            return data[: w2 * 2 * h]
        return np.frombuffer(data, np.uint8, count=stride * h).reshape(h, stride)[:, : w2 * 2].tobytes()
    if fourcc_v not in (FOURCC_BGRA, FOURCC_BGRX, FOURCC_RGBA, FOURCC_RGBX):
        return None
    px = np.frombuffer(data, np.uint8, count=stride * h).reshape(h, stride)[:, : w2 * 4].reshape(h, w2 // 2, 8)
    ri, gi, bi = (2, 1, 0) if fourcc_v in (FOURCC_BGRA, FOURCC_BGRX) else (0, 1, 2)
    r0, g0, b0 = (px[..., i].astype(np.int32) for i in (ri, gi, bi))
    r1, g1, b1 = (px[..., 4 + i].astype(np.int32) for i in (ri, gi, bi))
    out = np.empty((h, w2 // 2, 4), np.uint8)       # U Y0 V Y1
    out[..., 1] = (_YR * r0 + _YG * g0 + _YB * b0 + (16 << 16) + 32768) >> 16
    out[..., 3] = (_YR * r1 + _YG * g1 + _YB * b1 + (16 << 16) + 32768) >> 16
    rs, gs, bs = r0 + r1, g0 + g1, b0 + b1           # chroma of the pair = their average (the <<15 below halves it)
    out[..., 0] = np.clip((_UR * rs + _UG * gs + _UB * bs + (128 << 16) + 32768) >> 16, 0, 255)
    out[..., 2] = np.clip((_VR * rs + _VG * gs + _VB * bs + (128 << 16) + 32768) >> 16, 0, 255)
    return out.tobytes()


if __name__ == "__main__":
    for n, u in find(6):
        print(f"{n}\t{u}")
