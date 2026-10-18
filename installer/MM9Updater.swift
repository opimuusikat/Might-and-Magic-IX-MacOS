// MM9 Native Updater: a Windows XP style wizard that looks at an installed MM9 Native, shows what is
// out of date, and brings it up to date by running the bundled builder (Resources/builder/src/build.sh)
// on the game copy that is already on this Mac. Saves and settings stay; the saves are backed up first.
// Nothing from the game is in this app. MIT licence (see LICENSES/). Shares XPKit.swift with the installer.
import SwiftUI

let releasesPage = URL(string: "https://github.com/opimuusikat/Might-and-Magic-IX-MacOS/releases")!
let bundledVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"

/// The CHANGELOG.md section for this updater's version (heading "## <version>"), as plain lines; empty if none.
func releaseNotes() -> [String] {
    guard let res = Bundle.main.resourceURL,
          let text = try? String(contentsOf: res.appendingPathComponent("builder/CHANGELOG.md"), encoding: .utf8) else { return [] }
    var out: [String] = [], inSection = false
    for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("## ") { if inSection { break }; inSection = line.dropFirst(3).trimmingCharacters(in: .whitespaces) == bundledVersion; continue }
        if inSection { out.append(line.hasPrefix("- ") ? "\u{2022} " + line.dropFirst(2) : line) }
    }
    return out
}

/// One in-game bug-fix variant from fixes/index.json (via `build.sh --fixes`).
struct UFix: Identifiable { let id: String; let date: String; let stable: Bool; let title: String; var notes: [String] }

func parseFixes(_ text: String) -> (state: String, fixes: [UFix], recommended: String) {
    var state = "offline", list: [UFix] = [], rec = ""
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let eq = line.firstIndex(of: "=") else { continue }
        let k = String(line[line.startIndex..<eq]), v = String(line[line.index(after: eq)...])
        let f = v.components(separatedBy: "\t")
        switch k {
        case "fixes_source": state = v
        case "fix": if f.count >= 4 { list.append(UFix(id: f[0], date: f[1], stable: f[2] == "1", title: f[3], notes: [])) }
        case "fix_note": if f.count >= 2, let i = list.firstIndex(where: { $0.id == f[0] }) { list[i].notes.append(f[1]) }
        case "fix_default": rec = v
        default: break
        }
    }
    return (state, list, rec)
}

func sampleFixes() -> String {
    """
    fixes_source=ok
    fix=2026-10-20b\t2026-10-20\t0\tSave-game crash on the world map
    fix_note=2026-10-20b\tFixes a crash when saving on the world map (not tested enough yet).
    fix=2026-10-20a\t2026-10-20\t1\tMouse wheel and window focus
    fix_note=2026-10-20a\tMouse wheel scrolls the spell list again.
    fix_note=2026-10-20a\tAlt-Tab no longer leaves the cursor stuck.
    fix=2026-10-18\t2026-10-18\t1\tHD textures load from the right folder
    fix=2026-10-15\t2026-10-15\t1\tVideo options keep their values
    fix=2026-10-12\t2026-10-12\t1\tSound stutter on Bink movies
    fix_default=2026-10-20a
    """
}

// MARK: - What `build.sh --status` says

