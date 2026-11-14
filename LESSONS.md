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
