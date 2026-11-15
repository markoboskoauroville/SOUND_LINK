// Picture.swift: 2 PICTURE and 4 STREAM (v8, 15.11.2026). Marko: "so, Nii can send over NDI the picture to the Mac, but NDIHX
// will that and we have SDK from NDI original ... and build receiver in soundlink" and "Mac can stream, why phone should stream?"
//
// PICTURE: the NDI sources on the Wi-Fi (Manual Camera sends NDI HX, H.264/HEVC; Meditation Room sends BGRA); the NDI runtime
// decodes them. v10 (mac23's NDI review, MANTRA_MANIFEST modules/ndi-best-practice.md): connected by NAME (#6), read through
// the NDI frame sync at our own 25 fps clock (#8, as OBS DistroAV), UYVY/UYVA used as they are and BGRA/BGRX/RGBA/RGBX
// converted with vImage (#1, any other FourCC logged once), a connected source without new frames is "static", not stalled (#9). The runtime is NDI Tools' libndi, loaded with dlopen (ndi_min.h): nothing of the
// SDK is in this public repository or in the app.
// STREAM: ONE master to the VM's quality ladder (vm-chromium/studio-stream): the frame sync pulled at 25 fps by the Mac's clock +
// the chosen pair of the mixer, through ffmpeg (h264_videotoolbox 1080p25 5 Mbit/s GOP 2 s + aac_at 160 kbit/s CBR stereo) by
// RTMP over Tailscale. The same job as studio/studio.py, which stays as the command-line fallback.
import Foundation
import AppKit
import CoreImage
import CoreVideo
import Accelerate

// ---------------------------------------------------------------- the NDI runtime
final class NDIRuntime {
    static let shared = NDIRuntime()
    private(set) var loaded = false
    private(set) var path = ""
    var findCreate: SLNDI_find_create_v2!
    var findWait: SLNDI_find_wait_for_sources!
    var findSources: SLNDI_find_get_current_sources!
    var findDestroy: SLNDI_find_destroy!
    var recvCreate: SLNDI_recv_create_v3!
    var recvCapture: SLNDI_recv_capture_v2!
    var recvFreeVideo: SLNDI_recv_free_video_v2!
    var recvDestroy: SLNDI_recv_destroy!
    var recvConnections: SLNDI_recv_get_no_connections!
    var fsCreate: SLNDI_framesync_create!
    var fsDestroy: SLNDI_framesync_destroy!
    var fsVideo: SLNDI_framesync_capture_video!
    var fsFreeVideo: SLNDI_framesync_free_video!
    var fsAudio: SLNDI_framesync_capture_audio!
    var fsFreeAudio: SLNDI_framesync_free_audio!

    private init() {
        var dirs: [String] = []
        for k in ["NDI_RUNTIME_DIR_V6", "NDI_RUNTIME_DIR_V5"] { if let d = ProcessInfo.processInfo.environment[k] { dirs.append(d + "/libndi.dylib") } }
        dirs += ["/usr/local/lib/libndi.dylib", "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
                 "/Library/Application Support/NewTek/NDI/libndi.dylib", "/opt/homebrew/lib/libndi.dylib"]
        for p in dirs where FileManager.default.fileExists(atPath: p) {
            guard let h = dlopen(p, RTLD_NOW | RTLD_LOCAL) else { continue }
            func sym<T>(_ n: String, _ t: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: t) } }
            guard let ini = sym("NDIlib_initialize", SLNDI_initialize.self),
                  let fc = sym("NDIlib_find_create_v2", SLNDI_find_create_v2.self),
                  let fw = sym("NDIlib_find_wait_for_sources", SLNDI_find_wait_for_sources.self),
                  let fs = sym("NDIlib_find_get_current_sources", SLNDI_find_get_current_sources.self),
                  let fd = sym("NDIlib_find_destroy", SLNDI_find_destroy.self),
                  let rc = sym("NDIlib_recv_create_v3", SLNDI_recv_create_v3.self),
                  let rcap = sym("NDIlib_recv_capture_v2", SLNDI_recv_capture_v2.self),
                  let rfv = sym("NDIlib_recv_free_video_v2", SLNDI_recv_free_video_v2.self),
                  let rd = sym("NDIlib_recv_destroy", SLNDI_recv_destroy.self),
                  let rnc = sym("NDIlib_recv_get_no_connections", SLNDI_recv_get_no_connections.self),
                  let fsc = sym("NDIlib_framesync_create", SLNDI_framesync_create.self),
                  let fsd = sym("NDIlib_framesync_destroy", SLNDI_framesync_destroy.self),
                  let fsv = sym("NDIlib_framesync_capture_video", SLNDI_framesync_capture_video.self),
                  let fsfv = sym("NDIlib_framesync_free_video", SLNDI_framesync_free_video.self),
                  let fsa = sym("NDIlib_framesync_capture_audio", SLNDI_framesync_capture_audio.self),
                  let fsfa = sym("NDIlib_framesync_free_audio", SLNDI_framesync_free_audio.self) else { continue }
            guard ini() else { Log.line("NDI: \(p) refused to start"); continue }
            findCreate = fc; findWait = fw; findSources = fs; findDestroy = fd
            recvCreate = rc; recvCapture = rcap; recvFreeVideo = rfv; recvDestroy = rd; recvConnections = rnc
            fsCreate = fsc; fsDestroy = fsd; fsVideo = fsv; fsFreeVideo = fsfv; fsAudio = fsa; fsFreeAudio = fsfa
            loaded = true; path = p
            Log.line("NDI runtime: \(p)")
            return
        }
        Log.line("NDI runtime not found (install NDI Tools)")
    }
}

