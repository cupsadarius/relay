# Task 6 Report: Accessibility selected-text reading with clipboard fallback

## Status

Implemented and verified.

## Implementation

- Added `SelectionReading`, `AccessibilityReading`, and `ClipboardReading` protocols, all isolated to `MainActor` for actor-correct AppKit integration.
- Added `SelectionReader`, which reads Accessibility first and invokes clipboard copy only when Accessibility returns nil, empty, or whitespace-only text.
- Added the typed `SelectionReadingError.noUsableSelection` with the actionable message: “No selected text found. Select text and try again.” Clipboard fallback failures are normalized to this user-facing error.
- Added `AccessibilityService`, which reads the focused UI element and its selected-text attribute through `AXUIElement`. Unsupported/unavailable attributes return nil.
- Added `ClipboardService`, which snapshots the current pasteboard, sends Command-C with `CGEvent`, polls `changeCount` in ten 20 ms increments, reads the copied string, and restores the original pasteboard in `defer`.
- Added reusable `ClipboardSnapshot`, `ClipboardItemSnapshot`, and `ClipboardRepresentation` primitives. They preserve all pasteboard item types available as data, with a serialized property-list fallback, and can restore multiple pasteboard items and representations.
- Kept pasteboard access, copy-event delivery, and waiting behind injectable protocols so unit tests use deterministic fakes and require no Accessibility/Input Monitoring permissions.

## TDD evidence

1. Selection tests were written first. The focused test build failed because `SelectionReader`, `AccessibilityReading`, `ClipboardReading`, and `SelectionReadingError` did not exist.
2. The minimal reader and Accessibility implementation made the selection behavior pass.
3. Clipboard lifecycle and snapshot tests were written before `ClipboardService`; an unrestricted focused build failed on the missing clipboard types and protocols.
4. Implemented clipboard snapshot, polling, copy-event, and restoration behavior; 8 focused tests passed.
5. Self-review identified low-level clipboard errors escaping the selection boundary. A new regression test failed because the thrown error was not `SelectionReadingError.noUsableSelection`; the reader was then corrected to normalize the error.

## Verification

Command:

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data test
```

Result: `TEST SUCCEEDED`; 41 XCTest cases passed with 0 failures, plus 1 Swift Testing test passed.

## Self-review

- Confirmed Accessibility is always attempted before clipboard and that a usable Accessibility result never triggers Command-C.
- Confirmed nil, empty, and whitespace-only selections fall through or produce the typed actionable error.
- Confirmed clipboard restoration is registered before any throwing copy operation and runs on success, timeout, and thrown errors.
- Confirmed the timeout is bounded at 200 ms in exact 20 ms increments.
- Confirmed live AX, pasteboard, event, and wait behavior is absent from unit tests.

## Concerns

- Live Accessibility and synthesized Command-C behavior still depends on the user granting the corresponding macOS permissions; unit coverage intentionally validates orchestration through fakes rather than prompting for those permissions.
- Pasteboard representations backed only by lazy providers and unavailable as either immediate data or a serializable property list cannot be materialized. All immediately representable item/type data is preserved.
