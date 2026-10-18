// MM9 Native Installer: a Windows XP style setup wizard around the builder (Resources/builder/src/build.sh).
// The player picks (or drops) the GOG installer (.exe); the builder does everything else on this Mac.
// Nothing from the game is in this app. MIT licence (see LICENSES/).
import SwiftUI
import UniformTypeIdentifiers

let home = FileManager.default.homeDirectoryForCurrentUser.path
let supportDir = "\(home)/Library/Application Support/MM9 Native"
let gameCopy = "\(supportDir)/game"
let wineGame = "\(home)/Library/Application Support/Might and Magic IX/game"
let logFile = "\(supportDir)/logs/build.log"
let appPath = "\(home)/Applications/MM9 Native.app"

enum Phase: Equatable { case idle, running, done, failed(String) }

final class Installer: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var step = 0
    @Published var steps = 13
    @Published var stepTitle = "Starting"
    @Published var tail: [String] = []
    @Published var started = Date()
    @Published var chosen: String?
    @Published var gameFolderPresent = false
    @Published var appInstalled = false
    private var process: Process?
    private var activity: NSObjectProtocol?
    private var errorLines: [String] = []
    private var capturing = false

    init() { refresh() }

    func refresh() {
        let fm = FileManager.default
        gameFolderPresent = fm.fileExists(atPath: gameCopy + "/lithtech.exe") || fm.fileExists(atPath: wineGame + "/lithtech.exe")
        appInstalled = fm.fileExists(atPath: appPath)
    }

    /// `path` is the GOG installer (.exe), a game folder, or nil to use the game already on this Mac.
    func start(_ path: String?) {
        guard phase != .running else { return }
        guard let res = Bundle.main.resourceURL else { return }
        let builder = res.appendingPathComponent("builder/src/build.sh").path
        var env = ProcessInfo.processInfo.environment
        env["MM9N_DIALOGS"] = "0"
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        env["MM9N_INNOEXTRACT"] = res.appendingPathComponent("builder/bin/innoextract").path
        env["MM9N_GAME"] = nil; env["MM9N_INSTALLER"] = nil
        var isDir: ObjCBool = false
        if let p = path {
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { env["MM9N_GAME"] = p }
            else { env["MM9N_INSTALLER"] = p }
        }
        chosen = path
        step = 0; stepTitle = "Starting"; tail = []; errorLines = []; capturing = false
        started = Date(); phase = .running
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Building MM9 Native")
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
        refresh()
        if code == 0 { phase = .done }
        else if code == 130 || code == 15 { phase = .idle }
        else { phase = .failed(errorLines.isEmpty ? "The build stopped unexpectedly." : errorLines.joined(separator: "\n")) }
    }

    func cancel() { process?.interrupt() }
    func playGame() { NSWorkspace.shared.open(URL(fileURLWithPath: appPath)) }
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
let xpBeige = Color(hex: 0xECE9D8), xpBlue = Color(hex: 0x0054E3), xpBorder = Color(hex: 0x0831D9)
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
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(enabled ? Color(hex: 0x003C74) : Color(hex: 0xC9C7BA), lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 2).inset(by: 1.5).stroke(isDefault && enabled ? Color(hex: 0x6EA1F1) : .clear, lineWidth: 1.5))
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
                    Circle().stroke(Color(hex: 0x1C5180), lineWidth: 1)
                    if on { Circle().fill(Color(hex: 0x21A121)).frame(width: 5, height: 5) }
                }.frame(width: 13, height: 13)
                Text(title).font(tahoma()).foregroundColor(.black)
            }
        }.buttonStyle(.plain)
    }
}
struct XPCheck: View {
    let title: String; @Binding var on: Bool
    var body: some View {
        Button { on.toggle() } label: {
            HStack(spacing: 6) {
                ZStack {
                    Rectangle().fill(.white); Rectangle().stroke(Color(hex: 0x1C5180), lineWidth: 1)
                    if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundColor(Color(hex: 0x21A121)) }
                }.frame(width: 13, height: 13)
                Text(title).font(tahoma()).foregroundColor(.black)
            }
        }.buttonStyle(.plain)
    }
}
struct SunkenBox<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.background(Color.white).overlay(Rectangle().stroke(Color(hex: 0x7F9DB9), lineWidth: 1))
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
                            .fill(LinearGradient(colors: [Color(hex: 0x9BE69A), Color(hex: 0x2BC827), Color(hex: 0x9BE69A)], startPoint: .top, endPoint: .bottom))
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
        Link(destination: URL(string: "https://github.com/opimuusikat/Might-and-Magic-IX-MacOS")!) {
            Text("github.com/opimuusikat/Might-and-Magic-IX-MacOS").font(tahoma(10)).foregroundColor(Color(hex: 0x0000CC)).underline()
        }
    }
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

