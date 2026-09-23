import AVFoundation
import MediaToolbox

/// 재생 중인 소리 크기를 잡아내는 오디오 탭 (음량 미터·진단용)
final class AudioMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0

    /// 마지막으로 읽은 뒤의 최대 음량(0~1)을 돌려주고 초기화
    func take() -> Float {
        lock.lock(); defer { lock.unlock() }
        let p = peak
        peak = 0
        return p
    }

    fileprivate func feed(_ v: Float) {
        lock.lock()
        if v > peak { peak = v }
        lock.unlock()
    }

    /// 오디오 믹스의 각 입력에 탭을 달아 새 믹스를 만든다
    func tapped(_ mix: AVAudioMix) -> AVMutableAudioMix {
        let out = AVMutableAudioMix()
        out.inputParameters = mix.inputParameters.compactMap { p in
            guard let mp = p.mutableCopy() as? AVMutableAudioMixInputParameters else { return nil }
            mp.audioTapProcessor = makeTap()
            return mp
        }
        return out
    }

    private func makeTap() -> MTAudioProcessingTap? {
        var cb = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
            init: { _, info, storage in storage.pointee = info },
            finalize: { tap in
                Unmanaged<AudioMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: nil, unprepare: nil,
            process: { tap, frames, _, abl, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, abl, flagsOut, nil, framesOut) == noErr else { return }
                let meter = Unmanaged<AudioMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                var m: Float = 0
                for buf in UnsafeMutableAudioBufferListPointer(abl) {
                    guard let d = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let n = Int(buf.mDataByteSize) / 4
                    var i = 0
                    while i < n { m = max(m, abs(d[i])); i += 4 }
                }
                meter.feed(m)
            })
        var tap: Unmanaged<MTAudioProcessingTap>?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &cb, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr else { return nil }
        return tap?.takeRetainedValue()
    }
}
