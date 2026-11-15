# Sound Link (Mantra): TAKEOVER

**What it is.** A Mac app that sends stereo sound from the Mac over the Wi-Fi into the Android app Manual Camera (Mantra)
(repo markoboskoauroville/mantra-manual-camera, folder ~/Developer/MANTRA_NDI). Marko's case (14.11.2026): the camera in
one corner, the Mac in the other, both on the same Wi-Fi, his XLR mixer (16 or 18 channels) on the Mac. He chooses the
source and two of its channels, presses SEND, and the camera switches its sound to the Mac by itself; the take, GO LIVE
(VDO.Ninja), NDI and the meters then carry the desk's sound. Public and unpromoted (repo-privacy.md): no README.

- App: `/Applications/Sound Link (Mantra).app`, bundle id `community.auroville.soundlink`, signed "Mantra Apps".
- Version: `let VERSION = N` in app/App.swift (whole numbers). Built only by GitHub Actions (.github/workflows/build.yml,
  macos-15, swiftc via build.sh), release vN marked Latest with app.zip.
- Asks to update at start (app/Updater.swift, kits/mac-updater).
- Door (Star API functions): http://127.0.0.1:8974/fn/{status,devices,source,send,stop,permissions}, registered in
  ~/.config/star-fns/sound-link.json.
- Log: ~/Library/Logs/Sound Link (Mantra).log (every 5 s while sending: fill, rtt, latency, underruns, lost, late, drift).
- Permissions: Microphone (amber PERMISSIONS top right while missing), Local Network (macOS asks once at the first browse).

## The window (workflow-interface.md)
1 SOURCE: the input device (menu) with the stereo meter beside it (two bars, small gap, no L R), and the pairs of its
channels as pipes (1-2 | 3-4 | … | 17-18). 2 CAMERA: the Manual Camera phones found on the Wi-Fi, chosen by itself when
there is one. 3 SEND / STOP (the round number is the button). While sending: LATENCY | BUFFER | DROPOUTS | LOST | DRIFT | SENT.

## How it works
- Capture (app/Capture.swift): a HAL output unit (AUHAL) on the chosen device, IO 256 frames, channel map = the pair, the
  device's own rate (never changed); the pump converts to 48 kHz with AVAudioConverter when needed.
- Discovery: Manual Camera registers `_mantrasound._udp` with Android NSD while it is open; the Mac browses with NWBrowser.
- Transport (app/Link.swift, the wire written at its top): UDP, 48 kHz stereo 16-bit PCM, 240 frames (5 ms) per packet,
  sequence number and sample time (RTP-like), service class interactiveVoice. A hello every 250 ms carries the Mac's name
  and a ping; the phone answers each hello with its buffer, underruns, lost, late, drift and its name.
- The phone's side (MANTRA_NDI LinkJitter.kt, MacLink.kt): adaptive jitter buffer (target 40 ms + 3 × jitter, up to
  160 ms), one read cursor per consumer (the meter/take/NDI reader, and the GO LIVE WebRTC recorder), each resampled gently
  (±4000 ppm at most) so the Mac clock never drifts against the phone's audio clock.

## Test (no speakers): BlackHole 2ch
    sox -n -t coreaudio "BlackHole 2ch" synth 130 sine 440 vol 0.1     # a tone into BlackHole, the Mac's output untouched
    curl -s -XPOST 127.0.0.1:8974/fn/source -d '{"device":"BlackHole","pair":1}'
    curl -s -XPOST 127.0.0.1:8974/fn/send -d '{}'; sleep 120; curl -s -XPOST 127.0.0.1:8974/fn/status

## Install on the Mac (no compile)
    gh release download --repo markoboskoauroville/SOUND_LINK --pattern app.zip -D /tmp/sl --clobber
    ditto -x -k /tmp/sl/app.zip /tmp/sl/x && codesign --force -s "Mantra Apps" "/tmp/sl/x/Sound Link (Mantra).app"
    then the swap of swift-apps.md (".tmp-" copy, mv old away, mv new in), and open -g.

## v3–v5 (15.11.2026)
- v3: Tailscale. The Mac reads `tailscale status --json` every 15 s and sends a hello to each online peer on UDP 47474
  every 3 s; a peer that answers is listed as "<host> · Tailscale". The same phone (its id from v210 in the Bonjour TXT
  record and in each report, else its model) is one camera, Wi-Fi first. While sending, the Mac moves to the Wi-Fi way as
  soon as it is there, and falls back to Tailscale when the Wi-Fi way is silent for 2.5 s. The door's `send` takes
  `path: wifi|tailscale` to force one way for a measurement.
- v4: wire version 2. Each packet carries the block from N packets back in μ-law after its own block: 240-frame blocks on
  the Wi-Fi (1468 bytes, one Wi-Fi frame) and 160 over Tailscale (its MTU is 1280). The window shows LOST n / n back.
