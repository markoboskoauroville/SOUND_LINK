// Capture.swift: the input devices of the Mac and two channels of one of them, read with a HAL output unit.
//
// Why a raw AUHAL and not AVAudioEngine: the engine's input tap hands out buffers of about 100 ms on macOS, which is
// latency the link does not need, and the engine follows the system's default input. The HAL unit reads the device
// Marko chose (his 16 or 18 channel XLR mixer) at its own IO size (256 frames, about 5 ms), and its channel map takes
// any two of its channels (1-2, 3-4 ...). The device keeps its own sample rate: it is never changed from here, the
// pump converts to 48 kHz when the device runs at another rate.
import Foundation
import os
import CoreAudio
import AudioToolbox
import AVFoundation

struct InputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let channels: Int
    let rate: Double
    /// "1-2", "3-4" ... (an odd last channel pairs with itself: "17" on a 17-channel device)
    var pairs: [String] {
        stride(from: 0, to: channels, by: 2).map { c in c + 1 < channels ? "\(c + 1)-\(c + 2)" : "\(c + 1)" }
    }
}

enum Devices {
    static func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func all() -> [InputDevice] {
        var a = addr(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let ch = inputChannels(id)
            guard ch > 0 else { return nil }
            return InputDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                               name: string(id, kAudioObjectPropertyName) ?? "Device \(id)", channels: ch, rate: rate(id))
        }
    }

    static func string(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = addr(sel)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }

    static func inputChannels(_ id: AudioDeviceID) -> Int {
        var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func rate(_ id: AudioDeviceID) -> Double {
        var a = addr(kAudioDevicePropertyNominalSampleRate)
        var r: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &r) == noErr && r > 0 ? r : 48000
    }

    static func defaultInput() -> AudioDeviceID? {
        var a = addr(kAudioHardwarePropertyDefaultInputDevice)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr && id != 0 ? id : nil
    }

    /// Called on the main queue whenever a device is plugged in or pulled out.
    static func watch(_ changed: @escaping () -> Void) {
        var a = addr(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, DispatchQueue.main) { _, _ in changed() }
    }
}

/// Two channels, written by the audio thread, read by the pump. A short unfair lock on both sides; the audio thread
/// holds it only for one copy of one IO buffer. When nobody reads (before SEND) the oldest frames are dropped.
final class StereoRing {
    let capacity: Int
    private let l: UnsafeMutablePointer<Float>
    private let r: UnsafeMutablePointer<Float>
    private var w = 0
    private var count = 0
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)

    init(capacity: Int) {
        self.capacity = capacity
        l = .allocate(capacity: capacity); r = .allocate(capacity: capacity)
        l.initialize(repeating: 0, count: capacity); r.initialize(repeating: 0, count: capacity)
        lock.initialize(to: os_unfair_lock())
    }

    func write(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, _ n: Int) {
        os_unfair_lock_lock(lock)
        for i in 0..<n {
            l[w] = a[i]; r[w] = b[i]
            w += 1; if w == capacity { w = 0 }
        }
        count = min(capacity, count + n)
        os_unfair_lock_unlock(lock)
    }

    /// Up to `n` frames, oldest first. Returns how many.
    func read(_ a: UnsafeMutablePointer<Float>, _ b: UnsafeMutablePointer<Float>, _ n: Int) -> Int {
        os_unfair_lock_lock(lock)
        let take = min(n, count)
        var rd = (w - count + capacity) % capacity
        for i in 0..<take {
            a[i] = l[rd]; b[i] = r[rd]
            rd += 1; if rd == capacity { rd = 0 }
        }
        count -= take
        os_unfair_lock_unlock(lock)
        return take
    }

    func clear() { os_unfair_lock_lock(lock); count = 0; os_unfair_lock_unlock(lock) }
}

private let inputProc: AURenderCallback = { refCon, flags, ts, bus, frames, _ in
    Unmanaged<Capture>.fromOpaque(refCon).takeUnretainedValue().render(flags, ts, bus, frames)
}

final class Capture {
    private var unit: AudioUnit?
    private let maxFrames = 8192
    private let bufL = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
    private let bufR = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
    private var list = AudioBufferList.allocate(maximumBuffers: 2)
    /// Ten seconds at 96 kHz; the pump reads it every 2 ms.
    let ring = StereoRing(capacity: 96_000 * 4)
    private(set) var rate: Double = 48000
    private(set) var ioFrames: UInt32 = 256
    /// Peaks since the meter last read them (linear 0...1), and frames read in total.
    var peakL: Float = 0, peakR: Float = 0
    private(set) var framesIn: Int64 = 0
    private(set) var running = false

