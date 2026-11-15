// Sound Link (Mantra): stereo sound from the Mac (two channels of any input, his XLR mixer) over the Wi-Fi into
// Manual Camera (Mantra) on the phone, so the desk's sound is in the take and in the stream.
//
// Marko, 14.11.2026: "I'm choosing the source, and I press Send. When I press Send, my camera app automatically
// switches the sound and puts the status text that it's receiving sound from the Mac."
// The window is a workflow (MANTRA_MANIFEST workflow-interface.md): 1 SOURCE, 2 CAMERA, 3 SEND.
// v8 (15.11.2026, the Studio route): 1 SOURCE · 2 PICTURE (NDI from Manual Camera) · 3 SEND (the sound to the phone, as before,
// the phone chosen inside it) · 4 STREAM (one master, picture + the mixer, to the VM's quality ladder in Frankfurt).
import SwiftUI
import AppKit
import AVFoundation

let VERSION = 10
let APP_NAME = "Sound Link (Mantra)"
let RELEASES = URL(string: "https://github.com/markoboskoauroville/SOUND_LINK/releases/latest")!

enum Ink {
    static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
    static let ground = hex(0x1C1D1F)
    static let line = hex(0x3A3A3C)
    static let well = hex(0x161617)
    static let text = hex(0xECECEC)
    static let dim = hex(0x9A9A9E)
    static let green = hex(0x33D17A)
    static let grey = hex(0x7A8087)
    static let amber = hex(0xE8A33D)
    static let red = hex(0xFF3B30)
    static let orange = hex(0xFF9F0A)
}

// ---------------------------------------------------------------- permissions (swift-apps.md)
enum Permissions {
    static let needed = ["Microphone"]
    static func allowed(_ p: String) -> Bool {
        switch p {
        case "Microphone": return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        default: return true
        }
    }
    static var missing: [String] { needed.filter { !allowed($0) } }
    static func open(_ p: String) {
        Model.shared.checkPermissions()             // the click checks again (swift-apps.md, 1.11.2026)
        if allowed(p) { return }
        if p == "Microphone" && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { if ok { Model.shared.openSource() } } }
            return
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_" + p)!)
    }
}

extension View {
    func axButton(_ label: String, id: String, value: String? = nil, _ action: @escaping () -> Void) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
            .accessibilityValue(value ?? "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }
}

/// A word that can be pressed: orange under the mouse, red while pressed (swift-apps.md, 1.11.2026).
struct Word: View {
    let text: String
    var on = false
    var enabled = true
    let id: String
    let action: () -> Void
    @State private var hot = false
    @State private var down = false
    var body: some View {
        Text(text)
            .foregroundStyle(!enabled ? Ink.grey.opacity(0.5) : down ? Ink.red : hot ? Ink.orange : on ? Ink.green : Ink.grey)
            .underline(on)
            .contentShape(Rectangle())
            .onHover { h in hot = h && enabled; if enabled { if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } } }
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in down = enabled }.onEnded { _ in down = false })
            .onTapGesture { if enabled { action() } }
            .axButton(text, id: id, value: on ? "chosen" : "") { if enabled { action() } }
    }
}

// ---------------------------------------------------------------- the window
struct Root: View {
    @ObservedObject var m: Model
    let margin: CGFloat = 16

    var body: some View {
        GeometryReader { g in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    TopRow(missing: m.missing)
                    Hair()
                    SourceStep(m: m)
                    Hair()
                    PictureStep(s: Studio.shared)
                    Hair()
                    SendStep(m: m)
                    if m.sending { Hair(); Numbers(m: m) }
                    Hair()
                    StreamStep(s: Studio.shared, m: m)
                    Hair()
                    Text("© 2026 Mantra Productions").font(.system(size: 10)).foregroundStyle(Ink.dim)
                        .frame(maxWidth: .infinity).padding(.top, 10)
                }
                .frame(width: max(0, g.size.width - 2 * margin), alignment: .leading)
                .padding(.horizontal, margin).padding(.bottom, margin)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Ink.ground)
        .frame(minWidth: 520, idealWidth: 640, maxWidth: .infinity, minHeight: 440, idealHeight: 640, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }
}

