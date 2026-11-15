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
  "Mac Studio" (token in ~/.config/studio/camera-token, chmod 600; pair it at /admin → PAIR CAMERA). `--list` shows sources/devices.
- `studio/ndi_testsend.py`: an NDI test source "STUDIO TEST" (testsrc2), `studio.py --test` uses it with a 440/660 Hz tone.
- Proven 15.11.2026 with the test source: 50 s, speed 0.998x, 4.3 Mbit/s out, the VM ladder live, the gear playing every level.
- Not yet proven: the real Pixel NDI into studio.py (the Pixel was off the Mac's Wi-Fi and its NDI off), the mixer, A/V sync.
- Next: a Swift app "Studio (Mantra)" around studio.py (numbered workflow 1 CAMERA, 2 SOUND, 3 GO LIVE), built on GitHub.
