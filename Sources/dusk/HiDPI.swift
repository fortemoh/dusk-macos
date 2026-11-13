// HiDPI (Retina) on external monitors.
//
// A HiDPI mode is drawn at twice its size and scaled down to the panel: the same size on screen,
// with smoother text. For a monitor's own resolution and a few other sizes macOS has HiDPI modes
// already (2560x1440 HiDPI, drawn at 5120x2880, on a 1440p monitor), but marked for mirroring only,
// so the public mode list and System Settings leave them out. They work on their own as well:
// `dusk set hidpi on` switches to the one that looks the same size as the current mode, through
// SkyLight's full mode list, the way BetterDisplay's HiDPI toggle does. No administrator needed.
//
// `dusk set scaling on` adds HiDPI sizes in between, like BetterDisplay's flexible scaling, listed in
// System Settings. On Apple Silicon, WindowServer makes each `scale-resolutions` entry of W x H pixels
// in a display override a HiDPI mode that looks like W/2 x H/2, if the display pipe can scale it down
// to the panel and has the bandwidth at that refresh rate. It reads the override, which lives in
// /Library/Displays, when it sets up a monitor, so dusk reconnects the monitors after writing it.

import CoreGraphics
import Foundation
import IOKit.pwr_mgt

private let overridesDir = "/Library/Displays/Contents/Resources/Overrides"
private let systemOverridesDir = "/System/Library/Displays/Contents/Resources/Overrides"
/// Set in the overrides dusk writes; dusk never changes or removes another app's.
private let ownerKey = "local.dusk"
private let nativeFlag: UInt32 = 0x0200_0000        // kDisplayModeNativeFlag
private let mirrorOnlyFlag: UInt32 = 0x0020_0000    // kDisplayModeValidForMirroringFlag

private let SLSGetNumberOfDisplayModes = sym(skyLight, "SLSGetNumberOfDisplayModes",
    (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> CGError).self)
// (display, index, description, its size): see Mode.init for the layout.
private let SLSGetDisplayModeDescriptionOfLength = sym(skyLight, "SLSGetDisplayModeDescriptionOfLength",
    (@convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, Int32) -> CGError).self)
private let SLSGetCurrentDisplayMode = sym(skyLight, "SLSGetCurrentDisplayMode",
    (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> CGError).self)
private let SLSConfigureDisplayMode = sym(skyLight, "SLSConfigureDisplayMode",
    (@convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Int32) -> CGError).self)
// (display, mode number): whether it is the variable refresh rate (VRR) one.
private let SLSIsDisplayModeVRR = sym(skyLight, "SLSIsDisplayModeVRR",
    (@convention(c) (CGDirectDisplayID, Int32) -> Bool).self)
// (config, display, enabled): a soft disconnect or reconnect, as in BetterDisplay.
private let SLSConfigureDisplayEnabled = sym(skyLight, "SLSConfigureDisplayEnabled",
    (@convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> CGError).self)

struct Size: Hashable, Comparable {
    let width, height: Int
    static func < (a: Size, b: Size) -> Bool { a.width < b.width }
    var text: String { "\(width)x\(height)" }
}

/// A mode from SkyLight's full list, which has the mirroring-only ones too.
struct Mode {
    let number: Int32
    /// What it looks like, in points.
    let size: Size
    /// 2 for HiDPI.
    let scale: Int
    let hz: Int
    let vrr: Bool
    let mirrorOnly: Bool

    var hiDPI: Bool { scale > 1 }
    var pixels: Size { Size(width: size.width * scale, height: size.height * scale) }
    var text: String { (hiDPI ? "\(size.text) HiDPI (\(pixels.text))" : size.text) + ", \(hz) Hz" }