struct UStatus {
    var v: [String: String] = [:]; var reasons: [String] = []
    init(text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[line.startIndex..<eq]), val = String(line[line.index(after: eq)...])
            if k == "reason" { reasons.append(val) } else { v[k] = val }
        }
    }
    subscript(_ k: String) -> String { v[k] ?? "" }
    var blocker: String { self["blocker"] }
    var updateNeeded: Bool { self["update_needed"] == "yes" }
    var appUpdate: Bool { self["app_update"] == "yes" }       // the app itself is out of date (not just a tool)
    var saves: Int { Int(self["saves"]) ?? 0 }
    var freeGB: Int { Int(self["free_gb"]) ?? 0 }
    var appDir: String { (self["app_path"] as NSString).deletingLastPathComponent }
    var ok: Bool { !v.isEmpty }

    /// The list on the analysis page.
    var rows: [(Level, String)] {
        var r: [(Level, String)] = []
        let arm = self["mac_arm64"] == "1"
        r.append((arm ? .ok : .bad, arm ? "Apple Silicon Mac, macOS \(self["macos"])." : "This Mac has an Intel chip. MM9 Native needs Apple Silicon."))
        r.append((self["clt"] == "1" ? .ok : .bad, self["clt"] == "1" ? "Apple Command Line Tools are installed." : "Apple Command Line Tools are missing (needed to rebuild)."))
        r.append((freeGB >= 4 ? .ok : .bad, "Free disk space: \(freeGB) GB (about 4 GB are needed to rebuild)."))
        switch self["app_state"] {
        case "ok":
            let src = self["app_source"].isEmpty ? "unknown build, made before update tracking" : String(self["app_source"].prefix(8))
            r.append((appUpdate ? .warn : .ok, "MM9 Native app: \(self["app_path"]), built \(self["app_built"]) by builder \(self["app_version"]) (\(src))."))
            let smoke = self["app_smoke"].hasPrefix("passed")
            r.append((smoke ? .ok : .bad, smoke ? "Start-up test of that build: passed." : "Start-up test of that build: \(self["app_smoke"].isEmpty ? "no result" : self["app_smoke"])."))
            let good = !self["app_ghidra"].contains("DIFFERS") && !self["app_table"].contains("DIFFERS") && !self["app_ghidra"].isEmpty
            r.append((good ? .ok : .warn, "Code analysis: \(self["app_ghidra"].isEmpty ? "not recorded" : self["app_ghidra"]); function table \(self["app_table"].isEmpty ? "not recorded" : self["app_table"])."))
        case "foreign": r.append((.bad, "An app at \(self["app_path"]) was not made by the MM9 Native builder."))
        default: r.append((.bad, "MM9 Native app: not found in ~/Applications or /Applications."))
        }
        switch self["game_state"] {
        case "ok": r.append((.ok, "Game copy: GOG 1.3, \(saves) saved games (\(self["saves_mb"]) MB)."))
        case "wrong": r.append((.bad, "Game copy in \(self["app_support"])/game is not the GOG 1.3 version."))
        default: r.append((.bad, "Game copy: not found in \(self["app_support"])/game."))
        }
        for (key, name) in [("tools_ghidra", "Ghidra"), ("tools_jdk", "Java 21 runtime"), ("tools_unicorn", "Unicorn")] {
            switch self[key] {
            case "ok": r.append((.ok, "\(name): ready."))
            case "update": r.append((.warn, "\(name): a different version is here and will be replaced."))
            default: r.append((.info, "\(name): will be downloaded when you rebuild."))
            }
        }
        switch self["ffmpeg"] {
        case "ok": r.append((.ok, "Intro movies: ffmpeg is installed."))
        case "update": r.append((.warn, "Intro movies: ffmpeg is a different version and can be updated."))
        default: r.append((.info, "Intro movies: ffmpeg is not installed (the game skips the movies)."))
        }
        r.append((.info, self["wine_app"] == "1" ? "The Wine version of the game is also here; it is not touched." : "No Wine version of the game found (not needed)."))
        return r
    }
}

func sampleStatus(_ page: String) -> String {
    var s = """
    bundled_version=\(bundledVersion)
    bundled_source=3f6a0c9d2b7e41a85c1d9e0f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b
    mac_arm64=1
    macos=15.1
    clt=1
    free_gb=212
    app_path=/Users/you/Applications/MM9 Native.app
    app_state=ok
    app_version=1.0
    app_source=
    app_built=Sun Oct 18 14:02:11 EEST 2026
    app_smoke=passed: window 800x600, 100 draws
    app_ghidra=5 of 5 modules identical to the reference build
    app_table=identical to the reference build
    app_arm64=1
    app_support=/Users/you/Library/Application Support/MM9 Native
    game_state=ok
    saves=12
    saves_mb=3
    tools_ghidra=ok
    tools_jdk=ok
    tools_unicorn=ok
    ffmpeg=update
    wine_app=1
    wine_game=1
    update_needed=yes
    app_update=yes
    reason=Your MM9 Native was built by an older builder that did not record its version details.
    reason=The movie tool ffmpeg is not the version this builder expects.
    """
    if page == "uptodate" {
        s = s.replacingOccurrences(of: "app_source=\n", with: "app_source=3f6a0c9d2b7e41a85c1d9e0f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b\n")
            .replacingOccurrences(of: "ffmpeg=update", with: "ffmpeg=ok").replacingOccurrences(of: "update_needed=yes", with: "update_needed=no")
            .replacingOccurrences(of: "app_update=yes", with: "app_update=no").replacingOccurrences(of: "app_version=1.0", with: "app_version=\(bundledVersion)")
            .split(separator: "\n").filter { !$0.hasPrefix("reason=") }.joined(separator: "\n")
    }
    if page == "blocked" {
        s = """
        bundled_version=\(bundledVersion)
        mac_arm64=1
        macos=15.1
        clt=1
        free_gb=212
        app_path=
        app_state=missing
        app_support=/Users/you/Library/Application Support/MM9 Native
        game_state=missing
        saves=0
        saves_mb=0
        tools_ghidra=missing
        tools_jdk=missing
        tools_unicorn=missing
        ffmpeg=missing
        wine_app=0
        wine_game=0
        update_needed=no
        blocker=MM9 Native is not installed on this Mac. Use the MM9 Native Installer.
        """
    }
    return s
}

