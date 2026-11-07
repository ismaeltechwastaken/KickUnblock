import AVFoundation
import CoreMedia
import Foundation

public enum TSRemux {
    public struct Failure: LocalizedError {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    struct VideoSample { var dts: Int64; var pts: Int64; var nals: [Data]; var isSync: Bool }
    struct AudioFrame { var pts: Int64; var data: Data }
    struct AudioConfig: Equatable { var objectType: Int; var frequencyIndex: Int; var channels: Int }

    struct Demuxed {
        var video: [VideoSample] = []
        var audio: [AudioFrame] = []
        var sps: Data?
        var pps: Data?
        var audioConfig: AudioConfig?
    }

    static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    public static func convert(ts: URL, to mp4: URL) async throws {
        let demuxed = try demux(Data(contentsOf: ts, options: .mappedIfSafe))
        try await write(demuxed, to: mp4)
    }

    // MARK: demux

    static func demux(_ data: Data) throws -> Demuxed {
        var out = Demuxed()
        var pmtPID: Int?
        var videoPID: Int?
        var audioPID: Int?
        var pes: [Int: Data] = [:]
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count, bytes[offset] != 0x47 { offset += 1 }

        func flush(_ pid: Int) {
            guard let buf = pes[pid] else { return }
            pes[pid] = nil
            if pid == videoPID { handleVideoPES(buf, into: &out) }
            else if pid == audioPID { handleAudioPES(buf, into: &out) }
        }

        while offset + 188 <= bytes.count {
            defer { offset += 188 }
            guard bytes[offset] == 0x47 else { continue }
            let pid = (Int(bytes[offset + 1] & 0x1F) << 8) | Int(bytes[offset + 2])
            let start = bytes[offset + 1] & 0x40 != 0
            let control = (bytes[offset + 3] >> 4) & 0x3
            var p = offset + 4
            if control & 0x2 != 0 { p += 1 + Int(bytes[p]) }
            guard control & 0x1 != 0, p < offset + 188 else { continue }
            let payload = bytes[p..<(offset + 188)]
            if pid == 0 {
                pmtPID = parsePAT(Array(payload), start: start) ?? pmtPID
            } else if pid == pmtPID {
                if let streams = parsePMT(Array(payload), start: start) {
                    videoPID = streams.video ?? videoPID
                    audioPID = streams.audio ?? audioPID
                }
            } else if pid == videoPID || pid == audioPID {
                if start { flush(pid); pes[pid] = Data(payload) }
                else { pes[pid]?.append(contentsOf: payload) }
            }
        }
        if let v = videoPID { flush(v) }
        if let a = audioPID { flush(a) }
        guard !out.video.isEmpty, out.sps != nil, out.pps != nil else { throw Failure("This clip has no H.264 video to save.") }
        return out
    }

    static func parsePAT(_ b: [UInt8], start: Bool) -> Int? {
        guard start, !b.isEmpty else { return nil }
        let s = 1 + Int(b[0])
        guard b.count >= s + 8 else { return nil }
        let length = (Int(b[s + 1] & 0x0F) << 8) | Int(b[s + 2])
        var i = s + 8
        let end = min(b.count, s + 3 + length - 4)
        while i + 4 <= end {
            let program = (Int(b[i]) << 8) | Int(b[i + 1])
            let pid = (Int(b[i + 2] & 0x1F) << 8) | Int(b[i + 3])
            if program != 0 { return pid }
            i += 4
        }
        return nil
    }

    static func parsePMT(_ b: [UInt8], start: Bool) -> (video: Int?, audio: Int?)? {
        guard start, !b.isEmpty else { return nil }
        let s = 1 + Int(b[0])
        guard b.count >= s + 12 else { return nil }
        let length = (Int(b[s + 1] & 0x0F) << 8) | Int(b[s + 2])
        let infoLength = (Int(b[s + 10] & 0x0F) << 8) | Int(b[s + 11])
        var i = s + 12 + infoLength
        let end = min(b.count, s + 3 + length - 4)
        var video: Int?, audio: Int?
        while i + 5 <= end {
            let type = b[i]
            let pid = (Int(b[i + 1] & 0x1F) << 8) | Int(b[i + 2])
            let esLength = (Int(b[i + 3] & 0x0F) << 8) | Int(b[i + 4])
            if type == 0x1B, video == nil { video = pid }
            if type == 0x0F, audio == nil { audio = pid }
            i += 5 + esLength
        }
        return (video, audio)
    }

    static func timestamp(_ b: [UInt8], _ i: Int) -> Int64 {
        var v = Int64((b[i] >> 1) & 0x07) << 30
        v |= Int64(b[i + 1]) << 22
        v |= Int64(b[i + 2] >> 1) << 15
        v |= Int64(b[i + 3]) << 7
        v |= Int64(b[i + 4] >> 1)
        return v
    }