    private static let length = 212
    /// The 212-byte description: number at 0, IOKit flags at 4, width and height in points at 8
    /// and 12, refresh rate (UInt16) at 190 and scale (Float) at 208.
    fileprivate init?(_ display: CGDirectDisplayID, index: Int32) {
        guard let describe = SLSGetDisplayModeDescriptionOfLength else { return nil }
        var bytes = [UInt8](repeating: 0, count: Mode.length)
        let mode: Mode? = bytes.withUnsafeMutableBytes { raw in
            guard describe(display, index, raw.baseAddress!, Int32(Mode.length)) == .success else { return nil }
            let number = raw.load(fromByteOffset: 0, as: Int32.self)
            return Mode(number: number,
                        size: Size(width: Int(raw.load(fromByteOffset: 8, as: UInt32.self)), height: Int(raw.load(fromByteOffset: 12, as: UInt32.self))),
                        scale: max(1, Int(raw.load(fromByteOffset: 208, as: Float.self).rounded())),
                        hz: Int(raw.load(fromByteOffset: 190, as: UInt16.self)),
                        vrr: SLSIsDisplayModeVRR?(display, number) ?? false,
                        mirrorOnly: raw.load(fromByteOffset: 4, as: UInt32.self) & mirrorOnlyFlag != 0)
        }
        guard let mode else { return nil }
        self = mode
    }

    private init(number: Int32, size: Size, scale: Int, hz: Int, vrr: Bool, mirrorOnly: Bool) {
        (self.number, self.size, self.scale, self.hz, self.vrr, self.mirrorOnly) = (number, size, scale, hz, vrr, mirrorOnly)
    }
}

func modes(_ display: CGDirectDisplayID) -> [Mode] {
    var n: Int32 = 0
    guard let count = SLSGetNumberOfDisplayModes, count(display, &n) == .success else { return [] }
    return (0..<n).compactMap { Mode(display, index: $0) }
}

func currentMode(_ display: CGDirectDisplayID, in list: [Mode]) -> Mode? {
    var n: Int32 = -1
    guard let current = SLSGetCurrentDisplayMode, current(display, &n) == .success else { return nil }
    return list.first { $0.number == n }
}

/// A connected external monitor.
struct Panel {
    let id: CGDirectDisplayID
    let name: String
    /// Its own resolution in pixels.
    let native: Size

    /// macOS looks up overrides by model, so monitors of the same model share one.
    var overridePath: String {
        "\(overridesDir)/DisplayVendorID-\(String(CGDisplayVendorNumber(id), radix: 16))/DisplayProductID-\(String(CGDisplayModelNumber(id), radix: 16))"
    }

    /// The sizes `dusk set scaling on` adds, in the panel's aspect ratio: 5/8 to all of its width,
    /// and the usual sizes in between. macOS has the smaller ones already; bigger ones would be scaled
    /// down to less than half. Drawn at 8K (7680x4320) at most.
    var scalingSizes: [Size] {
        let usual = [(1280, 720), (1600, 900), (1920, 1080), (2048, 1152), (2304, 1296), (2560, 1440), (2880, 1620), (3200, 1800),
                     (3840, 2160), (1440, 900), (1680, 1050), (1920, 1200), (2560, 1600), (2880, 1800)]
        let (w, h) = (native.width, native.height)
        let eighths = (5...8).filter { w * $0 % 8 == 0 && h * $0 % 8 == 0 }.map { Size(width: w * $0 / 8, height: h * $0 / 8) }
        let between = usual.map { Size(width: $0.0, height: $0.1) }.filter { $0.width * h == $0.height * w && 2 * $0.width > w && $0.width <= w }
        return Set(eighths + between).filter { $0.width * $0.height <= 3840 * 2160 }.sorted()
    }

    var range: String { scalingSizes.isEmpty ? "none" : "\(scalingSizes.first!.text) to \(scalingSizes.last!.text)" }

    /// The added sizes WindowServer offers, as ordinary (not mirroring-only) HiDPI modes.
    var scaledSizes: [Size] {
        let offered = Set(modes(id).filter { $0.hiDPI && !$0.mirrorOnly }.map(\.size))
        return scalingSizes.filter(offered.contains)
    }
}

