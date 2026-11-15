// Model.swift: the three steps behind the window. 1 SOURCE (a device and a pair of its channels), 2 CAMERA (the
// Manual Camera phones found on the Wi-Fi, chosen by itself when there is one), 3 SEND / STOP.
import Foundation
import AVFoundation
import CoreAudio

final class Model: ObservableObject {
    static let shared = Model()

    @Published var devices: [InputDevice] = []
    @Published var deviceUID: String = ""
    @Published var pair: Int = 0                    // 0 = channels 1-2, 1 = 3-4 ...
    @Published var levelL: Float = 0                // linear peak 0...1, for the meter
    @Published var levelR: Float = 0
    @Published var sourceProblem: String?
    @Published var cameras: [String] = []           // names as listed: Wi-Fi first, then "<host> · Tailscale"
    @Published var camera: String?
    private var cams: [Cam] = []
    /// v3: the chosen phone, by its id (the same phone over Wi-Fi and over Tailscale is one choice)
    private var cameraID: String?
    @Published var path = ""                        // "Wi-Fi" or "Tailscale" while sending
    @Published var sending = false
    @Published var report = Report()
    @Published var answering = false                // the camera answered within 1.5 s
    @Published var sentSeconds = 0.0
    /// v2: checked every 2 s here (a timer inside the view was made again at every meter frame and never fired)
    @Published var missing: [String] = Permissions.missing
    private var ticks = 0

    let capture = Capture()
    let link = Link()
    private var pumpThread: Thread?
    private var pumping = false
    private var started: Date?
    private var lastLog = Date.distantPast
    /// A test (the door) may choose without writing his settings (swift-apps.md: tests never touch his settings).
    private var remember = true
    private var openedID: AudioDeviceID = 0

    var device: InputDevice? { devices.first { $0.uid == deviceUID } }

    init() {
        let d = UserDefaults.standard
        deviceUID = d.string(forKey: "device") ?? ""
        pair = d.integer(forKey: "pair")
        camera = d.string(forKey: "camera")
    }