- v5: N = 8 (40 ms), because Wi-Fi loses packets in bursts.
- The phone's buffer (v210): 150 ms on the Wi-Fi, 400 ms over Tailscale, plus 3 × jitter, plus 40 ms for each dropout
  (shrinks 1 ms every 5 s). Concealment repeats the block before at half level; dropouts fade.
- v6 (15.11.2026, lip-sync): the hello also carries the round trip the Mac measured (µs, u32) and its own delay (input buffer
  + half a packet + the poll, µs, u32) after the name. From v214 the camera stamps the take's sound earlier by
  Mac delay + rtt/2 + its buffer.

## 15.11.2026: Studio, the Mac as the encoder (studio/)
Marko: "maybe Mac can stream, why phone should stream? ... make this sound link also picture link." Python, no compiling:
- `studio/ndi.py`: libndi (/usr/local/lib/libndi.dylib, NDI Tools) through ctypes: find sources, receive UYVY frames.
- `studio/studio.py`: Manual Camera's NDI HX (Picture Link) + the mixer (avfoundation; Sound Link's device and pair when it runs,
  else `--audio "<name>" --pair N`) -> ffmpeg: h264_videotoolbox 1080p25 5 Mbit/s GOP 2 s + aac_at 160 kbit/s CBR stereo -> RTMP
  over Tailscale to chromium-vm `studio-ladder`. Frames are paced at 25 fps by the Mac's clock (a frozen last frame if the camera
  stalls, black before the first). A camera size other than 1920x1080 is letterboxed (numpy). Restarts the master on a drop.
  `--av-offset-ms` for the clap test, `--seconds N` for short SIM tests, `--go-live` = GO/STOP on the band site as the paired camera
  "MacBook Pro" (token in ~/.config/studio/camera-token, chmod 600; pair it at /admin → PAIR CAMERA). `--list` shows sources/devices.
- `studio/ndi_testsend.py`: an NDI test source "STUDIO TEST" (testsrc2), `studio.py --test` uses it with a 440/660 Hz tone.
- Proven 15.11.2026 with the test source: 50 s, speed 0.998x, 4.3 Mbit/s out, the VM ladder live, the gear playing every level.
- Not yet proven: the real Pixel NDI into studio.py (the Pixel was off the Mac's Wi-Fi and its NDI off), the mixer, A/V sync.
- Next: a Swift app "Studio (Mantra)" around studio.py (numbered workflow 1 CAMERA, 2 SOUND, 3 GO LIVE), built on GitHub.

## v8 (15.11.2026): 2 PICTURE and 4 STREAM inside the app
Marko: "build receiver in soundlink". Workflow now 1 SOURCE · 2 PICTURE · 3 SEND (the phone chosen inside it) · 4 STREAM.
- PICTURE (app/Picture.swift): the NDI runtime of NDI Tools (/usr/local/lib/libndi.dylib, or NDI_RUNTIME_DIR_V6) loaded by dlopen;
  the calls are declared by us in app/ndi_min.h (build.sh: -import-objc-header). No SDK file in this public repo or in the app.
  The private repo mantra-ndi-sdk holds only the Android Advanced SDK (arm64 .so, "Not for redistribution"), so no token or secret
  is needed. Finder every 2 s (Bonjour; door `picture {extra_ips}` for Tailscale), the Manual Camera source chosen by itself when it is
  the only one, decoded UYVY frames (the standard runtime decodes HX; compressed passthrough would need the Advanced SDK on the Mac),
  a 240 px preview at 4 fps, motion = mean luma difference between previews (0 = frozen). Info.plist Bonjour: _ndi._tcp.
- STREAM: the newest frame at 25 fps by the Mac's clock (black before the first) into ffmpeg (Homebrew) with the chosen device and pair:
  h264_videotoolbox 1080p25 5 Mbit/s GOP 2 s + aac_at 160 CBR stereo, RTMP to rtmp://100.102.86.30:1935/studio/master (UserDefaults
  streamTo). Restarts on a drop. go_live (door) / streamGoLive (defaults) = GO/STOP on the band site as the camera "MacBook Pro".
- Door: `picture {source?, extra_ips?}`, `stream {action: start|stop, go_live?, seconds?, to?}`.
- Built green: https://github.com/markoboskoauroville/SOUND_LINK/actions/runs/43680233093 (release v8 Latest, contains v7's pump fix).
  Installed 06:25 (v7 quit by AX OFF, swap, open -g; SEND to the Pixel restored with BlackHole 1-2 after 18 s; the phone showed
  "MAC LINK 165 ms"). Proven 06:26 with the NDI test source: PICTURE 1920x1080 at 25 fps, motion 2.3-2.8 (moving); STREAM 30 s:
  725 frames, speed 1x, 3.9-4.3 Mbit/s, the VM ladder live (1080p25 High, health live), VM ladder ~85 % of one core; the SEND
  to the Pixel went on (1 underrun, 1 lost in those 30 s). Not yet: the Pixel's own NDI (its NDI was off), the mixer.