// MARK: - Model

final class UpdaterModel: ObservableObject {
    let runner = BuildRunner()
    @Published var status: UStatus?
    @Published var analysing = false
    @Published var newer: String?
    @Published var fixes: [UFix] = []
    @Published var fixesState = "loading"     // loading, ok, offline
    @Published var recommendedFix = ""
    @Published var selectedFix = ""           // "" means no bug-fix variant
    private var fixChosen = false
    @Published var rebuild = false
    @Published var movies = true
    @Published var backup = true
    @Published var backupDir: String?
    var startPage: UPage = .welcome
    private var forward: Any?

    init(sample: String? = nil) {
        forward = runner.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        guard let page = sample ?? ProcessInfo.processInfo.environment["MM9U_PAGE"] else { return }
        switch page {
        case "analysis", "uptodate", "blocked", "fixes", "components", "install", "done", "failed":
            setStatus(UStatus(text: sampleStatus(page == "fixes" ? "analysis" : page)))
            startPage = page == "components" ? .components : page == "fixes" ? .fixes : (page == "analysis" || page == "uptodate" || page == "blocked") ? .analysis : .install
            if page == "analysis" { newer = "1.1" }
            if page == "fixes" { loadFixes(sample: sampleFixes()) }
            if page == "install" {
                runner.phase = .running; runner.step = 7; runner.stepTitle = "Analysing the code with Ghidra (5 modules, 3 at a time; the longest step)"
                runner.started = Date().addingTimeInterval(-420)
                runner.tail = ["Saved games backed up to ~/Library/Application Support/MM9 Native/backups/SaveGames-2026-10-18-141500", "[7/13] Analysing the code with Ghidra (5 modules, 3 at a time; the longest step)", "lithtech.exe  import+analysis 112s", "d3d.ren       import+analysis  38s"]
            }
            if page == "done" { runner.phase = .done; backupDir = "~/Library/Application Support/MM9 Native/backups/SaveGames-2026-10-18-141500" }
            if page == "failed" { runner.phase = .failed("Not enough free disk space: the build needs about 4 GB free on the disk that holds /Users/you/Library/Application Support/MM9 Native.") }
        default: break
        }
    }

    func setStatus(_ s: UStatus) {
        status = s; analysing = false
        rebuild = s.appUpdate; movies = s["ffmpeg"] != "missing"; backup = true
        chooseDefaultFix()
    }

    var installedFix: String { let f = status?["app_fix"] ?? ""; return f == "none" ? "" : f }
    var installedFixTitle: String { status?["app_fix_title"] ?? "" }
    /// What the player gets by default: the newest stable variant, or what they already have when none is stable.
    func chooseDefaultFix() {
        guard !fixChosen, status != nil, fixesState != "loading" else { return }
        selectedFix = recommendedFix.isEmpty ? installedFix : recommendedFix
        rebuild = forced || rebuild
    }
    func selectFix(_ id: String) { fixChosen = true; selectedFix = id; rebuild = forced || (status?.appUpdate ?? false) }

