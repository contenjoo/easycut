import CoreAudio

/// 지금 소리가 나가는 장치와 그 지연 (블루투스 이어폰이면 미리보기 소리가 화면보다 늦게 들릴 수 있다)
enum AudioOutput {
    struct Info {
        var name: String
        var bluetooth: Bool
        /// 장치가 알려 주는 출력 지연 (초)
        var latency: Double
    }

    static func current() -> Info? {
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr, dev != 0 else { return nil }

        func u32(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> UInt32 {
            var v: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            return AudioObjectGetPropertyData(dev, &a, 0, nil, &s, &v) == noErr ? v : 0
        }
        var name: Unmanaged<CFString>?
        var ns = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var na = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(dev, &na, 0, nil, &ns, &name)

        var rate: Float64 = 0
        var rs = UInt32(MemoryLayout<Float64>.size)
        var ra = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(dev, &ra, 0, nil, &rs, &rate)

        // 첫 출력 스트림의 지연
        var streamLatency: UInt32 = 0
        var sz: UInt32 = 0
        var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyDataSize(dev, &sa, 0, nil, &sz) == noErr, sz >= UInt32(MemoryLayout<AudioStreamID>.size) {
            var streams = [AudioStreamID](repeating: 0, count: Int(sz) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(dev, &sa, 0, nil, &sz, &streams) == noErr, let st = streams.first {
                var v: UInt32 = 0
                var s = UInt32(MemoryLayout<UInt32>.size)
                var a = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyLatency, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                if AudioObjectGetPropertyData(st, &a, 0, nil, &s, &v) == noErr { streamLatency = v }
            }
        }
        let frames = Double(u32(kAudioDevicePropertyLatency)) + Double(u32(kAudioDevicePropertySafetyOffset))
            + Double(u32(kAudioDevicePropertyBufferFrameSize)) + Double(streamLatency)
        let transport = u32(kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal)
        let bt = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        return Info(name: (name?.takeRetainedValue() as String?) ?? "?", bluetooth: bt, latency: rate > 0 ? frames / rate : 0)
    }

    /// AI·화면에 보여 줄 한 줄
    static func summary() -> String {
        guard let o = current() else { return "미리보기 소리 출력 장치를 확인하지 못했습니다" }
        var s = String(format: "미리보기 소리 출력: %@%@, 장치 지연 약 %.2f초", o.name, o.bluetooth ? " (블루투스)" : "", o.latency)
        if o.bluetooth {
            s += " — 블루투스는 실제로 0.1~0.3초 더 늦게 들리는 경우가 많습니다. 미리보기에서만 자막이 빠르게 느껴지면 자막을 옮기지 말고 Mac 스피커로 확인하세요 (내보낸 영상과는 무관)"
        } else if o.latency > 0.08 {
            s += " — 미리보기 소리가 그만큼 늦게 들릴 수 있습니다 (내보낸 영상과는 무관)"
        }
        return s
    }
}