- The `--shot` render is blank (ImageRenderer cannot draw the ScrollView/GeometryReader window): screenshots need the real window.

## v7 (15.11.2026, audio fix)
- Pump under a latency-critical activity, App Nap off (Info.plist NSAppSleepDisabled), hold-ups over 60 ms logged ("pump: held up").
- Installed on the Mac 15.11.2026 05:47 (gh release download v7, signed "Mantra Apps"); SEND from BlackHole 2ch 1-2 over the Wi-Fi.
- Measured with the camera v216: 0 dropouts and no arrival gap over 141 ms in 22 min (before: a 240–740 ms hole every 2–4 min).
- Open: BlackHole 2ch device volume 70.6 % (−18.8 dB) lowers everything in the stream; Marko decides whether it goes to 100 %.

## v9 (15.11.2026): the camera is named MacBook Pro
Marko: "what is Mac Studio? ... call it MacBook Pro, and I don't have this thing at all." Only the label changed (studio.py, Picture.swift):
the paired camera at /admin is now "MacBook Pro" (the token file is unchanged; re-pair under the new name if the site lists the old one).

## v10 (15.11.2026): mac23's NDI review fixes (MANTRA_MANIFEST modules/ndi-best-practice.md)
- #1 formats: the receivers ask UYVY_BGRA; the runtime then hands UYVY, or BGRA for sources with alpha (Meditation Room sends
  BGRA). UYVY/UYVA are used as they are (UYVA: the UYVY plane), BGRA/BGRX/RGBA/RGBX are converted to UYVY, BT.709 video range:
  vImage (vImageConvert_ARGB8888To422CbYpCrYp8) in Picture.swift, numpy fixed point in studio/ndi.py `to_uyvy` (1080p ~37 ms,
  720p ~9 ms). Any other FourCC is logged once ("FourCC X is not converted, its frames are skipped"). Measured: with UYVY_BGRA the
  runtime itself turns BGRX and NV12 into UYVY and UYVA into BGRA, so only UYVY and BGRA reach us in practice.
- #6 by name: the receiver connects with p_ndi_name only; the URL is shown but used only for an address typed by hand
  (door `picture {url: "ip:port", source?}`, studio.py `--ndi-url`). Log: "PICTURE: <name> by name, frame sync at 25 fps".
- #8 frame sync: NDIlib_framesync_create on the receiver; STREAM pulls `framesync_capture_video` at its own 25 fps clock
  (Picture.pull(); studio.py Frames.pull()), the frame sync repeats or drops; Picture's own 25 fps clock pulls only while STREAM
  does not. The source's own NDI sound is drained through `framesync_capture_audio` at the same clock (app: level only,
  `ndi_sound_db`; studio.py `--audio ndi` sends it into the master through a second pipe).
- #9 static vs stall: the app's picture state is live / static (connected, no new frame for 2 s: a send-on-change source) /
  lost (no connection); the STREAM line says "picture static (the source sends on change)". ndi_probe.py (in MANTRA_NDI
  scripts/, repo mantra-manual-camera) says STATIC instead of PICTURE STALL for such sources (see its header; `--static`, `--stall-ms`).
- Names: our NDI receiver names are "Sound Link" and "Studio" (no parentheses); ndi_testsend.py refuses a name with them.
- Tests without data: `studio.py --to null` encodes and throws away (no network); `ndi_testsend.py` has `--fourcc BGRA|BGRX|UYVA|NV12`,
  `--size`, `--on-change N`, `--tone`, `--stop-video-after N`. The app's STREAM was tested into a local listener
  (`ffmpeg -listen 1 -f flv -i rtmp://127.0.0.1:19350/live/test -f null -`); the door's `to` is remembered in UserDefaults
  `streamTo`, so delete it afterwards (`defaults delete community.auroville.soundlink streamTo`).
- Built green: https://github.com/markoboskoauroville/SOUND_LINK/actions/runs/43719210195 (release v10 Latest). Installed
  15.11.2026 14:30 (Sound Link was not running; downloaded, signed "Mantra Apps", ".tmp-" swap, open -g, window shows v10, quit again).
- Proven with test sources (Python and app): BGRA 1280x720 live 25 fps with correct colours, -23 dBFS NDI tone through the frame
  sync; STREAM 10 s to the local listener 244 frames; a source with one frame every 8 s shows "static". Not yet: Meditation Room
  itself (it was not running) and the Pixel's NDI.