/// The connected external monitors (not virtual or AirPlay displays).
func panels() -> [Panel] {
    let fbs = externalFramebuffers()
    defer { fbs.forEach { IOObjectRelease($0.service) } }
    let monitors = fbs.compactMap(\.monitor)
    let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    return externalDisplays().compactMap { id in
        let all = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
        guard let monitor = monitors.first(where: { $0.id == Monitor.id(id) }),
              let native = all.filter({ $0.ioFlags & nativeFlag != 0 && $0.pixelWidth == $0.width }).max(by: { $0.width < $1.width })
        else { return nil }
        return Panel(id: id, name: monitor.name, native: Size(width: native.width, height: native.height))
    }
}

// MARK: - HiDPI

/// The mode that looks the same size as `current`, in HiDPI or standard, with the same VRR setting
/// if it has one. It keeps the refresh rate if it can, or takes the highest; going back from a HiDPI
/// mode at the highest rate that size has in HiDPI, it takes the highest standard one.
private func counterpart(of current: Mode, in list: [Mode], hiDPI: Bool) -> Mode? {
    let sameSize = list.filter { $0.size == current.size }
    let capped = current.hiDPI && current.hz == sameSize.filter(\.hiDPI).map(\.hz).max()
    func rank(_ m: Mode) -> (Int, Int, Int) { (!capped && m.hz == current.hz ? 1 : 0, m.vrr == current.vrr ? 1 : 0, m.hz) }
    return sameSize.filter { $0.hiDPI == hiDPI }.max { rank($0) < rank($1) }
}

/// Sets each panel's mode, all at once. WindowServer saves them (`.permanently`) for this set of
/// connected monitors, or keeps them until logout (`.forSession`).
private func setModes(_ changes: [(Panel, Mode)], _ option: CGConfigureOption = .permanently) -> Bool {
    guard let configure = SLSConfigureDisplayMode else {
        fail("SkyLight mode API not found on this macOS")
        return false
    }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else {
        fail("could not begin display configuration")
        return false
    }
    for (p, mode) in changes where configure(config, p.id, mode.number) != .success {
        CGCancelDisplayConfiguration(config)
        fail("\(p.name): could not set \(mode.text)")
        return false
    }
    guard CGCompleteDisplayConfiguration(config, option) == .success else {
        fail("display configuration failed")
        return false
    }
    return true
}

/// Shows `panels` in HiDPI or standard, at the size each has now. Going back to standard, a size that
/// only exists in HiDPI falls back to the panel's own resolution.
private func switchModes(_ panels: [Panel], hiDPI: Bool) {
    var changes: [(panel: Panel, mode: Mode, from: Mode)] = []
    for p in panels {
        let list = modes(p.id)
        guard let current = currentMode(p.id, in: list) else {
            fail("\(p.name): could not read its modes")
            continue
        }
        if current.hiDPI == hiDPI {
            print("\(p.name): already \(current.text)")
            continue
        }
        func rank(_ m: Mode) -> (Int, Int) { (m.vrr == current.vrr ? 1 : 0, m.hz) }
        let native = hiDPI ? nil : list.filter { $0.size == p.native && !$0.hiDPI }.max { rank($0) < rank($1) }
        guard let target = counterpart(of: current, in: list, hiDPI: hiDPI) ?? native else {
            print("\(p.name): no HiDPI mode looks like \(current.size.text)")
            continue
        }
        changes.append((p, target, current))
    }
    guard !changes.isEmpty, setModes(changes.map { ($0.panel, $0.mode) }) else { return }
    for c in changes {
        // The display pipe's bandwidth rules out the highest refresh rates for modes drawn at 5K or so.
        print("\(c.panel.name): \(c.mode.text)" + (c.mode.hz < c.from.hz ? " (\(c.from.hz) Hz isn't offered in HiDPI at this size)" : ""))
    }
}