    /// Asks `build.sh --fixes` for the last 5 variants (needs the network; silent when offline).
    func loadFixes(sample: String? = nil) {
        fixesState = "loading"
        func finish(_ text: String) {
            let r = parseFixes(text); fixes = r.fixes; fixesState = r.state == "ok" ? "ok" : "offline"; recommendedFix = r.recommended
            chooseDefaultFix()
        }
        if let t = sample ?? ProcessInfo.processInfo.environment["MM9U_FIXES_FILE"].flatMap({ try? String(contentsOfFile: $0, encoding: .utf8) }) { finish(t); return }
        guard let res = Bundle.main.resourceURL else { return }
        let builder = res.appendingPathComponent("builder/src/build.sh").path
        DispatchQueue.global(qos: .userInitiated).async {
            var e = ProcessInfo.processInfo.environment; e["MM9N_DIALOGS"] = "0"; e["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [builder, "--fixes"]; p.environment = e
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
            var text = ""
            if (try? p.run()) != nil { text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit() }
            DispatchQueue.main.async { finish(text) }
        }
    }

    /// Runs `build.sh --status` (or reads MM9U_STATUS_FILE), then asks GitHub whether a newer updater exists.
    func analyse() {
        analysing = true; status = nil
        let env = ProcessInfo.processInfo.environment
        if let f = env["MM9U_STATUS_FILE"], let t = try? String(contentsOfFile: f, encoding: .utf8) { setStatus(UStatus(text: t)); return }
        guard let res = Bundle.main.resourceURL else { return }
        let builder = res.appendingPathComponent("builder/src/build.sh").path
        DispatchQueue.global(qos: .userInitiated).async {
            var e = env; e["MM9N_DIALOGS"] = "0"; e["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [builder, "--status"]; p.environment = e
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
            var text = ""
            if (try? p.run()) != nil { text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit() }
            DispatchQueue.main.async { self.setStatus(UStatus(text: text)) }
        }
        if env["MM9U_PAGE"] == nil { checkGitHub() }
        if env["MM9U_PAGE"] == nil || env["MM9U_FIXES_FILE"] != nil { loadFixes() }
    }

    /// Silent on any error.
    func checkGitHub() {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/opimuusikat/Might-and-Magic-IX-MacOS/releases/latest")!, timeoutInterval: 6)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept"); req.setValue("MM9-Native-Updater", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], var tag = j["tag_name"] as? String else { return }
            if tag.hasPrefix("v") || tag.hasPrefix("V") { tag.removeFirst() }
            let a = tag.split(separator: ".").map { Int($0) ?? 0 }, b = bundledVersion.split(separator: ".").map { Int($0) ?? 0 }
            for i in 0..<max(a.count, b.count) {
                let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
                if x != y { if x > y { DispatchQueue.main.async { self.newer = tag } }; return }
            }
        }.resume()
    }

    var forced: Bool { (status?.appUpdate ?? false) || (fixesState != "loading" && selectedFix != installedFix) }
    var willRun: Bool { forced || rebuild || movies }

