import AVFoundation
import os

final class AudioBuffersQueue {
    private let audioDescription: AudioStreamBasicDescription
    private var allBuffers = OSAllocatedUnfairLock(initialState: [CMSampleBuffer]())
    private var buffers = OSAllocatedUnfairLock(initialState: [CMSampleBuffer]())

    private(set) var duration = CMTime.zero

    var isEmpty: Bool {
        buffers.withLock(\.isEmpty)
    }

    init(audioDescription: AudioStreamBasicDescription) {
        self.audioDescription = audioDescription
        self.duration = CMTime(value: 0, timescale: Int32(audioDescription.mSampleRate))
    }

    func enqueue(
        numberOfBytes: UInt32,
        bytes: UnsafeRawPointer,
        numberOfPackets: UInt32,
        packets: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) throws {
        guard let buffer = try makeSampleBuffer(
            from: Data(bytes: bytes, count: Int(numberOfBytes)),
            packetCount: numberOfPackets,
            packetDescriptions: packets
        ) else { return }
        updateTimeOffset(for: buffer)
        buffers.withLock { $0.append(buffer) }
        allBuffers.withLock { $0.append(buffer) }
    }

    func peek() -> CMSampleBuffer? {
        buffers.withLock { $0.first }
    }

    func dequeue() -> CMSampleBuffer? {
        buffers.withLock { buffers in
            if buffers.isEmpty { return nil }
            return buffers.removeFirst()
        }
    }

    func removeFirst() {
        _ = dequeue()
    }

    func removeAll() {
        allBuffers.withLock { $0.removeAll() }
        buffers.withLock { $0.removeAll() }
        duration = .zero
    }

    func buffer(at time: CMTime) -> CMSampleBuffer? {
        allBuffers.withLock { buffers in
            buffers.first { $0.timeRange.containsTime(time) }
        }
    }

    func removeBuffer(at time: CMTime) {
        allBuffers.withLock { buffers in
            buffers.removeAll { $0.timeRange.containsTime(time) }
        }
    }

    // MARK: - Private

    private func makeSampleBuffer(
        from data: Data,
        packetCount: UInt32,
        packetDescriptions: UnsafePointer<AudioStreamPacketDescription>?
    ) throws -> CMSampleBuffer? {
        guard let blockBuffer = try makeBlockBuffer(from: data) else { return nil }
        let formatDescription = try CMFormatDescription(audioStreamBasicDescription: audioDescription)
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(packetCount),
            presentationTimeStamp: duration,
            packetDescriptions: packetDescriptions,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr else { throw AudioPlayerError.status(createStatus) }

        return sampleBuffer
    }

    private func makeBlockBuffer(from data: Data) throws -> CMBlockBuffer? {
        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == noErr else { throw AudioPlayerError.status(createStatus) }
        guard let blockBuffer else { return nil }
        return try data.withUnsafeBytes { pointer in
            guard let baseAddress = pointer.baseAddress else { return nil }
            let replaceStatus = CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
            guard replaceStatus == noErr else { throw AudioPlayerError.status(replaceStatus) }

            return blockBuffer
        }
    }

    private func updateTimeOffset(for buffer: CMSampleBuffer) {
        duration = buffer.presentationTimeStamp + buffer.duration
    }
}
