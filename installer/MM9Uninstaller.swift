// MM9 Native Uninstaller: a Windows XP style wizard (Luna-style red) that removes what the MM9 Native Installer
// and Updater put on this Mac: the app, the game copy and build files, the build tools and the game's settings.
// Saved games stay unless the player asks otherwise. Everything goes to the Trash, so it can be put back.
// The Wine version of the game ("Might and Magic IX.app" and its folder) is never touched.
// Nothing from the game is in this app. MIT licence (see LICENSES/). Shares XPKit.swift with the installer.
import SwiftUI

let toolsCache = "\(home)/Library/Application Support/MM9 Native Builder"
let oldToolsCache = "\(home)/Library/Caches/MM9 Native Builder"     // builder 1.0's default
let prefDomain = "local.mm9-native"
let prefFiles = ["\(home)/Library/Preferences/\(prefDomain).plist", "\(home)/Library/Saved Application State/\(prefDomain).savedState"]
let appMarker = "Contents/Resources/mm9native-builder.txt"
/// Kept inside the game copy when the saves stay: the saves, the game's own settings file and the HD texture packs.
let keptInGame: Set<String> = ["SaveGames", "autoexec.cfg", "HDTextures"]

func sizeOf(_ path: String) -> Int64 {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
    if !isDir.boolValue { return Int64((try? URL(fileURLWithPath: path).resourceValues(forKeys: Set(keys)))?.totalFileAllocatedSize ?? 0) }
    var total: Int64 = 0
    if let e = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys) {
        for case let u as URL in e {
            if let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true { total += Int64(v.totalFileAllocatedSize ?? 0) }
        }
    }
    return total
}
func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
func children(_ dir: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }.sorted() }

// MARK: - What is on this Mac

struct Found {
    var appPaths: [String] = []        // MM9 Native.app made by the builder
    var foreignApps: [String] = []     // an "MM9 Native.app" the builder did not make: left alone
    var appSize: Int64 = 0
    var supportPresent = false
    var supportSize: Int64 = 0         // the whole support folder
    var savesSize: Int64 = 0           // what stays when the saves are kept
    var saves = 0
    var toolsPresent = false
    var toolsSize: Int64 = 0
    var prefsPresent = false
    var wineApp = false
    var nothing: Bool { appPaths.isEmpty && !supportPresent && !toolsPresent && !prefsPresent }

    static func scan() -> Found {
        let fm = FileManager.default
        var f = Found()
        for d in ["\(home)/Applications", "/Applications"] {
            let p = "\(d)/MM9 Native.app"
            guard fm.fileExists(atPath: p) else { continue }
            if fm.fileExists(atPath: "\(p)/\(appMarker)") { f.appPaths.append(p); f.appSize += sizeOf(p) } else { f.foreignApps.append(p) }
        }
        f.supportPresent = fm.fileExists(atPath: supportDir)
        if f.supportPresent {
            f.supportSize = sizeOf(supportDir)
            f.saves = children("\(gameCopy)/SaveGames").count
            f.savesSize = keptInGame.reduce(sizeOf("\(supportDir)/backups")) { $0 + sizeOf("\(gameCopy)/\($1)") }
        }
        f.toolsPresent = fm.fileExists(atPath: toolsCache) || fm.fileExists(atPath: oldToolsCache)
        f.toolsSize = sizeOf(toolsCache) + sizeOf(oldToolsCache)
        f.prefsPresent = prefFiles.contains { fm.fileExists(atPath: $0) }
        f.wineApp = fm.fileExists(atPath: "/Applications/Might and Magic IX.app") || fm.fileExists(atPath: "\(home)/Applications/Might and Magic IX.app")
        return f
    }

    static let sample: Found = {
        var f = Found()
        f.appPaths = ["/Users/you/Applications/MM9 Native.app"]; f.appSize = 61_000_000
        f.supportPresent = true; f.supportSize = 1_420_000_000; f.savesSize = 3_100_000; f.saves = 12
        f.toolsPresent = true; f.toolsSize = 812_000_000; f.prefsPresent = true; f.wineApp = true
        return f
    }()
}