// ---------------------------------------------------------------- the picture
/// A source is connected by its NAME (NDI review #6): the runtime finds it again through discovery, so a phone whose USB
/// tether moved to another subnet is not lost. The URL is kept for display and used only for an address typed by hand.
struct NDISource: Hashable {
    let name: String; let url: String; var manual: Bool = false
}

/// One connection: the receiver and its frame sync, destroyed together under Picture's lock.
private final class NDIConn {
    let recv: UnsafeMutableRawPointer
    let sync: UnsafeMutableRawPointer
    var alive = true
    init(recv: UnsafeMutableRawPointer, sync: UnsafeMutableRawPointer) { self.recv = recv; self.sync = sync }
}

final class Picture {
    static let W = 1920, H = 1080, FPS = 25
    static func fourcc(_ s: String) -> UInt32 { s.utf8.reversed().reduce(0) { $0 << 8 | UInt32($1) } }
    static let fourccUYVY = fourcc("UYVY"), fourccUYVA = fourcc("UYVA")
    static let fourccBGRA = fourcc("BGRA"), fourccBGRX = fourcc("BGRX"), fourccRGBA = fourcc("RGBA"), fourccRGBX = fourcc("RGBX")
    static func name(_ f: UInt32) -> String {
        let b = [UInt8(f & 0xff), UInt8(f >> 8 & 0xff), UInt8(f >> 16 & 0xff), UInt8(f >> 24)]
        return b.allSatisfy({ $0 >= 32 && $0 < 127 }) ? String(decoding: b, as: UTF8.self) : String(format: "0x%08x", f)
    }

    var onSources: (([NDISource]) -> Void)?
    var onPreview: ((NSImage?, String) -> Void)?

    private let lock = NSLock()                       // the connection, the frame sync and `latest`
    private var conn: NDIConn?
    private var latest: Data?                         // 1920x1080 UYVY, the frame the frame sync gave last
    private var lastStamp: Int64 = .min
    private var skipped = Set<UInt32>()
    private(set) var frames = 0                       // new frames from the source
    private(set) var repeats = 0                      // ticks where the frame sync gave the same frame again
    private(set) var size = ""
    private(set) var format = ""
    private(set) var lastFrameAt = Date.distantPast
    private(set) var motion = 0.0                     // mean |Δ| of sampled luma between previews (0 = frozen)
    private(set) var fps = 0.0                        // new frames per second (the source's real rate)
    private(set) var connections = 0
    private(set) var ndiSoundDB = -120.0             // the source's own sound through the frame sync (shown, not sent)
    private var finderOn = false
    private(set) var source: NDISource?
    private var lastSample: [UInt8] = []
    private var lastPreview = Date.distantPast
    private var fpsCount = 0, fpsT0 = Date()
    private let previewQ = DispatchQueue(label: "ndi-preview", qos: .utility)
    private let ci = CIContext(options: [.cacheIntermediates: false])
    /// true while STREAM pulls the frame sync at its own 25 fps clock; otherwise Picture's own clock pulls it.
    var externalClock = false
    var extraIPs = ""