struct Hair: View {
    var body: some View { Rectangle().fill(Ink.line).frame(height: 1).padding(.vertical, 2) }
}

/// ON OFF · the name · TOP · PERMISSIONS (while missing) · v1 · ✕ (swift-apps.md, the first row of every app)
struct TopRow: View {
    let missing: [String]
    @AppStorage("onTop") private var onTop = false
    var body: some View {
        ZStack {
            (Text("Sound Link").fontWeight(.bold) + Text(" (Mantra)").fontWeight(.regular))
                .font(.system(size: 15)).foregroundStyle(Ink.text)
            HStack(spacing: 10) {
                Spacer().frame(width: 64)
                Text("ON").foregroundStyle(Ink.green)
                Text("OFF").foregroundStyle(Ink.grey)
                    .contentShape(Rectangle()).onTapGesture { Model.shared.stop(); NSApp.terminate(nil) }
                    .axButton("Off", id: "off") { DispatchQueue.main.async { Model.shared.stop(); NSApp.terminate(nil) } }
                Spacer()
                Text("TOP").foregroundStyle(onTop ? Ink.green : Ink.grey)
                    .contentShape(Rectangle()).onTapGesture { onTop.toggle(); TopRow.float(onTop) }
                    .axButton("Top", id: "top", value: onTop ? "on" : "off") { onTop.toggle(); TopRow.float(onTop) }
                ForEach(missing, id: \.self) { p in
                    Text("PERMISSIONS").foregroundStyle(Ink.amber)
                        .contentShape(Rectangle()).onTapGesture { Permissions.open(p) }
                        .axButton("Permissions " + p, id: "permissions") { Permissions.open(p) }
                        .help("\(p) is not allowed yet: a click opens its page in System Settings")
                }
                Text("v\(VERSION)").foregroundStyle(Ink.grey)
                    .contentShape(Rectangle()).onTapGesture { NSWorkspace.shared.open(RELEASES) }
                    .axButton("Version \(VERSION)", id: "version") { NSWorkspace.shared.open(RELEASES) }
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.grey)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
                    .onTapGesture { NSApp.keyWindow?.performClose(nil) }
                    .axButton("Close window", id: "close") { (NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible })?.performClose(nil) }
            }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
        }
        .frame(height: 32)
        .onAppear { DispatchQueue.main.async { TopRow.float(onTop) } }
    }
    static func float(_ on: Bool) {
        for w in NSApp.windows where w.title.hasPrefix(APP_NAME) || w.contentView is NSHostingView<Root> { w.level = on ? .floating : .normal }
    }
}

/// The round number is the button (workflow-interface.md): it lights and grows under the mouse.
struct Step<Content: View>: View {
    let n: Int
    let word: String
    var enabled = true
    var lit = false
    var id: String
    var action: (() -> Void)? = nil
    @ViewBuilder var content: Content
    @State private var hot = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            let pressable = action != nil && enabled
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(lit ? Ink.green : (pressable && hot ? Ink.orange : Ink.grey), lineWidth: 1.5)
                        .background(Circle().fill(lit ? Ink.green.opacity(0.25) : (pressable && hot ? Ink.orange.opacity(0.18) : .clear)))
                    Text("\(n)").font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(lit ? Ink.green : enabled ? Ink.text : Ink.grey)
                }
                .frame(width: 26, height: 26).scaleEffect(pressable && hot ? 1.12 : 1)
                Text(word).font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(lit ? Ink.green : enabled ? Ink.text : Ink.grey).underline(pressable && hot)
            }
            .frame(width: 112, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { h in hot = h; if pressable { if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } } }
            .onTapGesture { if pressable { action?() } }
            .axButton(word.capitalized, id: id) { if pressable { action?() } }
            VStack(alignment: .leading, spacing: 8) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
        .padding(.vertical, 10)
        .animation(.easeOut(duration: 0.12), value: hot)
    }
}

/// Choices on one line parted by pipes, wrapping when the window is narrow.
struct Pipes: View {
    let items: [String]
    let chosen: Int?
    let idPrefix: String
    let pick: (Int) -> Void
    var body: some View {
        Flow(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 6) {
                    if i > 0 { Text("|").foregroundStyle(Ink.line) }
                    Word(text: s, on: chosen == i, id: "\(idPrefix)-\(i + 1)") { pick(i) }
                }
            }
        }
        .font(.system(size: 13, weight: .bold, design: .monospaced))
    }
}