// MARK: - Model

final class UninstallModel: ObservableObject {
    @Published var found: Found?
    @Published var removeApp = true
    @Published var removeGame = true
    @Published var removeSaves = false
    @Published var removeTools = true
    @Published var removePrefs = true
    @Published var phase: Phase = .idle
    @Published var step = 0
    @Published var steps = 1
    @Published var stepTitle = "Starting"
    @Published var log: [String] = []
    @Published var freed: Int64 = 0
    @Published var gameRunning = false
    var startPage: XPage = .welcome
    let live: Bool

    init(sample: String? = nil) {
        let page = sample ?? ProcessInfo.processInfo.environment["MM9X_PAGE"]
        live = page == nil
        guard let page = page else { return }
        found = Found.sample
        switch page {
        case "components": startPage = .components
        case "uninstall": startPage = .uninstall; phase = .running; step = 2; steps = 4; stepTitle = "Moving the game copy and build files to the Trash"
            log = ["Moved to the Trash: /Users/you/Applications/MM9 Native.app", "Kept: /Users/you/Library/Application Support/MM9 Native/game/SaveGames"]
        case "done": startPage = .uninstall; phase = .done; freed = 2_290_000_000
        case "failed": startPage = .uninstall; phase = .failed("Could not move /Applications/MM9 Native.app to the Trash: you don't have permission to access it.")
        default: break
        }
    }

