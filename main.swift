import AppKit
import ApplicationServices
import CoreAudio
import ServiceManagement

// MARK: - Settings (per user, stored in UserDefaults; never in the repository)
//
//   defaults write <bundle id> outputDevice "My Monitor"   pin a specific output device by name
//   defaults delete <bundle id> outputDevice               back to automatic (first HDMI/DisplayPort output)
//   defaults write <bundle id> step 10                     volume step per key press (percent, default 5)

let bundleID = Bundle.main.bundleIdentifier ?? "MonitorKeys"
let defaults = UserDefaults.standard
let volumeStep = max(1, min(50, defaults.object(forKey: "step") as? Int ?? 5))
let automaticTransports: [UInt32] = [kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort]

// MARK: - Core Audio helpers

func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func deviceName(_ device: AudioDeviceID) -> String? {
    var property = address(kAudioObjectPropertyName)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout.size(ofValue: name))
    guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &name) == noErr else { return nil }
    return name?.takeRetainedValue() as String?
}

func transportType(_ device: AudioDeviceID) -> UInt32 {
    var property = address(kAudioDevicePropertyTransportType)
    var type = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(device, &property, 0, nil, &size, &type) == noErr ? type : 0
}

func hasOutput(_ device: AudioDeviceID) -> Bool {
    var property = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
    var size = UInt32(0)
    return AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr && size > 0
}

func outputDevices() -> [AudioDeviceID] {
    var property = address(kAudioHardwarePropertyDevices)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr else { return [] }
    var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &devices) == noErr else { return [] }
    return devices.filter(hasOutput)
}

func defaultOutputDevice() -> AudioDeviceID? {
    var property = address(kAudioHardwarePropertyDefaultOutputDevice)
    var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device) == noErr else { return nil }
    return device
}

// Same effect as picking the device in System Settings: sound output and alert sounds.
func setDefaultOutput(_ device: AudioDeviceID) {
    for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
        var property = address(selector)
        var id = device
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
    }
}

// The device this helper manages: the configured name, otherwise the first HDMI/DisplayPort output.
func targetDevice() -> AudioDeviceID? {
    let devices = outputDevices()
    if let name = defaults.string(forKey: "outputDevice") { return devices.first { deviceName($0) == name } }
    return devices.first { automaticTransports.contains(transportType($0)) }
}

// The target device, but only while it is the system's current output.
func activeDevice() -> AudioDeviceID? {
    guard let target = targetDevice(), defaultOutputDevice() == target else { return nil }
    return target
}

// MARK: - Volume model

enum Action { case up, down, mute }

struct Volume {
    var level: Int = 100
    var audible: Int = 100
    mutating func apply(_ action: Action) {
        if level > 0 { audible = level }
        switch action {
        case .up: level = min(100, level + volumeStep)
        case .down: level = max(0, level - volumeStep)
        case .mute: level = level > 0 ? 0 : min(100, max(1, audible))
        }
    }
}

if CommandLine.arguments.contains("--self-test") {
    var v = Volume(level: 98, audible: 50)
    v.apply(.up); precondition(v.level == 100)
    v.apply(.mute); precondition(v.level == 0)
    v.apply(.mute); precondition(v.level == 100)
    v.level = 2; v.apply(.down); precondition(v.level == 0)
    precondition(audio_self_test())
    print("PASS: gain scaling, exact mute, volume bounds and mute restore.")
    exit(0)
}

// MARK: - Menu bar app

