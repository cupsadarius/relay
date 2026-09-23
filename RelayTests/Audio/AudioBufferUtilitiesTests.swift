import AVFoundation
import XCTest
@testable import Relay

final class AudioBufferUtilitiesTests: XCTestCase {
    // MARK: - Level

    func testLevelOfSilenceAndOfNothingIsZero() {
        XCTAssertEqual(AudioBufferUtilities.level(of: [Float](repeating: 0, count: 1_920)), 0)
        XCTAssertEqual(AudioBufferUtilities.level(of: []), 0)
    }

    func testLevelClampsToOne() {
        XCTAssertEqual(AudioBufferUtilities.level(of: [Float](repeating: 1, count: 1_920)), 1)
        XCTAssertEqual(AudioBufferUtilities.level(of: [1, -1]), 1)
    }

    func testLevelIsRMSTimesFour() {
        // The RMS of a constant signal is its amplitude.
        XCTAssertEqual(AudioBufferUtilities.level(of: [Float](repeating: 0.2, count: 1_920)), 0.8, accuracy: 0.0001)
    }

    // MARK: - Converter

    func testConvertResamples48kTo16kAndFlushesAtEndOfStream() throws {
        let input = try Self.monoBuffer(sampleRate: 48_000, frames: 4_800) { Float(sin(Double($0) * 0.05)) }
        let outputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let converter = try XCTUnwrap(AVAudioConverter(from: input.format, to: outputFormat))
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1_700))

        let result = AudioBufferUtilities.convert(input, into: output, using: converter, exhaustedStatus: .endOfStream)

        XCTAssertNotEqual(result.status, .error)
        XCTAssertNil(result.error)
        XCTAssertEqual(Double(output.frameLength), 1_600, accuracy: 16)
    }

    func testConvertHandsTheInputOverExactlyOnce() throws {
        let input = try Self.monoBuffer(sampleRate: 24_000, frames: 100) { _ in 0.25 }
        let outputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: true))
        let converter = try XCTUnwrap(AVAudioConverter(from: input.format, to: outputFormat))
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 400))

        let result = AudioBufferUtilities.convert(input, into: output, using: converter)

        XCTAssertNotEqual(result.status, .error)
        XCTAssertEqual(output.frameLength, 100, "feeding the buffer twice would double the output")
    }

    // MARK: - Interleave

    func testInterleaveAndDeinterleaveRoundTripStereo() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 2, interleaved: false))
        let planar = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        planar.frameLength = 3
        let channels = try XCTUnwrap(planar.floatChannelData)
        for index in 0..<3 {
            channels[0][index] = Float(index)        // left: 0 1 2
            channels[1][index] = Float(index) + 10   // right: 10 11 12
        }

        let interleaved = AudioBufferUtilities.interleave(channels, channelCount: 2, frameLength: 3)
        XCTAssertEqual(interleaved, [0, 10, 1, 11, 2, 12])

        let back = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        back.frameLength = 3
        let backChannels = try XCTUnwrap(back.floatChannelData)
        AudioBufferUtilities.deinterleave(interleaved, channelCount: 2, into: backChannels)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: backChannels[0], count: 3)), [0, 1, 2])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: backChannels[1], count: 3)), [10, 11, 12])
    }

    func testMonoInterleaveIsACopy() throws {
        let buffer = try Self.monoBuffer(sampleRate: 24_000, frames: 4) { Float($0) }
        let channels = try XCTUnwrap(buffer.floatChannelData)
        XCTAssertEqual(AudioBufferUtilities.interleave(channels, channelCount: 1, frameLength: 4), [0, 1, 2, 3])
    }

    private static func monoBuffer(sampleRate: Double, frames: Int, sample: (Int) -> Float) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<frames { channel[index] = sample(index) }
        return buffer
    }
}
