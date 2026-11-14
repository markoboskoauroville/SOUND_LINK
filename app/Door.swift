// THE DOOR: the Star API functions of Sound Link (Mantra), JSON over HTTP on 127.0.0.1:8974 (swift-apps.md, 10.11.2026).
//   POST /fn/status        {}                                    devices? no: the state, the camera's numbers
//   POST /fn/devices       {}                                    the inputs with their channels
//   POST /fn/source        {device: "<part of the name>", pair: 1}   pair 1 = channels 1-2, 2 = 3-4 ... (not remembered)
//   POST /fn/send          {camera?: "<part of the name>"}       3 SEND
//   POST /fn/stop          {}                                    STOP
//   POST /fn/permissions   {}
// Registered in ~/.config/star-fns/sound-link.json, so `star fn "sound link" status` reaches it.
import Foundation
import Network

final class Door {
    static let shared = Door()
    static let port: UInt16 = 8974
    private var listener: NWListener?
    private let q = DispatchQueue(label: "door")

    func start() {
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Door.port)!)
        guard listener == nil, let l = try? NWListener(using: p) else { return }
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        l.stateUpdateHandler = { st in Log.line("door: \(st)") }
        l.start(queue: q)
        listener = l
        let dir = NSHomeDirectory() + "/.config/star-fns"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let reg: [String: Any] = ["app": APP_NAME, "port": Int(Door.port), "functions": [
            "status": "{} the source, the camera, sending?, latency, buffer, dropouts, lost, drift",
            "devices": "{} the Mac's inputs and their channels",
            "source": "{device, pair} choose an input by part of its name and a pair (1 = 1-2); not remembered",
            "send": "{camera?, path?} send to the camera (the only one, or the one whose name contains the word); path wifi|tailscale forces one way",
            "stop": "{} stop sending", "permissions": "{} missing permissions"]]
        if let d = try? JSONSerialization.data(withJSONObject: reg, options: [.prettyPrinted]) {
            try? d.write(to: URL(fileURLWithPath: dir + "/sound-link.json"))
        }
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: q)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ acc: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self = self else { c.cancel(); return }
            var buf = acc; if let d = data { buf.append(d) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<r.lowerBound], as: UTF8.self)
                let len = head.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") })
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if buf.count - r.upperBound >= len || done || err != nil { self.answer(c, head, Data(buf[r.upperBound...])); return }
            } else if done || err != nil || buf.count > 1_000_000 { c.cancel(); return }
            self.read(c, buf)
        }
    }

    private func answer(_ c: NWConnection, _ head: String, _ body: Data) {
        let first = head.components(separatedBy: "\r\n").first ?? ""
        let path = first.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let args = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let fn = path.hasPrefix("/fn/") ? String(path.dropFirst(4)) : String(path.dropFirst())
        let out = DispatchQueue.main.sync { self.call(fn, args) }
        let json = (try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        let h = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n"
        var d = Data(h.utf8); d.append(json)
        c.send(content: d, completion: .contentProcessed { _ in c.cancel() })
    }

    private func call(_ fn: String, _ a: [String: Any]) -> [String: Any] {
        let m = Model.shared
        switch fn {
        case "", "status": return m.status()
        case "devices":
            return ["ok": true, "devices": m.devices.map { d -> [String: Any] in ["name": d.name, "channels": d.channels, "rate": d.rate, "pairs": d.pairs] }]
        case "source":
            let want = (a["device"] as? String ?? "").lowercased()
            guard let d = m.devices.first(where: { $0.name.lowercased().contains(want) }) else { return ["ok": false, "error": "no input named \(want)"] }
            let p = max(1, a["pair"] as? Int ?? 1) - 1
            guard p < d.pairs.count else { return ["ok": false, "error": "\(d.name) has \(d.pairs.count) pairs"] }
            m.choose(deviceUID: d.uid, pair: p, remember: false)
            return ["ok": m.sourceProblem == nil, "device": d.name, "channels": d.pairs[p], "problem": m.sourceProblem ?? ""]
        case "send":
            if let want = (a["camera"] as? String)?.lowercased(), !want.isEmpty {
                guard let cam = m.cameras.first(where: { $0.lowercased().contains(want) }) else { return ["ok": false, "error": "no camera named \(want)", "cameras": m.cameras] }
                m.chooseCamera(cam, remember: false)
            }
            m.forcedPath = (a["path"] as? String)?.lowercased()     // "wifi" / "tailscale" for a measurement, else nil
            m.send()
            return ["ok": m.sending, "camera": m.camera ?? "", "path": m.path, "cameras": m.cameras]
        case "stop":
            m.stop(); return ["ok": true]
        case "permissions":
            return ["ok": true, "missing": Permissions.missing]
        default:
            return ["ok": false, "error": "unknown function \(fn)"]
        }
    }
}
