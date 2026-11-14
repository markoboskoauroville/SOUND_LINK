# Sound Link (Mantra): LESSONS

1. (14.11.2026) AVAudioEngine's input tap hands out ~100 ms buffers on macOS and follows the default input; for a link
   the HAL output unit with a channel map is the right tool (5 ms IO, any two channels of a multichannel mixer).
2. (14.11.2026) The phone's audio clock is the master. The Mac's packets fill a ring indexed by the Mac's sample count;
   each consumer on the phone reads it at its own pace and resamples by a small ratio steered by how full it is, so the
   two clocks never drift apart and the buffer never slowly runs dry or overflows.
3. (14.11.2026) macOS 15 asks for Local Network the first time an app browses Bonjour; NSBonjourServices and
   NSLocalNetworkUsageDescription must be in Info.plist or the browse finds nothing without a word.