final class Helper: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var status: NSMenuItem!
    var levelItem: NSMenuItem!
    var slider: NSSlider!
    var deviceMenu: NSMenu!
    var loginItem: NSMenuItem!
    var tap: CFMachPort?
    var timer: Timer?
    var currentDevice: AudioDeviceID?
    var running = false
    var starting = false
    var targetPresent = false
    var volume = Volume()
    var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil); return
        }
        volume.level = min(100, max(0, defaults.object(forKey: "level") as? Int ?? 100))
        volume.audible = min(100, max(1, defaults.object(forKey: "audible") as? Int ?? 100))
        audio_set_level(Float(volume.level) / 100)
        buildMenu()

        // Start at login on first launch; the menu toggle turns it off again.
        if !defaults.bool(forKey: "loginItemConfigured") {
            defaults.set(true, forKey: "loginItemConfigured")
            setLoginItem(true)
        }

        // Route sound to the target whenever it (re)appears: plug-in, wake, boot.
        targetPresent = targetDevice() != nil
        if let target = targetDevice() { setDefaultOutput(target) }
        var devices = address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, .main) { [weak self] _, _ in
            guard let self = self else { return }
            let present = targetDevice() != nil
            if present && !self.targetPresent, let target = targetDevice() { setDefaultOutput(target) }
            self.targetPresent = present
            self.rebuildDeviceMenu()
        }

        // Start after launch so the system audio permission prompt is attributed to this app.
        DispatchQueue.main.async { self.restart() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(restart), name: NSWorkspace.didWakeNotification, object: nil)

        // SIGTERM quits cleanly; SIGUSR1 prints a status line; SIGUSR2 opens the Accessibility prompt.
        for (number, handler) in [(SIGTERM, { NSApp.terminate(nil) }), (SIGUSR1, { self.logStatus() }), (SIGUSR2, { self.requestPermission() })] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler(handler: handler); source.resume()
            signalSources.append(source)
        }
    }

    func buildMenu() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        status = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        levelItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(status); menu.addItem(levelItem)
        slider = NSSlider(value: Double(volume.level), minValue: 0, maxValue: 100, target: self, action: #selector(slide))
        slider.frame = NSRect(x: 12, y: 6, width: 200, height: 24)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 224, height: 36))
        view.addSubview(slider)
        let sliderItem = NSMenuItem(); sliderItem.view = view; menu.addItem(sliderItem)
        menu.addItem(entry("Mute / Unmute", #selector(mute)))
        menu.addItem(.separator())
        let devices = NSMenuItem(title: "Output Device", action: nil, keyEquivalent: "")
        deviceMenu = NSMenu(); devices.submenu = deviceMenu; menu.addItem(devices)
        rebuildDeviceMenu()
        menu.addItem(entry("Enable Keyboard Control…", #selector(requestPermission)))
        loginItem = entry("Start at Login", #selector(toggleLoginItem)); menu.addItem(loginItem)
        menu.addItem(entry("Restart Audio", #selector(restart)))
        menu.addItem(.separator())
        menu.addItem(entry("Quit (restore normal volume)", #selector(quit)))
        item.menu = menu
        updateUI()
    }

    func entry(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    func rebuildDeviceMenu() {
        deviceMenu.removeAllItems()
        let pinned = defaults.string(forKey: "outputDevice")
        let automatic = entry("Automatic (first HDMI / DisplayPort)", #selector(chooseDevice))
        automatic.state = pinned == nil ? .on : .off
        deviceMenu.addItem(automatic)
        deviceMenu.addItem(.separator())
        for device in outputDevices() {
            guard let name = deviceName(device) else { continue }
            let choice = entry(name, #selector(chooseDevice))
            choice.representedObject = name
            choice.state = name == pinned ? .on : .off
            deviceMenu.addItem(choice)
        }
    }

    @objc func chooseDevice(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { defaults.set(name, forKey: "outputDevice") }
        else { defaults.removeObject(forKey: "outputDevice") }
        rebuildDeviceMenu()
        if let target = targetDevice() { setDefaultOutput(target) }
        restart()
    }

    func setLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { fputs("MonitorKeys: login item: \(error)\n", stderr) }
        updateUI()
    }
    @objc func toggleLoginItem() { setLoginItem(SMAppService.mainApp.status != .enabled) }

    func updateUI() {
        item.button?.title = volume.level == 0 ? "Muted" : "Vol \(volume.level)%"
        levelItem.title = "Mac output level: \(volume.level)%"
        slider.doubleValue = Double(volume.level)
        slider.isEnabled = running
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    func setLevel() {
        audio_set_level(Float(volume.level) / 100)
        defaults.set(volume.level, forKey: "level"); defaults.set(volume.audible, forKey: "audible")
        updateUI()
    }
    @objc func slide() {
        volume.level = Int(slider.doubleValue.rounded())
        if volume.level > 0 { volume.audible = volume.level }
        setLevel()
    }
    @objc func mute() { if running { volume.apply(.mute); setLevel() } }
    @objc func sleeping() { audio_stop(); running = false; currentDevice = nil; updateUI() }

    @objc func restart() {
        guard !starting else { return }
        starting = true
        defer { starting = false; updateUI() }
        audio_stop(); running = false
        currentDevice = activeDevice()
        guard let device = currentDevice else {
            if let target = targetDevice(), let name = deviceName(target) { status.title = "Select \(name) as the sound output" }
            else if defaults.string(forKey: "outputDevice") != nil { status.title = "Configured output device not connected" }
            else { status.title = "No HDMI or DisplayPort output found" }
            return
        }
        running = audio_start(device)
        if running {
            status.title = "Adjusting Mac output · monitor volume untouched"
            installTap()
        } else {
            status.title = "Audio failed: \(String(cString: audio_error()))"
        }
        fputs("MonitorKeys: \(status.title)\n", stderr)
    }

    func tick() {
        guard !starting else { return }
        if activeDevice() != currentDevice { restart(); return }
        // The tap only delivers callbacks while something is playing; silence at idle is normal.
        if running && tap == nil && AXIsProcessTrusted() { installTap() }
    }

    @objc func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) { installTap() }
    }

    func installTap() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            status.title = "Audio ready · keyboard needs Accessibility permission"
            return
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(1 << 14),  // NX_SYSDEFINED
            callback: { _, type, event, context in
                guard let context = context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<Helper>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                guard owner.running, activeDevice() == owner.currentDevice,
                    let ns = NSEvent(cgEvent: event), ns.type == .systemDefined,
                    ns.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }  // NX_SUBTYPE_AUX_CONTROL_BUTTONS
                let action: Action
                switch (ns.data1 >> 16) & 0xffff {
                case 0: action = .up; case 1: action = .down; case 7: action = .mute
                default: return Unmanaged.passUnretained(event)
                }
                let down = ((ns.data1 >> 8) & 0xff) == 0x0a
                let repeated = (ns.data1 & 1) != 0
                if down && !(action == .mute && repeated) {
                    owner.volume.apply(action); owner.setLevel()
                }
                return nil  // consumed: macOS does not show its own (disabled) volume overlay
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap = tap else { status.title = "Could not capture volume keys; check Accessibility and retry"; return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        status.title = "Volume keys active · monitor volume untouched"
    }

    func logStatus() {
        let target = targetDevice().flatMap(deviceName) ?? "none"
        fputs("MonitorKeys: status=\"\(status.title)\" target=\"\(target)\" running=\(running) level=\(volume.level) callbacks=\(audio_callbacks()) inputPeak=\(audio_input_peak()) outputPeak=\(audio_output_peak()) accessibility=\(AXIsProcessTrusted()) keyboardTap=\(tap != nil) loginItem=\(SMAppService.mainApp.status == .enabled)\n", stderr)
    }

    func applicationWillTerminate(_ notification: Notification) { audio_stop() }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let helper = Helper()
app.delegate = helper
app.run()
