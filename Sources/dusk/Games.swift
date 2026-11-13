// Standard while a game runs, and HiDPI kept when monitors come and go. Both run in `dusk tint`.
//
// A game on a monitor in HiDPI draws at twice the size, or at the monitor's size scaled up, and HiDPI
// modes drawn at 5K or so can't reach the highest refresh rates. So when a game starts, every external
// monitor in HiDPI switches to the standard mode of the same size, at its highest refresh rate, and
// back when the last game quits. Only then: each switch blanks the monitor for a moment, so switching
// between apps changes nothing.
//
// Games are found by what they do, with no list of them: the app in front fills a display and keeps
// the GPU busy, or fills a display and says it is a game in its Info.plist. That holds for Wine
// programs, games started as a bare executable and ports alike, while full-screen videos, browsers and
// documents leave their app's GPU time low. The GPU driver keeps that time per process in the
// IORegistry. `dusk set game <app> on|off` is for an app it gets wrong.
//
// macOS saves the display modes per set of connected monitors. A set it hasn't seen in HiDPI, like one
// monitor alone while the other is off, comes up in standard. With `dusk set hidpi on`, monitors that
// were in HiDPI before monitors attached, left or woke are put back in it.

import AppKit
import IOKit
import notify

/// An app in front that fills a display is a game once its GPU time has been at least this share of
/// the time for this many 2 s samples in a row. Games stay far above it even in their menus.
private let busyGPU = 0.15, busySamples = 2

/// What `dusk set game` matches, lowercased: the bundle ID, the name, the executable's name, and the
/// apps it is inside, such as a Wine wrapper.
private func names(_ app: NSRunningApplication) -> Set<String> {
    var names = [app.bundleIdentifier, app.localizedName]
    if let exe = app.executableURL {
        names.append(exe.lastPathComponent)
        names += exe.pathComponents.filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) as String? }
    }
    return Set(names.compactMap { $0?.lowercased() })
}

/// `dusk set game <app> on|off`: true for a game, false for not one, nil to go by what it does.
private func marked(_ app: NSRunningApplication, _ s: Settings) -> Bool? {
    let n = names(app)
    if s.notGames.contains(where: { n.contains($0.lowercased()) }) { return false }
    if s.games.contains(where: { n.contains($0.lowercased()) }) { return true }
    return nil
}

private func name(_ app: NSRunningApplication) -> String {
    app.localizedName ?? app.executableURL?.lastPathComponent ?? "a game"
}

/// Whether the app's Info.plist, or the one built into its executable, says it is a game; per bundle.
private var declared: [URL: Bool] = [:]

private func declaresGame(_ app: NSRunningApplication) -> Bool {
    guard let url = app.bundleURL ?? app.executableURL else { return false }
    if let known = declared[url] { return known }
    let info = CFBundleCopyInfoDictionaryForURL(url as CFURL) as? [String: Any]
    let category = info?["LSApplicationCategoryType"] as? String ?? ""
    let game = category == "public.app-category.games"
        || category.hasPrefix("public.app-category.") && category.hasSuffix("-games")
    declared[url] = game
    return game
}

/// Whether one of the process's windows covers a whole display: full screen, or a window that size.
private func fillsDisplay(_ pid: pid_t) -> Bool {
    let displays = onlineDisplays().map(CGDisplayBounds)
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.contains { w in
        guard w[kCGWindowOwnerPID as String] as? pid_t == pid, w[kCGWindowLayer as String] as? Int ?? -1 >= 0,
              let b = w[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: b as CFDictionary) else { return false }
        return displays.contains { bounds.contains($0) }
    }
}

