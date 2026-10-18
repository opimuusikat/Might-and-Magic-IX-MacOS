// Shared pieces of the MM9 Native Installer and Updater: the Windows XP (Luna) look, the banner artwork,
// the title bar and wizard page, and the runner that starts build.sh and follows its [n/m] steps.
// Nothing from the game is in here. MIT licence (see LICENSES/).
import SwiftUI

let home = FileManager.default.homeDirectoryForCurrentUser.path
let supportDir = "\(home)/Library/Application Support/MM9 Native"
let gameCopy = "\(supportDir)/game"
let wineGame = "\(home)/Library/Application Support/Might and Magic IX/game"
let logFile = "\(supportDir)/logs/build.log"
let appPath = "\(home)/Applications/MM9 Native.app"

enum Phase: Equatable { case idle, running, done, failed(String) }

/// Runs build.sh, follows its "[n/m] title" lines, and keeps the lines of its failure message.
final class BuildRunner: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var step = 0
    @Published var steps = 13
    @Published var stepTitle = "Starting"
    @Published var tail: [String] = []
    @Published var started = Date()
    var errorLines: [String] = []
    var onFinish: (() -> Void)?
    private var process: Process?
    private var activity: NSObjectProtocol?
    private var capturing = false

    /// `env` is the whole environment for the builder; `preface` lines go first into the details.
    func start(builder: String, env: [String: String], preface: [String] = [], reason: String = "Building MM9 Native") {
        guard phase != .running || process == nil else { return }
        step = 0; stepTitle = "Starting"; tail = preface; errorLines = []; capturing = false
        started = Date(); phase = .running
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [builder]
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        var buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { return }
            buffer.append(d)
            while let nl = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                DispatchQueue.main.async { self?.handle(line) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.finished(proc.terminationStatus) }
        }
        do { try p.run(); process = p }
        catch { finished(127) }
    }

    private func handle(_ line: String) {
        if let r = line.range(of: #"^\[(\d+)/(\d+)\] (.*)$"#, options: .regularExpression) {
            let s = String(line[r])
            let parts = s.dropFirst().split(separator: "]", maxSplits: 1)
            let nums = parts[0].split(separator: "/")
            step = Int(nums[0]) ?? step; steps = Int(nums[1]) ?? steps
            stepTitle = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : stepTitle
        }
        if line.hasPrefix("The build stopped at step") { capturing = true; errorLines = [] }
        if capturing, !line.hasPrefix("  Full log"), !line.hasPrefix("  If you ask") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { errorLines.append(t) }
        }
        let t = line.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { tail.append(t); if tail.count > 400 { tail.removeFirst(100) } }
    }

    private func finished(_ code: Int32) {
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        process = nil
        onFinish?()
        if code == 0 { phase = .done }
        else if code == 130 || code == 15 { phase = .idle }
        else { phase = .failed(errorLines.isEmpty ? "The build stopped unexpectedly." : errorLines.joined(separator: "\n")) }
    }

    func cancel() { process?.interrupt() }
    func showLog() { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: logFile)]) }
    func copyLog() {
        let text = (try? String(contentsOfFile: logFile, encoding: .utf8)) ?? tail.joined(separator: "\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Windows XP (Luna) look

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}
/// Colour scheme of the XP window parts. The installer keeps Luna Blue; the updater sets `.olive` (Luna Olive Green,
/// "Homestead") and the uninstaller `.red` (a Luna-style red) once at start, before any view is built.
enum XPTheme { case blue, olive, red }
nonisolated(unsafe) var xpTheme: XPTheme = .blue
private func pick<T>(_ blue: T, _ olive: T, _ red: T) -> T { switch xpTheme { case .blue: return blue; case .olive: return olive; case .red: return red } }
private func themed(_ blue: UInt32, _ olive: UInt32, _ red: UInt32) -> Color { Color(hex: pick(blue, olive, red)) }
let xpBeige = Color(hex: 0xECE9D8)
var xpBorder: Color { themed(0x0831D9, 0x5E7B2C, 0xA3170B) }          // window frame
var xpEdge: Color { themed(0x003C74, 0x3E5A1B, 0x6E1008) }            // button outline
var xpFocus: Color { themed(0x6EA1F1, 0xA7C46A, 0xF09A8A) }           // default-button inner ring
var xpControlEdge: Color { themed(0x1C5180, 0x4F6B22, 0x8A2016) }     // radio and checkbox outline
var xpListEdge: Color { themed(0x7F9DB9, 0xA2AE7E, 0xBF9893) }        // list and group box border
var xpSelect: Color { themed(0x316AC5, 0x8DA85A, 0xC8381A) }          // selection / highlight
func tahoma(_ size: CGFloat = 11, bold: Bool = false) -> Font { .custom(bold ? "Tahoma Bold" : "Tahoma", size: size) }
func trebuchet(_ size: CGFloat) -> Font { .custom("Trebuchet MS Bold", size: size) }

struct XPButtonStyle: ButtonStyle {
    var isDefault = false
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(tahoma(11)).foregroundColor(enabled ? .black : Color(hex: 0xACA899))
            .frame(minWidth: 75, minHeight: 23).padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 3).fill(LinearGradient(
                    colors: configuration.isPressed ? [Color(hex: 0xCECAB8), Color(hex: 0xE3E0D0)] : [.white, Color(hex: 0xECEBE5), Color(hex: 0xD6D0C5)],
                    startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(enabled ? xpEdge : Color(hex: 0xC9C7BA), lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 2).inset(by: 1.5).stroke(isDefault && enabled ? xpFocus : .clear, lineWidth: 1.5))
    }
}
struct XPButton: View {
    let title: String; var isDefault = false; var action: () -> Void = {}
    var body: some View { Button(title, action: action).buttonStyle(XPButtonStyle(isDefault: isDefault)) }
}