/// `dusk set hidpi on`: each external monitor in HiDPI, at the size it has now. If a game runs, its
/// monitors stay as they are when it quits.
func hiDPIOn() {
    Settings.store.removeObject(forKey: gameModesKey)
    let all = panels()
    all.isEmpty ? fail("no external monitors") : switchModes(all, hiDPI: true)
}

/// `dusk set hidpi off`: each external monitor in standard resolution, at the size it has now.
func hiDPIOff() {
    Settings.store.removeObject(forKey: gameModesKey)
    let all = panels()
    all.isEmpty ? fail("no external monitors") : switchModes(all, hiDPI: false)
}

/// Whether every external monitor shows a HiDPI mode now (the menu's check mark).
func hiDPIShown() -> Bool {
    let all = panels()
    return !all.isEmpty && all.allSatisfy { p in currentMode(p.id, in: modes(p.id))?.hiDPI ?? false }
}

/// Each external monitor (by `Monitor.id`), whether it shows HiDPI, and whether it has a HiDPI mode
/// of the size it shows.
func hiDPIStates() -> [(monitor: String, shown: Bool, offered: Bool)] {
    panels().compactMap { p in
        let list = modes(p.id)
        guard let current = currentMode(p.id, in: list) else { return nil }
        return (Monitor.id(p.id), current.hiDPI, current.hiDPI || list.contains { $0.hiDPI && $0.size == current.size })
    }
}

/// After monitors attach, leave or wake, with `hidpi on`: `monitors` back in HiDPI. macOS saves the
/// modes per set of connected monitors, so a set it hasn't seen in HiDPI comes up in standard;
/// once dusk has switched it, macOS keeps it for that set too.
func keepHiDPI(_ monitors: Set<String>) {
    let lost = panels().filter { monitors.contains(Monitor.id($0.id)) }
    guard !lost.isEmpty else { return }
    print("[\(stamp())] back in HiDPI after the monitors changed")
    switchModes(lost, hiDPI: true)
}

// MARK: - Games

/// The monitors `standardForGame` switched, each with the HiDPI mode it had: in the settings file,
/// so that they still switch back if `dusk tint` restarts meanwhile.
private let gameModesKey = "gameModes"

private struct SavedMode {
    let monitor: String
    let size: Size
    let hz: Int
    let vrr: Bool

    init(_ panel: Panel, _ mode: Mode) {
        (monitor, size, hz, vrr) = (Monitor.id(panel.id), mode.size, mode.hz, mode.vrr)
    }

    init?(_ d: [String: Any]) {
        guard let monitor = d["monitor"] as? String, let w = d["width"] as? Int, let h = d["height"] as? Int,
              let hz = d["hz"] as? Int, let vrr = d["vrr"] as? Bool else { return nil }
        (self.monitor, size, self.hz, self.vrr) = (monitor, Size(width: w, height: h), hz, vrr)
    }

    var plist: [String: Any] { ["monitor": monitor, "width": size.width, "height": size.height, "hz": hz, "vrr": vrr] }
}

private func savedGameModes() -> [SavedMode] {
    (Settings.store.array(forKey: gameModesKey) as? [[String: Any]] ?? []).compactMap(SavedMode.init)
}

/// Whether monitors wait to switch back to HiDPI after a game.
func gameModesSaved() -> Bool { !savedGameModes().isEmpty }

/// When a game starts: each external monitor in HiDPI to the standard mode of the same size, at its
/// highest refresh rate and with the same VRR setting, until logout at most (macOS keeps the saved
/// HiDPI mode). They are remembered for `hiDPIAfterGames`.
func standardForGame(_ game: String) {
    var changes: [(panel: Panel, mode: Mode, from: Mode)] = []
    for p in panels() {
        let list = modes(p.id)
        guard let current = currentMode(p.id, in: list), current.hiDPI else { continue }
        func rank(_ m: Mode) -> (Int, Int) { (m.vrr == current.vrr ? 1 : 0, m.hz) }
        guard let target = list.filter({ !$0.hiDPI && $0.size == current.size }).max(by: { rank($0) < rank($1) }) else {
            print("\(p.name): no standard mode looks like \(current.size.text), staying in HiDPI")
            continue
        }
        changes.append((p, target, current))
    }
    guard !changes.isEmpty else { return }
    print("[\(stamp())] \(game) started: standard while it runs")
    guard setModes(changes.map { ($0.panel, $0.mode) }, .forSession) else { return }
    let saved = savedGameModes() + changes.map { SavedMode($0.panel, $0.from) }
    Settings.store.set(saved.map(\.plist), forKey: gameModesKey)
    for c in changes { print("\(c.panel.name): \(c.mode.text)") }
}

