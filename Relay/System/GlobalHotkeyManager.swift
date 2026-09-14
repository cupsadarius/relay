@preconcurrency import CoreGraphics
@preconcurrency import CoreFoundation
import Foundation

enum HotkeyPhase: Equatable, Sendable {
    case pressed
    case released
}

struct HotkeyInvocation: Equatable, Sendable {
    let action: HotkeyAction
    let phase: HotkeyPhase
}

enum HotkeyInputEvent: Equatable, Sendable {
    case keyDown(keyCode: UInt16, modifiers: Set<HotkeyModifier>, isRepeat: Bool)
    case keyUp(keyCode: UInt16, modifiers: Set<HotkeyModifier>)
    case flagsChanged(modifiers: Set<HotkeyModifier>)
}

struct HotkeyMatcher {
    private let definitions: [HotkeyAction: HotkeyDefinition]
    private var activeChordActions = Set<HotkeyAction>()
    private var functionIsDown = false
    private var functionOnlyActions = Set<HotkeyAction>()

    init(definitions: [HotkeyAction: HotkeyDefinition]) {
        self.definitions = definitions
    }

    mutating func match(_ event: HotkeyInputEvent) -> [HotkeyInvocation] {
        switch event {
        case let .keyDown(keyCode, modifiers, isRepeat):
            guard !isRepeat else { return [] }
            guard let action = chordAction(keyCode: keyCode, modifiers: modifiers),
                  activeChordActions.insert(action).inserted
            else { return [] }
            return [HotkeyInvocation(action: action, phase: .pressed)]

        case let .keyUp(keyCode, _):
            let actions = HotkeyAction.allCases.filter { action in
                guard activeChordActions.contains(action),
                      case let .chord(definedKeyCode, _) = definitions[action]
                else { return false }
                return definedKeyCode == keyCode
            }
            activeChordActions.subtract(actions)
            return actions.map { HotkeyInvocation(action: $0, phase: .released) }

        case let .flagsChanged(modifiers):
            let isDown = modifiers.contains(.function)
            defer { functionIsDown = isDown }

            if isDown, !functionIsDown {
                guard modifiers == [.function] else { return [] }
                guard let action = modifierOnlyFunctionAction() else { return [] }
                functionOnlyActions.insert(action)
                return [HotkeyInvocation(action: action, phase: .pressed)]
            }

            if !isDown, functionIsDown {
                let actions = HotkeyAction.allCases.filter(functionOnlyActions.contains)
                functionOnlyActions.removeAll()
                return actions.map { HotkeyInvocation(action: $0, phase: .released) }
            }

            return []
        }
    }

    private func chordAction(
        keyCode: UInt16,
        modifiers: Set<HotkeyModifier>
    ) -> HotkeyAction? {
        HotkeyAction.allCases.first { action in
            guard case let .chord(definedKeyCode, definedModifiers) = definitions[action]
            else { return false }
            return definedKeyCode == keyCode && definedModifiers == modifiers
        }
    }

    private func modifierOnlyFunctionAction() -> HotkeyAction? {
        HotkeyAction.allCases.first { definitions[$0] == .modifierOnly(.function) }
    }
}

enum HotkeyRegistrationStatus: Equatable, Sendable {
    case registered
    case unavailable(String)
}

@MainActor
protocol HotkeyManaging: AnyObject {
    @discardableResult
    func register(
        settings: AppSettings,
        handler: @escaping @MainActor (HotkeyAction, HotkeyPhase) -> Void
    ) -> HotkeyRegistrationStatus
}

@MainActor
final class GlobalHotkeyManager: HotkeyManaging {
    static let permissionFailureMessage = "Global hotkeys need Accessibility permission. Enable Relay in System Settings > Privacy & Security > Accessibility, then retry in Diagnostics. Input Monitoring is an alternative for listen-only access."

    private let diagnostics: DiagnosticsRecorder?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var matcher = HotkeyMatcher(definitions: [:])
    private var handler: (@MainActor (HotkeyAction, HotkeyPhase) -> Void)?

    init(diagnostics: DiagnosticsRecorder? = nil) { self.diagnostics = diagnostics }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
    }

    @discardableResult
    func register(
        settings: AppSettings,
        handler: @escaping @MainActor (HotkeyAction, HotkeyPhase) -> Void
    ) -> HotkeyRegistrationStatus {
        matcher = HotkeyMatcher(definitions: settings.hotkeys)
        self.handler = handler

        if eventTap != nil {
            diagnostics?.record(.eventTapRegistered)
            return .registered
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: pointer
        ) else {
            diagnostics?.record(.eventTapUnavailable)
            return .unavailable(Self.permissionFailureMessage)
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        diagnostics?.record(.eventTapRegistered)
        return .registered
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated { manager.diagnostics?.record(.eventTapDisabled) }
            MainActor.assumeIsolated { manager.reenableTap() }
            return Unmanaged.passUnretained(event)
        }

        guard let input = GlobalHotkeyManager.inputEvent(type: type, event: event) else {
            return Unmanaged.passUnretained(event)
        }
        MainActor.assumeIsolated { manager.receive(input) }
        return Unmanaged.passUnretained(event)
    }

    private static func inputEvent(type: CGEventType, event: CGEvent) -> HotkeyInputEvent? {
        let modifiers = hotkeyModifiers(from: event.flags)
        switch type {
        case .keyDown:
            return .keyDown(
                keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                modifiers: modifiers,
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            )
        case .keyUp:
            return .keyUp(
                keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                modifiers: modifiers
            )
        case .flagsChanged:
            return .flagsChanged(modifiers: modifiers)
        default:
            return nil
        }
    }

    private static func hotkeyModifiers(from flags: CGEventFlags) -> Set<HotkeyModifier> {
        var result = Set<HotkeyModifier>()
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskSecondaryFn) { result.insert(.function) }
        return result
    }

    private func receive(_ input: HotkeyInputEvent) {
        diagnostics?.record(.keyboardEventReceived)
        for invocation in matcher.match(input) {
            diagnostics?.record(.hotkeyMatched(action: invocation.action, phase: invocation.phase))
            handler?(invocation.action, invocation.phase)
        }
    }

    private func reenableTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            diagnostics?.record(.eventTapReenabled)
        }
    }
}