/// The process's GPU time so far, in nanoseconds, from the GPU driver's clients in the IORegistry.
private func gpuTime(_ pid: pid_t) -> UInt64 {
    var total: UInt64 = 0
    for gpu in services("IOAccelerator") {
        defer { IOObjectRelease(gpu) }
        var clients: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(gpu, kIOServicePlane, &clients) == KERN_SUCCESS else { continue }
        defer { IOObjectRelease(clients) }
        while case let client = IOIteratorNext(clients), client != 0 {
            defer { IOObjectRelease(client) }
            // "pid 1234, name"
            guard (property(client, "IOUserClientCreator") as? String)?.hasPrefix("pid \(pid),") == true else { continue }
            for usage in property(client, "AppUsage") as? [[String: Any]] ?? [] {
                total += (usage["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0
            }
        }
    }
    return total
}

/// The games `dusk tint` found, by process: for `dusk status`, and for `dusk tint` itself if it restarts.
private let gamesKey = "gamesRunning"

func runningGames() -> [pid_t: String] {
    var games: [pid_t: String] = [:]
    for case let (pid, name as String) in Settings.store.dictionary(forKey: gamesKey) ?? [:] {
        if let pid = pid_t(pid), NSRunningApplication(processIdentifier: pid) != nil { games[pid] = name }
    }
    return games
}

/// The resident part of both: app launches and quits for games, display changes and wake for HiDPI.
final class ModeWatcher {
    private var games: [pid_t: String] = [:] {
        didSet {
            guard games != oldValue else { return }
            Settings.store.set(Dictionary(uniqueKeysWithValues: games.map { (String($0.key), $0.value) }), forKey: gamesKey)
        }
    }
    private var known: Set<pid_t> = []
    private var apps: NSKeyValueObservation?
    private var token: Int32 = 0
    /// Bumped to cancel a pending switch back after a game.
    private var quitGeneration = 0
    /// Looking at the app in front every 2 s, until `watchUntil`.
    private var timer: DispatchSourceTimer?
    private var watchUntil = Date.distantPast
    private var sample: (pid: pid_t, gpu: UInt64, at: UInt64, busy: Int)?
    /// Per monitor, whether it was in HiDPI when the displays last settled without a monitor
    /// attaching, leaving or waking: what to put back. Follows changes made in System Settings.
    private var wasHiDPI: [String: Bool] = [:]
    private var settleGeneration = 0
    /// Since the displays last settled: a monitor attached, left or woke.
    private var reconnected = false
    private var asleep = false

    init() {
        let s = Settings.load()
        let running = NSWorkspace.shared.runningApplications
        known = Set(running.map(\.processIdentifier))
        // Found before dusk tint restarted, or marked.
        games = runningGames()
        for app in running where marked(app, s) == true { games[app.processIdentifier] = name(app) }
        let workspace = NSWorkspace.shared
        // The list itself, since didLaunchApplication misses apps that start without a Dock icon.
        apps = workspace.observe(\.runningApplications) { [unowned self] _, _ in
            DispatchQueue.main.async { self.appsChanged() }
        }
        let center = workspace.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [unowned self] _ in watch(60) }
        }
        notify_register_dispatch(settingsChanged, &token, .main) { [unowned self] _ in marksChanged() }
        CGDisplayRegisterReconfigurationCallback({ _, flags, watcher in
            Unmanaged<ModeWatcher>.fromOpaque(watcher!).takeUnretainedValue().displaysChanged(flags)
        }, Unmanaged.passUnretained(self).toOpaque())
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [unowned self] _ in asleep = true }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [unowned self] _ in
                asleep = false
                reconnected = true
                settle()
            }
        }
        // Switched for a game when dusk tint last ran (or restarted): back once none runs.
        if games.isEmpty && gameModesSaved() { gamesQuit() }
        watch(60)
        settle()
    }

    private func appsChanged() {
        let s = Settings.load()
        let running = NSWorkspace.shared.runningApplications
        let pids = Set(running.map(\.processIdentifier))
        let launched = running.filter { !known.contains($0.processIdentifier) }
        known = pids
        let had = !games.isEmpty
        games = games.filter { pids.contains($0.key) }
        for app in launched where marked(app, s) == true { found(app) }
        // A game can take a few minutes to load and fill the screen.
        if launched.contains(where: { $0.activationPolicy != .prohibited }) { watch(300) }
        if had && games.isEmpty { gamesQuit() }
    }

    /// After `dusk set game`: running apps marked on are games, and ones marked off aren't.
    private func marksChanged() {
        let s = Settings.load()
        let had = !games.isEmpty
        for app in NSWorkspace.shared.runningApplications {
            switch marked(app, s) {
            case true?: if games[app.processIdentifier] == nil { found(app) }
            case false?: games[app.processIdentifier] = nil
            case nil: break
            }
        }
        if had && games.isEmpty { gamesQuit() }
    }

    private func found(_ app: NSRunningApplication) {
        let first = games.isEmpty
        let game = name(app)
        games[app.processIdentifier] = game
        guard first else { return }
        quitGeneration += 1
        if Settings.load().gameStandard { displayQueue.async { standardForGame(game) } }
    }

    /// Back to HiDPI 3 s after the last game quit, unless another starts meanwhile (a game that
    /// restarts itself, or a launcher handing over).
    private func gamesQuit() {
        quitGeneration += 1
        let generation = quitGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            guard generation == quitGeneration, games.isEmpty else { return }
            displayQueue.async { hiDPIAfterGames() }
        }
    }

    /// Look at the app in front every 2 s for a while: after an app starts, another comes to the front,
    /// a full-screen space opens or the displays change. Nothing runs in between.
    private func watch(_ seconds: TimeInterval) {
        watchUntil = max(watchUntil, Date() + seconds)
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        t.setEventHandler { [unowned self] in
            guard Date() < watchUntil else {
                timer?.cancel()
                timer = nil
                sample = nil
                return
            }
            lookAtFront()
        }
        t.resume()
        timer = t
    }

    /// A game is the app in front when it fills a display and either says it is a game or has kept
    /// the GPU busy for `busySamples` samples in a row.
    private func lookAtFront() {
        guard let app = NSWorkspace.shared.frontmostApplication, games[app.processIdentifier] == nil,
              app.processIdentifier != getpid(), marked(app, Settings.load()) == nil,
              fillsDisplay(app.processIdentifier) else {
            sample = nil
            return
        }
        if declaresGame(app) { return found(app) }
        let pid = app.processIdentifier
        let gpu = gpuTime(pid), now = DispatchTime.now().uptimeNanoseconds
        var busy = 0
        if let last = sample, last.pid == pid {
            let share = Double(gpu > last.gpu ? gpu - last.gpu : 0) / Double(now - last.at)
            busy = share >= busyGPU ? last.busy + 1 : 0
        }
        sample = (pid, gpu, now, busy)
        if busy >= busySamples {
            sample = nil
            found(app)
        }
    }

    private func displaysChanged(_ flags: CGDisplayChangeSummaryFlags) {
        guard !flags.contains(.beginConfigurationFlag) else { return }
        if asleep || !flags.isDisjoint(with: [.addFlag, .removeFlag, .enabledFlag, .disabledFlag]) { reconnected = true }
        // A game that changes the mode or captures the display.
        watch(60)
        settle()
    }

    /// 3 s after the last display change or wake: put monitors that lost HiDPI back, or else note
    /// which ones are in HiDPI now.
    private func settle() {
        settleGeneration += 1
        let generation = settleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            guard generation == settleGeneration, !asleep else { return }
            // While a game runs or its monitors wait to switch back, their modes are the game's.
            guard games.isEmpty, !gameModesSaved() else { return }
            let states = hiDPIStates()
            if reconnected {
                reconnected = false
                let lost = states.filter { !$0.shown && $0.offered && wasHiDPI[$0.monitor] ?? true }.map(\.monitor)
                if Settings.load().hiDPI && !lost.isEmpty {
                    // Noted when the switch has settled.
                    return displayQueue.async { keepHiDPI(Set(lost)) }
                }
            }
            for s in states { wasHiDPI[s.monitor] = s.shown }
        }
    }
}

