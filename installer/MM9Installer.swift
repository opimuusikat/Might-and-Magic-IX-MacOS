// MM9 Native Installer: a Windows XP style setup wizard around the builder (Resources/builder/src/build.sh).
// The player picks (or drops) the GOG installer (.exe); the builder does everything else on this Mac.
// Nothing from the game is in this app. MIT licence (see LICENSES/).
import SwiftUI
import UniformTypeIdentifiers

final class Installer: ObservableObject {
    let runner = BuildRunner()
    @Published var chosen: String?
    @Published var gameFolderPresent = false
    @Published var appInstalled = false
    @Published var movies = true      // also download ffmpeg so the intro movies play
    private var forward: Any?
    var phase: Phase { get { runner.phase } set { runner.phase = newValue } }
    var step: Int { runner.step }
    var steps: Int { runner.steps }
    var stepTitle: String { runner.stepTitle }
    var tail: [String] { runner.tail }
    var started: Date { runner.started }

    init() {
        forward = runner.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        runner.onFinish = { [weak self] in self?.refresh() }
        refresh()
        // Screenshots for the README: MM9I_PAGE=install|done|failed shows that page with sample values (no build runs).
        switch ProcessInfo.processInfo.environment["MM9I_PAGE"] {
        case "install":
            runner.phase = .running; runner.step = 7; runner.stepTitle = "Analysing the code with Ghidra (5 modules, 3 at a time; the longest step)"
            runner.started = Date().addingTimeInterval(-420)
            runner.tail = ["[7/13] Analysing the code with Ghidra (5 modules, 3 at a time; the longest step)", "lithtech.exe  import+analysis 112s", "d3d.ren       import+analysis  38s", "cshell.dll    import+analysis  71s"]
        case "done": runner.phase = .done
        case "failed": runner.phase = .failed("Not enough free disk space: the build needs about 4 GB free on the disk that holds /Users/you/Library/Application Support/MM9 Native.")
        default: break
        }
    }

    func refresh() {
        let fm = FileManager.default
        gameFolderPresent = fm.fileExists(atPath: gameCopy + "/lithtech.exe") || fm.fileExists(atPath: wineGame + "/lithtech.exe")
        appInstalled = fm.fileExists(atPath: appPath) && ProcessInfo.processInfo.environment["MM9I_PAGE"] == nil   // screenshots: a clean Mac
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
        env["MM9N_FFMPEG_DOWNLOAD"] = movies ? "1" : "0"
        var isDir: ObjCBool = false
        if let p = path {
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { env["MM9N_GAME"] = p }
            else { env["MM9N_INSTALLER"] = p }
        }
        chosen = path
        runner.start(builder: builder, env: env)
    }

    func cancel() { runner.cancel() }
    func playGame() { NSWorkspace.shared.open(URL(fileURLWithPath: appPath)) }
    func showLog() { runner.showLog() }
    func copyLog() { runner.copyLog() }
}

enum Page { case welcome, license, select, components, install }