    /// Backs up the saves (if asked), then runs the bundled builder on the existing game copy.
    func startUpdate() {
        guard let s = status, let res = Bundle.main.resourceURL else { return }
        let builder = res.appendingPathComponent("builder/src/build.sh").path
        var env = ProcessInfo.processInfo.environment
        env["MM9N_DIALOGS"] = "0"; env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        env["MM9N_GAME"] = nil; env["MM9N_INSTALLER"] = nil
        env["MM9N_FFMPEG_DOWNLOAD"] = movies ? "1" : "0"
        env["MM9N_FIX"] = selectedFix.isEmpty ? "none" : selectedFix
        env["MM9N_SUPPORT"] = s["app_support"]; env["MM9N_APPDIR"] = s.appDir
        backupDir = nil
        runner.step = 0; runner.stepTitle = "Starting"; runner.tail = []; runner.started = Date(); runner.phase = .running
        guard backup && s.saves > 0 else { runner.start(builder: builder, env: env); return }
        let support = s["app_support"]
        runner.tail = ["Backing up saved games…"]
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Self.backupSaves(support: support)
            DispatchQueue.main.async {
                switch r {
                case .success(let dir):
                    self.backupDir = dir
                    self.runner.start(builder: builder, env: env, preface: ["Saved games backed up to \(dir)"])
                case .failure(let e): self.runner.phase = .failed("The saved games could not be backed up, so nothing was changed.\n\(e.message)")
                }
            }
        }
    }

    struct BackupError: Error { let message: String }
    static func backupSaves(support: String) -> Result<String, BackupError> {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let stamp = f.string(from: Date()), dir = support + "/backups", dst = "\(dir)/SaveGames-\(stamp)"
        func cp(_ args: [String]) -> Bool {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/cp"); p.arguments = args
            p.standardOutput = Pipe(); p.standardError = Pipe()
            guard (try? p.run()) != nil else { return false }
            p.waitUntilExit(); return p.terminationStatus == 0
        }
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        catch { return .failure(BackupError(message: "Cannot create \(dir).")) }
        if !cp(["-c", "-R", support + "/game/SaveGames", dst]) {
            try? FileManager.default.removeItem(atPath: dst)
            if !cp(["-R", support + "/game/SaveGames", dst]) { try? FileManager.default.removeItem(atPath: dst); return .failure(BackupError(message: "Copying \(support)/game/SaveGames to \(dst) failed.")) }
        }
        if FileManager.default.fileExists(atPath: support + "/game/autoexec.cfg") { _ = cp([support + "/game/autoexec.cfg", "\(dir)/autoexec-\(stamp).cfg"]) }
        return .success(dst)
    }

    func play() { if let p = status?["app_path"], !p.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } }
}

// MARK: - Window

enum UPage { case welcome, analysis, fixes, components, install }

struct UpdaterRoot: View {
    @ObservedObject var m: UpdaterModel
    let live: Bool
    @State private var page: UPage
    @State private var launch = true
    @State private var cltOK: Bool
    @State private var freeGB: Double
    @State private var showDetails = false
    @State private var tick = Date()
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(m: UpdaterModel, live: Bool) {
        self.m = m; self.live = live
        _page = State(initialValue: m.startPage)
        _cltOK = State(initialValue: live ? commandLineToolsReady() : true)
        _freeGB = State(initialValue: live ? freeDiskGB() : 212)
        _showDetails = State(initialValue: ProcessInfo.processInfo.environment["MM9U_DETAILS"] != nil)   // for screenshots
    }

