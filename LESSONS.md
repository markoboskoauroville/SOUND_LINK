# Sound Link (Mantra): LESSONS

1. (14.11.2026) AVAudioEngine's input tap hands out ~100 ms buffers on macOS and follows the default input; for a link
   the HAL output unit with a channel map is the right tool (5 ms IO, any two channels of a multichannel mixer).
2. (14.11.2026) The phone's audio clock is the master. The Mac's packets fill a ring indexed by the Mac's sample count;
   each consumer on the phone reads it at its own pace and resamples by a small ratio steered by how full it is, so the
   two clocks never drift apart and the buffer never slowly runs dry or overflows.
3. (14.11.2026) macOS 15 asks for Local Network the first time an app browses Bonjour; NSBonjourServices and
   NSLocalNetworkUsageDescription must be in Info.plist or the browse finds nothing without a word.
4. (15.11.2026) Wi-Fi at 200 small packets a second lost 4.3 % in bursts. A redundant copy two blocks back recovered only
   a third of them; eight back (40 ms) is the useful distance. μ-law keeps it inside one 1500-byte frame.
5. (15.11.2026) Over Tailscale through the Frankfurt relay the round trip is 95–230 ms and bursty: the phone needs about
   0.4–0.6 s of buffer for zero dropouts. Over the Wi-Fi 0.15–0.18 s is enough.
6. (15.11.2026) The phone answered from an IPv6 link-local address over the Wi-Fi (Bonjour resolved it that way). Any
   check of the path by address must handle IPv6 as well (the phone treats only 100.64/10 as Tailscale).

## 15.11.2026: Studio
- libndi works from Python ctypes on the Mac (structs: source_t, recv_create_v3_t, video_frame_v2_t): no compiled receiver needed.
- An NDI test sender fed by ffmpeg without `-re` ran at 378 % CPU and starved discovery ("none seen"): always pace test sources.
- Homebrew ffmpeg here has no drawtext and no libsrt; it has the whip muxer, rtmp(s), h264_videotoolbox and aac_at.
- avfoundation and the rawvideo pipe both follow the Mac's clock: pace the frames by time.monotonic(), let aresample=async fix the sound.
- (v8) An NDI receiver needs no SDK files: dlopen the installed runtime and declare the few structs yourself; the build stays public.
- (v8) Writing frames to ffmpeg's stdin from Swift: ignore SIGPIPE and use write(2), never FileHandle.write (it raises and kills the app).

## 15.11.2026: drops on the way to the camera
- The camera heard holes of 0.2–0.7 s every 2–4 minutes with no packet lost, while ping to the phone stayed under 70 ms. Since v7
  (pump thread under `beginActivity(.userInitiated, .latencyCritical)`, `NSAppSleepDisabled` in Info.plist) the camera saw no gap
  over 141 ms in 22 minutes. The log now says "pump: held up N times in 10 s, the longest X ms" whenever the pump waits >60 ms.
- **Gain:** BlackHole 2ch's own device volume was at 0.706 = −18.8 dB (BlackHole maps the scalar linearly to −64..0 dB). A −12 dBFS
  test tone arrived at −30.8 dBFS everywhere. Whatever plays into BlackHole is that much lower in the stream; read the device
  volume (CoreAudio 'volm') before blaming the link. Not changed without Marko.
- Test signals go into BlackHole directly: `sox -q test.wav -t coreaudio "BlackHole 2ch"`; the default output (ADAM) is untouched.

## 15.11.2026: device names
- Device names come from Marko: MacBook Pro (his laptop), Pixel 7, Nothing Phone. Never invent product names ("Mac Studio" was invented and he does not own one).