/// `dusk set game <app> on|off|auto`: a game, not one, or as it plays. An app's or executable's path
/// counts by its name.
func markGame(_ app: String, _ value: String) {
    var name = app.contains("/") ? URL(fileURLWithPath: (app as NSString).expandingTildeInPath).lastPathComponent : app
    if name.lowercased().hasSuffix(".app") { name.removeLast(4) }
    name = name.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else { usage() }
    let key = name.lowercased()
    change {
        $0.games.removeAll { $0.lowercased() == key }
        $0.notGames.removeAll { $0.lowercased() == key }
        if value == "on" { $0.games.append(name) }
        if value == "off" { $0.notGames.append(name) }
    }
    let running = Set(NSWorkspace.shared.runningApplications.filter { names($0).contains(key) }.compactMap(\.localizedName))
    let what = ["on": "a game", "off": "not a game", "auto": "a game if it plays like one"][value]!
    print("\(name): \(what)" + (running.isEmpty ? "" : " (running now: \(running.sorted().joined(separator: ", ")))"))
}

/// The `dusk status` lines for HiDPI's setting and games.
func gameStatus() {
    let s = Settings.load()
    print("HiDPI")
    print("  kept          \(s.hiDPI ? "yes, after monitors come and go or wake" : "no (dusk set hidpi on keeps it)")")
    print("  in games      \(s.gameStandard ? "standard while a game runs" : "unchanged")")
    let running = Set(runningGames().values).sorted()
    print("  games now     \(running.isEmpty ? "none" : running.joined(separator: ", "))")
    if !s.games.isEmpty { print("  marked        \(s.games.joined(separator: ", "))") }
    if !s.notGames.isEmpty { print("  not games     \(s.notGames.joined(separator: ", "))") }
}