/// When the last game has quit: the monitors `standardForGame` switched back to the HiDPI mode each
/// had, unless it shows another size now.
func hiDPIAfterGames() {
    let saved = savedGameModes()
    guard !saved.isEmpty else { return }
    Settings.store.removeObject(forKey: gameModesKey)
    var changes: [(Panel, Mode)] = []
    for p in panels() {
        guard let was = saved.first(where: { $0.monitor == Monitor.id(p.id) }) else { continue }
        let list = modes(p.id)
        guard let current = currentMode(p.id, in: list), !current.hiDPI, current.size == was.size,
              let target = list.first(where: { $0.hiDPI && $0.size == was.size && $0.hz == was.hz && $0.vrr == was.vrr })
                ?? counterpart(of: current, in: list, hiDPI: true) else { continue }
        changes.append((p, target))
    }
    guard !changes.isEmpty else { return }
    print("[\(stamp())] no game running: HiDPI again")
    guard setModes(changes) else { return }
    for (p, mode) in changes { print("\(p.name): \(mode.text)") }
}

/// The panels whose current mode `matches` back to standard.
private func standard(_ panels: [Panel], where matches: (Panel, Mode) -> Bool) {
    switchModes(panels.filter { p in currentMode(p.id, in: modes(p.id)).map { matches(p, $0) } ?? false }, hiDPI: false)
}

// MARK: - Scaling overrides

private func overrideData(_ panel: Panel) -> Data {
    // macOS reads only the first override it finds, so keep what the one it ships for the model says.
    let shipped = panel.overridePath.replacingOccurrences(of: overridesDir, with: systemOverridesDir)
    var dict = NSDictionary(contentsOfFile: shipped) as? [String: Any] ?? [:]
    let entries = panel.scalingSizes.map { s in
        [UInt32(2 * s.width).bigEndian, UInt32(2 * s.height).bigEndian].withUnsafeBytes { Data($0) }
    }
    dict["scale-resolutions"] = (dict["scale-resolutions"] as? [Any] ?? []) + entries
    dict["DisplayVendorID"] = Int(CGDisplayVendorNumber(panel.id))
    dict["DisplayProductID"] = Int(CGDisplayModelNumber(panel.id))
    dict[ownerKey] = true
    return try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
}

private func isDusks(_ path: String) -> Bool {
    guard let data = FileManager.default.contents(atPath: path),
          let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
    return dict[ownerKey] as? Bool == true
}

private enum Override { case none, current, outdated, other }

private func override(_ panel: Panel) -> Override {
    guard let data = FileManager.default.contents(atPath: panel.overridePath) else { return .none }
    guard isDusks(panel.overridePath) else { return .other }
    return data == overrideData(panel) ? .current : .outdated
}

/// dusk's overrides, for any monitor model.
private func dusksOverrides() -> [String] {
    let fm = FileManager.default
    return ((try? fm.contentsOfDirectory(atPath: overridesDir)) ?? []).sorted().flatMap { vendor in
        ((try? fm.contentsOfDirectory(atPath: "\(overridesDir)/\(vendor)")) ?? []).sorted().map { "\(overridesDir)/\(vendor)/\($0)" }
    }.filter(isDusks)
}

