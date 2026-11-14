// Link.swift: finds Manual Camera on the Wi-Fi (Bonjour _mantrasound._udp, no IP typing) and sends it the sound.
//
// THE WIRE (the same in MANTRA_NDI app/.../LinkJitter.kt and MacLink.kt; numbers big-endian, PCM little-endian):
//   Mac → phone, every 5 ms   "MSLA" ver=1 ch=2 frames:u16 seq:u32 sampleTime:i64   then frames×2×Int16 LE (48 kHz)
//   Mac → phone, every 250 ms "MSLH" ver=1 ping:u32 macNs:i64 nameLen:u8 name(UTF-8)   hello, the Mac's name and a ping
//   Mac → phone, on STOP      "MSLB" ver=1                                             bye
//   phone → Mac, on each hello "MSLR" ver=1 state:u8 fillMs:u16 targetMs:u16 ping:u32 macNs:i64 underruns:u32
//                              lost:u32 late:u32 driftPpm:i32 packets:u32 skips:u32 nameLen:u8 name
// The phone answers every hello at once, so the round trip is measured from the echoed macNs; no answer for 1.5 s
// and the window says the camera stopped answering. The phone stops by itself 1.5 s after the last packet.
import Foundation
import Network

struct Report {
    var state = 0            // 0 waiting, 1 buffering, 2 playing
    var fillMs = 0
    var targetMs = 0
    var underruns = 0
    var lost = 0
    var late = 0
    var driftPpm = 0
    var packets = 0
    var skips = 0
    var phone = ""
    var rttMs = 0.0
}

final class Link {
    static let type = "_mantrasound._udp"
    private let q = DispatchQueue(label: "link", qos: .userInteractive)
    private var browser: NWBrowser?
    private var conn: NWConnection?
    private var endpoints: [String: NWEndpoint] = [:]
    private var hello: DispatchSourceTimer?
    private var ping: UInt32 = 0
    private var seq: UInt32 = 0
    private(set) var sampleTime: Int64 = 0
    private(set) var lastReportAt: Date?
    private(set) var report = Report()
    private(set) var sentPackets = 0
    private(set) var sendErrors = 0
    let macName = Host.current().localizedName ?? "Mac"

    /// Called on the main queue: the names of the cameras found (sorted).
    var onCameras: (([String]) -> Void)?
    /// Called on the main queue for every answer from the camera.
    var onReport: ((Report) -> Void)?

    func browse() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: Link.type, domain: nil), using: .udp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }
            var found: [String: NWEndpoint] = [:]
            for r in results {
                if case let .service(name, _, _, _) = r.endpoint, found[name] == nil { found[name] = r.endpoint }
            }
            self.endpoints = found
            let names = found.keys.sorted()
            DispatchQueue.main.async { self.onCameras?(names) }
        }
        b.stateUpdateHandler = { st in Log.line("browser: \(st)") }
        b.start(queue: q)
        browser = b
    }

    /// Opens the way to `camera` and starts the hellos. Audio follows with `send`.
    func open(_ camera: String) -> Bool {
        close(sayBye: false)
        guard let ep = q.sync(execute: { endpoints[camera] }) else { return false }
        let params = NWParameters.udp
        params.serviceClass = .interactiveVoice     // Wi-Fi WMM voice queue: the lowest delay the radio offers
        let c = NWConnection(to: ep, using: params)
        c.stateUpdateHandler = { st in Log.line("link to \(camera): \(st)") }
        c.start(queue: q)
        conn = c
        seq = 0; sampleTime = 0; sentPackets = 0; sendErrors = 0; lastReportAt = nil; report = Report()
        receive(c)
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.sendHello() }
        t.resume()
        hello = t
        return true
    }

    func close(sayBye: Bool = true) {
        hello?.cancel(); hello = nil
        if let c = conn {
            if sayBye {
                var d = Data("MSLB".utf8); d.append(1)
                for _ in 0..<3 { c.send(content: d, completion: .idempotent) }
            }
            q.asyncAfter(deadline: .now() + 0.2) { c.cancel() }
        }
        conn = nil
    }

    /// One packet of 240 frames of interleaved 16-bit stereo PCM. From the pump's thread.
    func send(pcm: Data) {
        guard let c = conn else { return }
        let frames = pcm.count / 4
        var d = Data(capacity: 20 + pcm.count)
        d.append(contentsOf: Array("MSLA".utf8))
        d.append(1); d.append(2)
        d.be(UInt16(frames)); d.be(seq); d.be(sampleTime)
        d.append(pcm)
        seq &+= 1
        sampleTime += Int64(frames)
        sentPackets += 1
        c.send(content: d, completion: .contentProcessed { [weak self] e in if e != nil { self?.sendErrors += 1 } })
    }

    private func sendHello() {
        guard let c = conn else { return }
        ping &+= 1
        var d = Data("MSLH".utf8)
        d.append(1)
        d.be(ping); d.be(Int64(Link.nowNs()))
        let name = Array(macName.utf8.prefix(60))
        d.append(UInt8(name.count)); d.append(contentsOf: name)
        c.send(content: d, completion: .idempotent)
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, err in
            guard let self = self, self.conn === c else { return }
            if let d = data, d.count >= 47, d.prefix(4) == Data("MSLR".utf8) { self.take(d) }
            if err == nil { self.receive(c) }
        }
    }

    private func take(_ d: Data) {
        var r = Report()
        var at = 5
        r.state = Int(d[d.startIndex + at]); at += 1
        r.fillMs = Int(d.u16(at)); at += 2
        r.targetMs = Int(d.u16(at)); at += 2
        at += 4                                     // the ping's number
        let echoed = d.i64(at); at += 8
        r.underruns = Int(d.u32(at)); at += 4
        r.lost = Int(d.u32(at)); at += 4
        r.late = Int(d.u32(at)); at += 4
        r.driftPpm = Int(Int32(bitPattern: d.u32(at))); at += 4
        r.packets = Int(d.u32(at)); at += 4
        r.skips = Int(d.u32(at)); at += 4
        let n = Int(d[d.startIndex + at]); at += 1
        if at + n <= d.count { r.phone = String(decoding: d[d.startIndex + at ..< d.startIndex + at + n], as: UTF8.self) }
        r.rttMs = Double(Int64(Link.nowNs()) - echoed) / 1e6
        report = r
        lastReportAt = Date()
        DispatchQueue.main.async { self.onReport?(r) }
    }

    static func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}

extension Data {
    mutating func be(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xff)) }
    mutating func be(_ v: UInt32) { for s in stride(from: 24, through: 0, by: -8) { append(UInt8((v >> UInt32(s)) & 0xff)) } }
    mutating func be(_ v: Int64) { let u = UInt64(bitPattern: v); for s in stride(from: 56, through: 0, by: -8) { append(UInt8((u >> UInt64(s)) & 0xff)) } }
    func u16(_ i: Int) -> UInt16 { let b = startIndex + i; return UInt16(self[b]) << 8 | UInt16(self[b + 1]) }
    func u32(_ i: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(self[startIndex + i + $1]) } }
    func i64(_ i: Int) -> Int64 { Int64(bitPattern: (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(self[startIndex + i + $1]) }) }
}

/// ~/Library/Logs/Sound Link (Mantra).log: what happened and, every 5 s while sending, the link's numbers.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Sound Link (Mantra).log")
    private static let q = DispatchQueue(label: "log")
    private static let f: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()
    static func line(_ s: String) {
        let t = f.string(from: Date())
        q.async {
            let l = Data("\(t) \(s)\n".utf8)
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(l); try? h.close() }
            else { try? l.write(to: url) }
        }
    }
}