    /// Opens `device` and reads its channels `left` and `right` (0-based). nil when it runs, else the reason in words.
    func start(device: AudioDeviceID, left: Int, right: Int) -> String? {
        stop()
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { return "no HAL unit on this Mac" }
        var u: AudioUnit?
        guard AudioComponentInstanceNew(comp, &u) == noErr, let au = u else { return "the HAL unit did not open" }
        var one: UInt32 = 1, zero: UInt32 = 0
        var st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4)
        st |= AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4)
        var dev = device
        st |= AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev,
                                   UInt32(MemoryLayout<AudioDeviceID>.size))
        if st != noErr { AudioComponentInstanceDispose(au); return "the device would not open (\(st))" }
        var hw = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size)
        rate = hw.mSampleRate > 0 ? hw.mSampleRate : Devices.rate(device)
        // the two channels Marko chose, as the unit's two output channels
        var map: [Int32] = [Int32(left), Int32(right)]
        st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1, &map, UInt32(8))
        if st != noErr { Log.line("channel map refused (\(st)), the first two channels are read") }
        var fmt = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        st = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, size)
        if st != noErr { AudioComponentInstanceDispose(au); return "the device refused two float channels (\(st))" }
        var frames: UInt32 = 256
        AudioUnitSetProperty(au, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, 4)
        size = 4
        AudioUnitGetProperty(au, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &ioFrames, &size)
        var cb = AURenderCallbackStruct(inputProc: inputProc, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb,
                             UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard AudioUnitInitialize(au) == noErr else { AudioComponentInstanceDispose(au); return "the device would not start" }
        guard AudioOutputUnitStart(au) == noErr else {
            AudioUnitUninitialize(au); AudioComponentInstanceDispose(au); return "the device would not start reading"
        }
        unit = au
        running = true
        ring.clear()
        Log.line("capture: device \(device) channels \(left + 1)+\(right + 1) at \(Int(rate)) Hz, IO \(ioFrames) frames")
        return nil
    }

    func stop() {
        guard let au = unit else { return }
        AudioOutputUnitStop(au)
        AudioUnitUninitialize(au)
        AudioComponentInstanceDispose(au)
        unit = nil
        running = false
        peakL = 0; peakR = 0
    }

    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ ts: UnsafePointer<AudioTimeStamp>,
                            _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard let au = unit, frames <= UInt32(maxFrames) else { return noErr }
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: UnsafeMutableRawPointer(bufL))
        list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: UnsafeMutableRawPointer(bufR))
        let st = AudioUnitRender(au, flags, ts, bus, frames, list.unsafeMutablePointer)
        if st != noErr { return st }
        let n = Int(frames)
        ring.write(bufL, bufR, n)
        var pl = peakL, pr = peakR
        for i in 0..<n { pl = max(pl, abs(bufL[i])); pr = max(pr, abs(bufR[i])) }
        peakL = pl; peakR = pr
        framesIn += Int64(n)
        return noErr
    }
}

/// Reads the ring, converts to 48 kHz when the device runs at another rate, and hands out packets of 240 frames
/// (5 ms) as interleaved 16-bit little-endian PCM.
final class Pump {
    static let rate = 48_000.0
    static let frames = 240
    private let capture: Capture
    private var converter: AVAudioConverter?
    private var inBuf: AVAudioPCMBuffer?
    private var outBuf: AVAudioPCMBuffer?
    private let tmpL = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
    private let tmpR = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
    private var pendL: [Float] = []
    private var pendR: [Float] = []

    init(_ c: Capture) {
        capture = c
        if abs(c.rate - Pump.rate) > 0.5,
           let fi = AVAudioFormat(standardFormatWithSampleRate: c.rate, channels: 2),
           let fo = AVAudioFormat(standardFormatWithSampleRate: Pump.rate, channels: 2) {
            converter = AVAudioConverter(from: fi, to: fo)
            inBuf = AVAudioPCMBuffer(pcmFormat: fi, frameCapacity: 16384)
            outBuf = AVAudioPCMBuffer(pcmFormat: fo, frameCapacity: 40000)
            Log.line("pump: converting \(Int(c.rate)) Hz to 48000 Hz")
        }
    }

    /// Everything waiting, as whole packets' worth of PCM (each 240 frames × 2 channels × 2 bytes).
    func packets() -> [Data] {
        let n = capture.ring.read(tmpL, tmpR, 16384)
        if n > 0 {
            if let conv = converter, let ib = inBuf, let ob = outBuf {
                let l = ib.floatChannelData![0], r = ib.floatChannelData![1]
                l.update(from: tmpL, count: n); r.update(from: tmpR, count: n)
                ib.frameLength = AVAudioFrameCount(n)
                ob.frameLength = 0
                var fed = false
                var err: NSError?
                _ = conv.convert(to: ob, error: &err) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true; status.pointee = .haveData; return ib
                }
                let m = Int(ob.frameLength)
                if m > 0 {
                    pendL.append(contentsOf: UnsafeBufferPointer(start: ob.floatChannelData![0], count: m))
                    pendR.append(contentsOf: UnsafeBufferPointer(start: ob.floatChannelData![1], count: m))
                }
            } else {
                pendL.append(contentsOf: UnsafeBufferPointer(start: tmpL, count: n))
                pendR.append(contentsOf: UnsafeBufferPointer(start: tmpR, count: n))
            }
        }
        var out: [Data] = []
        let f = Pump.frames
        var at = 0
        while pendL.count - at >= f {
            var d = Data(count: f * 4)
            d.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: Int16.self)
                for i in 0..<f {
                    p[2 * i] = Pump.s16(pendL[at + i]).littleEndian
                    p[2 * i + 1] = Pump.s16(pendR[at + i]).littleEndian
                }
            }
            out.append(d)
            at += f
        }
        if at > 0 { pendL.removeFirst(at); pendR.removeFirst(at) }
        return out
    }

    static func s16(_ x: Float) -> Int16 { Int16(max(-32768, min(32767, (x * 32767).rounded()))) }
}
