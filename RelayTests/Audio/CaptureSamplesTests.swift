import CoreMedia
import XCTest

@testable import Relay

final class CaptureSamplesTests: XCTestCase {
    func testFloatMonoBufferAtSpeechRateGivesItsSamples() throws {
        let buffer = try makeBuffer(samples: [0.25, -0.5, 0.75], sampleRate: AudioInput.sttSampleRate, isFloat: true)

        XCTAssertEqual(try CaptureSamples.floats(from: buffer), [0.25, -0.5, 0.75])
    }

    func testBufferAtAnotherRateIsRejected() throws {
        let buffer = try makeBuffer(samples: [0.25], sampleRate: 48_000, isFloat: true)

        XCTAssertThrowsError(try CaptureSamples.floats(from: buffer))
    }

    func testIntegerBufferIsRejected() throws {
        let buffer = try makeBuffer(samples: [0.25], sampleRate: AudioInput.sttSampleRate, isFloat: false)

        XCTAssertThrowsError(try CaptureSamples.floats(from: buffer))
    }

    private func makeBuffer(samples: [Float], sampleRate: Double, isFloat: Bool) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: (isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        XCTAssertEqual(
            CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &format), noErr)

        let length = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        XCTAssertEqual(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block),
            noErr)
        _ = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: length)
        }

        var buffer: CMSampleBuffer?
        XCTAssertEqual(
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: samples.count,
                presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &buffer),
            noErr)
        return try XCTUnwrap(buffer)
    }
}