    var available: Bool { NDIRuntime.shared.loaded }

    /// Sources every 2 s (Bonjour on the LAN, plus extraIPs for Tailscale).
    func startFinder() {
        guard available, !finderOn else { return }
        finderOn = true
        let t = Thread { [weak self] in
            let rt = NDIRuntime.shared
            var last: [NDISource] = []
            while let self = self, self.finderOn {
                let ips = self.extraIPs
                let f: UnsafeMutableRawPointer? = ips.withCString { c in
                    var fc = SLNDIFindCreate(show_local_sources: true, p_groups: nil, p_extra_ips: ips.isEmpty ? nil : c)
                    return rt.findCreate(&fc)
                }
                guard let finder = f else { Thread.sleep(forTimeInterval: 2); continue }
                for _ in 0..<4 { _ = rt.findWait(finder, 500) }
                while self.finderOn {
                    _ = rt.findWait(finder, 2000)
                    var n: UInt32 = 0
                    var out: [NDISource] = []
                    if let arr = rt.findSources(finder, &n) {
                        for i in 0..<Int(n) {
                            let s = arr[i]
                            out.append(NDISource(name: s.p_ndi_name.map { String(cString: $0) } ?? "",
                                                 url: s.p_url_address.map { String(cString: $0) } ?? ""))
                        }
                    }
                    if out != last { last = out; DispatchQueue.main.async { self.onSources?(out) } }
                    if ips != self.extraIPs { break }
                }
                rt.findDestroy(finder)
            }
        }
        t.name = "ndi-find"; t.start()
    }

    func connect(_ s: NDISource) {
        guard available else { return }
        disconnect()
        let rt = NDIRuntime.shared
        // by name; the URL only when it was typed by hand. No parentheses in our receiver's name (ndi-best-practice §1).
        let name = s.name.isEmpty ? nil : strdup(s.name), url = (s.manual && !s.url.isEmpty) ? strdup(s.url) : nil, me = strdup("Sound Link")
        var rc = SLNDIRecvCreateV3(source_to_connect_to: SLNDISource(p_ndi_name: name.map { UnsafePointer($0) }, p_url_address: url.map { UnsafePointer($0) }),
                                   color_format: 1 /* UYVY_BGRA */, bandwidth: 100 /* highest */, allow_video_fields: false,
                                   p_ndi_recv_name: UnsafePointer(me))
        let r = rt.recvCreate(&rc)
        free(name); free(url); free(me)
        guard let recv = r else { Log.line("NDI: no receiver for \(s.name)"); return }
        guard let sync = rt.fsCreate(recv) else { rt.recvDestroy(recv); Log.line("NDI: no frame sync for \(s.name)"); return }
        let c = NDIConn(recv: recv, sync: sync)
        lock.lock()
        conn = c; source = s; latest = nil; lastStamp = .min; frames = 0; repeats = 0; format = ""; size = ""
        lastFrameAt = .distantPast; fpsCount = 0; fpsT0 = Date()
        lock.unlock()
        Log.line("PICTURE: \(s.name) " + (s.manual ? "at \(s.url) (typed by hand)" : "by name") + ", frame sync at \(Picture.FPS) fps")
        // Picture's own clock: pulls the frame sync at 25 fps for the preview while STREAM does not (STREAM pulls it itself).
        let t = Thread { [weak self] in
            let t0 = Date(); var n = 0
            while let self = self, c.alive {
                n += 1
                let due = t0.addingTimeInterval(Double(n) / Double(Picture.FPS))
                let wait = due.timeIntervalSinceNow
                if wait > 0 { Thread.sleep(forTimeInterval: wait) } else if wait < -1 { n = Int(-t0.timeIntervalSinceNow * Double(Picture.FPS)) }
                if !self.externalClock { _ = self.pull() }
                if n % Picture.FPS == 0 { self.connections = Int(c.alive ? rt.recvConnections(c.recv) : 0) }
            }
            let l = self?.lock
            l?.lock()
            rt.fsDestroy(c.sync); rt.recvDestroy(c.recv)      // the frame sync before its receiver
            l?.unlock()
        }
        t.name = "ndi-sync"; t.start()
    }