private func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// Runs `command` as root, after macOS's administrator password dialog (/Library/Displays is root's).
private func asAdmin(_ command: String, _ reason: String) -> Bool {
    let p = Process()
    if geteuid() == 0 {
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
    } else {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \(quoted(command)) with prompt \(quoted(reason)) with administrator privileges"]
    }
    let err = Pipe()
    p.standardOutput = FileHandle.nullDevice
    p.standardError = err
    do { try p.run() } catch {
        fail("could not run \(p.executableURL!.path)")
        return false
    }
    let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        fail(message.contains("-128") ? "cancelled" : "failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        return false
    }
    return true
}

private func writeOverrides(_ panels: [Panel]) -> Bool {
    var seen = Set<String>()
    let commands = panels.filter { seen.insert($0.overridePath).inserted }.map { p in
        let path = shellQuoted(p.overridePath)
        return "/bin/mkdir -p \(shellQuoted((p.overridePath as NSString).deletingLastPathComponent))"
            + " && echo \(overrideData(p).base64EncodedString()) | /usr/bin/base64 -D > \(path) && /bin/chmod 644 \(path)"
    }
    return asAdmin(commands.joined(separator: " && "), "dusk wants to add HiDPI resolutions for your monitors.")
}

// MARK: - Reconnecting

/// Polls `done` every 50 ms for up to `seconds`.
@discardableResult
private func wait(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
    let end = Date() + seconds
    while !done() {
        if Date() > end { return false }
        usleep(50_000)
    }
    return true
}

