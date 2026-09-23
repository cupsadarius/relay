@preconcurrency import CoreFoundation
@preconcurrency import CoreGraphics
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
    private let uptime: () -> TimeInterval
    private var activeChordActions = Set<HotkeyAction>()
    private var functionIsDown = false
    private var functionOnlyActions = Set<HotkeyAction>()
    private var previousModifiers = Set<HotkeyModifier>()
    private var doubleTapState = DoubleTapState.idle

    private enum DoubleTapState {
        case idle
        case firstPress(HotkeyModifier, HotkeyAction, TimeInterval)
        case awaitingSecondPress(HotkeyModifier, HotkeyAction, TimeInterval)
        case secondPress(HotkeyModifier, HotkeyAction)
    }

    private static let doubleTapWindow: TimeInterval = 0.5

    init(
        definitions: [HotkeyAction: HotkeyDefinition],
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.definitions = definitions
        self.uptime = uptime
    }

    mutating func match(_ event: HotkeyInputEvent) -> [HotkeyInvocation] {
        switch event {
        case let .keyDown(keyCode, modifiers, isRepeat):
            cancelPendingDoubleTap()
            guard !isRepeat else { return [] }
            guard let action = chordAction(keyCode: keyCode, modifiers: modifiers),
                activeChordActions.insert(action).inserted
            else { return [] }
            return [HotkeyInvocation(action: action, phase: .pressed)]

        case let .keyUp(keyCode, _):
            cancelPendingDoubleTap()
            let actions = HotkeyAction.allCases.filter { action in
                guard activeChordActions.contains(action),
                    case let .chord(definedKeyCode, _) = definitions[action]
                else { return false }
                return definedKeyCode == keyCode
            }
            activeChordActions.subtract(actions)
            return actions.map { HotkeyInvocation(action: $0, phase: .released) }

        case let .flagsChanged(modifiers):
            // Ignore no-op repeats: some keyboards (notably Fn/external ones) resend the current
            // modifier state without an actual change. A strict alternating-state guard below
            // would otherwise treat that duplicate as a genuine extra modifier and cancel any
            // pending double-tap gesture.
            guard modifiers != previousModifiers else { return [] }
            let doubleTapInvocations = matchDoubleTapModifier(modifiers: modifiers)
            previousModifiers = modifiers
            if !doubleTapInvocations.isEmpty { return doubleTapInvocations }

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

    private mutating func matchDoubleTapModifier(
        modifiers: Set<HotkeyModifier>
    ) -> [HotkeyInvocation] {
        let currentTime = uptime()
        switch doubleTapState {
        case let .secondPress(modifier, activeAction):
            if !modifiers.contains(modifier) {
                doubleTapState = .idle
                return [.init(action: activeAction, phase: .released)]
            }
            return []

        case let .firstPress(modifier, action, _):
            // Tap 1's hold duration is deliberately not charged against the double-tap window:
            // only the release→second-press gap (checked below, in .awaitingSecondPress) governs
            // whether the gesture is recognized, so a user holding tap 1 a bit long still arms it.
            guard previousModifiers == [modifier], modifiers.isEmpty
            else {
                cancelPendingDoubleTap()
                return []
            }
            doubleTapState = .awaitingSecondPress(modifier, action, currentTime)

        case let .awaitingSecondPress(modifier, action, releasedAt):
            guard modifiers == [modifier],
                currentTime - releasedAt <= Self.doubleTapWindow
            else {
                cancelPendingDoubleTap()
                return []
            }
            doubleTapState = .secondPress(modifier, action)
            return [.init(action: action, phase: .pressed)]

        case .idle:
            guard modifiers.count == 1,
                let modifier = modifiers.first,
                let action = doubleTapAction(for: modifier),
                !previousModifiers.contains(modifier)
            else { return [] }
            doubleTapState = .firstPress(modifier, action, currentTime)
        }
        return []
    }

    private mutating func cancelPendingDoubleTap() {
        switch doubleTapState {
        case .firstPress, .awaitingSecondPress:
            doubleTapState = .idle
        case .idle, .secondPress:
            break
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

    private func doubleTapAction(for modifier: HotkeyModifier) -> HotkeyAction? {
        HotkeyAction.allCases.first { definitions[$0] == .doubleTapModifier(modifier) }
    }
}

enum HotkeyRegistrationStatus: Equatable, Sendable {
    case registered
    case unavailable(String)
}

@MainActor
protocol HotkeyManaging: AnyObject {
    func setHandler(_ handler: @escaping @MainActor (HotkeyAction, HotkeyPhase) -> Void)
    /// Creates the event tap if it doesn't exist yet; never re-creates it. Cheap to call often.
    @discardableResult
    func ensureTap() -> HotkeyRegistrationStatus
    /// Rebuilds the matcher only when `definitions` differ from the current ones, so an
    /// unchanged update never discards in-flight chord/double-tap state.
    func update(definitions: [HotkeyAction: HotkeyDefinition])
}

@MainActor
final class GlobalHotkeyManager: HotkeyManaging {
    static let permissionFailureMessage =
        "Global hotkeys need Accessibility permission. Enable Relay in System Settings > Privacy & Security > Accessibility, then retry in Diagnostics. Input Monitoring is an alternative for listen-only access."

    private let diagnostics: DiagnosticsRecorder?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var matcher = HotkeyMatcher(definitions: [:])
    private var definitions: [HotkeyAction: HotkeyDefinition] = [:]
    private var handler: (@MainActor (HotkeyAction, HotkeyPhase) -> Void)?
    /// Creates the underlying Mach port `register()` treats as "the event tap". Defaults to the
    /// real `CGEvent.tapCreate` call. Injectable only so tests can verify `register()`'s
    /// `eventTap != nil` guard (never recreating the tap on subsequent calls) with a factory that
    /// succeeds deterministically, instead of depending on this machine's Accessibility
    /// permission at test time.
    private let tapFactory: @MainActor (CGEventMask, UnsafeMutableRawPointer) -> CFMachPort?

    init(
        diagnostics: DiagnosticsRecorder? = nil,
        tapFactory: @escaping @MainActor (CGEventMask, UnsafeMutableRawPointer) -> CFMachPort? = GlobalHotkeyManager.createRealTap
    ) {
        self.diagnostics = diagnostics
        self.tapFactory = tapFactory
    }

    private static func createRealTap(mask: CGEventMask, userInfo: UnsafeMutableRawPointer) -> CFMachPort? {
        CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: userInfo
        )
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
    }

    func setHandler(_ handler: @escaping @MainActor (HotkeyAction, HotkeyPhase) -> Void) {
        self.handler = handler
    }

    func update(definitions: [HotkeyAction: HotkeyDefinition]) {
        guard definitions != self.definitions else { return }
        self.definitions = definitions
        matcher = HotkeyMatcher(definitions: definitions)
    }

    @discardableResult
    func ensureTap() -> HotkeyRegistrationStatus {
        if eventTap != nil {
            diagnostics?.record(.eventTapRegistered)
            return .registered
        }

        let mask =
            CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = tapFactory(mask, pointer) else {
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

    /// Feeds one decoded input event through the matcher. Internal so tests can drive it without CGEvents.
    func receive(_ input: HotkeyInputEvent) {
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