    func disconnect() {
        lock.lock(); conn?.alive = false; conn = nil; source = nil; latest = nil; lock.unlock()
        DispatchQueue.main.async { self.onPreview?(nil, "") }
    }

    /// One tick of the output clock (NDI review #8): the frame the frame sync gives for now, as 1920x1080 UYVY, or nil
    /// before the first frame. Called at 25 fps by STREAM while it runs, else by Picture's own clock. The frame sync repeats
    /// the last frame when the source is slower or sends only on change, and drops frames when it is faster.
    func pull() -> Data? {
        let rt = NDIRuntime.shared
        lock.lock(); defer { lock.unlock() }
        guard let c = conn, c.alive else { return nil }
        // the source's own sound: drained at this clock so the frame sync's queue stays short; its level is shown only
        var a = SLNDIAudioFrameV2()
        rt.fsAudio(c.sync, &a, 48000, 2, Int32(48000 / Picture.FPS))
        if let p = a.p_data, a.no_samples > 0 {
            var sum: Float = 0; vDSP_svesq(p, 1, &sum, vDSP_Length(a.no_samples))
            ndiSoundDB = sum > 0 ? Double(10 * log10(sum / Float(a.no_samples))) : -120
        }
        rt.fsFreeAudio(c.sync, &a)
        var v = SLNDIVideoFrameV2()
        rt.fsVideo(c.sync, &v, 1 /* progressive */)
        defer { rt.fsFreeVideo(c.sync, &v) }
        guard let p = v.p_data, v.xres > 1, v.yres > 0 else { return latest }
        let stamp = v.timestamp != 0 ? v.timestamp : v.timecode
        if stamp == lastStamp, latest != nil { repeats += 1; return latest }
        let w = Int(v.xres), h = Int(v.yres), stride = Int(v.line_stride_in_bytes), f = v.FourCC
        let out: Data
        switch f {
        case Picture.fourccUYVY, Picture.fourccUYVA:       // UYVA: the UYVY plane first, then alpha (not needed)
            out = Picture.fit(p, w, h, stride)
        case Picture.fourccBGRA, Picture.fourccBGRX, Picture.fourccRGBA, Picture.fourccRGBX:
            guard let u = Picture.rgbToUYVY(p, w, h, stride, bgr: f == Picture.fourccBGRA || f == Picture.fourccBGRX) else { return latest }
            out = u.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                Picture.fit(UnsafeMutablePointer(mutating: b.bindMemory(to: UInt8.self).baseAddress!), w / 2 * 2, h, w / 2 * 4)
            }
        default:
            if !skipped.contains(f) { skipped.insert(f); Log.line("PICTURE: FourCC \(Picture.name(f)) is not converted, its frames are skipped") }
            return latest
        }
        if Picture.name(f) != format {
            format = Picture.name(f)
            Log.line("PICTURE: \(w)x\(h) \(format)" + (f == Picture.fourccUYVY ? "" : ", converted to UYVY"))
        }
        lastStamp = stamp; latest = out
        frames += 1; fpsCount += 1
        size = "\(w)x\(h)"; lastFrameAt = Date()
        let el = Date().timeIntervalSince(fpsT0)
        if el >= 2 { fps = Double(fpsCount) / el; fpsCount = 0; fpsT0 = Date() }
        if Date().timeIntervalSince(lastPreview) > 0.25 { lastPreview = Date(); previewQ.async { self.preview(out) } }
        return out
    }

    /// The newest frame (1920x1080 UYVY) or nil, without pulling the frame sync.
    func frame() -> Data? { lock.lock(); defer { lock.unlock() }; return latest }

    /// BGRA/BGRX/RGBA/RGBX into UYVY of the same size (width made even) with vImage: BT.709, video range (NDI review #1).
    private static let info709: vImage_ARGBToYpCbCr? = {
        var info = vImage_ARGBToYpCbCr()
        var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        let e = vImageConvert_ARGBToYpCbCr_GenerateConversion(kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2, &range, &info,
                                                              kvImageARGB8888, kvImage422CbYpCrYp8, vImage_Flags(kvImageNoFlags))
        if e != kvImageNoError { Log.line("PICTURE: vImage conversion setup failed (\(e))"); return nil }
        return info
    }()

    static func rgbToUYVY(_ p: UnsafeMutablePointer<UInt8>, _ w: Int, _ h: Int, _ stride: Int, bgr: Bool) -> Data? {
        guard var info = info709 else { return nil }
        let w2 = w / 2 * 2
        var out = Data(count: w2 * h * 2)
        let e: vImage_Error = out.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) -> vImage_Error in
            var src = vImage_Buffer(data: UnsafeMutableRawPointer(p), height: vImagePixelCount(h), width: vImagePixelCount(w2), rowBytes: stride)
            var dst = vImage_Buffer(data: o.baseAddress!, height: vImagePixelCount(h), width: vImagePixelCount(w2), rowBytes: w2 * 2)
            // permuteMap: where A, R, G, B sit in the source's 4 bytes
            let map: [UInt8] = bgr ? [3, 2, 1, 0] : [3, 0, 1, 2]
            return vImageConvert_ARGB8888To422CbYpCrYp8(&src, &dst, &info, map, vImage_Flags(kvImageNoFlags))
        }
        if e != kvImageNoError { Log.line("PICTURE: vImage conversion failed (\(e))"); return nil }
        return out
    }

    /// Any size into 1920x1080 UYVY: copied row by row when it is 1920x1080, else nearest-neighbour inside black bars.
    static func fit(_ p: UnsafeMutablePointer<UInt8>, _ w: Int, _ h: Int, _ rowBytes: Int) -> Data {
        var out = Data(count: W * H * 2)
        out.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) in
            let dst = o.bindMemory(to: UInt8.self).baseAddress!
            if w == W && h == H {
                for y in 0..<H { memcpy(dst + y * W * 2, p + y * rowBytes, W * 2) }
                return
            }
            // black in UYVY: U=128 Y=16 V=128 Y=16
            for i in stride(from: 0, to: W * H * 2, by: 4) { dst[i] = 128; dst[i + 1] = 16; dst[i + 2] = 128; dst[i + 3] = 16 }
            let s = min(Double(W) / Double(w), Double(H) / Double(h))
            let ow = max(2, Int(Double(w) * s) / 2 * 2), oh = max(2, Int(Double(h) * s))
            let x0 = (W - ow) / 4 * 2, y0 = (H - oh) / 2
            let macroOut = ow / 2, macroIn = max(1, w / 2)
            for y in 0..<oh {
                let sy = min(h - 1, y * h / oh)
                let srow = p + sy * rowBytes, drow = dst + (y0 + y) * W * 2 + x0 * 2
                for mx in 0..<macroOut {
                    let sx = min(macroIn - 1, mx * macroIn / macroOut)
                    memcpy(drow + mx * 4, srow + sx * 4, 4)
                }
            }
        }
        return out
    }

    private func preview(_ d: Data) {
        // motion: luma of 2000 points compared with the previous preview
        var sample = [UInt8](repeating: 0, count: 2000)
        d.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            let n = b.count / 2
            for i in 0..<2000 { sample[i] = b[(i * (n / 2000)) * 2 + 1] }
        }
        if lastSample.count == sample.count {
            var sum = 0; for i in 0..<sample.count { sum += abs(Int(sample[i]) - Int(lastSample[i])) }
            motion = Double(sum) / Double(sample.count)
        }
        lastSample = sample
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, Picture.W, Picture.H, kCVPixelFormatType_422YpCbCr8, nil, &pb) == kCVReturnSuccess, let buf = pb else { return }
        CVPixelBufferLockBaseAddress(buf, [])
        if let dst = CVPixelBufferGetBaseAddress(buf) {
            let ds = CVPixelBufferGetBytesPerRow(buf)
            d.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                for y in 0..<Picture.H { memcpy(dst + y * ds, b.baseAddress! + y * Picture.W * 2, Picture.W * 2) }
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        let img = CIImage(cvPixelBuffer: buf).transformed(by: CGAffineTransform(scaleX: 320.0 / Double(Picture.W), y: 320.0 / Double(Picture.W)))
        guard let cg = ci.createCGImage(img, from: img.extent) else { return }
        let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let line = "\(size) · \(String(format: "%.0f", fps)) fps"
        DispatchQueue.main.async { self.onPreview?(ns, line) }
    }

    /// "live", "static" (connected, no new frame for 2 s: a source that sends only on change, NDI review #9), "lost"
    /// (no connection) or "" (nothing chosen).
    var state: String {
        guard source != nil else { return "" }
        if Date().timeIntervalSince(lastFrameAt) <= 2 { return "live" }
        return connections > 0 ? "static" : "lost"
    }

    func status() -> [String: Any] {
        ["runtime": NDIRuntime.shared.path, "source": source?.name ?? "", "frames": frames, "repeats": repeats, "size": size,
         "format": format, "fps": (fps * 10).rounded() / 10, "motion": (motion * 100).rounded() / 100,
         "connections": connections, "state": state, "ndi_sound_db": (ndiSoundDB * 10).rounded() / 10,
         "age_s": lastFrameAt == .distantPast ? -1 : (Date().timeIntervalSince(lastFrameAt) * 10).rounded() / 10]
    }
}