struct XPRadio: View {
    let title: String; let on: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [Color(hex: 0xDCDCD7), .white], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Circle().stroke(xpControlEdge, lineWidth: 1)
                    if on { Circle().fill(Color(hex: 0x21A121)).frame(width: 5, height: 5) }
                }.frame(width: 13, height: 13)
                Text(title).font(tahoma()).foregroundColor(.black)
            }
        }.buttonStyle(.plain)
    }
}
struct XPCheck: View {
    let title: String; @Binding var on: Bool; var locked = false   // locked: ticked and greyed, cannot be changed
    var body: some View {
        Button { if !locked { on.toggle() } } label: {
            HStack(spacing: 6) {
                ZStack {
                    Rectangle().fill(locked ? Color(hex: 0xECE9D8) : .white); Rectangle().stroke(locked ? Color(hex: 0xACA899) : xpControlEdge, lineWidth: 1)
                    if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundColor(locked ? Color(hex: 0x8A8A8A) : Color(hex: 0x21A121)) }
                }.frame(width: 13, height: 13)
                Text(title).font(tahoma()).foregroundColor(locked ? Color(hex: 0x808080) : .black)
            }
        }.buttonStyle(.plain)
    }
}
struct SunkenBox<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.background(Color.white).overlay(Rectangle().stroke(xpListEdge, lineWidth: 1))
    }
}
struct TopRounded: Shape {   // rounded top corners only (UnevenRoundedRectangle needs macOS 14)
    func path(in r: CGRect) -> Path {
        var p = Path(); let c: CGFloat = 8
        p.move(to: CGPoint(x: 0, y: r.maxY)); p.addLine(to: CGPoint(x: 0, y: c))
        p.addQuadCurve(to: CGPoint(x: c, y: 0), control: .zero)
        p.addLine(to: CGPoint(x: r.maxX - c, y: 0))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: c), control: CGPoint(x: r.maxX, y: 0))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.closeSubpath(); return p
    }
}
struct Etched: View {
    var body: some View { VStack(spacing: 0) { Color(hex: 0xACA899).frame(height: 1); Color.white.frame(height: 1) } }
}

struct XPProgress: View {
    let fraction: Double; let running: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { ctx in
            GeometryReader { g in
                let n = max(Int((g.size.width - 4) / 10), 1)
                let filled = Int((fraction * Double(n)).rounded(.down))
                let t = Int(ctx.date.timeIntervalSinceReferenceDate * 8)
                HStack(spacing: 2) {
                    ForEach(0..<n, id: \.self) { i in
                        let span = max(n - filled, 1)
                        let marching = running && i >= filled && abs((i - filled) - (t % (span + 4)) + 1) < 3
                        Rectangle()
                            .fill(LinearGradient(colors: pick([0x9BE69A, 0x2BC827, 0x9BE69A], [0xD6E39A, 0x8FB12E, 0xD6E39A], [0xF5A99C, 0xD8321E, 0xF5A99C]).map { Color(hex: $0) }, startPoint: .top, endPoint: .bottom))
                            .opacity(i < filled || marching ? 1 : 0)
                            .frame(width: 8)
                    }
                    Spacer(minLength: 0)
                }.padding(2)
            }
        }
        .frame(height: 18)
        .background(.white).overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(hex: 0x686868), lineWidth: 1))
    }
}

