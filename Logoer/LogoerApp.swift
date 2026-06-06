//
//  LogoerApp.swift
//  Logoer
//
//  Created by apple on 2024/7/18.
//

import SwiftUI
import Sparkle
import CoreGraphics
import SDWebImageSwiftUI

let ud = UserDefaults.standard
var maskLockTime: Date?
var aboveSonoma = false
var aboveSequoia = false
var dataModel = DataModel()
var updaterController: SPUStandardUpdaterController!
var logoWindows = [NSWindow]()
private var maskRefreshGeneration = 0

private func normalizedMaskInterval(_ interval: Int) -> TimeInterval {
    return TimeInterval(max(interval, 1))
}

@main
struct LogoerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var body: some Scene {
        Settings {
            SettingsView().fixedSize()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    @AppStorage("logoStyle") var logoStyle = "rainbow"
    @AppStorage("maskInterval") var maskInterval = 5

    private var maskTimer: Timer?
    private var screenTimer: Timer?
    private var batteryTimer: Timer?
    private var userDefaultsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        dataModel.battery = getPowerState()
        startMaskTimer()
        screenTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            getFullScreens()
        }

        batteryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            dataModel.battery = getPowerState()
        }

        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.startMaskTimer()
        }

        if #available(macOS 14, *) { aboveSonoma = true }
        if #available(macOS 15, *) { aboveSequoia = true }
        refeshMask()
        createLogo()
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(onDisplayWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didActivateApplication(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        tips(id: "logoer.first-start.note", text: "When Logoer is running, you can run it again to bring up the settings panel.")
        tips(id: "logoer.full-screen.note", text: "Enabling \"Visible in Full Screen Mode\" will keep the logo visible in full screen mode.")
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        maskTimer?.invalidate()
        screenTimer?.invalidate()
        batteryTimer?.invalidate()
        if let userDefaultsObserver {
            NotificationCenter.default.removeObserver(userDefaultsObserver)
        }
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, nil)
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.screensDidWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.didActivateApplicationNotification, object: nil)
        cleanMaskFiles()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        createLogo()
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14, *) {
            NSApp.mainMenu?.items.first?.submenu?.item(at: 2)?.performAction()
        }else if #available(macOS 13, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.windows.first(where: { !logoWindows.contains($0) })?.level = .floating
        }
        return true
    }

    @objc func onDisplayWake() { print("Display WakeUp"); createLogo() }

    @objc func didActivateApplication(_ notification: Notification) {
        if logoStyle == "appicon",
           let userInfo = notification.userInfo,
           let app = userInfo[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            dataModel.appIcon = getIcon(app: app)
            createLogo()
        }
    }

    private func startMaskTimer() {
        maskTimer?.invalidate()
        let interval = normalizedMaskInterval(maskInterval)
        maskTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            if let lockTime = maskLockTime, Date().timeIntervalSince(lockTime) >= interval {
                maskLockTime = nil
            }
            if maskLockTime == nil { refeshMask() }
        }
    }
}

func getIcon(app: NSRunningApplication?) -> NSImage {
    if let app = app, let path = app.bundleURL?.path {
        if let rep = NSWorkspace.shared.icon(forFile: path)
            .bestRepresentation(for: NSRect(x: 0, y: 0, width: 128, height: 128), context: nil, hints: nil) {
            let icon = NSImage(size: rep.size)
            icon.addRepresentation(rep)
            return icon
        } else {
            return NSWorkspace.shared.icon(forFile: path)
        }
    }
    return NSImage.appiconBack
}

func displayReconfigurationCallback(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags, userInfo: UnsafeMutableRawPointer?) {
    print("Display Re-Configuration: \(flags)")
    DispatchQueue.main.async { createLogo() }
}