enum Page { case welcome, license, select, install }

struct ContentView: View {
    @StateObject var inst = Installer()
    @State private var page: Page = {
        switch ProcessInfo.processInfo.environment["MM9I_PAGE"] { case "license": return .license; case "select": return .select; case "install": return .install; default: return .welcome }
    }()
    @State private var accepted = false
    @State private var useExisting = false
    @State private var path = ""
    @State private var launch = true
    @State private var targeted = false
    @State private var showDetails = false
    @State private var tick = Date()
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            ZStack {
                xpBeige
                VStack(spacing: 0) {
                    switch page {
                    case .welcome: welcome
                    case .license: wizardPage("License Agreement", "Please read the following notice before continuing.") { license }
                    case .select: wizardPage("Select Game Source", "Where is your copy of Might and Magic IX?") { select }
                    case .install: installPage
                    }
                    Etched()
                    buttons.padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
        }
        .frame(width: 520, height: 400)
        .preferredColorScheme(.light).foregroundColor(.black)
        .clipShape(TopRounded())
        .overlay(TopRounded().stroke(xpBorder, lineWidth: 1))
        .background(WindowSetup())
        .onReceive(timer) { tick = $0 }
        .onChange(of: inst.phase) { _ in inst.refresh() }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard page == .select || page == .welcome || page == .license, let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let u = url { DispatchQueue.main.async { path = u.path; useExisting = false; accepted = true; page = .select } }
            }
            return true
        }
    }

    // MARK: title bar
    var titleBar: some View {
        HStack(spacing: 6) {
            Logo(size: 22)
            Text("Might and Magic IX Native Setup").font(trebuchet(13)).foregroundColor(.white).shadow(color: .black.opacity(0.6), radius: 0, x: 1, y: 1)
            Spacer()
            captionButton("minus") { NSApp.keyWindow?.miniaturize(nil) }
            captionButton("xmark", red: true) { if inst.phase == .running { inst.cancel() }; NSApp.terminate(nil) }
        }
        .padding(.horizontal, 6).frame(height: 30)
        .background(LinearGradient(stops: [
            .init(color: Color(hex: 0x0997FF), location: 0), .init(color: Color(hex: 0x0053EE), location: 0.12),
            .init(color: Color(hex: 0x0050EE), location: 0.5), .init(color: Color(hex: 0x0066FF), location: 0.9), .init(color: Color(hex: 0x003DD7), location: 1)],
            startPoint: .top, endPoint: .bottom))
    }
    func captionButton(_ symbol: String, red: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .heavy)).foregroundColor(.white)
                .frame(width: 21, height: 21)
                .background(RoundedRectangle(cornerRadius: 3).fill(red
                    ? LinearGradient(colors: [Color(hex: 0xE9886C), Color(hex: 0xC8381A)], startPoint: .top, endPoint: .bottom)
                    : LinearGradient(colors: [Color(hex: 0x5C8EF5), Color(hex: 0x2253D8)], startPoint: .top, endPoint: .bottom)))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    // MARK: pages
    var welcome: some View {
        HStack(spacing: 0) {
            Banner()
            VStack(alignment: .leading, spacing: 12) {
                Text("Welcome to the Might and Magic IX Native Setup Wizard").font(tahoma(14, bold: true))
                Text("This wizard builds a native Apple Silicon version of Might and Magic IX on your Mac, from your own copy of the game.").font(tahoma())
                Text("It needs about 4 GB of free space and an internet connection, and takes 10 to 25 minutes.").font(tahoma())
                if inst.appInstalled {
                    Text("MM9 Native is already installed on this Mac.").font(tahoma(11, bold: true)).padding(.top, 4)
                    XPButton(title: "Play MM9 Native") { inst.playGame() }
                }
                Spacer()
                Text("Click Next to continue.").font(tahoma())
                GitHubLink()
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color.white)
        }
    }

    func wizardPage<C: View>(_ title: String, _ subtitle: String, @ViewBuilder _ body: () -> C) -> some View {
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
            body().padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    var license: some View {
        VStack(alignment: .leading, spacing: 10) {
            SunkenBox {
                ScrollView {
                    Text("""
                    For educational and research purposes only.

                    This setup contains no game code, no game assets and nothing derived from a game. You must own a legally purchased copy of Might and Magic IX (GOG release 1.3). Everything the wizard makes from it is built on your Mac and stays there.

                    Do not share the finished game app: it contains a translation of the game's code, which belongs to its owner. Friends should run this setup themselves with their own copy.

                    This project is not affiliated with Ubisoft, The 3DO Company, New World Computing, Monolith Productions, LithTech or GOG. The setup itself is MIT licensed; it downloads Ghidra (Apache 2.0), Eclipse Temurin (GPLv2 + Classpath Exception) and Unicorn (GPLv2) and uses innoextract (zlib).
                    """).font(tahoma()).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }.frame(height: 160)
            XPRadio(title: "I accept the terms of this notice", on: accepted) { accepted = true }
            XPRadio(title: "I do not accept the terms of this notice", on: !accepted) { accepted = false }
        }
    }

    var select: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose your GOG installer (setup_might_and_magic_9_writ_of_fate_1.3_….exe), or an unpacked game folder. You can also drag it onto this window.").font(tahoma())
            if inst.gameFolderPresent {
                XPRadio(title: "Use the game already on this Mac", on: useExisting) { useExisting = true }
                XPRadio(title: "Use this installer or folder:", on: !useExisting) { useExisting = false }
            }
            HStack(spacing: 8) {
                SunkenBox {
                    Text(path.isEmpty ? "No file chosen" : path).font(tahoma()).foregroundColor(path.isEmpty ? Color(hex: 0x808080) : .black)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4).frame(height: 21)
                }
                XPButton(title: "Browse…") { choose() }
            }
            .padding(2).background(targeted ? Color(hex: 0xB5D2FF) : .clear)
            Text("The installer is only read; your original is not changed.").font(tahoma()).foregroundColor(Color(hex: 0x555555))
        }
    }

    var installPage: some View {
        switch inst.phase {
        case .done: return AnyView(finishDone)
        case .failed(let msg): return AnyView(finishFailed(msg))
        default: return AnyView(installing)
        }
    }

    var installing: some View {
        let elapsed = Int(tick.timeIntervalSince(inst.started))
        return HStack(spacing: 0) {
            Banner()
            VStack(alignment: .leading, spacing: 10) {
                Text("Installing").font(.custom("Georgia Bold", size: 16)).foregroundColor(Color(hex: 0x3B2410))
                Text("Please wait while Might and Magic IX Native is built on your Mac.").font(tahoma())
                Text("Step \(inst.step) of \(inst.steps): \(inst.stepTitle)").font(tahoma(11, bold: true)).lineLimit(2).padding(.top, 6)
                XPProgress(fraction: Double(max(inst.step - 1, 0)) / Double(inst.steps), running: true)
                Text("Elapsed: \(elapsed / 60) min \(elapsed % 60) s. Keep this window open; the Mac stays awake until the build is done.").font(tahoma()).foregroundColor(Color(hex: 0x555555))
                XPCheck(title: "Show details", on: $showDetails)
                if showDetails {
                    SunkenBox {
                        ScrollView { Text(inst.tail.suffix(60).joined(separator: "\n")).font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(4).textSelection(.enabled) }
                    }.frame(height: 90)
                }
                Spacer(minLength: 0)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(xpBeige)
        }
    }

    var finishDone: some View {
        HStack(spacing: 0) {
            Banner(dawn: true, gameIcon: NSWorkspace.shared.icon(forFile: appPath))
            VStack(alignment: .leading, spacing: 12) {
                Text("Completing the Might and Magic IX Native Setup Wizard").font(tahoma(14, bold: true))
                Text("MM9 Native is now in the Applications folder in your home folder (~/Applications).").font(tahoma())
                Text("Movies need ffmpeg (brew install ffmpeg); the game works without it.").font(tahoma()).foregroundColor(Color(hex: 0x555555))
                Spacer()
                XPCheck(title: "Launch MM9 Native", on: $launch)
                Text("Click Finish to close the wizard.").font(tahoma())
                GitHubLink()
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color.white)
        }
    }

    func finishFailed(_ msg: String) -> some View {
        wizardPage("Setup failed", "The build stopped before it was finished.") {
            VStack(alignment: .leading, spacing: 8) {
                SunkenBox { ScrollView { Text(msg).font(tahoma()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6) } }.frame(height: 130)
                HStack { XPButton(title: "Copy log") { inst.copyLog() }; XPButton(title: "Show log") { inst.showLog() } }
                Text("If you ask for help, send the log. It holds tool output and file names only.").font(tahoma()).foregroundColor(Color(hex: 0x555555))
            }
        }
    }

    // MARK: buttons
    var buttons: some View {
        HStack(spacing: 8) {
            Spacer()
            switch (page, inst.phase) {
            case (.install, .done):
                XPButton(title: "Finish", isDefault: true) { if launch { inst.playGame() }; NSApp.terminate(nil) }
            case (.install, .failed):
                XPButton(title: "< Back") { inst.phase = .idle; page = .select }
                XPButton(title: "Try Again", isDefault: true) { inst.start(useExisting ? nil : path) }
                XPButton(title: "Cancel") { NSApp.terminate(nil) }
            case (.install, _):
                XPButton(title: "< Back").disabled(true)
                XPButton(title: "Next >").disabled(true)
                XPButton(title: "Cancel") { inst.cancel() }
            default:
                XPButton(title: "< Back") { back() }.disabled(page == .welcome)
                XPButton(title: page == .select ? "Install" : "Next >", isDefault: true) { next() }.disabled(!canNext)
                XPButton(title: "Cancel") { NSApp.terminate(nil) }
            }
        }
    }
    var canNext: Bool {
        switch page { case .welcome: return true; case .license: return accepted; case .select: return useExisting || !path.isEmpty; case .install: return false }
    }
    func next() {
        switch page {
        case .welcome: page = .license
        case .license: page = .select; if inst.gameFolderPresent && path.isEmpty { useExisting = true }
        case .select: page = .install; inst.start(useExisting ? nil : path)
        case .install: break
        }
    }
    func back() {
        switch page { case .license: page = .welcome; case .select: page = .license; default: break }
    }
    func choose() {
        let panel = NSOpenPanel()
        panel.message = "Choose your GOG installer for Might and Magic 9 (setup_might_and_magic_9_….exe) or an unpacked game folder"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let u = panel.url { path = u.path; useExisting = false }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MM9InstallerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    init() {
        if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            let r = ImageRenderer(content: AppIconArt()); r.scale = 1
            if let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: out)) }
            exit(0)
        }
    }
    var body: some Scene {
        WindowGroup("MM9 Native Installer") { ContentView() }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
    }
}
