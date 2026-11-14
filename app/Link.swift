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
    var id = ""
    var rttMs = 0.0
}

/// One way to one phone: over the Wi-Fi (Bonjour) or over Tailscale (probed on port 47474). `id` is the phone's
/// own (ANDROID_ID from v210, else its model), so the same phone found both ways is one camera, the Wi-Fi first.
struct Cam: Equatable {
    let name: String
    let id: String
    let lan: Bool
    let endpoint: NWEndpoint
    static func model(_ s: String) -> String {
        var m = s
        for p in ["Manual Camera (", "Manual Camera · "] where m.hasPrefix(p) { m = String(m.dropFirst(p.count)) }
        if m.hasSuffix(")") { m.removeLast() }
        return m
    }
}

final class Link {
    static let type = "_mantrasound._udp"
    private let q = DispatchQueue(label: "link", qos: .userInteractive)
    private var browser: NWBrowser?
    private var conn: NWConnection?
    private var lanCams: [String: Cam] = [:]
    private var tsCams: [String: (cam: Cam, seen: Date)] = [:]
    let probe = TailscaleProbe()
    static let port: UInt16 = 47474
    private var hello: DispatchSourceTimer?
    private var ping: UInt32 = 0
    private var seq: UInt32 = 0
    private(set) var sampleTime: Int64 = 0
    private(set) var lastReportAt: Date?
    private(set) var report = Report()
    private(set) var sentPackets = 0
    private(set) var sendErrors = 0
    let macName = Host.current().localizedName ?? "Mac"

    /// Called on the main queue: every way to every camera, the Wi-Fi ones first.
    var onCameras: (([Cam]) -> Void)?

    /// The cameras as the window lists them: Wi-Fi first; a Tailscale way only for a phone not found on the Wi-Fi.
    func all() -> [Cam] {
        let lan = lanCams.values.sorted { $0.name < $1.name }
        let ids = Set(lan.map(\.id))
        let ts = tsCams.values.filter { Date().timeIntervalSince($0.seen) < 10 }.map(\.cam)
            .filter { !ids.contains($0.id) }.sorted { $0.name < $1.name }
        return lan + ts
    }
    /// Every way, the twins included (for falling back to Tailscale when the Wi-Fi way goes).
    func ways(for id: String) -> [Cam] {
        let lan = lanCams.values.filter { $0.id == id }
        let ts = tsCams.values.filter { $0.cam.id == id && Date().timeIntervalSince($0.seen) < 10 }.map(\.cam)
        return lan + ts
    }
    private func publish() { let c = all(); DispatchQueue.main.async { self.onCameras?(c) } }
    /// Called on the main queue for every answer from the camera.
    var onReport: ((Report) -> Void)?

