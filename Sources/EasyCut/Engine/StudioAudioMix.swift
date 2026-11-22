import AVFoundation

/// Both capture devices request 48 kHz PCM. Each slot is tagged with its absolute frame
/// number so delayed packets can never be mixed into a later pass through the ring.
final class StudioAudioMix {
    private let lock = NSLock()
    private var epoch: CMTime?
    private let capacity = 96_000
    private var frames = [Int64](repeating: -1, count: 96_000)
    private var amplitudes = [Float](repeating: 0, count: 96_000)
    private let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                       channels: 1, interleaved: true)!

    func begin(at epoch: CMTime) { lock.withLock { self.epoch = epoch } }

    func add(_ sample: CMSampleBuffer) {
        guard let start = lock.withLock({ epoch }), let description = sample.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard format.sampleRate == 48_000, sample.numSamples > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples)) else { return }
        let offset = (sample.presentationTimeStamp - start).seconds * 48_000
        guard offset.isFinite, abs(offset) < Double(Int64.max / 2) else { return }
        let first = Int64(offset.rounded())
        let count = sample.numSamples
        pcm.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count),
                                                           into: pcm.mutableAudioBufferList) == noErr else { return }
        let channels = Int(format.channelCount)
        guard channels > 0 else { return }
        var mixed = [Float](repeating: 0, count: count)
        if let planes = pcm.floatChannelData {
            for channel in 0..<channels {
                let plane = planes[channel]
                for i in 0..<count { mixed[i] += plane[i * pcm.stride] / Float(channels) }
            }
        } else if let planes = pcm.int16ChannelData {
            let scale = Float(channels) * 32_768
            for channel in 0..<channels {
                let plane = planes[channel]
                for i in 0..<count { mixed[i] += Float(plane[i * pcm.stride]) / scale }
            }
        } else { return }
        lock.withLock {
            for i in 0..<count {
                let frame = first + Int64(i)
                guard frame >= 0 else { continue }
                let slot = Int(frame % Int64(capacity))
                if frames[slot] != frame {
                    amplitudes[slot] = 0
                    frames[slot] = frame
                }
                amplitudes[slot] += mixed[i]
            }
        }
    }

    func read(from first: Int64, count: Int) -> CMSampleBuffer? {
        let length = count * MemoryLayout<Int16>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        var bytes: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil,
                                          dataPointerOut: &bytes) == noErr, let bytes else { return nil }
        bytes.withMemoryRebound(to: Int16.self, capacity: count) { samples in
            lock.withLock {
                for i in 0..<count {
                    let frame = first + Int64(i), slot = Int(frame % Int64(capacity))
                    let value = frames[slot] == frame ? amplitudes[slot] : 0
                    let amplitude = value.isFinite ? min(1, max(-1, value)) : 0
                    samples[i] = Int16(amplitude * Float(Int16.max))
                }
            }
        }
        var result: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                        presentationTimeStamp: CMTime(value: first, timescale: 48_000),
                                        decodeTimeStamp: .invalid)
        var stride = 2
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: output.formatDescription,
                                        sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &stride, sampleBufferOut: &result) == noErr else { return nil }
        return result
    }
}