/// Hides the macOS title bar buttons and lets the XP title bar drag the window.
struct WindowSetup: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titleVisibility = .hidden; w.titlebarAppearsTransparent = true
            w.styleMask.insert(.fullSizeContentView)
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(b)?.isHidden = true }
            w.appearance = NSAppearance(named: .aqua)
            w.isMovableByWindowBackground = true
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = true
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}


// MARK: - Original artwork (drawn here; nothing taken from the game)

/// The project logo (Resources/logo.jpg), shown as a rounded square.
let logoImage: NSImage? = Bundle.main.url(forResource: "logo", withExtension: "jpg").flatMap { NSImage(contentsOf: $0) }
struct Logo: View {
    let size: CGFloat
    var body: some View {
        Group {
            if let i = logoImage { Image(nsImage: i).resizable().interpolation(.high).scaledToFit() }
            else { Color(hex: 0x1B2A6B) }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.16))
        .shadow(color: .black.opacity(0.6), radius: size * 0.04, y: size * 0.02)
    }
}

/// Night (or dawn) landscape: stars, moon, mountains, a castle on a hill, pines.
struct SceneArt: View {
    var dawn = false
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let c: [Color] = dawn ? [Color(hex: 0x1B2A6B), Color(hex: 0x6A4C93), Color(hex: 0xE58F5B), Color(hex: 0xFFD27A)]
                                  : [Color(hex: 0x070A24), Color(hex: 0x1B1B4D), Color(hex: 0x5A2A5C), Color(hex: 0xC0603A)]
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(stops: [.init(color: c[0], location: 0), .init(color: c[1], location: 0.4), .init(color: c[2], location: 0.72), .init(color: c[3], location: 0.88)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
            var seed: UInt64 = 20020
            func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
            for _ in 0..<50 {
                let x = rnd() * w, y = rnd() * h * 0.62, r = 0.4 + rnd() * 0.9, a = dawn ? 0.3 : 0.4 + rnd() * 0.6
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)), with: .color(.white.opacity(a)))
            }
            let moon = CGPoint(x: w * 0.27, y: h * 0.62)
            ctx.fill(Path(ellipseIn: CGRect(x: moon.x - 30, y: moon.y - 30, width: 60, height: 60)), with: .color(Color(hex: 0xF4EBC8).opacity(0.14)))
            ctx.fill(Path(ellipseIn: CGRect(x: moon.x - 12, y: moon.y - 12, width: 24, height: 24)), with: .color(Color(hex: 0xF4EBC8).opacity(dawn ? 0.5 : 1)))
            func ridge(_ pts: [(Double, Double)], _ col: Color) {
                var p = Path(); p.move(to: CGPoint(x: 0, y: h))
                for (x, y) in pts { p.addLine(to: CGPoint(x: x * w, y: y * h)) }
                p.addLine(to: CGPoint(x: w, y: h)); p.closeSubpath(); ctx.fill(p, with: .color(col))
            }
            ridge([(0, 0.74), (0.14, 0.66), (0.28, 0.74), (0.5, 0.62), (0.7, 0.75), (0.86, 0.67), (1, 0.74)], Color(hex: dawn ? 0x4B3A78 : 0x2A2147))
            ridge([(0, 0.82), (0.2, 0.76), (0.42, 0.83), (0.62, 0.78), (0.82, 0.84), (1, 0.79)], Color(hex: dawn ? 0x2B2255 : 0x161230))
            let ink = Color(hex: 0x0B0A1C), cx = w * 0.68, base = h * 0.84
            ctx.fill(Path(ellipseIn: CGRect(x: cx - w * 0.3, y: base - h * 0.02, width: w * 0.6, height: h * 0.14)), with: .color(ink))
            func rect(_ x: Double, _ y: Double, _ ww: Double, _ hh: Double, _ col: Color = ink) { ctx.fill(Path(CGRect(x: x, y: y, width: ww, height: hh)), with: .color(col)) }
            func roof(_ x: Double, _ y: Double, _ ww: Double, _ hh: Double) {
                var p = Path(); p.move(to: CGPoint(x: x - ww * 0.15, y: y)); p.addLine(to: CGPoint(x: x + ww / 2, y: y - hh)); p.addLine(to: CGPoint(x: x + ww * 1.15, y: y)); p.closeSubpath(); ctx.fill(p, with: .color(ink))
            }
            rect(cx - w * 0.14, base - h * 0.10, w * 0.28, h * 0.10)
            for i in 0..<7 { rect(cx - w * 0.14 + Double(i) * w * 0.045, base - h * 0.115, w * 0.025, h * 0.016) }
            let towers: [(Double, Double)] = [(-0.19, 0.19), (-0.04, 0.23), (0.115, 0.17)]
            for (dx, th) in towers {
                rect(cx + w * dx, base - h * th, w * 0.075, h * th); roof(cx + w * dx, base - h * th, w * 0.075, h * 0.07)
            }
            for (dx, th) in towers { rect(cx + w * dx + w * 0.027, base - h * th + h * 0.04, w * 0.02, h * 0.022, Color(hex: 0xFFC857)) }
            rect(cx - w * 0.015, base - h * 0.045, w * 0.03, h * 0.045, Color(hex: 0x1E1500))
            for (x, s) in [(0.06, 1.0), (0.14, 0.75), (0.2, 0.9)] as [(Double, Double)] {
                for k in 0..<3 {
                    var p = Path(); let ty = h * (0.87 - 0.045 * s) + Double(k) * h * 0.028 * s, bw = w * (0.07 - 0.012 * Double(k)) * s
                    p.move(to: CGPoint(x: w * x, y: ty)); p.addLine(to: CGPoint(x: w * x - bw / 2, y: ty + h * 0.04 * s)); p.addLine(to: CGPoint(x: w * x + bw / 2, y: ty + h * 0.04 * s)); p.closeSubpath()
                    ctx.fill(p, with: .color(Color(hex: 0x07061A)))
                }
            }
            ctx.fill(Path(CGRect(x: 0, y: h * 0.94, width: w, height: h * 0.06)), with: .color(Color(hex: 0x07061A)))
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                Gradient(colors: [.clear, .black.opacity(0.35)]), center: CGPoint(x: w / 2, y: h / 2), startRadius: min(w, h) * 0.5, endRadius: max(w, h) * 0.8))
        }
    }
}

