//
//  HotkeyMonitor.swift
//  Mac native speech to text
//
//  Created by Kartik Khorwal on 4/8/26.
//

import Cocoa
import Carbon.HIToolbox

class HotkeyMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?
    private var isHotkeyHeld = false
    private var fnIsDown = false
    private let onHotkeyDown: () -> Void
    private let onHotkeyUp: () -> Void
    private let onHandsFreeToggle: () -> Void
    private let onCancel: () -> Void

    // Fn (Globe) key
    private static let fnKeyCode: Int64 = 63
    // Space key
    private static let spaceKeyCode: Int64 = 49
    // Escape key
    private static let escapeKeyCode: Int64 = 53
    // Delete/Backspace key
    private static let deleteKeyCode: Int64 = 51

    /// Whether the event tap is active
    var isRunning: Bool { eventTap != nil }

    /// Whether hands-free mode is active (managed externally, read by event handler)
    var isHandsFree = false

    /// Ignore the next Fn release (used when activating hands-free while Fn is held)
    private var ignoreFnRelease = false

    /// Track whether Space is currently held to ignore key-repeat events
    private var spaceIsDown = false

    init(
        onHotkeyDown: @escaping () -> Void,
        onHotkeyUp: @escaping () -> Void,
        onHandsFreeToggle: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onHotkeyDown = onHotkeyDown
        self.onHotkeyUp = onHotkeyUp
        self.onHandsFreeToggle = onHandsFreeToggle
        self.onCancel = onCancel
    }

    /// Open System Settings to the Keyboard pane
    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        if eventTap != nil { return }

        // Listen for flagsChanged (Fn), keyDown, and keyUp
        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[HotkeyMonitor] Failed to create event tap — will retry when Accessibility is granted")
            startRetrying()
            return
        }

        stopRetrying()
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        print("[HotkeyMonitor] started — listening for Fn (hold) and Fn+Space (hands-free)")
    }

    func stop() {
        stopRetrying()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
            print("[HotkeyMonitor] stopped")
        }
    }

    // MARK: - Retry

    private func startRetrying() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if AXIsProcessTrusted() {
                print("[HotkeyMonitor] Accessibility now granted — retrying event tap")
                self.start()
            }
        }
    }

    private func stopRetrying() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    // MARK: - Event handling

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable if the system disabled our tap
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // MARK: Key up — track Space release
        if type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == HotkeyMonitor.spaceKeyCode {
                spaceIsDown = false
            }
            // Swallow Space/Escape key-up if hands-free is active to avoid leaking to app
            if isHandsFree && (keyCode == HotkeyMonitor.spaceKeyCode || keyCode == HotkeyMonitor.escapeKeyCode) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // MARK: Key down handling
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            // Fn+Space while not already in hands-free → toggle on (only on first press)
            if keyCode == HotkeyMonitor.spaceKeyCode && fnIsDown && !isHandsFree && !spaceIsDown {
                spaceIsDown = true
                print("[HotkeyMonitor] >>> Fn+Space — hands-free toggle ON")
                ignoreFnRelease = true // don't stop on the upcoming Fn release
                DispatchQueue.main.async { [weak self] in
                    self?.onHandsFreeToggle()
                }
                return nil
            }

            // Swallow Space repeats while held (Fn+Space or during hands-free)
            if keyCode == HotkeyMonitor.spaceKeyCode && spaceIsDown {
                return nil
            }

            // Delete/Backspace → cancel only if actively recording
            if keyCode == HotkeyMonitor.deleteKeyCode && (isHotkeyHeld || isHandsFree) {
                print("[HotkeyMonitor] >>> CANCEL (Delete)")
                isHotkeyHeld = false
                isHandsFree = false
                DispatchQueue.main.async { [weak self] in
                    self?.onCancel()
                }
                return nil
            }

            // In hands-free mode: Space (fresh press) or Escape → stop
            if isHandsFree {
                if keyCode == HotkeyMonitor.spaceKeyCode {
                    spaceIsDown = true
                    print("[HotkeyMonitor] >>> hands-free OFF (Space)")
                    DispatchQueue.main.async { [weak self] in
                        self?.onHandsFreeToggle()
                    }
                    return nil
                }
                if keyCode == HotkeyMonitor.escapeKeyCode {
                    print("[HotkeyMonitor] >>> hands-free OFF (Escape)")
                    DispatchQueue.main.async { [weak self] in
                        self?.onHandsFreeToggle()
                    }
                    return nil
                }
            }

            return Unmanaged.passUnretained(event)
        }

        // MARK: Fn key (flagsChanged)
        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == HotkeyMonitor.fnKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let fnHeld = flags.contains(.maskSecondaryFn)

        if fnHeld && !fnIsDown {
            // Fn pressed down
            fnIsDown = true

            // In hands-free mode, ignore Fn hold
            if isHandsFree {
                return nil
            }

            // Space is already held when Fn comes down → activate hands-free
            if spaceIsDown {
                print("[HotkeyMonitor] >>> Fn DOWN while Space held — hands-free toggle ON")
                ignoreFnRelease = true
                DispatchQueue.main.async { [weak self] in
                    self?.onHandsFreeToggle()
                }
                return nil
            }

            isHotkeyHeld = true
            print("[HotkeyMonitor] >>> Fn DOWN")
            DispatchQueue.main.async { [weak self] in
                self?.onHotkeyDown()
            }
            return nil

        } else if !fnHeld && fnIsDown {
            // Fn released
            fnIsDown = false

            // Skip this release if hands-free was just activated while Fn was held
            if ignoreFnRelease {
                ignoreFnRelease = false
                return nil
            }

            // In hands-free mode, ignore Fn release — only Fn+Space stops it
            if isHandsFree {
                return nil
            }

            if isHotkeyHeld {
                isHotkeyHeld = false
                print("[HotkeyMonitor] <<< Fn UP")
                DispatchQueue.main.async { [weak self] in
                    self?.onHotkeyUp()
                }
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    deinit {
        stop()
    }
}