    var body: some View {
        VStack(spacing: 0) {
            XPTitleBar(title: "Might and Magic IX Native Updater") { if m.runner.phase == .running { m.runner.cancel() }; NSApp.terminate(nil) }
            ZStack {
                xpBeige
                VStack(spacing: 0) {
                    switch page {
                    case .welcome: welcome
                    case .analysis: XPWizardPage(title: "Checking Your Installation", subtitle: "Setup is looking at what is on this Mac.") { analysis }
                    case .fixes: XPWizardPage(title: "Bug-Fix Version", subtitle: "Choose which in-game bug-fix set MM9 Native is built with.") { fixesPage }
                    case .components: XPWizardPage(title: "Select Components", subtitle: "Choose what Setup should update on your Mac.") { components }
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
        .environment(\.xpStatic, !live)
        .background(live ? AnyView(WindowSetup()) : AnyView(EmptyView()))
        .onReceive(timer) { tick = $0; if live && page == .components { cltOK = commandLineToolsReady(); freeGB = freeDiskGB() } }
        .onChange(of: m.runner.phase) { ph in if ph == .idle && page == .install { page = .components } }   // cancelled
    }

    // MARK: pages
    var welcome: some View {
        HStack(spacing: 0) {
            Banner()
            VStack(alignment: .leading, spacing: 12) {
                Text("Welcome to the Might and Magic IX Native Updater").font(tahoma(14, bold: true))
                Text("This wizard checks which build of MM9 Native you have and brings it up to date with this updater's builder, version \(bundledVersion). Your saves, settings and HD textures stay.").font(tahoma())
                let notes = releaseNotes()
                if !notes.isEmpty {
                    Text("What's new in \(bundledVersion):").font(tahoma(11, bold: true))
                    SunkenBox {
                        XPScroll { VStack(alignment: .leading, spacing: 3) {
                            ForEach(0..<notes.count, id: \.self) { Text(notes[$0]).font(tahoma(11)) }
                        }.padding(6).frame(maxWidth: .infinity, alignment: .leading) }
                    }.frame(height: 90)
                }
                Spacer()
                Text("Click Next to continue.").font(tahoma())
                GitHubLink()
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color.white)
        }
    }

    var analysis: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = m.status, !m.analysing {
                SunkenBox {
                    XPScroll { VStack(alignment: .leading, spacing: 5) {
                        ForEach(0..<s.rows.count, id: \.self) { XPStatusRow(level: s.rows[$0].0, text: s.rows[$0].1) { EmptyView() } }
                    }.padding(6).frame(maxWidth: .infinity, alignment: .leading) }
                }.frame(height: 124)
                verdict(s)
                if let n = m.newer {
                    HStack(spacing: 6) {
                        Text("A newer updater (v\(n)) is on GitHub.").font(tahoma())
                        XPLink(url: releasesPage, text: "Open the releases page")
                    }
                }
                if m.fixesState == "ok", !m.recommendedFix.isEmpty, m.recommendedFix != m.installedFix {
                    Text("A newer bug-fix variant is available (\(m.recommendedFix)). Click Next to choose.").font(tahoma())
                }
                Spacer(minLength: 0)
            } else {
                Text("Looking at your MM9 Native, the game copy, the tools and this Mac. This takes a few seconds.").font(tahoma())
                XPProgress(fraction: 0, running: true).padding(.top, 8)
                Spacer(minLength: 0)
            }
        }
    }
    @ViewBuilder func verdict(_ s: UStatus) -> some View {
        if !s.ok {
            Text("The check could not be run.").font(tahoma(11, bold: true)).foregroundColor(Color(hex: 0xC8381A))
        } else if !s.blocker.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(s.blocker).font(tahoma(11, bold: true)).foregroundColor(Color(hex: 0xC8381A)).fixedSize(horizontal: false, vertical: true)
                if s["mac_arm64"] == "1" {
                    XPLink(url: releasesPage, text: "Get the MM9 Native Installer from the releases page")
                }
            }
        } else if s.updateNeeded {
            VStack(alignment: .leading, spacing: 3) {
                Text("An update is available.").font(tahoma(11, bold: true))
                ForEach(0..<min(s.reasons.count, 3), id: \.self) { Text("• " + s.reasons[$0]).font(tahoma()).fixedSize(horizontal: false, vertical: true) }
            }
        } else {
            Text("MM9 Native is up to date.").font(tahoma(11, bold: true)).foregroundColor(Color(hex: 0x21A121))
        }
    }