/// The left panel of the welcome, install and finish pages.
struct Banner: View {
    var dawn = false; var gameIcon: NSImage? = nil
    var body: some View {
        ZStack(alignment: .top) {
            SceneArt(dawn: dawn)
            VStack(spacing: 6) {
                Logo(size: 148).padding(.top, 8)
                if let i = gameIcon { Image(nsImage: i).resizable().frame(width: 44, height: 44).padding(.top, 4) }
            }
        }.frame(width: 164)
    }
}

struct GitHubLink: View {
    var body: some View {
        XPLink(url: URL(string: "https://github.com/opimuusikat/Might-and-Magic-IX-MacOS")!, text: "github.com/opimuusikat/Might-and-Magic-IX-MacOS", size: 10)
    }
}

/// Set while a page is rendered to a PNG: ImageRenderer cannot draw Link and ScrollView (it paints placeholders).
struct XPStaticKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var xpStatic: Bool { get { self[XPStaticKey.self] } set { self[XPStaticKey.self] = newValue } } }
struct XPLink: View {
    let url: URL; let text: String; var size: CGFloat = 11
    @Environment(\.xpStatic) var isStatic
    var body: some View {
        let t = Text(text).font(tahoma(size)).foregroundColor(Color(hex: 0x0000CC)).underline()
        if isStatic { t } else { Link(destination: url) { t } }
    }
}
struct XPScroll<C: View>: View {
    @ViewBuilder var content: C
    @Environment(\.xpStatic) var isStatic
    var body: some View { if isStatic { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).overlay(alignment: .topLeading) { content }.clipped() } else { ScrollView { content } } }
}

/// App icon: the logo on a rounded tile. Rendered by `MM9Installer --render-icon out.png`.
struct AppIconArt: View {
    var body: some View {
        Group {
            if let i = logoImage { Image(nsImage: i).resizable().interpolation(.high).scaledToFill() } else { Color(hex: 0x1B2A6B) }
        }
        .frame(width: 824, height: 824).clipShape(RoundedRectangle(cornerRadius: 185))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 10)
        .frame(width: 1024, height: 1024)
    }
}