    static func pesHeader(_ b: [UInt8]) -> (pts: Int64?, dts: Int64?, body: Int)? {
        guard b.count >= 9, b[0] == 0, b[1] == 0, b[2] == 1 else { return nil }
        let flags = b[7] >> 6
        let body = 9 + Int(b[8])
        guard b.count >= body else { return nil }
        var pts: Int64?, dts: Int64?
        if flags & 0x2 != 0, b.count >= 14 { pts = timestamp(b, 9) }
        if flags == 0x3, b.count >= 19 { dts = timestamp(b, 14) }
        return (pts, dts ?? pts, body)
    }

    static func nalUnits(_ b: [UInt8], from start: Int) -> [Data] {
        var units: [Data] = []
        var i = start
        var unitStart: Int?
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                if let s = unitStart {
                    var e = i
                    while e > s, b[e - 1] == 0 { e -= 1 }
                    if e > s { units.append(Data(b[s..<e])) }
                }
                i += 3
                unitStart = i
            } else {
                i += 1
            }
        }
        if let s = unitStart, s < b.count { units.append(Data(b[s..<b.count])) }
        return units
    }

    static func handleVideoPES(_ data: Data, into out: inout Demuxed) {
        let b = [UInt8](data)
        guard let h = pesHeader(b) else { return }
        guard let pts = h.pts, let dts = h.dts else {
            appendContinuation(b, from: h.body, into: &out)
            return
        }
        let firstCode = attachLeadingBytes(b, from: h.body, into: &out)
        var nals: [Data] = []
        var sync = false
        for nal in nalUnits(b, from: firstCode) {
            guard let first = nal.first else { continue }
            switch first & 0x1F {
            case 7: out.sps = out.sps ?? nal
            case 8: out.pps = out.pps ?? nal
            case 9: break
            case 5: sync = true; nals.append(nal)
            default: nals.append(nal)
            }
        }
        guard !nals.isEmpty else { return }
        out.video.append(VideoSample(dts: dts, pts: pts, nals: nals, isSync: sync))
    }

    static func attachLeadingBytes(_ b: [UInt8], from start: Int, into out: inout Demuxed) -> Int {
        var code = start
        while code + 3 <= b.count, !(b[code] == 0 && b[code + 1] == 0 && b[code + 2] == 1) { code += 1 }
        if code + 3 > b.count { code = b.count }
        var head = code
        if code < b.count { while head > start, b[head - 1] == 0 { head -= 1 } }
        if head > start, var last = out.video.popLast() {
            if !last.nals.isEmpty { last.nals[last.nals.count - 1].append(contentsOf: b[start..<head]) }
            out.video.append(last)
        }
        return code
    }

    static func appendContinuation(_ b: [UInt8], from start: Int, into out: inout Demuxed) {
        let code = attachLeadingBytes(b, from: start, into: &out)
        guard var last = out.video.popLast() else { return }
        for nal in nalUnits(b, from: code) {
            guard let type = nal.first.map({ $0 & 0x1F }) else { continue }
            if type == 5 { last.isSync = true }
            if type != 7, type != 8, type != 9 { last.nals.append(nal) }
        }
        out.video.append(last)
    }

    static func handleAudioPES(_ data: Data, into out: inout Demuxed) {
        let b = [UInt8](data)
        guard let h = pesHeader(b), let pts = h.pts else { return }
        var i = h.body
        var index: Int64 = 0
        while i + 7 <= b.count, b[i] == 0xFF, b[i + 1] & 0xF0 == 0xF0 {
            let protectionAbsent = b[i + 1] & 0x01 == 1
            let config = AudioConfig(objectType: Int((b[i + 2] >> 6) & 0x3) + 1,
                                     frequencyIndex: Int((b[i + 2] >> 2) & 0xF),
                                     channels: Int((b[i + 2] & 0x1) << 2) | Int(b[i + 3] >> 6))
            let length = (Int(b[i + 3] & 0x3) << 11) | (Int(b[i + 4]) << 3) | Int(b[i + 5] >> 5)
            let header = protectionAbsent ? 7 : 9
            guard length > header, i + length <= b.count, config.frequencyIndex < sampleRates.count else { break }
            out.audioConfig = out.audioConfig ?? config
            let rate = Int64(sampleRates[config.frequencyIndex])
            out.audio.append(AudioFrame(pts: pts + index * 1024 * 90000 / rate, data: Data(b[(i + header)..<(i + length)])))
            index += 1
            i += length
        }
    }

    static func unwrap(_ values: [Int64]) -> [Int64] {
        var result: [Int64] = []
        var offset: Int64 = 0
        var previous: Int64?
        for v in values {
            if let p = previous, v + offset < p - (1 << 32) { offset += 1 << 33 }
            let u = v + offset
            result.append(u)
            previous = u
        }
        return result
    }

    static func audioSpecificConfig(_ c: AudioConfig) -> [UInt8] {
        [UInt8((c.objectType << 3) | (c.frequencyIndex >> 1)), UInt8(((c.frequencyIndex & 1) << 7) | (c.channels << 3))]
    }

    static func elementaryStreamDescriptor(_ c: AudioConfig) -> [UInt8] {
        let specific: [UInt8] = [0x05, 0x02] + audioSpecificConfig(c)
        let decoder: [UInt8] = [0x04, UInt8(13 + specific.count), 0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + specific
        let body: [UInt8] = [0, 0, 0] + decoder + [0x06, 0x01, 0x02]
        return [0x03, UInt8(body.count)] + body
    }

    // MARK: mux

    static func time(_ ticks: Int64) -> CMTime { CMTime(value: ticks, timescale: 90000) }

    static func write(_ d: Demuxed, to url: URL) async throws {
        guard let sps = d.sps, let pps = d.pps else { throw Failure("This clip has no H.264 video to save.") }
        var video: CMFormatDescription?
        let status = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &video)
            }
        }
        guard status == noErr, let video else { throw Failure("The clip's video format isn't supported.") }

        var audio: CMFormatDescription?
        if let c = d.audioConfig {
            var asbd = AudioStreamBasicDescription(mSampleRate: Float64(sampleRates[c.frequencyIndex]), mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: UInt32(c.objectType), mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                mChannelsPerFrame: UInt32(c.channels), mBitsPerChannel: 0, mReserved: 0)
            let cookie = elementaryStreamDescriptor(c)
            let st = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: cookie.count, magicCookie: cookie, extensions: nil, formatDescriptionOut: &audio)
            guard st == noErr else { audio = nil; return try await write(Demuxed(video: d.video, audio: [], sps: d.sps, pps: d.pps, audioConfig: nil), to: url) }
        }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: video)
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if let audio, !d.audio.isEmpty {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audio)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        let dts = unwrap(d.video.map(\.dts))
        let base0 = dts.first ?? 0
        let pts = unwrap(d.video.map(\.pts))
        let apts = unwrap(d.audio.map(\.pts))
        let base = min(base0, pts.min() ?? base0, apts.first ?? base0)

        guard writer.startWriting() else { throw writer.error ?? Failure("Couldn't start writing the clip.") }
        writer.startSession(atSourceTime: time(min(pts.min() ?? base, apts.first ?? .max) - base))
        func videoSample(_ i: Int) throws -> CMSampleBuffer {
            let next = i + 1 < dts.count ? dts[i + 1] : dts[i] + (i > 0 ? dts[i] - dts[i - 1] : 1500)
            var payload = Data()
            for nal in d.video[i].nals {
                var n = UInt32(nal.count).bigEndian
                payload.append(Data(bytes: &n, count: 4))
                payload.append(nal)
            }
            return try makeSample(payload, format: video, pts: time(pts[i] - base), dts: time(dts[i] - base),
                                  duration: time(max(1, next - dts[i])), sync: d.video[i].isSync)
        }

        var vi = 0, ai = audioInput == nil ? d.audio.count : 0
        var idle = 0
        while vi < d.video.count || ai < d.audio.count {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw writer.error ?? Failure("Couldn't write the clip.") }
            let videoFirst = ai >= d.audio.count || (vi < d.video.count && dts[vi] <= apts[ai])
            var progressed = false
            for useVideo in videoFirst ? [true, false] : [false, true] {
                if useVideo, vi < d.video.count, videoInput.isReadyForMoreMediaData {
                    guard videoInput.append(try videoSample(vi)) else { throw writer.error ?? Failure("Couldn't write the clip.") }
                    vi += 1; progressed = true
                    if vi == d.video.count { videoInput.markAsFinished() }
                    break
                }
                if !useVideo, ai < d.audio.count, let input = audioInput, let audio, input.isReadyForMoreMediaData {
                    let sample = try makeAudioSample(d.audio[ai].data, format: audio, pts: time(apts[ai] - base))
                    guard input.append(sample) else { throw writer.error ?? Failure("Couldn't write the clip.") }
                    ai += 1; progressed = true
                    if ai == d.audio.count { input.markAsFinished() }
                    break
                }
            }
            if progressed { idle = 0; continue }
            idle += 1
            guard idle < 3000 else { throw Failure("Saving the clip stalled.") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure("Couldn't finish writing the clip.") }
    }

    static func makeAudioSample(_ data: Data, format: CMFormatDescription, pts: CMTime) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &block) == noErr, let block else { throw Failure("Not enough memory to save the clip.") }
        _ = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        var packet = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(data.count))
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                sampleCount: 1, presentationTimeStamp: pts, packetDescriptions: &packet, sampleBufferOut: &sample) == noErr,
              let sample else { throw Failure("Couldn't package the clip's audio.") }
        return sample
    }

    static func makeSample(_ data: Data, format: CMFormatDescription, pts: CMTime, dts: CMTime, duration: CMTime, sync: Bool) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &block) == noErr, let block else { throw Failure("Not enough memory to save the clip.") }
        _ = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: dts)
        var size = data.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                sampleBufferOut: &sample) == noErr, let sample else { throw Failure("Couldn't package the clip.") }
        if !sync, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