struct Flow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 10_000
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > w { y += row + 4; x = 0; row = 0 }
            x += s.width + spacing; row = max(row, s.height); widest = max(widest, x)
        }
        return CGSize(width: min(w, widest), height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > b.minX && x + s.width > b.maxX { y += row + 4; x = b.minX; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

/// One meter: two bars with a small gap for stereo, no line between them, no L R (vu-meter-mono-stereo.md).
struct StereoMeter: View {
    let l: Float
    let r: Float
    var body: some View {
        GeometryReader { g in
            VStack(spacing: 2) {
                bar(l, g.size.width)
                bar(r, g.size.width)
            }
        }
        .frame(height: 8)
    }
    func bar(_ v: Float, _ w: CGFloat) -> some View {
        let db = v > 0 ? 20 * log10(Double(v)) : -120
        let x = CGFloat(max(0, min(1, (db + 60) / 60)))
        let colour = db > -1 ? Ink.red : db > -12 ? Ink.amber : Ink.green
        return ZStack(alignment: .leading) {
            Rectangle().fill(Ink.well)
            Rectangle().fill(colour).frame(width: w * x)
        }
        .frame(height: 3)
    }
}

struct SourceStep: View {
    @ObservedObject var m: Model
    var body: some View {
        Step(n: 1, word: "SOURCE", lit: m.capture.running, id: "source") {
            HStack(spacing: 10) {
                Menu {
                    ForEach(m.devices) { d in
                        Button("\(d.name)  ·  \(d.channels) ch") { m.choose(deviceUID: d.uid, pair: 0) }
                    }
                } label: {
                    Text(m.device.map { "\($0.name) · \($0.channels) ch" } ?? "choose an input")
                        .font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Ink.text)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityIdentifier("device")
                StereoMeter(l: m.levelL, r: m.levelR).frame(minWidth: 80)
            }
            if let d = m.device, d.pairs.count > 1 {
                Pipes(items: d.pairs, chosen: m.pair, idPrefix: "pair") { i in m.choose(deviceUID: d.uid, pair: i) }
            }
            if let p = m.sourceProblem {
                Text(p).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct CameraStep: View {
    @ObservedObject var m: Model
    var body: some View {
        Step(n: 2, word: "CAMERA", lit: m.answering, id: "camera") {
            if m.cameras.isEmpty {
                Text("looking for Manual Camera on the Wi-Fi … open it on the phone")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Pipes(items: m.cameras, chosen: m.camera.flatMap { m.cameras.firstIndex(of: $0) }, idPrefix: "cam") { i in
                    m.chooseCamera(m.cameras[i])
                }
            }
        }
    }
}

struct SendStep: View {
    @ObservedObject var m: Model
    var body: some View {
        let can = m.sending || (m.capture.running && (m.camera != nil || m.cameras.count == 1))
        Step(n: 3, word: m.sending ? "STOP" : "SEND", enabled: can, lit: m.sending, id: "send",
             action: { m.sending ? m.stop() : m.send() }) {
            if m.cameras.isEmpty {
                Text("the sound to Manual Camera: looking for it on the Wi-Fi …")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Pipes(items: m.cameras, chosen: m.camera.flatMap { m.cameras.firstIndex(of: $0) }, idPrefix: "cam") { i in
                    m.chooseCamera(m.cameras[i])
                }
            }
            Text(line).font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(m.sending ? (m.answering ? Ink.green : Ink.amber) : Ink.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    var line: String {
        if !m.sending { return m.capture.running ? (m.camera == nil && m.cameras.count != 1 ? "choose the camera" : "ready: \(m.pairName) of \(m.device?.name ?? "") to \(m.camera ?? m.cameras.first ?? "")") : "choose the source" }
        if !m.answering { return "sending · the camera is not answering yet" }
        let phase = m.report.state == 2 ? "camera receiving" : "camera buffering"
        return "sending · \(phase) · \(m.report.phone) · \(m.path)"
    }
}

/// While it sends: one table of labelled cells (workflow-interface.md §3).
struct Numbers: View {
    @ObservedObject var m: Model
    var body: some View {
        let r = m.report
        HStack(spacing: 0) {
            cell("LATENCY", m.answering ? String(format: "%.0f ms", m.latencyMs) : "–")
            cell("BUFFER", "\(r.fillMs) / \(r.targetMs) ms")
            cell("DROPOUTS", "\(r.underruns)", r.underruns > 0 ? Ink.amber : Ink.text)
            cell("LOST", "\(r.lost) / \(r.recovered) back", r.lost > r.recovered ? Ink.amber : Ink.text)
            cell("DRIFT", "\(r.driftPpm) ppm")
            cell("SENT", clock(m.sentSeconds))
        }
        .padding(.vertical, 8)
    }
    func cell(_ label: String, _ value: String, _ c: Color = Ink.text) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Ink.dim)
            Text(value).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(c)
            Rectangle().fill(Ink.line).frame(height: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
    }
    func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

/// 2 PICTURE: the NDI sources on the Wi-Fi (Manual Camera sends NDI HX), the chosen one small and moving.
struct PictureStep: View {
    @ObservedObject var s: Studio
    var body: some View {
        Step(n: 2, word: "PICTURE", lit: s.preview != nil, id: "picture") {
            if !s.picture.available {
                Text("the NDI runtime is missing: install NDI Tools (ndi.video/tools), then open Sound Link again")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
            } else if s.sources.isEmpty {
                Text("looking for NDI on the Wi-Fi … in Manual Camera switch NDI on")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Pipes(items: s.sources.map(\.name), chosen: s.chosen.flatMap { c in s.sources.firstIndex { $0.name == c } }, idPrefix: "ndi") { i in
                    s.choose(s.sources[i].name)
                }
            }
            if let img = s.preview {
                HStack(alignment: .bottom, spacing: 10) {
                    Image(nsImage: img).resizable().aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .frame(maxWidth: 240).overlay(Rectangle().stroke(Ink.line, lineWidth: 1))
                        .accessibilityLabel("Picture preview")
                    Text(s.previewLine).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Ink.dim)
                }
            }
        }
    }
}

/// 4 STREAM / STOP: one master (the picture + the pair of 1 SOURCE) to the VM's quality ladder.
struct StreamStep: View {
    @ObservedObject var s: Studio
    @ObservedObject var m: Model
    var body: some View {
        let can = s.streaming || m.device != nil
        Step(n: 4, word: s.streaming ? "STOP" : "STREAM", enabled: can, lit: s.streaming, id: "stream",
             action: { s.streaming ? s.stopStream() : s.stream() }) {
            Text(s.streamLine).font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(s.streaming ? Ink.green : Ink.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// ---------------------------------------------------------------- the app
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        Log.line("start v\(VERSION)")
        Model.shared.begin()
        Studio.shared.begin()
        Door.shared.start()
        for w in NSApp.windows where w.title.hasPrefix(APP_NAME) { w.setFrameAutosaveName("SoundLinkMain") }
        if CommandLine.arguments.contains("--login") { for w in NSApp.windows { w.orderOut(nil) } }
        Updater.checkAtStart()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ n: Notification) { Model.shared.stop(); Studio.shared.stopStream() }
}

struct SoundLinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window(APP_NAME, id: "main") { Root(m: Model.shared) }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentMinSize)
            .defaultSize(width: 640, height: 640)
    }
}

@main
enum Main {
    static func main() {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--shot"), i + 1 < a.count {
            // the window drawn off screen into a PNG, never shown (screenshots-without-his-screen)
            let ok = MainActor.assumeIsolated { () -> Bool in
                _ = NSApplication.shared
                let v = Root(m: Model.shared).frame(width: 640, height: 520)
                let r = ImageRenderer(content: v)
                r.scale = 2
                guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { return false }
                return (try? png.write(to: URL(fileURLWithPath: a[i + 1]))) != nil
            }
            exit(ok ? 0 : 1)
        }
        if a.contains("--devices") {
            for d in Devices.all() { print("\(d.name)\t\(d.channels) ch\t\(Int(d.rate)) Hz\t\(d.uid)") }
            exit(0)
        }
        SoundLinkApp.main()
    }
}