/// Apple's Command Line Tools (clang) are installed.
func commandLineToolsReady() -> Bool {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select"); p.arguments = ["-p"]
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return false }
    let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return FileManager.default.fileExists(atPath: path + "/usr/bin/clang")
}
func freeDiskGB() -> Double {
    let v = try? URL(fileURLWithPath: home).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return Double(v?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_073_741_824
}

// MARK: - Shared window parts

/// The XP title bar with the minimise and close buttons. `onClose` defaults to quitting.
struct XPTitleBar: View {
    let title: String; var onClose: () -> Void = { NSApp.terminate(nil) }
    var body: some View {
        HStack(spacing: 6) {
            Logo(size: 22)
            Text(title).font(trebuchet(13)).foregroundColor(.white).shadow(color: .black.opacity(0.6), radius: 0, x: 1, y: 1)
            Spacer()
            captionButton("minus") { NSApp.keyWindow?.miniaturize(nil) }
            captionButton("xmark", red: true, action: onClose)
        }
        .padding(.horizontal, 6).frame(height: 30)
        .background(LinearGradient(stops: zip(pick([0x0997FF, 0x0053EE, 0x0050EE, 0x0066FF, 0x003DD7],
                                                  [0xC3D488, 0x9DB75A, 0x8EA94C, 0x9CB65B, 0x6A8532],
                                                  [0xF2826E, 0xCC2A18, 0xBE200F, 0xD2321E, 0x8E1206]), [0, 0.12, 0.5, 0.9, 1])
            .map { Gradient.Stop(color: Color(hex: $0), location: $1) }, startPoint: .top, endPoint: .bottom))
    }
    func captionButton(_ symbol: String, red: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .heavy)).foregroundColor(.white)
                .frame(width: 21, height: 21)
                .background(RoundedRectangle(cornerRadius: 3).fill(red
                    ? LinearGradient(colors: [Color(hex: 0xE9886C), Color(hex: 0xC8381A)], startPoint: .top, endPoint: .bottom)
                    : LinearGradient(colors: pick([0x5C8EF5, 0x2253D8], [0xB4C874, 0x6B8634], [0xF4A08E, 0xB52A18]).map { Color(hex: $0) }, startPoint: .top, endPoint: .bottom)))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white, lineWidth: 1))
        }.buttonStyle(.plain)
    }
}

/// A page with the cream header (title, subtitle, logo) and the body below it.
struct XPWizardPage<C: View>: View {
    let title: String; let subtitle: String; @ViewBuilder var content: C
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.custom("Georgia Bold", size: 14)).foregroundColor(Color(hex: 0x3B2410))
                    Text(subtitle).font(tahoma()).foregroundColor(Color(hex: 0x5A3E22)).padding(.leading, 14)
                }
                Spacer()
                Logo(size: 50)
            }.padding(.horizontal, 16).padding(.vertical, 6).frame(height: 62)
            .background(LinearGradient(colors: [Color(hex: 0xF8EFD0), Color(hex: 0xE6D4A2)], startPoint: .top, endPoint: .bottom))
            Etched()
            content.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// A line with a status icon: green check, red cross, amber exclamation, or a grey "info" dot.
enum Level { case ok, bad, warn, info }
struct XPStatusRow<A: View>: View {
    let level: Level; let text: String; @ViewBuilder var action: A
    var body: some View {
        HStack(spacing: 8) {
            switch level {
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundColor(Color(hex: 0x21A121))
            case .bad: Image(systemName: "xmark.circle.fill").foregroundColor(Color(hex: 0xC8381A))
            case .warn: Image(systemName: "exclamationmark.circle.fill").foregroundColor(Color(hex: 0xE08A00))
            case .info: Image(systemName: "info.circle.fill").foregroundColor(Color(hex: 0x8A8A8A))
            }
            Text(text).font(tahoma()).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            action
        }
    }
}
func installCLT() {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select"); p.arguments = ["--install"]
    p.standardOutput = Pipe(); p.standardError = Pipe(); try? p.run()
}
/// The "Checking this Mac" block of the components pages (the page polls `commandLineToolsReady()` and `freeDiskGB()` once a second).
struct XPMacChecks: View {
    let cltOK: Bool; let freeGB: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Checking this Mac").font(tahoma(11, bold: true))
            XPStatusRow(level: cltOK ? .ok : .bad, text: cltOK ? "Apple Command Line Tools are installed." : "Apple Command Line Tools are missing. They are free and need no Apple ID.") {
                if !cltOK { XPButton(title: "Install…") { installCLT() } }
            }
            XPStatusRow(level: freeGB >= 4 ? .ok : .bad, text: String(format: "Free disk space: %.0f GB (about 4 GB are needed).", freeGB)) { EmptyView() }
            if !cltOK { Text("Click Install…, follow Apple's window (about 10 minutes), then come back here. This page notices by itself.").font(tahoma()).foregroundColor(Color(hex: 0x555555)) }
        }
    }
}

/// Renders a view to a PNG (scale 2) for the screenshot hooks.
@MainActor func renderPNG<V: View>(_ view: V, to path: String, scale: CGFloat = 2) {
    let r = ImageRenderer(content: view); r.scale = scale
    if let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
}