struct ContentView: View {
    @StateObject var inst = Installer()
    @State private var page: Page = {
        switch ProcessInfo.processInfo.environment["MM9I_PAGE"] { case "license": return .license; case "select": return .select; case "components": return .components; case "install", "done", "failed": return .install; default: return .welcome }
    }()
    @State private var accepted = ProcessInfo.processInfo.environment["MM9I_PAGE"] != nil   // screenshots show the accepted state
    @State private var useExisting = false
    @State private var path = ""
    @State private var launch = true
    @State private var cltOK = commandLineToolsReady()
    @State private var freeGB = freeDiskGB()
    @State private var targeted = false
    @State private var showDetails = false
    @State private var tick = Date()
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            XPTitleBar(title: "Might and Magic IX Native Setup") { if inst.phase == .running { inst.cancel() }; NSApp.terminate(nil) }
            ZStack {
                xpBeige
                VStack(spacing: 0) {
                    switch page {
                    case .welcome: welcome
                    case .license: wizardPage("License Agreement", "Please read the following notice before continuing.") { license }
                    case .select: wizardPage("Select Game Source", "Where is your copy of Might and Magic IX?") { select }
                    case .components: wizardPage("Select Components", "Choose what Setup should install on your Mac.") { components }
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
        .onReceive(timer) { tick = $0; if page == .components { cltOK = commandLineToolsReady(); freeGB = freeDiskGB() } }
        .onChange(of: inst.phase) { ph in inst.refresh(); if ph == .idle && page == .install { page = .components } }   // cancelled
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard page == .select, let p = providers.first else { return false }   // not before the notice is accepted
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let u = url { DispatchQueue.main.async { path = u.path; useExisting = false } }
            }
            return true
        }
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

    func wizardPage<C: View>(_ title: String, _ subtitle: String, @ViewBuilder _ body: () -> C) -> some View { XPWizardPage(title: title, subtitle: subtitle, content: body) }

    var license: some View {
        VStack(alignment: .leading, spacing: 10) {
            SunkenBox {
                XPScroll {
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

    var components: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.square.fill").foregroundColor(Color(hex: 0x8A8A8A))
                Text("Build tools: Ghidra, Java 21 and Unicorn (about 0.8 GB, downloaded for you)").font(tahoma()).foregroundColor(Color(hex: 0x555555))
            }
            XPCheck(title: "Intro movies: download ffmpeg (about 28 MB)", on: $inst.movies)
            Text("Without it the game still works, but skips its logo and intro movies.").font(tahoma()).foregroundColor(Color(hex: 0x555555)).padding(.leading, 19)
            Etched().padding(.vertical, 4)
            XPMacChecks(cltOK: cltOK, freeGB: freeGB)
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
                        XPScroll { Text(inst.tail.suffix(60).joined(separator: "\n")).font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(4).textSelection(.enabled) }
                    }.frame(height: 90)
                }
                Spacer(minLength: 0)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(xpBeige)
        }
    }

    var finishDone: some View {
        HStack(spacing: 0) {
            Banner(dawn: true, gameIcon: FileManager.default.fileExists(atPath: appPath) ? NSWorkspace.shared.icon(forFile: appPath) : nil)
            VStack(alignment: .leading, spacing: 12) {
                Text("Completing the Might and Magic IX Native Setup Wizard").font(tahoma(14, bold: true))
                Text("MM9 Native is now in the Applications folder in your home folder (~/Applications).").font(tahoma())
                Text(FileManager.default.isExecutableFile(atPath: supportDir + "/tools/ffmpeg") ? "The intro movies are enabled (ffmpeg was downloaded)."
                     : "Movies need ffmpeg (brew install ffmpeg); the game works without it.").font(tahoma()).foregroundColor(Color(hex: 0x555555))
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
                SunkenBox { XPScroll { Text(msg).font(tahoma()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6) } }.frame(height: 130)
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
                XPButton(title: page == .components ? "Install" : "Next >", isDefault: true) { next() }.disabled(!canNext)
                XPButton(title: "Cancel") { NSApp.terminate(nil) }
            }
        }
    }
    var canNext: Bool {
        switch page { case .welcome: return true; case .license: return accepted; case .select: return useExisting || !path.isEmpty; case .components: return cltOK && freeGB >= 4; case .install: return false }
    }
    func next() {
        switch page {
        case .welcome: page = .license
        case .license: page = .select; if inst.gameFolderPresent && path.isEmpty { useExisting = true }
        case .select: page = .components; cltOK = commandLineToolsReady(); freeGB = freeDiskGB()
        case .components: page = .install; inst.start(useExisting ? nil : path)
        case .install: break
        }
    }
    func back() {
        switch page { case .license: page = .welcome; case .select: page = .license; case .components: page = .select; default: break }
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
        // `--render-page out.png` (with MM9I_PAGE=welcome|license|select|components|install|done|failed): README screenshot, no window.
        if let i = CommandLine.arguments.firstIndex(of: "--render-page"), i + 1 < CommandLine.arguments.count {
            renderPNG(ContentView().environment(\.xpStatic, true), to: CommandLine.arguments[i + 1])
            exit(0)
        }
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