    func fixLabel(_ f: UFix) -> String {
        var t = "\(f.date)  \(f.title)"
        if f.id == m.installedFix { t += "   [installed]" }
        if f.id == m.recommendedFix { t += "   [recommended]" } else if !f.stable { t += "   [not marked stable yet]" }
        return t
    }
    var fixesPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(m.installedFix.isEmpty ? "You have: no bug-fix variant (builder \(bundledVersion) as shipped)." : "You have: \(m.installedFix) \(m.installedFixTitle.isEmpty ? "" : "– " + m.installedFixTitle)")
                .font(tahoma(11, bold: true)).lineLimit(2)
            if m.fixesState == "loading" {
                Text("Looking for bug-fix variants on GitHub…").font(tahoma())
                XPProgress(fraction: 0, running: true).padding(.top, 4)
            } else if m.fixesState == "offline" {
                Text("The list of bug-fix variants could not be loaded (no internet, or GitHub did not answer). You can go on; the app keeps the variant it has, but a rebuild then needs the internet to fetch it again.")
                    .font(tahoma()).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The last \(m.fixes.count) available. The installer picks the newest one marked stable.").font(tahoma())
                SunkenBox {
                    XPScroll { VStack(alignment: .leading, spacing: 5) {
                        ForEach(m.fixes) { f in XPRadio(title: fixLabel(f), on: m.selectedFix == f.id) { m.selectFix(f.id) } }
                        XPRadio(title: "No bug-fix variant (builder \(bundledVersion) as shipped)", on: m.selectedFix.isEmpty) { m.selectFix("") }
                    }.padding(6).frame(maxWidth: .infinity, alignment: .leading) }
                }.frame(height: 122)
                if let f = m.fixes.first(where: { $0.id == m.selectedFix }), !f.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(0..<f.notes.count, id: \.self) { Text("\u{2022} " + f.notes[$0]).font(tahoma()).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                if !(m.fixes.first(where: { $0.id == m.selectedFix })?.stable ?? true) {
                    Text("This variant is not marked stable yet. It may have new problems.").font(tahoma()).foregroundColor(Color(hex: 0xA05A00))
                }
            }
            Spacer(minLength: 0)
            Text(m.selectedFix == m.installedFix ? "Nothing changes in the bug fixes." : "Switching variant rebuilds the app (5 to 30 minutes). Your saves stay.")
                .font(tahoma()).foregroundColor(Color(hex: 0x555555))
        }
    }

    var components: some View {
        let s = m.status ?? UStatus(text: "")
        let ff = s["ffmpeg"]
        return VStack(alignment: .leading, spacing: 9) {
            XPCheck(title: m.forced ? "Rebuild the MM9 Native app with builder \(bundledVersion)" : "Rebuild anyway (repair)", on: $m.rebuild, locked: m.forced)
            XPCheck(title: "Intro movies: \(ff == "missing" ? "download" : ff == "update" ? "update" : "keep") ffmpeg (about 28 MB)", on: $m.movies)
            Text(!m.rebuild && m.movies ? "Updating runs the whole builder, so the app is rebuilt too." : "Without ffmpeg the game still works, but skips its logo and intro movies.")
                .font(tahoma()).foregroundColor(Color(hex: 0x555555)).padding(.leading, 19)
            XPCheck(title: "Back up saved games first (\(s.saves) saved games, \(s["saves_mb"]) MB)", on: $m.backup)
            Etched().padding(.vertical, 4)
            XPMacChecks(cltOK: cltOK, freeGB: freeGB)
        }
    }

    var installPage: some View {
        switch m.runner.phase {
        case .done: return AnyView(finishDone)
        case .failed(let msg): return AnyView(finishFailed(msg))
        default: return AnyView(installing)
        }
    }

    var installing: some View {
        let elapsed = max(Int(tick.timeIntervalSince(m.runner.started)), 0), r = m.runner
        return HStack(spacing: 0) {
            Banner()
            VStack(alignment: .leading, spacing: 10) {
                Text("Updating").font(.custom("Georgia Bold", size: 16)).foregroundColor(Color(hex: 0x3B2410))
                Text("Please wait while MM9 Native is rebuilt…").font(tahoma())
                Text("Step \(r.step) of \(r.steps): \(r.stepTitle)").font(tahoma(11, bold: true)).lineLimit(2).padding(.top, 6)
                XPProgress(fraction: Double(max(r.step - 1, 0)) / Double(r.steps), running: true)
                Text("Elapsed: \(elapsed / 60) min \(elapsed % 60) s. Keep this window open; the Mac stays awake until the update is done.").font(tahoma()).foregroundColor(Color(hex: 0x555555))
                XPCheck(title: "Show details", on: $showDetails)
                if showDetails {
                    SunkenBox {
                        XPScroll { Text(r.tail.suffix(60).joined(separator: "\n")).font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(4).textSelection(.enabled) }
                    }.frame(height: 90)
                }
                Spacer(minLength: 0)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(xpBeige)
        }
    }

    var finishDone: some View {
        let app = m.status?["app_path"] ?? ""
        return HStack(spacing: 0) {
            Banner(dawn: true, gameIcon: !app.isEmpty && FileManager.default.fileExists(atPath: app) ? NSWorkspace.shared.icon(forFile: app) : nil)
            VStack(alignment: .leading, spacing: 12) {
                Text("Completing the Might and Magic IX Native Updater").font(tahoma(14, bold: true))
                Text("MM9 Native was updated to builder \(bundledVersion)\(m.selectedFix.isEmpty ? "" : ", bug-fix variant \(m.selectedFix)").").font(tahoma())
                Text(m.backupDir.map { "Your saved games were backed up first, to \($0)." } ?? "No backup of the saved games was made. They were not touched.").font(tahoma()).foregroundColor(Color(hex: 0x555555))
                Spacer()
                XPCheck(title: "Launch MM9 Native", on: $launch)
                Text("Click Finish to close the wizard.").font(tahoma())
                GitHubLink()
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color.white)
        }
    }

    func finishFailed(_ msg: String) -> some View {
        XPWizardPage(title: "Update failed", subtitle: "The update stopped before it was finished.") {
            VStack(alignment: .leading, spacing: 8) {
                SunkenBox { XPScroll { Text(msg).font(tahoma()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6) } }.frame(height: 110)
                HStack { XPButton(title: "Copy log") { m.runner.copyLog() }; XPButton(title: "Show log") { m.runner.showLog() } }
                Text("Your previous MM9 Native app was not changed.").font(tahoma(11, bold: true))
                Text("If you ask for help, send the log. It holds tool output and file names only.").font(tahoma()).foregroundColor(Color(hex: 0x555555))
            }
        }
    }

    // MARK: buttons
    var buttons: some View {
        let s = m.status
        return HStack(spacing: 8) {
            Spacer()
            switch (page, m.runner.phase) {
            case (.install, .done):
                XPButton(title: "Finish", isDefault: true) { if launch { m.play() }; NSApp.terminate(nil) }
            case (.install, .failed):
                XPButton(title: "< Back") { m.runner.phase = .idle }
                XPButton(title: "Try Again", isDefault: true) { m.startUpdate() }
                XPButton(title: "Close") { NSApp.terminate(nil) }
            case (.install, _):
                XPButton(title: "< Back").disabled(true)
                XPButton(title: "Next >").disabled(true)
                XPButton(title: "Cancel") { m.runner.cancel() }
            default:
                XPButton(title: "< Back") { back() }.disabled(page == .welcome)
                XPButton(title: page == .components ? "Update" : "Next >", isDefault: true) { next() }.disabled(!canNext)
                XPButton(title: page == .analysis && s != nil && s!.ok && s!.blocker.isEmpty && !s!.updateNeeded ? "Close" : "Cancel") { NSApp.terminate(nil) }
            }
        }
    }
    var canNext: Bool {
        switch page {
        case .welcome: return true
        case .analysis: return !m.analysing && (m.status?.ok ?? false) && (m.status?.blocker.isEmpty ?? false)
        case .fixes: return m.fixesState != "loading"
        case .components: return m.willRun && cltOK && freeGB >= 4 && (m.status?.blocker.isEmpty ?? false)
        case .install: return false
        }
    }
    func next() {
        switch page {
        case .welcome: page = .analysis; m.analyse()
        case .analysis: page = .fixes
        case .fixes: page = .components; cltOK = commandLineToolsReady(); freeGB = freeDiskGB()
        case .components: page = .install; m.startUpdate()
        case .install: break
        }
    }
    func back() {
        switch page { case .analysis: page = .welcome; case .fixes: page = .analysis; case .components: page = .fixes; case .install: page = .components; default: break }
    }
}

