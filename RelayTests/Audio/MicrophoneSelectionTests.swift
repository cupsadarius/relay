import XCTest

@testable import Relay

final class MicrophoneSelectionTests: XCTestCase {
    private let builtIn = AudioInputDevice(id: 10, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    private let airPods = AudioInputDevice(id: 20, uid: "AA-BB:input", name: "AirPods Pro")

    func testNoChoiceUsesDefault() {
        XCTAssertEqual(
            MicrophoneSelection.resolve(nil, connected: [builtIn, airPods]),
            .init(device: nil, missing: nil)
        )
    }

    func testConnectedChoiceIsUsed() {
        let choice = SelectedMicrophone(uid: builtIn.uid, name: builtIn.name)
        XCTAssertEqual(
            MicrophoneSelection.resolve(choice, connected: [airPods, builtIn]),
            .init(device: builtIn, missing: nil)
        )
    }

    func testMissingChoiceFallsBackToDefaultWithNote() {
        let choice = SelectedMicrophone(uid: "gone", name: "Old Headset")
        XCTAssertEqual(
            MicrophoneSelection.resolve(choice, connected: [builtIn]),
            .init(device: nil, missing: choice)
        )
    }
}