func refeshMask() {
    if !Thread.isMainThread {
        DispatchQueue.main.async { refeshMask() }
        return
    }

    maskRefreshGeneration += 1
    let generation = maskRefreshGeneration

    @AppStorage("maskMode") var maskMode: Bool = false
    if !maskMode {
        dataModel.masks = []
        return
    }

    if #available(macOS 10.15, *) {
        if !CGPreflightScreenCaptureAccess() {
            print("Screen recording permission not granted")
            dataModel.masks = []
            return
        }
    }

    let screens = NSScreen.screens
    let origins = screens.indices.map { getOrigin(of: screens[$0], in: screens) }
    let urls = screens.indices.map { getMaskURL(index: $0) }

    DispatchQueue.global(qos: .userInitiated).async {
        var masks = [maskImage]()
        for index in screens.indices {
            _ = process(path: "/usr/sbin/screencapture", arguments: ["-x", "-R", "\(origins[index].x),\(origins[index].y),4,4", urls[index].path])
            if let image = NSImage(contentsOf: urls[index]) { masks.append(maskImage(url: urls[index], image: image)) }
        }
        DispatchQueue.main.async {
            guard generation == maskRefreshGeneration else { return }
            dataModel.masks = masks
        }
    }
}

func createLogo(noCache: Bool = false) {
    @AppStorage("logoStyle") var logoStyle = "rainbow"
    print("refesh logo at: \(Date())")

    if noCache {
        DispatchQueue.global(qos: .userInitiated).async {
            SDImageCache.shared.clearMemory()
            SDImageCache.shared.clearDisk()
        }
    }

    let screens = NSScreen.screens

    // Reuse windows if screen count matches, otherwise recreate
    if logoWindows.count == screens.count {
        for index in screens.indices {
            let screen = screens[index]
            let maskURL = getMaskURL(index: index)
            let appleMenuBarHeight = screen.frame.height - screen.visibleFrame.height - (screen.visibleFrame.origin.y - screen.frame.origin.y) - 1
            let logo = logoWindows[index]
            logo.contentView = NSHostingView(rootView: ContentView(model: dataModel, screen: screen, maskURL: maskURL))
            logo.setFrameOrigin(NSPoint(x: 15 + screen.frame.minX, y: screen.frame.minY + screen.frame.height - appleMenuBarHeight/2 - 12))
            logo.orderFront(nil)
        }
    } else {
        for w in logoWindows { w.close() }
        logoWindows.removeAll()

        for index in screens.indices {
            let screen = screens[index]
            let maskURL = getMaskURL(index: index)
            let appleMenuBarHeight = screen.frame.height - screen.visibleFrame.height - (screen.visibleFrame.origin.y - screen.frame.origin.y) - 1
            let logo = NSWindow(contentRect: NSRect(x:0, y: 0, width: 24, height: 24), styleMask: [.fullSizeContentView], backing: .buffered, defer: false)
            logo.contentView = NSHostingView(rootView: ContentView(model: dataModel, screen: screen, maskURL: maskURL))
            logo.title = "logo".local
            logo.isOpaque = false
            logo.hasShadow = false
            logo.isRestorable = false
            logo.ignoresMouseEvents = true
            logo.isReleasedWhenClosed = false
            logo.level = .statusBar
            logo.backgroundColor = .clear
            logo.collectionBehavior = [.canJoinAllSpaces, .transient]
            logo.setFrameOrigin(NSPoint(x: 15 + screen.frame.minX, y: screen.frame.minY + screen.frame.height - appleMenuBarHeight/2 - 12))
            logo.orderFront(nil)
            logoWindows.append(logo)
        }
    }
}

func getFullScreens() {
    var screenList = [NSRect]()
    if let windows = CGWindowListCopyWindowInfo([.excludeDesktopElements, .optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
        for window in windows {
            if getOwner(window) == "SystemUIServer" { continue }
            if let level = window[kCGWindowLayer as String] as? Int { if level != 0 { continue } }
            if let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] {
                let windowRect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
                for screen in NSScreen.screens {
                    if windowRect.equalTo(screen.frame) { screenList.append(screen.frame) }
                }
            }
        }
    }
    if screenList != dataModel.fullScreens {
        if screenList.count < dataModel.fullScreens.count {
            maskLockTime = Date()
            refeshMask()
        }
        dataModel.fullScreens = screenList
    }
}

