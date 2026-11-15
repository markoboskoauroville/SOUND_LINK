// ndi_min.h: the few NDI runtime calls Sound Link uses, declared by us (the public NDI v5/v6 C ABI: the same layout as
// NDIlib_source_t, NDIlib_find_create_t, NDIlib_recv_create_v3_t, NDIlib_video_frame_v2_t). No NDI SDK file is in this
// public repository: the app loads the NDI runtime that NDI Tools installs (/usr/local/lib/libndi.dylib) with dlopen at
// run time, so nothing of the SDK is compiled in, linked or redistributed. Picture Link, 15.11.2026.
#include <stdint.h>
#include <stdbool.h>

typedef struct { const char* p_ndi_name; const char* p_url_address; } SLNDISource;
typedef struct { bool show_local_sources; const char* p_groups; const char* p_extra_ips; } SLNDIFindCreate;
typedef struct { SLNDISource source_to_connect_to; int color_format; int bandwidth; bool allow_video_fields; const char* p_ndi_recv_name; } SLNDIRecvCreateV3;
typedef struct {
    int xres, yres; uint32_t FourCC; int frame_rate_N, frame_rate_D; float picture_aspect_ratio; int frame_format_type;
    int64_t timecode; uint8_t* p_data; int line_stride_in_bytes; const char* p_metadata; int64_t timestamp;
} SLNDIVideoFrameV2;

typedef bool (*SLNDI_initialize)(void);
typedef void* (*SLNDI_find_create_v2)(const SLNDIFindCreate*);
typedef bool (*SLNDI_find_wait_for_sources)(void*, uint32_t);
typedef const SLNDISource* (*SLNDI_find_get_current_sources)(void*, uint32_t*);
typedef void (*SLNDI_find_destroy)(void*);
typedef void* (*SLNDI_recv_create_v3)(const SLNDIRecvCreateV3*);
// video, audio, metadata: NULL for the kinds not wanted (they are then dropped by the runtime)
typedef int (*SLNDI_recv_capture_v2)(void*, SLNDIVideoFrameV2*, void*, void*, uint32_t);
typedef void (*SLNDI_recv_free_video_v2)(void*, const SLNDIVideoFrameV2*);
typedef void (*SLNDI_recv_destroy)(void*);