    func browse() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Link.type, domain: nil), using: .udp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }
            var found: [String: Cam] = [:]
            for r in results {
                guard case let .service(name, _, _, _) = r.endpoint, found[name] == nil else { continue }
                var id = Cam.model(name)
                if case let .bonjour(txt) = r.metadata, let v = txt["id"], !v.isEmpty { id = v }
                found[name] = Cam(name: name, id: id, lan: true, endpoint: r.endpoint)
            }
            self.lanCams = found
            Log.line("Wi-Fi cameras: \(found.keys.sorted())")
            self.publish()
        }
        b.stateUpdateHandler = { st in Log.line("browser: \(st)") }
        b.start(queue: q)
        browser = b
        probe.onFound = { [weak self] ip, host, phone, id, rtt in
            guard let self = self else { return }
            self.q.async {
                let key = id.isEmpty ? Cam.model(phone) : id
                let cam = Cam(name: "\(host) · Tailscale", id: key, lan: false,
                              endpoint: .hostPort(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: Link.port)!))
                let isNew = self.tsCams[ip] == nil
                self.tsCams[ip] = (cam, Date())
                if isNew { Log.line(String(format: "Tailscale camera: %@ at %@ (probe rtt %.0f ms)", cam.name, ip, rtt)); self.publish() }
            }
        }
        probe.start()
        // a Tailscale way that stops answering leaves the list
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 5, repeating: .seconds(5))
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            let before = self.tsCams.count
            self.tsCams = self.tsCams.filter { Date().timeIntervalSince($0.value.seen) < 10 }
            if self.tsCams.count != before { self.publish() }
        }
        t.resume()
        expiry = t
    }
    private var expiry: DispatchSourceTimer?
    /// The way being used now.
    private(set) var current: Cam?

    /// Opens the way to `camera` and starts the hellos. Audio follows with `send`.
    func open(_ cam: Cam) -> Bool {
        close(sayBye: false)
        let ep = cam.endpoint
        let camera = cam.name
        current = cam
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
        at += n
        if at < d.count {                            // v210 phones: their id after the name
            let m = Int(d[d.startIndex + at]); at += 1
            if at + m <= d.count { r.id = String(decoding: d[d.startIndex + at ..< d.startIndex + at + m], as: UTF8.self) }
        }
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

/// Finds Manual Camera over Tailscale, where Bonjour does not reach: every 3 s a hello to each online peer on port
/// 47474 (`tailscale status --json`, read every 15 s); a peer that answers with "MSLR" is a camera.
final class TailscaleProbe {
    /// (ip, Tailscale host name, the phone's name, its id, round trip in ms), from the probe's thread.
    var onFound: ((String, String, String, String, Double) -> Void)?
    private var peers: [(ip: String, host: String)] = []
    private var fd: Int32 = -1
    static let cli = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    func start() {
        guard fd < 0, TailscaleProbe.cli != nil else { Log.line("tailscale: no CLI, Tailscale ways are not looked for"); return }
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let t = Thread { [weak self] in self?.loop() }
        t.name = "tailscale-probe"; t.start()
    }

    private func readPeers() {
        guard let cli = TailscaleProbe.cli else { return }
        let p = Process(); p.executableURL = URL(fileURLWithPath: cli); p.arguments = ["status", "--json"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let peer = j["Peer"] as? [String: [String: Any]] else { return }
        peers = peer.values.compactMap { v in
            guard (v["Online"] as? Bool) == true, let ips = v["TailscaleIPs"] as? [String],
                  let ip = ips.first(where: { !$0.contains(":") }) else { return nil }
            return (ip, v["HostName"] as? String ?? ip)
        }
    }

    private func loop() {
        var lastPeers = Date.distantPast, lastSend = Date.distantPast
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            if Date().timeIntervalSince(lastPeers) > 15 { readPeers(); lastPeers = Date() }
            if Date().timeIntervalSince(lastSend) > 3 {
                lastSend = Date()
                var d = Data("MSLH".utf8); d.append(1); d.be(UInt32(0)); d.be(Int64(Link.nowNs()))
                let name = Array("probe".utf8); d.append(UInt8(name.count)); d.append(contentsOf: name)
                for p in peers {
                    var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = Link.port.bigEndian
                    inet_pton(AF_INET, p.ip, &a.sin_addr)
                    d.withUnsafeBytes { raw in
                        withUnsafePointer(to: &a) { ap in
                            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                _ = sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                }
            }
            var from = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { fp in
                fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in buf.withUnsafeMutableBytes { recvfrom(fd, $0.baseAddress, $0.count, 0, sa, &len) } }
            }
            guard n >= 47, buf[0] == 0x4D, buf[1] == 0x53, buf[2] == 0x4C, buf[3] == 0x52 else { continue }
            let d = Data(buf[0..<n])
            var ipb = [CChar](repeating: 0, count: 64)
            inet_ntop(AF_INET, &from.sin_addr, &ipb, 64)
            let ip = String(cString: ipb)
            let echoed = d.i64(14)
            let rtt = Double(Int64(Link.nowNs()) - echoed) / 1e6
            let nl = Int(d[46]); var phone = "", id = ""
            if 47 + nl <= n { phone = String(decoding: d[47..<(47 + nl)], as: UTF8.self) }
            if 47 + nl < n { let m = Int(d[47 + nl]); if 48 + nl + m <= n { id = String(decoding: d[(48 + nl)..<(48 + nl + m)], as: UTF8.self) } }
            let host = peers.first { $0.ip == ip }?.host ?? ip
            onFound?(ip, host, phone, id, rtt)
        }
    }
}
