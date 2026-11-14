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
    @Published var cameras: [String] = []
    @Published var camera: String?
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
            self.cameras = names
            if self.camera == nil || !(names.contains(self.camera!)) {
                if names.count == 1 { self.camera = names[0] }       // one camera: chosen by itself
                else if !self.sending { self.camera = names.contains(self.camera ?? "") ? self.camera : nil }
            }
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

    func send() {
        guard !sending else { return }
        guard let cam = camera ?? (cameras.count == 1 ? cameras[0] : nil) else { return }
        if !capture.running { openSource() }
        guard capture.running else { return }
        guard link.open(cam) else { return }
        camera = cam
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
        let pump = Pump(capture)
        pumping = true
        let link = self.link
        let t = Thread { [weak self] in
            while self?.pumping == true {
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

    private func tick() {
        ticks += 1
        if ticks % 60 == 0 { checkPermissions() }
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
                Log.line(String(format: "sending %.1f s, %d packets, %d send errors | camera %@: %@, fill %d ms (target %d), rtt %.1f ms, latency ≈ %.0f ms, underruns %d, lost %d, late %d, skips %d, drift %d ppm",
                                sentSeconds, link.sentPackets, link.sendErrors, r.phone, answering ? "receiving" : "NOT ANSWERING",
                                r.fillMs, r.targetMs, r.rttMs, latencyMs, r.underruns, r.lost, r.late, r.skips, r.driftPpm))
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
                "cameras": cameras, "camera": camera ?? "", "sending": sending, "answering": answering,
                "sent_s": sentSeconds, "packets": link.sentPackets, "send_errors": link.sendErrors,
                "phone": r.phone, "phone_state": ["waiting", "buffering", "playing"][min(2, max(0, r.state))],
                "fill_ms": r.fillMs, "target_ms": r.targetMs, "rtt_ms": r.rttMs, "latency_ms": latencyMs,
                "underruns": r.underruns, "lost": r.lost, "late": r.late, "skips": r.skips, "drift_ppm": r.driftPpm,
                "permissions_missing": Permissions.missing]
    }

    func db(_ x: Float) -> Double { x > 0 ? max(-120, 20 * log10(Double(x))) : -120 }
}