// ---------------------------------------------------------------- the master to the VM ladder
final class Streamer {
    static let defaultTo = "rtmp://100.102.86.30:1935/studio/master"   // chromium-vm's Tailscale address (studio-ladder)
    static let site = "https://santoshi-band.pages.dev"
    static let tokenFile = NSHomeDirectory() + "/.config/studio/camera-token"

    private(set) var running = false
    private(set) var framesOut = 0
    private(set) var speed = ""
    private(set) var kbps = ""
    private(set) var restarts = 0
    private(set) var startedAt: Date?
    private(set) var problem: String?
    private(set) var siteLive = false
    private var wentGo = false
    var onChange: (() -> Void)?
    private var proc: Process?
    private var stopping = false

    static func ffmpegPath() -> String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// device = the CoreAudio/AVFoundation name of the input, pair 0 = channels 1-2.
    func start(picture: Picture, device: String, pair: Int, to: String, kbps vk: Int = 5000, goLive: Bool, seconds: Double = 0) {
        guard !running else { return }
        guard let ff = Streamer.ffmpegPath() else { problem = "ffmpeg is missing (brew install ffmpeg)"; onChange?(); return }
        running = true; stopping = false; restarts = 0; framesOut = 0; problem = nil; startedAt = Date(); siteLive = false; wentGo = false
        signal(SIGPIPE, SIG_IGN)
        Log.line("STREAM to \(to): picture \(picture.source?.name ?? "none"), sound \(device) pair \(pair + 1), \(vk) kbit/s + AAC 160")
        picture.externalClock = true
        let t = Thread { [weak self] in
            guard let self = self else { return }
            defer { picture.externalClock = false }
            let end = seconds > 0 ? Date().addingTimeInterval(seconds) : Date.distantFuture
            let black: Data = { var d = Data(count: Picture.W * Picture.H * 2)
                d.withUnsafeMutableBytes { b in let p = b.bindMemory(to: UInt8.self); for i in stride(from: 0, to: p.count, by: 4) { p[i] = 128; p[i+1] = 16; p[i+2] = 128; p[i+3] = 16 } }
                return d }()
            while !self.stopping && Date() < end {
                let l = pair * 2, r = pair * 2 + 1
                let args = ["-hide_banner", "-loglevel", "warning", "-stats_period", "2", "-progress", "pipe:2", "-nostdin",
                            "-thread_queue_size", "256", "-f", "rawvideo", "-pix_fmt", "uyvy422", "-s", "\(Picture.W)x\(Picture.H)",
                            "-framerate", "\(Picture.FPS)", "-i", "pipe:0",
                            "-thread_queue_size", "1024", "-f", "avfoundation", "-i", ":" + device,
                            "-filter_complex", "[0:v]format=nv12[v];[1:a]pan=stereo|c0=c\(l)|c1=c\(r),aresample=48000:async=1000:first_pts=0[a]",
                            "-map", "[v]", "-map", "[a]",
                            "-c:v", "h264_videotoolbox", "-realtime", "1", "-profile:v", "high", "-b:v", "\(vk)k",
                            "-maxrate", "\(vk * 6 / 5)k", "-bufsize", "\(vk * 2)k", "-g", "\(Picture.FPS * 2)",
                            "-force_key_frames", "expr:gte(t,n_forced*2)",
                            "-c:a", "aac_at", "-aac_at_mode", "cbr", "-b:a", "160k", "-ar", "48000", "-ac", "2",
                            "-f", "flv", to]
                let p = Process(); p.executableURL = URL(fileURLWithPath: ff); p.arguments = args
                let inp = Pipe(), err = Pipe(); p.standardInput = inp; p.standardError = err; p.standardOutput = FileHandle.nullDevice
                do { try p.run() } catch { self.problem = "ffmpeg did not start: \(error.localizedDescription)"; break }
                self.proc = p
                let fd = inp.fileHandleForWriting.fileDescriptor
                err.fileHandleForReading.readabilityHandler = { [weak self] h in
                    let d = h.availableData; guard !d.isEmpty, let self = self else { return }
                    for line in String(decoding: d, as: UTF8.self).split(separator: "\n") {
                        if line.hasPrefix("speed=") { self.speed = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
                        else if line.hasPrefix("bitrate=") { self.kbps = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
                        else if !line.contains("=") { Log.line("ffmpeg: \(line)") }
                    }
                }
                let t0 = Date(); var n = 0
                while p.isRunning && !self.stopping && Date() < end {
                    let due = t0.addingTimeInterval(Double(n) / Double(Picture.FPS))
                    let wait = due.timeIntervalSinceNow
                    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                    else if wait < -1 { n = Int(-t0.timeIntervalSinceNow * Double(Picture.FPS)) }
                    let fr = picture.pull() ?? black          // the frame sync, at this clock
                    let ok = fr.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> Bool in
                        var off = 0
                        while off < b.count {
                            let w = write(fd, b.baseAddress! + off, b.count - off)
                            if w <= 0 { return false }
                            off += w
                        }
                        return true
                    }
                    if !ok { break }
                    n += 1; self.framesOut += 1
                    if goLive && !self.wentGo && n == Picture.FPS * 8 { self.wentGo = true; DispatchQueue.global().async { self.site("go") } }
                    if n % (Picture.FPS * 2) == 0 { DispatchQueue.main.async { self.onChange?() } }
                }
                try? inp.fileHandleForWriting.close()
                let dl = Date().addingTimeInterval(5); while p.isRunning && Date() < dl { Thread.sleep(forTimeInterval: 0.1) }
                if p.isRunning { p.terminate() }
                err.fileHandleForReading.readabilityHandler = nil
                if self.stopping || Date() >= end { break }
                self.restarts += 1
                Log.line("STREAM: the master stopped (network?), again in 2 s (restart \(self.restarts))")
                Thread.sleep(forTimeInterval: 2)
            }
            if self.siteLive { self.site("stop") }
            self.running = false; self.proc = nil
            Log.line("STREAM stopped after \(self.framesOut) frames, \(self.restarts) restarts")
            DispatchQueue.main.async { self.onChange?() }
        }
        t.name = "stream"; t.start()
        onChange?()
    }

    func stop() { stopping = true; proc?.terminate() }

    /// GO / STOP on the band site as the paired camera "MacBook Pro", via "studio" (the viewers get the ladder and the gear).
    private func site(_ action: String) {
        guard let tok = try? String(contentsOfFile: Streamer.tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !tok.isEmpty else {
            Log.line("SITE: no camera token in \(Streamer.tokenFile) (pair \"MacBook Pro\" at /admin)"); return
        }
        var rq = URLRequest(url: URL(string: Streamer.site + "/api/live")!)
        rq.httpMethod = "POST"; rq.timeoutInterval = 10
        rq.setValue("application/json", forHTTPHeaderField: "content-type")
        rq.setValue("Bearer " + tok, forHTTPHeaderField: "authorization")
        rq.httpBody = try? JSONSerialization.data(withJSONObject: ["action": action, "via": "studio"])
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: rq) { d, _, e in
            let j = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            Log.line("SITE \(action): live=\(j["live"] ?? "?") via=\(j["via"] ?? "?") \(e?.localizedDescription ?? "")")
            if action == "go" { self.siteLive = (j["live"] as? Bool) == true }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 12)
    }

    func status() -> [String: Any] {
        ["running": running, "frames_out": framesOut, "speed": speed, "kbps": kbps, "restarts": restarts,
         "site_live": siteLive, "problem": problem ?? "",
         "seconds": startedAt.map { running ? (Date().timeIntervalSince($0) * 10).rounded() / 10 : 0 } ?? 0]
    }
}

// ---------------------------------------------------------------- the state behind 2 PICTURE and 4 STREAM
final class Studio: ObservableObject {
    static let shared = Studio()
    let picture = Picture()
    let streamer = Streamer()
    @Published var sources: [NDISource] = []
    @Published var chosen: String?                  // the NDI source's name
    @Published var preview: NSImage?
    @Published var previewLine = ""
    @Published var streaming = false
    @Published var streamLine = ""
    private var remember = true

