# Momentary updates: Marko's words, saved before any code

## 14.11.2026 ~23:15, the request (word for word)

"another Swift app to develop for this case, that is Sound Link. A Sound Link is basically finding this application in the Mantra manual camera on the network and sending the sound from my Mac. We're going to have the camera on one corner and my Mac on another corner. They will both be in the same Wi-Fi network, and on my Mac there will be a connected XLR mixer with all its 16 channels, 18 channels, I don't know. This is a stereo link only, so I'm choosing 2 channels. I'm choosing the source, and I press Send. When I press Send, my camera app automatically switches the sound and puts the status text that it's receiving sound from the Mac. In that case, we can have the sound from the desk in the stream. That's the idea. Please make a Sound Link"

## 14.11.2026 ~23:45, over Tailscale (word for word)

"please also make a sound link work over tail scale because maybe we will not be on the same Wi-Fi"

## 14.11.2026 ~23:55, Wi-Fi first (word for word)

"now the phones are on the same network, the phone and the laptop ... So you can now check if it goes through Tailscale or goes to Wi-Fi. Wi-Fi needs to have an advantage over Tailscale, and I guess Tailscale has more delay. I'm not sure. Let me know."

## 14.11.2026 ~00:02, a decent buffer (word for word)

"many dropouts when this is sending sound and lost packages. Can we build some decent buffer here"

## 15.11.2026, fix the audio streaming: test signals through BlackHole, measure drops (Marko, word for word)
"Please let's uh fix our audio streaming. You need to stop this application which is now running through Black Hole, which is my DJ app DJ Pro from algorithm quit it. And through Black Hole, please send oscillator different test signals and and measure the drops. You need to open the stream. You start the stream from the Pixel phone. Open the stream on the Mac in any browser of your choice, and record audio. And see if there are drops, jittering, whatever errors in audio, you work on fixing those, please."

## 15.11.2026, Studio stream: audio quality choice like YouTube, the Mac as encoder, Picture Link (Marko, voice, word for word)

"Also another feature we need to have for the users is to choose their quality of audio stream. Similar as on [YouTube]. You will have all these title options. So each user get its own quality of source, which cannot be better than the master quality. So you need to find audio stream which is not to big, not to small. Let's let's do like this. Let's do AAC 160 which is like the best. It's a stereo quality of audio coming from the mixer in the hall. And then user can go from 160 to half, to half of half to reduce the bandwidth. Quality, let's call it like this. Q column 160 and then stereo or mono, S or M. And if the stream is mono, then the quality is getting higher in sound, but in space is less. If I put for example stereo, I get stereo. And then I can reduce my bandwidth, stereo or mono mode. Yes, do that please. By default 160 AAC stereo. So in that sense, our streaming does not need to be real-time. We can have 10 to 15 seconds delay, like YouTube has, to get the uncompressed audio, compress it and then send it. So, I guess 10 to 15 seconds is okay. Maybe you can take 5 seconds of audio, compress it and send it and start again. Because we are in the local network with our sound link, so then through Wi-Fi, we can send uncompressed audio or even better with sound link, we can send already compressed audio, so the phone is not working too much. That would be the best way, I think. ... If there is sound link, pre-digest everything, and then you just stream in that quality ... So from my Mac to phone, which is streaming, maybe Mac can stream, why phone should stream? Maybe we can make this sound link also picture link. So I'm getting picture from the phone to my Mac and all the processing is done on the bigger and better machine. And then it attach audio and it can really send multiple different streams of audio quality. So and video quality, so user can choose depends on his connection. Let's copy YouTube system, the gear icon, quality, etc. Yes, let's do that, please. I feel we should use the power of the Mac since it's connected to the mixer and to the Wi-Fi and use just the phone to deliver the image from the Sony camera with Wi-Fi to the Mac. That's the best. But make both direction work, but now let's develop for the next concert this workflow. So, our camera, Mantra, manual camera is sending stream from the Sony to the Mac, and Mac is streaming. Let's do that."

**Plan (master, 15.11.2026):** Picture Link phone → Mac over the LAN; the Mac ("Studio") muxes the Sony picture with the mixer audio and sends ONE master (1080p25 H.264 ~5 Mbit/s + AAC 160 stereo) to the Frankfurt relay; the VM builds the ladder (1080/720/480/360; Q:160/80/40 S and M) as HLS with separate audio renditions; /live/ gets a YouTube-like gear. The phone → relay route keeps working. Status (15.11.2026, ~06:30): built and proven with an NDI test source: studio.py (SOUND_LINK/studio) → studio-ladder/studio-web on chromium-vm (vm-chromium/studio-stream) → /live/ gear (SANTOSHI_BAND_SITE live/studio.js, deployed). Open: Oracle ingress tcp 2053 (public door), the real Pixel NDI + mixer test, the clap test, the Swift app.

## 15.11.2026, the NDI HX receiver inside Sound Link (Marko, word for word, relayed by a cloud session)

"so, Nii can send over NDI the picture to the Mac, but NDIHX will that and we have SDK from NDI original, it's right in a GitHub, and build receiver in soundlink"

**Meaning (master):** the NDI HX receiver goes into the Sound Link (Mantra) Mac app itself (Swift), built with the official NDI SDK from the private repo mantra-ndi-sdk (fetched at build time, never committed here). Workflow 1 SOURCE (audio) · 2 PICTURE (NDI) · 3 SEND (to the phone) / STREAM (to Frankfurt). studio.py stays as the CLI fallback. Status (15.11.2026 ~06:20): v8 built green and released Latest (NDI runtime by dlopen, no SDK needed); installed 06:25 and proven with the NDI test source (PICTURE 25 fps moving, STREAM 30 s to the VM ladder at 1x); the Pixel's own NDI and the mixer are next.