func getOwner(_ w: [String: Any]) -> String {
    let name = w["kCGWindowOwnerName"] as? String ?? ""
    if name.contains("pid=") {
        guard let pid = w["kCGWindowOwnerPID"] as? Int else { return "" }
        for app in NSWorkspace.shared.runningApplications {
            if let name = app.localizedName, app.processIdentifier == pid {
                return name
            }
        }
    }
    return name
}

func getOrigin(of screen: NSScreen, in screens: [NSScreen]) -> NSPoint {
    if !screen.isMainScreen {
        if let mainScreen = screens.first(where: { $0.isMainScreen }) {
            let fullScreenRect = screens.reduce(NSRect.zero) { (result, screen) -> NSRect in result.union(screen.frame) }
            let screenFrame = screen.frame
            let mainScreenFrame = mainScreen.frame
            let originOffset = fullScreenRect.size.height
            let convertedMainOrigin = CGPoint(x: mainScreenFrame.origin.x, y: originOffset - mainScreenFrame.origin.y - mainScreenFrame.size.height)
            let convertedOrigin = CGPoint(x: screenFrame.origin.x, y: originOffset - screenFrame.origin.y - screenFrame.size.height)
            return NSPoint(x: convertedOrigin.x, y: convertedOrigin.y - convertedMainOrigin.y)
        }
    }
    return NSPoint(x: 0, y: 0)
}

func getMaskURL(index: Int) -> URL {
    let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    let logoerCache = cacheDir.appendingPathComponent("com.lihaoyun6.Logoer", isDirectory: true)
    try? FileManager.default.createDirectory(at: logoerCache, withIntermediateDirectories: true)
    return logoerCache.appendingPathComponent("mask\(index).png")
}

func cleanMaskFiles() {
    let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    let logoerCache = cacheDir.appendingPathComponent("com.lihaoyun6.Logoer", isDirectory: true)
    for i in 0..<8 {
        let url = logoerCache.appendingPathComponent("mask\(i).png")
        try? FileManager.default.removeItem(at: url)
    }
}

func tips(id: String, text: String) {
    let never = UserDefaults.standard.object(forKey: "neverRemindMe") as? [String] ?? []
    if !never.contains(id) {
        let alert = createAlert(title: "Logoer Tips".local, message: text.local, button1: "Don't remind me again", button2: "OK")
        DispatchQueue.main.async {
            if alert.runModal() == .alertFirstButtonReturn { UserDefaults.standard.setValue(never + [id], forKey: "neverRemindMe") }
        }
    }
}

func createAlert(level: NSAlert.Style = .warning, title: String, message: String, button1: String, button2: String = "") -> NSAlert {
    let alert = NSAlert()
    alert.messageText = title.local
    alert.informativeText = message.local
    alert.addButton(withTitle: button1.local)
    if button2 != "" { alert.addButton(withTitle: button2.local) }
    alert.alertStyle = level
    return alert
}

fileprivate func process(path: String, arguments: [String], timeout: Double = 0) -> String? {
    let task = Process()
    task.launchPath = path
    task.arguments = arguments
    task.standardError = Pipe()

    let outputPipe = Pipe()
    defer { outputPipe.fileHandleForReading.closeFile() }
    task.standardOutput = outputPipe

    var timeoutWork: DispatchWorkItem?
    if timeout != 0 {
        let work = DispatchWorkItem {
            if task.isRunning { task.terminate() }
        }
        timeoutWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + TimeInterval(timeout), execute: work)
    }

    do {
        try task.run()
    } catch let error {
        timeoutWork?.cancel()
        print("\(error.localizedDescription)")
        return nil
    }

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    timeoutWork?.cancel()
    let output = String(decoding: outputData, as: UTF8.self)

    if output.isEmpty { return nil }

    return output.trimmingCharacters(in: .newlines)
}