    func begin() {
        let d = UserDefaults.standard
        chosen = d.string(forKey: "ndiSource")
        picture.extraIPs = d.string(forKey: "ndiExtraIPs") ?? ""
        picture.onSources = { [weak self] list in
            guard let self = self else { return }
            self.sources = list
            if self.picture.source == nil {
                // the remembered source, else the only Manual Camera (MANUAL / MANTRA / PIXEL in its name)
                let want = self.chosen.flatMap { c in list.first { $0.name == c } }
                    ?? { let cams = list.filter { $0.name.uppercased().range(of: "MANUAL|MANTRA|PIXEL", options: .regularExpression) != nil }
                         return cams.count == 1 ? cams[0] : nil }()
                if let s = want { self.choose(s.name, remember: false) }
            }
        }
        picture.onPreview = { [weak self] img, line in self?.preview = img; self?.previewLine = line }
        streamer.onChange = { [weak self] in self?.refresh() }
        picture.startFinder()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func choose(_ name: String, remember r: Bool = true) {
        guard let s = sources.first(where: { $0.name == name }) else { return }
        chosen = name
        if r { UserDefaults.standard.set(name, forKey: "ndiSource") }
        picture.connect(s)
    }

    /// An address typed by hand (no discovery): the only case where the URL is used to connect.
    func chooseManual(name: String, url: String) {
        chosen = name.isEmpty ? url : name
        picture.connect(NDISource(name: name, url: url, manual: true))
    }

    func stream(goLive: Bool = UserDefaults.standard.bool(forKey: "streamGoLive"), seconds: Double = 0) {
        let m = Model.shared
        guard let dev = m.device else { streamLine = "choose the source (1) first"; return }
        let to = UserDefaults.standard.string(forKey: "streamTo") ?? Streamer.defaultTo
        streamer.start(picture: picture, device: dev.name, pair: m.pair, to: to, goLive: goLive, seconds: seconds)
        refresh()
    }

    func stopStream() { streamer.stop(); refresh() }

    func refresh() {
        streaming = streamer.running
        if let p = streamer.problem { streamLine = p; return }
        if streamer.running {
            let pic: String
            switch picture.state {
            case "": pic = "no picture (black)"
            case "static": pic = "picture static (the source sends on change)"
            case "lost": pic = "picture lost (no connection)"
            default: pic = "picture live"
            }
            streamLine = "streaming · \(pic) · \(streamer.kbps.isEmpty ? "starting" : streamer.kbps) · speed \(streamer.speed)" +
                (streamer.restarts > 0 ? " · \(streamer.restarts) restarts" : "") + (streamer.siteLive ? " · site LIVE" : "")
        } else {
            streamLine = picture.source == nil ? "choose the picture (2), then STREAM sends one master to Frankfurt" :
                "ready: \(picture.source!.name) + \(Model.shared.pairName) of \(Model.shared.device?.name ?? "?") to Frankfurt"
        }
    }

    func status() -> [String: Any] {
        ["sources": sources.map(\.name), "chosen": chosen ?? "", "picture": picture.status(), "stream": streamer.status(),
         "ndi_runtime": picture.available]
    }
}