struct ContentView: View {
    @StateObject var m = UpdaterModel()
    var body: some View { UpdaterRoot(m: m, live: true) }
}

/// App icon: the installer's logo tile with a small green "update" badge. Rendered by `MM9Updater --render-icon out.png`.
struct UpdaterIconArt: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AppIconArt()
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(hex: 0x5BD65B), Color(hex: 0x1E9A1E)], startPoint: .top, endPoint: .bottom))
                Circle().stroke(.white, lineWidth: 14)
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 170, weight: .bold)).foregroundColor(.white)
            }
            .frame(width: 340, height: 340).shadow(color: .black.opacity(0.45), radius: 14, y: 10)
            .padding(.trailing, 50).padding(.bottom, 50)
        }.frame(width: 1024, height: 1024)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MM9UpdaterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    init() {
        xpTheme = .olive   // Luna Olive Green for the updater; the installer stays Luna Blue
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--render-icon"), i + 1 < a.count {
            renderPNG(UpdaterIconArt(), to: a[i + 1], scale: 1)
            exit(0)
        }
        if let i = a.firstIndex(of: "--render-page"), i + 2 < a.count {
            let page = a[i + 1]
            let m = UpdaterModel(sample: page == "welcome" ? "welcome" : page)
            renderPNG(UpdaterRoot(m: m, live: false), to: a[i + 2])
            exit(0)
        }
    }
    var body: some Scene {
        WindowGroup("MM9 Native Updater") { ContentView() }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
    }
}