extension String {
    var local: String { return NSLocalizedString(self, comment: "") }
    var deletingPathExtension: String { return (self as NSString).deletingPathExtension }
}

extension NSScreen {
    var hasTopNotchDesign: Bool {
        guard #available(macOS 12, *) else { return false }
        return safeAreaInsets.top != 0
    }
    var displayID: CGDirectDisplayID? {
        return deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID
    }
    var isMainScreen: Bool {
        guard let id = self.displayID else { return false }
        return (CGDisplayIsMain(id) == 1)
    }
}

extension NSMenuItem {
    func performAction() {
        guard let menu else { return }
        menu.performActionForItem(at: menu.index(of: self))
    }
}

func randomEmoji(full: Bool = false) -> String {
    let characters = Array(full ? "😀😃😄😁😆😅😂🤣🥲🥹☺️😊😇🙂🙃😉😌😍🥰😘😗😙😚😋😛😝😜🤪🤨🧐🤓😎🥸🤩🥳🙂‍↕️😏😒🙂‍↔️😞😔😟😕🙁☹️😣😖😫😩🥺😢😭😮‍💨😤😠😡🤬🤯😳🥵🥶😱😨😰😥😓🫣🤗🫡🤔🫢🤭🤫🤥😶😶‍🌫️😐😑😬🫨🫠🙄😯😦😧😮😲🥱😴🤤😪😵😵‍💫🫥🤐🥴🤢🤮🤧😷🤒🤕🤑🤠😈👿👹👺🤡💩👻💀☠️👽👾🤖🎃😺😸😹😻😼😽🙀😿😾👋🤚🖐✋🖖👌🤌🤏✌️🤞🫰🤟🤘🤙🫵🫱🫲🫸🫷🫳🫴👈👉👆🖕👇☝️👍👎✊👊🤛🤜👏🫶🙌👐🤲🤝🙏✍️💅🤳💪🦾🦵🦿🦶👣👂🦻👃🫀🫁🧠🦷🦴👀👁👅👄🫦💋🩸👶👧🧒👦👩🧑👨👩‍🦱🧑‍🦱👨‍🦱👩‍🦰🧑‍🦰👨‍🦰👱‍♀️👱👱‍♂️👩‍🦳🧑‍🦳👨‍🦳👩‍🦲🧑‍🦲👨‍🦲🧔‍♀️🧔🧔‍♂️👵🧓👴👲👳‍♀️👳👳‍♂️🧕👮‍♀️👮👮‍♂️👷‍♀️👷👷‍♂️💂‍♀️💂💂‍♂️🕵️‍♀️🕵️🕵️‍♂️👩‍⚕️🧑‍⚕️👨‍⚕️👩‍🌾🧑‍🌾👨‍🌾👩‍🍳🧑‍🍳👨‍🍳👩‍🎓🧑‍🎓👨‍🎓👩‍🎤🧑‍🎤👨‍🎤👩‍🏫🧑‍🏫👨‍🏫👩‍🏭🧑‍🏭👨‍🏭👩‍💻🧑‍💻👨‍💻👩‍💼🧑‍💼👨‍💼👩‍🔧🧑‍🔧👨‍🔧👩‍🔬🧑‍🔬👨‍🔬👩‍🎨🧑‍🎨👨‍🎨👩‍🚒🧑‍🚒👨‍🚒👩‍✈️🧑‍✈️👨‍✈️👩‍🚀🧑‍🚀👨‍🚀👩‍⚖️🧑‍⚖️👨‍⚖️👰‍♀️👰👰‍♂️🤵‍♀️🤵🤵‍♂️👸🫅🤴🥷🦸‍♀️🦸🦸‍♂️🦹‍♀️🦹🦹‍♂️🤶🧑‍🎄🎅🧙‍♀️🧙🧙‍♂️🧝‍♀️🧝🧝‍♂️🧛‍♀️🧛🧛‍♂️🧟‍♀️🧟🧟‍♂️🧞‍♀️🧞🧞‍♂️🧜‍♀️🧜🧜‍♂️🧚‍♀️🧚🧚‍♂️🧌👼🤰🫄🫃🤱👩‍🍼🧑‍🍼👨‍🍼🙇‍♀️🙇🙇‍♂️💁‍♀️💁💁‍♂️🙅‍♀️🙅🙅‍♂️🙆‍♀️🙆🙆‍♂️🙋‍♀️🙋🙋‍♂️🧏‍♀️🧏🧏‍♂️🤦‍♀️🤦🤦‍♂️🤷‍♀️🤷🤷‍♂️🙎‍♀️🙎🙎‍♂️🙍‍♀️🙍🙍‍♂️💇‍♀️💇💇‍♂️💆‍♀️💆💆‍♂️🧖‍♀️🧖🧖‍♂️💅🤳💃🕺👯‍♀️👯👯‍♂️🕴👩‍🦽👩‍🦽‍➡️🧑‍🦽🧑‍🦽‍➡️👨‍🦽👨‍🦽‍➡️👩‍🦼👩‍🦼‍➡️🧑‍🦼🧑‍🦼‍➡️👨‍🦼👨‍🦼‍➡️🚶‍♀️🚶‍♀️‍➡️🚶🚶‍➡️🚶‍♂️🚶‍♂️‍➡️👩‍🦯👩‍🦯‍➡️🧑‍🦯🧑‍🦯‍➡️👨‍🦯👨‍🦯‍➡️🧎‍♀️🧎‍♀️‍➡️🧎🧎‍➡️🧎‍♂️🧎‍♂️‍➡️🏃‍♀️🏃‍♀️‍➡️🏃🏃‍➡️🏃‍♂️🏃‍♂️‍➡️🧍‍♀️🧍🧍‍♂️👭🧑‍🤝‍🧑👬👫👩‍❤️‍👩💑👨‍❤️‍👨👩‍❤️‍👨👩‍❤️‍💋‍👩💏👨‍❤️‍💋‍👨👩‍❤️‍💋‍👨👪👨‍👩‍👦👨‍👩‍👧👨‍👩‍👧‍👦👨‍👩‍👦‍👦👨‍👩‍👧‍👧👨‍👨‍👦👨‍👨‍👧👨‍👨‍👧‍👦👨‍👨‍👦‍👦👨‍👨‍👧‍👧👩‍👩‍👦👩‍👩‍👧👩‍👩‍👧‍👦👩‍👩‍👦‍👦👩‍👩‍👧‍👧👨‍👦👨‍👦‍👦👨‍👧👨‍👧‍👦👨‍👧‍👧👩‍👦👩‍👦‍👦👩‍👧👩‍👧‍👦👩‍👧‍👧🧑‍🧑‍🧒🧑‍🧑‍🧒‍🧒🧑‍🧒🧑‍🧒‍🧒🗣👤👥🫂🧳🌂☂️🧵🪡🪢🪭🧶👓🕶🥽🥼🦺👔👕👖🧣🧤🧥🧦👗👘🥻🩴🩱🩲🩳👙👚👛👜👝🎒👞👟🥾🥿👠👡🩰👢👑👒🎩🎓🧢⛑🪖💄💍💼🐶🐱🐭🐹🐰🦊🐻🐼🐻‍❄️🐨🐯🦁🐮🐷🐽🐸🐵🙈🙉🙊🐒🐔🐧🐦🐦‍⬛🐤🐣🐥🦆🦅🦉🦇🐺🐗🐴🦄🐝🪱🐛🦋🐌🐞🐜🪰🪲🪳🦟🦗🕷🕸🦂🐢🐍🦎🦖🦕🐙🦑🦐🦞🦀🪼🪸🐡🐠🐟🐬🐳🐋🦈🐊🐅🐆🦓🫏🦍🦧🦣🐘🦛🦏🐪🐫🦒🦘🦬🐃🐂🐄🐎🐖🐏🐑🦙🐐🦌🫎🐕🐩🦮🐕‍🦺🐈🐈‍⬛🪽🪶🐓🦃🦤🦚🦜🦢🪿🦩🕊🐇🦝🦨🦡🦫🦦🦥🐁🐀🐿🦔🐾🐉🐲🐦‍🔥🌵🎄🌲🌳🌴🪹🪺🪵🌱🌿☘️🍀🎍🪴🎋🍃🍂🍁🍄🍄‍🟫🐚🪨🌾💐🌷🪷🌹🥀🌺🌸🪻🌼🌻🌞🌝🌛🌜🌚🌕🌖🌗🌘🌑🌒🌓🌔🌙🌎🌍🌏🪐💫⭐️🌟✨⚡️☄️💥🔥🌪🌈☀️🌤⛅️🌥☁️🌦🌧⛈🌩🌨❄️☃️⛄️🌬💨💧💦🫧☔️☂️🌊🍏🍎🍐🍊🍋🍋‍🟩🍌🍉🍇🍓🫐🍈🍒🍑🥭🍍🥥🥝🍅🍆🥑🥦🫛🥬🥒🌶🫑🌽🥕🫒🧄🧅🫚🥔🍠🫘🥐🥯🍞🥖🥨🧀🥚🍳🧈🥞🧇🥓🥩🍗🍖🦴🌭🍔🍟🍕🫓🥪🥙🧆🌮🌯🫔🥗🥘🫕🥫🍝🍜🍲🍛🍣🍱🥟🦪🍤🍙🍚🍘🍥🥠🥮🍢🍡🍧🍨🍦🥧🧁🍰🎂🍮🍭🍬🍫🍿🍩🍪🌰🥜🍯🥛🍼🫖☕️🍵🧃🥤🧋🫙🍶🍺🍻🥂🍷🫗🥃🍸🍹🧉🍾🧊🥄🍴🍽🥣🥡🥢🧂⚽️🏀🏈⚾️🥎🎾🏐🏉🥏🎱🪀🏓🏸🏒🏑🥍🏏🪃🥅⛳️🪁🏹🎣🤿🥊🥋🎽🛹🛼🛷⛸🥌🎿⛷🏂🪂🏋️‍♀️🏋️🏋️‍♂️🤼‍♀️🤼🤼‍♂️🤸‍♀️🤸🤸‍♂️⛹️‍♀️⛹️⛹️‍♂️🤺🤾‍♀️🤾🤾‍♂️🏌️‍♀️🏌️🏌️‍♂️🏇🧘‍♀️🧘🧘‍♂️🏄‍♀️🏄🏄‍♂️🏊‍♀️🏊🏊‍♂️🤽‍♀️🤽🤽‍♂️🚣‍♀️🚣🚣‍♂️🧗‍♀️🧗🧗‍♂️🚵‍♀️🚵🚵‍♂️🚴‍♀️🚴🚴‍♂️🏆🥇🥈🥉🏅🎖🏵🎗🎫🎟🎪🤹🤹‍♂️🤹‍♀️🎭🩰🎨🎬🎤🎧🎼🎹🥁🪘🪇🎷🎺🪗🎸🪕🎻🪈🎲♟🎯🎳🎮🎰🧩🚗🚕🚙🚌🚎🏎🚓🚑🚒🚐🛻🚚🚛🚜🦯🦽🦼🛴🚲🛵🏍🛺🚨🚔🚍🚘🚖🛞🚡🚠🚟🚃🚋🚞🚝🚄🚅🚈🚂🚆🚇🚊🚉✈️🛫🛬🛩💺🛰🚀🛸🚁🛶⛵️🚤🛥🛳⛴🚢⚓️🛟🪝⛽️🚧🚦🚥🚏🗺🗿🗽🗼🏰🏯🏟🎡🎢🛝🎠⛲️⛱🏖🏝🏜🌋⛰🏔🗻🏕⛺️🛖🏠🏡🏘🏚🏗🏭🏢🏬🏣🏤🏥🏦🏨🏪🏫🏩💒🏛⛪️🕌🕍🛕🕋⛩🛤🛣🗾🎑🏞🌅🌄🌠🎇🎆🌇🌆🏙🌃🌌🌉🌁⌚️📱📲💻⌨️🖥🖨🖱🖲🕹🗜💽💾💿📀📼📷📸📹🎥📽🎞📞☎️📟📠📺📻🎙🎚🎛🧭⏱⏲⏰🕰⌛️⏳📡🔋🪫🔌💡🔦🕯🪔🧯🛢🛍️💸💵💴💶💷🪙💰💳💎⚖️🪮🪜🧰🪛🔧🔨⚒🛠⛏🪚🔩⚙️🪤🧱⛓⛓️‍💥🧲🔫💣🧨🪓🔪🗡⚔️🛡🚬⚰️🪦⚱️🏺🔮📿🧿🪬💈⚗️🔭🔬🕳🩹🩺🩻🩼💊💉🩸🧬🦠🧫🧪🌡🧹🪠🧺🧻🚽🚰🚿🛁🛀🧼🪥🪒🧽🪣🧴🛎🔑🗝🚪🪑🛋🛏🛌🧸🪆🖼🪞🪟🛍🛒🎁🎈🎏🎀🪄🪅🎊🎉🪩🎎🏮🎐🧧✉️📩📨📧💌📥📤📦🏷🪧📪📫📬📭📮📯📜📃📄📑🧾📊📈📉🗒🗓📆📅🗑🪪📇🗃🗳🗄📋📁📂🗂🗞📰📓📔📒📕📗📘📙📚📖🔖🧷🔗📎🖇📐📏🧮📌📍✂️🖊🖋✒️🖌🖍📝✏️🔍🔎🔏🔐🔒🔓❤️🩷🧡💛💚💙🩵💜🖤🩶🤍🤎❤️‍🔥❤️‍🩹💔❣️💕💞💓💗💖💘💝💟☮️✝️☪️🪯🕉☸️✡️🔯🕎☯️☦️🛐⛎♈️♉️♊️♋️♌️♍️♎️♏️♐️♑️♒️♓️🆔⚛️🉑☢️☣️📴📳🈶🈚️🈸🈺🈷️✴️🆚💮🉐㊙️㊗️🈴🈵🈹🈲🅰️🅱️🆎🆑🅾️🆘❌⭕️🛑⛔️📛🚫💯💢♨️🚷🚯🚳🚱🔞📵🚭❗️❕❓❔‼️⁉️🔅🔆〽️⚠️🚸🔱⚜️🔰♻️✅🈯️💹❇️✳️❎🌐💠Ⓜ️🌀💤🏧🚾♿️🅿️🛗🈳🈂️🛂🛃🛄🛅🚹🚺🚼⚧🚻🚮🎦🛜📶🈁🔣ℹ️🔤🔡🔠🆖🆗🆙🆒🆕🆓0️⃣1️⃣2️⃣3️⃣4️⃣5️⃣6️⃣7️⃣8️⃣9️⃣🔟🔢#️⃣*️⃣⏏️▶️◀️🔼🔽➡️⬅️⬆️⬇️↗️↘️↙️↖️↕️↔️↪️↩️⤴️⤵️🔀🔁🔂🔄🔃🎵🎶➕➖➗✖️🟰♾💲💱™️©️®️〰️➰➿🔚🔙🔛🔝🔜✔️☑️🔘🔴🟠🟡🟢🔵🟣⚫️⚪️🟤🔺🔻🔸🔹🔶🔷🔳🔲▪️▫️◾️◽️◼️◻️🟥🟧🟨🟩🟦🟪⬛️⬜️🟫🔈🔇🔉🔊🔔🔕📣📢👁‍🗨💬💭🗯♠️♣️♥️♦️🃏🎴🀄️🕐🕑🕒🕓🕔🕕🕖🕗🕘🕙🕚🕛🕜🕝🕞◔🕡🕢🕣🕤🕥🕦🕧" : "😀😃😄😁😆😅😂🤣🥲🥹☺️😊😇🙂🙃😉😌😍🥰😘😗😙😚😋😛😝😜🤪🤨🧐🤓😎🥸🤩🥳🙂‍↕️😏😒🙂‍↔️😞😔😟😕🙁☹️😣😖😫😩🥺😢😭😮‍💨😤😠😡🤬🤯😳🥵🥶😱😨😰😥😓🫣🤗🤔🫢🤭🤫🤥😶😶‍🌫️😐😑😬🫨🫠🙄😯😦😧😮😲🥱😴🤤😪😵😵‍💫🤐🥴🤢🤮🤧😷🤒🤕🤑🤠😈👿🤡👽🤖🎃👹🌞🌝🌚🌕🌖🌗🌘🌑🌒🌓🌔🌎🌍🌏🌼🌺🌸🐵🦧🪨🍏🍎🍑🫑🍞🍔🍟🍚🍘🍥🧁🍱🍩🍪🌰🥡⚽️🏀🏈⚾️🥎🎾🏐🎱🎲🏵🎹🎰🚌🚑🚛🚞🚨🚔🚍🚖🚆🗺🗾🎑🏞🌅🌄🌠🎇🎆🌇🌆🏙🌃🌌🌉🌁🏨🏪🏩🏛🏠🏚🏢🏬🏣🏤🏥🏦⌚️💻🖲💽💾💿📀🎛🧭📺📟☎️⏰🕰🩻🔮🧿🪙🛎🖼🎁🪩📜📄📑🧾📊📈📉🗒🗓📆📅🗄📋📰📓📔📒📕📗📘📙📚📝💟☮️✝️☪️🪯🕉☸️✡️🔯🕎☯️☦️🛐⛎♈️♉️♊️♋️♌️♍️♎️♏️♐️♑️♒️♓️🆔⚛️🉑☢️☣️📴📳🈶🈚️🈸🈺🈷️✴️🆚💮🉐㊙️㊗️🈴🈵🈹🈲🅰️🅱️🆎🆑🅾️🆘🛑⛔️🚷🚯🚳🚱🔞📵🚭✅🈯️💹❇️✳️❎🌐Ⓜ️🏧🚾♿️🅿️🛗🈳🈂️🛂🛃🛄🛅🚹🚺🚼🚻🚮🎦🛜📶🈁🔣ℹ️🔤🔡🔠🆖🆗🆙🆒🆕🆓0️⃣1️⃣2️⃣3️⃣4️⃣5️⃣6️⃣7️⃣8️⃣9️⃣🔟🔢#️⃣*️⃣⏏️▶️⏩⏪⏫⏬◀️🔼🔽➡️⬅️⬆️⬇️↗️↘️↙️↖️↕️↔️↪️↩️⤴️⤵️🔀🔁🔂🔄🔃☑️🔘🔴🟠🟡🟢🔵🟣⚫️⚪️🟤🔳🔲🟥🟧🟨🟩🟦🟪⬛️⬜️🟫🕐🕑🕒🕓🕔🕕🕖🕗🕘🕙🕚🕛🕜🕝🕒🕓🕔🕕🕖🕗🕘🕙🕚🕛")
    if let randomString = characters.shuffled().first { return String(randomString) }
    return "🍎"
}