    func scan() {
        guard live else { return }
        found = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let f = Found.scan()
            DispatchQueue.main.async {
                self.found = f
                self.removeApp = !f.appPaths.isEmpty; self.removeGame = f.supportPresent
                self.removeTools = f.toolsPresent; self.removePrefs = f.prefsPresent
            }
        }
    }

    func checkRunning() { if live { gameRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: prefDomain).isEmpty } }
    func quitGame() { NSRunningApplication.runningApplications(withBundleIdentifier: prefDomain).forEach { $0.terminate() } }

    var anything: Bool { removeApp || removeGame || removeTools || removePrefs }
    var keepsSaves: Bool { removeGame && !removeSaves && (found?.savesSize ?? 0) > 0 }
    var toFree: Int64 {
        guard let f = found else { return 0 }
        return (removeApp ? f.appSize : 0) + (removeGame ? f.supportSize - (removeSaves ? 0 : f.savesSize) : 0) + (removeTools ? f.toolsSize : 0)
    }

    /// Moves the chosen items to the Trash, one group per step.
    func start() {
        guard let f = found, phase != .running else { return }
        var plan: [(String, () throws -> Void)] = []
        if removeApp && !f.appPaths.isEmpty { plan.append(("Moving MM9 Native to the Trash", { for p in f.appPaths { try self.trash(p) } })) }
        if removeGame && f.supportPresent {
            let keep = !removeSaves
            plan.append((keep ? "Moving the game copy and build files to the Trash" : "Moving the game copy, saved games and build files to the Trash", {
                guard keep else { try self.trash(supportDir); return }
                for c in children(supportDir) where c != "backups" {
                    if c == "game" { for g in children(gameCopy) where !keptInGame.contains(g) { try self.trash("\(gameCopy)/\(g)") } }
                    else { try self.trash("\(supportDir)/\(c)") }
                }
                for k in keptInGame.sorted() where FileManager.default.fileExists(atPath: "\(gameCopy)/\(k)") { self.note("Kept: \(gameCopy)/\(k)") }
                if FileManager.default.fileExists(atPath: "\(supportDir)/backups") { self.note("Kept: \(supportDir)/backups") }
            }))
        }
        if removeTools && f.toolsPresent { plan.append(("Moving the build tools to the Trash", { for p in [toolsCache, oldToolsCache] { try self.trash(p) } })) }
        if removePrefs && f.prefsPresent {
            plan.append(("Removing the game's settings", {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults"); p.arguments = ["delete", prefDomain]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                if (try? p.run()) != nil { p.waitUntilExit() }
                for p in prefFiles { try self.trash(p) }
            }))
        }
        steps = max(plan.count, 1); step = 0; log = []; freed = 0; phase = .running
        let expected = toFree
        DispatchQueue.global(qos: .userInitiated).async {
            for (i, (title, work)) in plan.enumerated() {
                DispatchQueue.main.async { self.step = i + 1; self.stepTitle = title }
                do { try work() }
                catch {
                    DispatchQueue.main.async { self.phase = .failed(error.localizedDescription) }
                    return
                }
            }
            DispatchQueue.main.async { self.freed = expected; self.step = self.steps; self.phase = .done }
        }
    }

    private func note(_ s: String) { DispatchQueue.main.async { self.log.append(s) } }
    /// To the Trash; deleted outright only where the volume has no Trash.
    private func trash(_ path: String) throws {
        let fm = FileManager.default, u = URL(fileURLWithPath: path)
        guard fm.fileExists(atPath: path) else { return }
        do { try fm.trashItem(at: u, resultingItemURL: nil); note("Moved to the Trash: \(path)") }
        catch let e as CocoaError where e.code == .featureUnsupported { try fm.removeItem(at: u); note("Deleted: \(path)") }
        catch { throw NSError(domain: "MM9", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not move \(path) to the Trash: \(error.localizedDescription)"]) }
    }

    func openTrash() { NSWorkspace.shared.open(URL(fileURLWithPath: "\(home)/.Trash")) }
}

// MARK: - Window

enum XPage { case welcome, components, uninstall }

struct UninstallerRoot: View {
    @ObservedObject var m: UninstallModel
    @State private var page: XPage
    @State private var showDetails = false
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(m: UninstallModel) { self.m = m; _page = State(initialValue: m.startPage) }

    var body: some View {
        VStack(spacing: 0) {
            XPTitleBar(title: "Might and Magic IX Native Uninstall") { if m.phase != .running { NSApp.terminate(nil) } }
            ZStack {
                xpBeige
                VStack(spacing: 0) {
                    switch page {
                    case .welcome: welcome
                    case .components: XPWizardPage(title: "Choose What to Remove", subtitle: "Tick the parts of MM9 Native you want to remove.") { components }
                    case .uninstall: uninstallPage
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
        .environment(\.xpStatic, !m.live)
        .background(m.live ? AnyView(WindowSetup()) : AnyView(EmptyView()))
        .onReceive(timer) { _ in if page == .components { m.checkRunning() } }
    }

    // MARK: pages
    var welcome: some View {
        HStack(spacing: 0) {
            Banner()
            VStack(alignment: .leading, spacing: 12) {
                Text("Welcome to the Might and Magic IX Native Uninstall Wizard").font(tahoma(14, bold: true))
                Text("This wizard removes MM9 Native from your Mac: the app, the game copy it was built from, the build tools and the game's settings.").font(tahoma())
                Text("Your saved games are kept unless you choose to remove them. Everything goes to the Trash, so you can still put it back.").font(tahoma())
                Text("The Wine version of the game (Might and Magic IX.app) and your GOG installer are not touched.").font(tahoma()).foregroundColor(Color(hex: 0x555555))
                Spacer()
                Text("Click Next to continue.").font(tahoma())
                GitHubLink()
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color.white)
        }
    }

    @ViewBuilder var components: some View {
        if let f = m.found {
            if f.nothing {
                VStack(alignment: .leading, spacing: 8) {
                    XPStatusRow(level: .info, text: "MM9 Native is not installed on this Mac. There is nothing to remove.") { EmptyView() }
                    ForEach(f.foreignApps, id: \.self) { p in
                        XPStatusRow(level: .warn, text: "\(p) was not made by the MM9 Native builder, so it is left alone.") { EmptyView() }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    row("MM9 Native app", f.appSize, on: $m.removeApp, present: !f.appPaths.isEmpty)
                    row("Game copy, logs and build files", f.supportSize - f.savesSize, on: $m.removeGame, present: f.supportPresent)
                    XPCheck(title: "Also remove my saved games (\(f.saves) saved games, HD textures, backups: \(bytes(f.savesSize)))",
                            on: Binding(get: { m.removeGame && m.removeSaves }, set: { m.removeSaves = $0 }), locked: !m.removeGame || f.savesSize == 0)
                        .padding(.leading, 19)
                    row("Build tools: Ghidra, Java 21 and Unicorn", f.toolsSize, on: $m.removeTools, present: f.toolsPresent)
                    row("Game settings (graphics and window options)", 0, on: $m.removePrefs, present: f.prefsPresent)
                    Etched().padding(.vertical, 3)
                    if m.removeGame && m.removeSaves {
                        XPStatusRow(level: .warn, text: "Your saved games will go to the Trash too. Empty the Trash only if you are sure.") { EmptyView() }
                    } else if m.removeGame && f.savesSize > 0 {
                        XPStatusRow(level: .info, text: "Saved games stay in ~/Library/Application Support/MM9 Native.") { EmptyView() }
                    }
                    if m.gameRunning {
                        XPStatusRow(level: .bad, text: "MM9 Native is running. Quit it first.") { XPButton(title: "Quit Game") { m.quitGame() } }
                    }
                    ForEach(f.foreignApps, id: \.self) { p in
                        XPStatusRow(level: .warn, text: "\(p) was not made by the builder; it is left alone.") { EmptyView() }
                    }
                    Spacer(minLength: 0)
                    Text("Space freed after you empty the Trash: \(bytes(m.toFree)).").font(tahoma(11, bold: true))
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Looking for MM9 Native on this Mac…").font(tahoma())
                XPProgress(fraction: 0, running: true).padding(.top, 4)
                Spacer(minLength: 0)
            }
        }
    }
    func row(_ title: String, _ size: Int64, on: Binding<Bool>, present: Bool) -> some View {
        let label = present ? (size > 0 ? "\(title) (\(bytes(size)))" : title) : "\(title): not found"
        return XPCheck(title: label, on: present ? on : .constant(false), locked: !present)
    }

    var uninstallPage: some View {
        switch m.phase {
        case .done: return AnyView(finishDone)
        case .failed(let msg): return AnyView(finishFailed(msg))
        default: return AnyView(removing)
        }
    }

    var removing: some View {
        HStack(spacing: 0) {
            Banner()
            VStack(alignment: .leading, spacing: 10) {
                Text("Uninstalling").font(.custom("Georgia Bold", size: 16)).foregroundColor(Color(hex: 0x3B2410))
                Text("Please wait while MM9 Native is removed from your Mac.").font(tahoma())
                Text("Step \(m.step) of \(m.steps): \(m.stepTitle)").font(tahoma(11, bold: true)).lineLimit(2).padding(.top, 6)
                XPProgress(fraction: Double(max(m.step - 1, 0)) / Double(m.steps), running: true)
                XPCheck(title: "Show details", on: $showDetails)
                if showDetails { details }
                Spacer(minLength: 0)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(xpBeige)
        }
    }
    var details: some View {
        SunkenBox {
            XPScroll { Text(m.log.joined(separator: "\n")).font(.system(size: 10, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading).padding(4).textSelection(.enabled) }
        }.frame(height: 90)
    }

    var finishDone: some View {
        HStack(spacing: 0) {
            Banner(dawn: true)
            VStack(alignment: .leading, spacing: 12) {
                Text("Completing the Might and Magic IX Native Uninstall Wizard").font(tahoma(14, bold: true))
                Text("MM9 Native was removed. The removed items are in the Trash; empty it to free \(bytes(m.freed)).").font(tahoma())
                if m.keepsSaves {
                    Text("Your saved games were kept in ~/Library/Application Support/MM9 Native. If you install MM9 Native again, they are still there.").font(tahoma()).foregroundColor(Color(hex: 0x555555))
                }
                if m.found?.wineApp ?? false {
                    Text("The Wine version of the game was not touched.").font(tahoma()).foregroundColor(Color(hex: 0x555555))
                }
                XPCheck(title: "Show details", on: $showDetails)
                if showDetails { details }
                Spacer()
                Text("Click Finish to close the wizard.").font(tahoma())
                GitHubLink()
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color.white)
        }
    }

    func finishFailed(_ msg: String) -> some View {
        XPWizardPage(title: "Uninstall stopped", subtitle: "Some items could not be removed.") {
            VStack(alignment: .leading, spacing: 8) {
                SunkenBox { XPScroll { Text(msg).font(tahoma()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6) } }.frame(height: 70)
                Text("What was already removed is in the Trash. You can drag the rest to the Trash in Finder, or try again.").font(tahoma()).fixedSize(horizontal: false, vertical: true)
                if !m.log.isEmpty { details }
            }
        }
    }

    // MARK: buttons
    var buttons: some View {
        HStack(spacing: 8) {
            Spacer()
            switch (page, m.phase) {
            case (.uninstall, .done):
                XPButton(title: "Open Trash") { m.openTrash() }
                XPButton(title: "Finish", isDefault: true) { NSApp.terminate(nil) }
            case (.uninstall, .failed):
                XPButton(title: "< Back") { m.phase = .idle; page = .components; m.scan() }
                XPButton(title: "Try Again", isDefault: true) { m.start() }
                XPButton(title: "Close") { NSApp.terminate(nil) }
            case (.uninstall, _):
                XPButton(title: "< Back").disabled(true)
                XPButton(title: "Next >").disabled(true)
                XPButton(title: "Cancel").disabled(true)
            default:
                XPButton(title: "< Back") { page = .welcome }.disabled(page == .welcome)
                XPButton(title: page == .components ? "Uninstall" : "Next >", isDefault: true) { next() }.disabled(!canNext)
                XPButton(title: m.found?.nothing ?? false ? "Close" : "Cancel") { NSApp.terminate(nil) }
            }
        }
    }
    var canNext: Bool {
        switch page {
        case .welcome: return true
        case .components: return m.found.map { !$0.nothing } ?? false && m.anything && !m.gameRunning
        case .uninstall: return false
        }
    }
    func next() {
        switch page {
        case .welcome: page = .components; m.scan(); m.checkRunning()
        case .components: page = .uninstall; m.start()
        case .uninstall: break
        }
    }
}

struct ContentView: View {
    @StateObject var m = UninstallModel()
    var body: some View { UninstallerRoot(m: m) }
}

/// App icon: the installer's logo tile with a small red "remove" badge. Rendered by `MM9Uninstaller --render-icon out.png`.
struct UninstallerIconArt: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AppIconArt()
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(hex: 0xF2826E), Color(hex: 0xB81E10)], startPoint: .top, endPoint: .bottom))
                Circle().stroke(.white, lineWidth: 14)
                Image(systemName: "trash.fill").font(.system(size: 160, weight: .bold)).foregroundColor(.white)
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
struct MM9UninstallerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    init() {
        xpTheme = .red   // Luna-style red for the uninstaller; the installer is blue, the updater olive green
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--render-icon"), i + 1 < a.count {
            renderPNG(UninstallerIconArt(), to: a[i + 1], scale: 1)
            exit(0)
        }
        // `--render-page welcome|components|uninstall|done|failed out.png`: README screenshot with sample values, no window.
        if let i = a.firstIndex(of: "--render-page"), i + 2 < a.count {
            renderPNG(UninstallerRoot(m: UninstallModel(sample: a[i + 1])), to: a[i + 2])
            exit(0)
        }
    }
    var body: some Scene {
        WindowGroup("MM9 Native Uninstaller") { ContentView() }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
    }
}
