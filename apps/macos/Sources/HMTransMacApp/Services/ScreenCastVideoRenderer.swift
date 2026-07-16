import AVFoundation
import CoreMedia
import Foundation
import QuartzCore

/// 将 MatePad 发送的 H.264 Annex-B、AVCC 或 avcC 参数集转换为系统可解码的样本。
/// 参数集只保存在内存中，停止投屏后立即清空，不会形成视频文件或历史记录。
@MainActor
final class ScreenCastVideoRenderer {
    let displayLayer = AVSampleBufferDisplayLayer()
    private var renderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }
    private var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    private(set) var videoDimensions = CMVideoDimensions(width: 0, height: 0)

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0.04, alpha: 1)
    }

    func reset() {
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        formatDescription = nil
        sps = nil
        pps = nil
        videoDimensions = CMVideoDimensions(width: 0, height: 0)
    }

    func enqueue(
        annexB data: Data,
        presentationTimeUs: UInt64,
        isKeyFrame: Bool,
        isCodecConfig: Bool
    ) throws {
        let units = h264NALUnits(in: data)
        guard !units.isEmpty else { return }

        var pictureUnits: [Data] = []
        for unit in units where !unit.isEmpty {
            switch unit[unit.startIndex] & 0x1f {
            case 7:
                sps = unit
            case 8:
                pps = unit
            default:
                pictureUnits.append(unit)
            }
        }

        if formatDescription == nil || isCodecConfig {
            try rebuildFormatDescriptionIfPossible()
        }
        guard !pictureUnits.isEmpty, let formatDescription else { return }

        var avcc = Data()
        for unit in pictureUnits {
            var size = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &size) { avcc.append(contentsOf: $0) }
            avcc.append(unit)
        }

        var blockBuffer: CMBlockBuffer?
        let createBlockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createBlockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw ScreenCastVideoError.cannotCreateBlockBuffer(createBlockStatus)
        }
        let replaceStatus = avcc.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else {
            throw ScreenCastVideoError.cannotCopyFrame(replaceStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(presentationTimeUs), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = avcc.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw ScreenCastVideoError.cannotCreateSample(sampleStatus)
        }

        // 投屏追求实时显示，不把采集端的绝对 PTS 当成本地播放时间线等待。
        CMSetAttachment(
            sampleBuffer,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldNotPropagate
        )
        if !isKeyFrame {
            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleAttachmentKey_NotSync,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldNotPropagate
            )
        }
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
        }
        renderer.enqueue(sampleBuffer)
    }

    private func rebuildFormatDescriptionIfPossible() throws {
        guard let sps, let pps else { return }
        var result: CMFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                var pointers: [UnsafePointer<UInt8>] = [
                    spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!,
                ]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &result
                )
            }
        }
        guard status == noErr, let result else {
            throw ScreenCastVideoError.cannotCreateFormat(status)
        }
        formatDescription = result
        videoDimensions = CMVideoFormatDescriptionGetDimensions(result)
    }

    /// HarmonyOS 编码器在不同设备上可能输出 Annex-B、长度前缀 AVCC，
    /// 编码配置回调也可能直接返回 AVCDecoderConfigurationRecord（avcC）。
    private func h264NALUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return [] }

        if let parameterSets = avcCParameterSets(in: bytes) {
            return parameterSets
        }

        var starts: [(offset: Int, prefix: Int)] = []
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append((index, 3))
                index += 3
            } else if index + 4 <= bytes.count,
                      bytes[index] == 0, bytes[index + 1] == 0,
                      bytes[index + 2] == 0, bytes[index + 3] == 1 {
                starts.append((index, 4))
                index += 4
            } else {
                index += 1
            }
        }
        if !starts.isEmpty {
            return starts.enumerated().compactMap { position, start in
                let payloadStart = start.offset + start.prefix
                let payloadEnd = position + 1 < starts.count ? starts[position + 1].offset : bytes.count
                guard payloadStart < payloadEnd else { return nil }
                return Data(bytes[payloadStart..<payloadEnd])
            }
        }

        if let units = lengthPrefixedNALUnits(in: bytes) {
            return units
        }
        return [data]
    }

    private func lengthPrefixedNALUnits(in bytes: [UInt8]) -> [Data]? {
        var result: [Data] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = Int(bytes[offset]) << 24
                | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8
                | Int(bytes[offset + 3])
            offset += 4
            guard length > 0, offset + length <= bytes.count else { return nil }
            result.append(Data(bytes[offset..<(offset + length)]))
            offset += length
        }
        return offset == bytes.count && !result.isEmpty ? result : nil
    }

    private func avcCParameterSets(in bytes: [UInt8]) -> [Data]? {
        guard bytes.count >= 7, bytes[0] == 1 else { return nil }
        var offset = 6
        let spsCount = Int(bytes[5] & 0x1f)
        guard spsCount > 0 else { return nil }
        var result: [Data] = []

        for _ in 0..<spsCount {
            guard offset + 2 <= bytes.count else { return nil }
            let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            guard length > 0, offset + length <= bytes.count else { return nil }
            result.append(Data(bytes[offset..<(offset + length)]))
            offset += length
        }

        guard offset < bytes.count else { return nil }
        let ppsCount = Int(bytes[offset])
        offset += 1
        guard ppsCount > 0 else { return nil }
        for _ in 0..<ppsCount {
            guard offset + 2 <= bytes.count else { return nil }
            let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            guard length > 0, offset + length <= bytes.count else { return nil }
            result.append(Data(bytes[offset..<(offset + length)]))
            offset += length
        }
        return result
    }
}

private enum ScreenCastVideoError: LocalizedError {
    case cannotCreateFormat(OSStatus)
    case cannotCreateBlockBuffer(OSStatus)
    case cannotCopyFrame(OSStatus)
    case cannotCreateSample(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .cannotCreateFormat(code): "无法创建 H.264 解码格式（\(code)）"
        case let .cannotCreateBlockBuffer(code): "无法创建投屏帧缓冲（\(code)）"
        case let .cannotCopyFrame(code): "无法写入投屏帧（\(code)）"
        case let .cannotCreateSample(code): "无法创建投屏视频样本（\(code)）"
        }
    }
}