    func begin() {
        refreshDevices()
        Devices.watch { [weak self] in self?.refreshDevices() }
        link.onCameras = { [weak self] names in
            guard let self = self else { return }
            self.cams = names
            self.cameras = names.map(\.name)
            if let id = self.cameraID, let c = names.first(where: { $0.id == id }) { self.camera = c.name }
            else if names.count == 1 { self.camera = names[0].name; self.cameraID = names[0].id }   // one camera: chosen by itself
            else if !self.sending { self.camera = nil }
        }
        link.onReport = { [weak self] r in self?.report = r }
        link.browse()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        if Permissions.allowed("Microphone") { openSource() }
        else if !CommandLine.arguments.contains("--login") { AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async { if ok { self.openSource() } } } }
    }

    func refreshDevices() {
        devices = Devices.all()
        if device == nil {
            // remembered device gone (or first start): the system's default input
            let def = Devices.defaultInput()
            deviceUID = devices.first { $0.id == def }?.uid ?? devices.first?.uid ?? ""
            pair = 0
        }
        if let d = device, pair >= d.pairs.count { pair = 0 }
        if !capture.running || device?.id != openedID { openSource() }
    }

    func choose(deviceUID uid: String, pair p: Int, remember r: Bool = true) {
        remember = r
        deviceUID = uid; pair = p
        if r { UserDefaults.standard.set(uid, forKey: "device"); UserDefaults.standard.set(p, forKey: "pair") }
        openSource()
    }

    func chooseCamera(_ name: String, remember r: Bool = true) {
        camera = name
        cameraID = cams.first { $0.name == name }?.id
        if r { UserDefaults.standard.set(name, forKey: "camera") }
        if sending { stop(); send() }
    }

    func openSource() {
        guard let d = device else { sourceProblem = "no input device"; return }
        guard Permissions.allowed("Microphone") else { sourceProblem = "the microphone permission is missing"; return }
        let left = pair * 2, right = min(pair * 2 + 1, d.channels - 1)
        sourceProblem = capture.start(device: d.id, left: left, right: right)
        openedID = sourceProblem == nil ? d.id : 0
        if sending, sourceProblem == nil { startPump() }
    }

    // ---------------------------------------------------------------- 3 SEND / STOP

    /// A test may force one way ("wifi" / "tailscale") for a measurement; nil follows Wi-Fi first.
    var forcedPath: String?

    func send() {
        guard !sending else { return }
        guard var c = cams.first(where: { $0.name == camera }) ?? (cams.count == 1 ? cams[0] : nil) else { return }
        if let f = forcedPath, let w = link.ways(for: c.id).first(where: { $0.lan == (f == "wifi") }) { c = w }
        if !capture.running { openSource() }
        guard capture.running else { return }
        link.macSideUs = Int(Double(capture.ioFrames) / capture.rate * 1e6) + 3500
        guard link.open(c) else { return }
        camera = c.name; cameraID = c.id; path = c.lan ? "Wi-Fi" : "Tailscale"
        let cam = c.name
        sending = true
        started = Date()
        answering = false
        report = Report()
        Log.line("SEND to \(cam): \(device?.name ?? "?") channels \(pairName) at \(Int(capture.rate)) Hz")
        startPump()
    }

    func stop() {
        guard sending else { return }
        sending = false
        stopPump()
        link.close()
        Log.line("STOP after \(String(format: "%.1f", sentSeconds)) s, \(link.sentPackets) packets; camera: fill \(report.fillMs) ms, " +
                 "underruns \(report.underruns), lost \(report.lost), late \(report.late), drift \(report.driftPpm) ppm")
        answering = false
    }

    var pairName: String { device.map { $0.pairs.indices.contains(pair) ? $0.pairs[pair] : "1-2" } ?? "1-2" }

    private func startPump() {
        stopPump()
        capture.ring.clear()
        let pump = Pump(capture, frames: link.current?.lan == false ? 160 : 240)
        pumping = true
        let link = self.link
        // v7 (15.11.2026, Marko: "fix our audio streaming ... see if there are drops"): the camera heard a hole of 0.2 to
        // 0.7 s every two to four minutes while a ping to the phone stayed under 70 ms, so the network was not stopping.
        // The pump now runs under an activity that keeps App Nap and timer coalescing away from it, and says in the log
        // when it was held up for more than 60 ms, so a stop on the Mac's side is seen at once.
        let t = Thread { [weak self] in
            let token = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
                                                              reason: "Sound Link sends audio")
            defer { ProcessInfo.processInfo.endActivity(token) }
            var last = DispatchTime.now().uptimeNanoseconds
            var worst: UInt64 = 0, held = 0, since = last
            while self?.pumping == true {
                let now = DispatchTime.now().uptimeNanoseconds
                let gap = now - last
                last = now
                if gap > 60_000_000 { held += 1; worst = max(worst, gap) }
                if now - since > 10_000_000_000 {
                    if held > 0 { Log.line("pump: held up \(held) times in 10 s, the longest \(worst / 1_000_000) ms") }
                    held = 0; worst = 0; since = now
                }
                for p in pump.packets() { link.send(pcm: p) }
                usleep(2000)
            }
        }
        t.qualityOfService = .userInteractive
        t.name = "pump"
        t.start()
        pumpThread = t
    }

    private func stopPump() { pumping = false; pumpThread = nil }

    func checkPermissions() {
        let now = Permissions.missing
        if now != missing { missing = now; if now.isEmpty && !capture.running { openSource() } }
    }

    /// v3 (Marko, 14.11.2026: "Wi-Fi needs to have an advantage over Tailscale"): while sending, the Wi-Fi way is
    /// used whenever the phone is found on the Wi-Fi; Tailscale only when the Wi-Fi way is gone (or stops answering).
    private func followPath() {
        guard sending, forcedPath == nil, let id = cameraID, let cur = link.current else { return }
        let ways = link.ways(for: id)
        let silent = link.lastReportAt.map { Date().timeIntervalSince($0) > 2.5 } ?? (Date().timeIntervalSince(started ?? Date()) > 3)
        var next: Cam?
        if !cur.lan, let w = ways.first(where: { $0.lan }) { next = w }                       // Wi-Fi came back
        else if cur.lan && silent, let t = ways.first(where: { !$0.lan }) { next = t }         // Wi-Fi way gone
        guard let n = next, n != cur else { return }
        Log.line("path: \(cur.lan ? "Wi-Fi" : "Tailscale") → \(n.lan ? "Wi-Fi" : "Tailscale") (\(n.name))")
        stopPump()
        _ = link.open(n)
        camera = n.name; path = n.lan ? "Wi-Fi" : "Tailscale"
        started = Date()
        startPump()
    }

    private func tick() {
        ticks += 1
        if ticks % 60 == 0 { checkPermissions() }
        if ticks % 30 == 0 { followPath() }
        // the meter falls 20 dB a second, rises at once
        let fall: Float = 0.79
        levelL = max(capture.peakL, levelL * fall); capture.peakL = 0
        levelR = max(capture.peakR, levelR * fall); capture.peakR = 0
        if sending {
            sentSeconds = Double(link.sampleTime) / Pump.rate
            answering = link.lastReportAt.map { Date().timeIntervalSince($0) < 1.5 } ?? false
            if Date().timeIntervalSince(lastLog) >= 5 {
                lastLog = Date()
                let r = report
                Log.line(String(format: "[\(path)] sending %.1f s, %d packets, %d send errors | camera %@: %@, fill %d ms (target %d), rtt %.1f ms, latency ≈ %.0f ms, underruns %d, lost %d, recovered %d, concealed %d, late %d, skips %d, drift %d ppm",
                                sentSeconds, link.sentPackets, link.sendErrors, r.phone, answering ? "receiving" : "NOT ANSWERING",
                                r.fillMs, r.targetMs, r.rttMs, latencyMs, r.underruns, r.lost, r.recovered, r.concealed, r.late, r.skips, r.driftPpm))
            }
        }
    }

    /// Mac input buffer + half a packet + the pump's poll + one way on the air + the camera's buffer.
    var latencyMs: Double {
        Double(capture.ioFrames) / capture.rate * 1000 + 2.5 + 1 + report.rttMs / 2 + Double(report.fillMs)
    }

    func status() -> [String: Any] {
        let r = report
        return ["ok": true, "version": VERSION, "device": device?.name ?? "", "channels": pairName, "rate": capture.rate,
                "capturing": capture.running, "source_problem": sourceProblem ?? "", "level_db": [db(levelL), db(levelR)],
                "cameras": cameras, "camera": camera ?? "", "sending": sending, "answering": answering, "path": path,
                "sent_s": sentSeconds, "packets": link.sentPackets, "send_errors": link.sendErrors,
                "phone": r.phone, "phone_state": ["waiting", "buffering", "playing"][min(2, max(0, r.state))],
                "fill_ms": r.fillMs, "target_ms": r.targetMs, "rtt_ms": r.rttMs, "latency_ms": latencyMs,
                "underruns": r.underruns, "lost": r.lost, "recovered": r.recovered, "concealed": r.concealed, "late": r.late, "skips": r.skips, "drift_ppm": r.driftPpm,
                "permissions_missing": Permissions.missing]
    }

    func db(_ x: Float) -> Double { x > 0 ? max(-120, 20 * log10(Double(x))) : -120 }
}