private typealias Alloc = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?
private typealias InitWithObject = @convention(c) (UnsafeMutableRawPointer, Selector, AnyObject) -> Unmanaged<AnyObject>?
private typealias InitMode = @convention(c) (UnsafeMutableRawPointer, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>?
private typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool

/// `[[cls alloc] init…]` for a CoreGraphics class without a public header: `call` gets the alloc'ed
/// instance, the init method's selector and its implementation.
private func make(_ className: String, _ initializer: String,
                  _ call: (UnsafeMutableRawPointer, Selector, IMP) -> Unmanaged<AnyObject>?) -> NSObject? {
    let allocSel = NSSelectorFromString("alloc"), initSel = NSSelectorFromString(initializer)
    guard let cls = NSClassFromString(className), let meta = object_getClass(cls),
          let alloc = class_getMethodImplementation(meta, allocSel),
          let initImp = class_getMethodImplementation(cls, initSel),
          let instance = unsafeBitCast(alloc, to: Alloc.self)(cls, allocSel) else { return nil }
    return call(instance, initSel, initImp)?.takeRetainedValue() as? NSObject
}

/// Runs `body` with the ID of a virtual display that is online meanwhile, 1920x1080 so that most
/// windows moved to it keep their size (WindowServer allows 1920 wide at most). False if it couldn't
/// be made.
private func withVirtualDisplay(_ body: (CGDirectDisplayID) -> Bool) -> Bool {
    var result = false
    let shown = autoreleasepool { () -> Bool in
        guard let descriptor = (NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type)?.init(),
              let settings = (NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type)?.init() else { return false }
        descriptor.setValue("dusk", forKey: "name")
        descriptor.setValue(0xd05c, forKey: "vendorID")
        descriptor.setValue(1, forKey: "productID")
        descriptor.setValue(1, forKey: "serialNum")
        descriptor.setValue(1920, forKey: "maxPixelsWide")
        descriptor.setValue(1080, forKey: "maxPixelsHigh")
        descriptor.setValue(NSValue(size: NSSize(width: 530, height: 300)), forKey: "sizeInMillimeters")
        descriptor.setValue(DispatchQueue.global(), forKey: "queue")
        let terminated: @convention(block) (AnyObject?, AnyObject?) -> Void = { _, _ in }
        descriptor.setValue(unsafeBitCast(terminated, to: AnyObject.self), forKey: "terminationHandler")
        guard let mode = make("CGVirtualDisplayMode", "initWithWidth:height:refreshRate:", { obj, sel, imp in
                  unsafeBitCast(imp, to: InitMode.self)(obj, sel, 1920, 1080, 60)
              }),
              let display = make("CGVirtualDisplay", "initWithDescriptor:", { obj, sel, imp in
                  unsafeBitCast(imp, to: InitWithObject.self)(obj, sel, descriptor)
              }) else { return false }
        settings.setValue([mode], forKey: "modes")
        settings.setValue(0, forKey: "hiDPI")
        let applySel = NSSelectorFromString("applySettings:")
        let id = (display.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0
        return withExtendedLifetime(display) {
            guard unsafeBitCast(display.method(for: applySel), to: Apply.self)(display, applySel, settings),
                  wait(5, until: { onlineDisplays().contains(id) }) else { return false }
            result = body(id)
            return true
        }
    }
    // Released when the pool drained, which removes it.
    wait(5) { !onlineDisplays().contains { CGDisplayVendorNumber($0) == 0xd05c } }
    return shown && result
}

/// Applies `edit` to a display configuration for this login session.
private func configure(_ edit: (CGDisplayConfigRef) -> Bool) -> Bool {
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
    guard edit(config) else {
        CGCancelDisplayConfiguration(config)
        return false
    }
    return CGCompleteDisplayConfiguration(config, .forSession) == .success
}

private func arrange(_ origins: [CGDirectDisplayID: CGPoint], _ config: CGDisplayConfigRef) -> Bool {
    origins.allSatisfy { CGConfigureDisplayOrigin(config, $0.key, Int32($0.value.x), Int32($0.value.y)) == .success }
}

/// Has WindowServer set the panels up again, which reads their overrides: it disconnects and
/// reconnects them (they go blank for a few seconds), with a virtual display online meanwhile. That
/// one is the main display while they are off, since WindowServer won't disconnect the main display,
/// and keeps the Mac from being without a display. False if that couldn't be done.
private func reconnect(_ panels: [Panel]) -> Bool {
    guard let enable = SLSConfigureDisplayEnabled else { return false }
    // With its monitors off, a Mac can go to sleep in the middle of this (BetterDisplay does the same).
    var awake: IOPMAssertionID = 0
    let held = IOPMAssertionCreateWithName("PreventSystemSleep" as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "dusk is reconnecting the monitors" as CFString, &awake) == kIOReturnSuccess
    defer { if held { IOPMAssertionRelease(awake) } }
    let ids = Set(panels.map(\.id))
    let before = Dictionary(uniqueKeysWithValues: onlineDisplays().map { ($0, CGDisplayBounds($0).origin) })
    let done = withVirtualDisplay { virtual in
        if ids.contains(CGMainDisplayID()) {
            let o = CGDisplayBounds(virtual).origin
            let moved = Dictionary(uniqueKeysWithValues: onlineDisplays().map {
                ($0, CGPoint(x: CGDisplayBounds($0).minX - o.x, y: CGDisplayBounds($0).minY - o.y))
            })
            guard configure({ arrange(moved, $0) }), wait(5, until: { CGDisplayIsMain(virtual) != 0 }) else { return false }
        }
        let off = configure { c in ids.allSatisfy { enable(c, $0, false) == .success } }
        if off { wait(5) { ids.isDisjoint(with: onlineDisplays()) } }
        // Whatever happened, turn them back on.
        let on = configure { c in ids.allSatisfy { enable(c, $0, true) == .success } }
            || configure { c in ids.allSatisfy { enable(c, $0, true) == .success } }
        return off && on && wait(10) { ids.isSubset(of: onlineDisplays()) }
    }
    // Without the virtual display WindowServer goes back to the arrangement it saved for these
    // displays; put it back if it didn't.
    if wait(3, until: { before.allSatisfy { onlineDisplays().contains($0.key) && CGDisplayBounds($0.key).origin == $0.value } }) == false {
        _ = configure { arrange(before.filter { onlineDisplays().contains($0.key) }, $0) }
    }
    return done
}

// MARK: - Scaling commands

/// `dusk set scaling on`: adds the in-between HiDPI sizes for each monitor model (with the
/// administrator password), and reconnects the monitors so macOS lists them.
func scalingOn() {
    let all = panels()
    if all.isEmpty { return fail("no external monitors") }
    for p in all where override(p) == .other {
        print("\(p.name): \(p.overridePath) is another app's (BetterDisplay's?), leaving it as it is")
    }
    let missing = all.filter { [.none, .outdated].contains(override($0)) && !$0.scalingSizes.isEmpty }
    if !missing.isEmpty {
        guard writeOverrides(missing) else { return }
        for p in missing { print("\(p.name): added HiDPI \(p.range)") }
    }
    let unloaded = all.filter { override($0) == .current && $0.scaledSizes.isEmpty }
    if !unloaded.isEmpty {
        print("reconnecting the monitors to load them")
        guard reconnect(unloaded), wait(10, until: { unloaded.allSatisfy { !$0.scaledSizes.isEmpty } }) else {
            return fail("macOS didn't load them; turn the monitors off and on to load them")
        }
    }
    for p in all where override(p) == .current {
        print("\(p.name): HiDPI \(p.scaledSizes.map(\.text).joined(separator: ", ")) in System Settings > Displays")
    }
}

/// `dusk set scaling off`, and `uninstall`: removes dusk's overrides, after switching monitors in an
/// added mode back to standard.
func scalingOff() {
    let paths = dusksOverrides()
    guard !paths.isEmpty else { return }
    let all = panels()
    standard(all) { p, mode in mode.hiDPI && !mode.mirrorOnly && p.scalingSizes.contains(mode.size) }
    let dirs = Set(paths.map { ($0 as NSString).deletingLastPathComponent }).sorted()
        + [overridesDir, "/Library/Displays/Contents/Resources", "/Library/Displays/Contents", "/Library/Displays"]
    let command = "/bin/rm -f \(paths.map(shellQuoted).joined(separator: " "))"
        + " && { /bin/rmdir \(dirs.map(shellQuoted).joined(separator: " ")) 2>/dev/null; true; }"
    guard asAdmin(command, "dusk wants to remove the HiDPI resolutions it added.") else { return }
    paths.forEach { print("removed \($0)") }
    let loaded = all.filter { !$0.scaledSizes.isEmpty }
    if !loaded.isEmpty {
        print("reconnecting the monitors to unload them")
        if !reconnect(loaded) { print("they go away when the monitors reconnect") }
    }
}

/// For `uninstall`: monitors in a HiDPI mode macOS doesn't list (mirroring-only, or added) back to
/// standard, and dusk's overrides removed.
func removeHiDPI() {
    standard(panels()) { p, mode in mode.hiDPI && mode.pixels.width > p.native.width }
    scalingOff()
}

// MARK: - Status

/// The `dusk status` lines for one monitor.
func hiDPIStatus(_ panel: Panel?) {
    guard let panel else { return }
    let list = modes(panel.id)
    guard let current = currentMode(panel.id, in: list) else { return }
    print("  mode          \(current.text)")
    let hiDPI: String
    if current.hiDPI {
        hiDPI = "on"
    } else if let best = list.filter({ $0.size == current.size && $0.hiDPI }).max(by: { $0.hz < $1.hz }) {
        hiDPI = "off (\(current.size.text) HiDPI goes up to \(best.hz) Hz)"
    } else {
        hiDPI = "off (none at \(current.size.text))"
    }
    print("  hidpi         \(hiDPI)")
    let scaled = panel.scaledSizes
    let scaling = switch override(panel) {
    case .current: scaled.isEmpty ? "on, loaded once the monitor reconnects" : "on: \(scaled.map(\.text).joined(separator: ", "))"
    case .outdated: "on, from an older dusk (dusk set scaling on updates it)"
    case .other: "\(panel.overridePath) is another app's"
    case .none: "off (on adds HiDPI \(panel.range))"
    }
    print("  scaling       \(scaling)")
}
