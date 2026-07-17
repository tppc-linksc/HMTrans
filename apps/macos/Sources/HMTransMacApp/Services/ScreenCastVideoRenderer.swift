import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import VideoToolbox

/// 将 MatePad 发送的 H.264 Annex-B、AVCC 或 avcC 参数集转换为系统可解码的样本。
/// 参数集只保存在内存中，停止投屏后立即清空，不会形成视频文件或历史记录。
struct ScreenCastDecodeOutcome: Sendable {
    let displayed: Bool
    let width: Int
    let height: Int
}

final class ScreenCastVideoRenderer: @unchecked Sendable {
    let displayLayer: AVSampleBufferDisplayLayer
    private let decodeQueue = DispatchQueue(
        label: "HMTrans.ScreenCastVideoRenderer.\(UUID().uuidString)",
        qos: .userInteractive
    )
    private let renderer: AVSampleBufferVideoRenderer
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var sps: Data?
    private var pps: Data?
    private var waitingForKeyFrame = true
    private var lastDisplayTimeStamp = CMTime.invalid

    private var videoDimensions = CMVideoDimensions(width: 0, height: 0)

    @MainActor
    init() {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0.04, alpha: 1)
        displayLayer = layer
        // Apple 明确允许 sampleBufferRenderer 在后台线程安全入队；这里只在主线程
        // 取得一次引用，之后每路会话在自己的串行解码队列中使用。
        renderer = layer.sampleBufferRenderer
    }

    func reset() {
        decodeQueue.sync {
            if let decompressionSession {
                VTDecompressionSessionInvalidate(decompressionSession)
            }
            decompressionSession = nil
            renderer.flush(removingDisplayedImage: true, completionHandler: nil)
            formatDescription = nil
            sps = nil
            pps = nil
            waitingForKeyFrame = true
            lastDisplayTimeStamp = .invalid
            videoDimensions = CMVideoDimensions(width: 0, height: 0)
        }
    }

    func enqueueAsync(
        annexB data: Data,
        presentationTimeUs: UInt64,
        isKeyFrame: Bool,
        isCodecConfig: Bool,
        completion: @escaping @Sendable (Result<ScreenCastDecodeOutcome, Error>) -> Void
    ) {
        decodeQueue.async { [self] in
            do {
                let displayed = try enqueue(
                    annexB: data,
                    presentationTimeUs: presentationTimeUs,
                    isKeyFrame: isKeyFrame,
                    isCodecConfig: isCodecConfig
                )
                completion(.success(ScreenCastDecodeOutcome(
                    displayed: displayed,
                    width: Int(videoDimensions.width),
                    height: Int(videoDimensions.height)
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func enqueue(
        annexB data: Data,
        presentationTimeUs: UInt64,
        isKeyFrame: Bool,
        isCodecConfig: Bool
    ) throws -> Bool {
        let units = h264NALUnits(in: data)
        guard !units.isEmpty else { return false }

        var pictureUnits: [Data] = []
        var containsIDR = false
        for unit in units where !unit.isEmpty {
            let type = unit[unit.startIndex] & 0x1f
            switch type {
            case 7:
                sps = unit
            case 8:
                pps = unit
            default:
                pictureUnits.append(unit)
                containsIDR = containsIDR || type == 5
            }
        }

        if formatDescription == nil || isCodecConfig {
            try rebuildFormatDescriptionIfPossible()
        }
        guard !pictureUnits.isEmpty, let formatDescription else { return false }

        // 解码器被刷新后只能从 IDR 恢复。过去这里继续提交 P 帧，系统会静默丢弃，
        // 于是网络帧率仍在增长但窗口永久停在首帧。
        let effectiveKeyFrame = isKeyFrame || containsIDR
        guard !waitingForKeyFrame || effectiveKeyFrame else { return false }
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            waitingForKeyFrame = true
            guard effectiveKeyFrame else { return false }
        }

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
        if !effectiveKeyFrame {
            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleAttachmentKey_NotSync,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldNotPropagate
            )
        }
        guard let session = try decompressionSession(for: formatDescription) else { return false }
        let decoded = DecodedFrameBox()
        var decodeInfo = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            infoFlagsOut: &decodeInfo
        ) { status, infoFlags, imageBuffer, _, presentationTimeStamp, presentationDuration in
            decoded.store(
                status: status,
                dropped: infoFlags.contains(.frameDropped),
                imageBuffer: imageBuffer,
                presentationTimeStamp: presentationTimeStamp,
                presentationDuration: presentationDuration
            )
        }
        guard decodeStatus == noErr else {
            waitingForKeyFrame = true
            throw ScreenCastVideoError.cannotDecodeFrame(decodeStatus)
        }
        let output = decoded.value
        guard output.status == noErr, !output.dropped, let imageBuffer = output.imageBuffer else {
            waitingForKeyFrame = true
            throw ScreenCastVideoError.cannotDecodeFrame(output.status)
        }

        // 编码端 PTS 只用于保证帧顺序，不能直接作为 Mac 显示层的播放时钟。
        // 部分 HarmonyOS 设备会把 Surface 的纳秒单调时钟原样写进 attr.pts；
        // 若按协议微秒再次换算，显示层会把后续帧排到数天以后，表面上就像只投出首帧。
        // 每个已解码画面改用 Mac 当前主机时钟，并保持严格递增，才能真正即时刷新。
        var displayTiming = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: nextDisplayTimeStamp(),
            decodeTimeStamp: .invalid
        )
        var displayFormat: CMVideoFormatDescription?
        let displayFormatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &displayFormat
        )
        guard displayFormatStatus == noErr, let displayFormat else {
            throw ScreenCastVideoError.cannotCreateDisplaySample(displayFormatStatus)
        }
        var displaySample: CMSampleBuffer?
        let displayStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: displayFormat,
            sampleTiming: &displayTiming,
            sampleBufferOut: &displaySample
        )
        guard displayStatus == noErr, let displaySample else {
            throw ScreenCastVideoError.cannotCreateDisplaySample(displayStatus)
        }
        CMSetAttachment(
            displaySample,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldNotPropagate
        )
        renderer.enqueue(displaySample)
        waitingForKeyFrame = false
        return true
    }

    private func nextDisplayTimeStamp() -> CMTime {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if lastDisplayTimeStamp.isValid, CMTimeCompare(now, lastDisplayTimeStamp) <= 0 {
            lastDisplayTimeStamp = CMTimeAdd(
                lastDisplayTimeStamp,
                CMTime(value: 1, timescale: 1_000_000)
            )
        } else {
            lastDisplayTimeStamp = now
        }
        return lastDisplayTimeStamp
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
        if let decompressionSession {
            VTDecompressionSessionInvalidate(decompressionSession)
        }
        decompressionSession = nil
        waitingForKeyFrame = true
    }

    private func decompressionSession(
        for formatDescription: CMVideoFormatDescription
    ) throws -> VTDecompressionSession? {
        if let decompressionSession { return decompressionSession }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let decoderSpecification: [CFString: Any] = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true,
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpecification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw ScreenCastVideoError.cannotCreateDecoder(status)
        }
        decompressionSession = session
        return session
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

private struct DecodedFrameOutput {
    let status: OSStatus
    let dropped: Bool
    let imageBuffer: CVImageBuffer?
    let presentationTimeStamp: CMTime
    let presentationDuration: CMTime
}

/// 同步解码关闭异步与时序处理后，VideoToolbox 会在函数返回前调用完成块；
/// 锁仍用于满足系统回调的 Sendable 边界，避免把 CVPixelBuffer 跨 actor 传递。
private final class DecodedFrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var output = DecodedFrameOutput(
        status: -1,
        dropped: false,
        imageBuffer: nil,
        presentationTimeStamp: .invalid,
        presentationDuration: .invalid
    )

    var value: DecodedFrameOutput { lock.withLock { output } }

    func store(
        status: OSStatus,
        dropped: Bool,
        imageBuffer: CVImageBuffer?,
        presentationTimeStamp: CMTime,
        presentationDuration: CMTime
    ) {
        lock.withLock {
            output = DecodedFrameOutput(
                status: status,
                dropped: dropped,
                imageBuffer: imageBuffer,
                presentationTimeStamp: presentationTimeStamp,
                presentationDuration: presentationDuration
            )
        }
    }
}

private enum ScreenCastVideoError: LocalizedError {
    case cannotCreateFormat(OSStatus)
    case cannotCreateDecoder(OSStatus)
    case cannotCreateBlockBuffer(OSStatus)
    case cannotCopyFrame(OSStatus)
    case cannotCreateSample(OSStatus)
    case cannotDecodeFrame(OSStatus)
    case cannotCreateDisplaySample(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .cannotCreateFormat(code): "无法创建 H.264 解码格式（\(code)）"
        case let .cannotCreateDecoder(code): "无法创建 H.264 硬件解码器（\(code)）"
        case let .cannotCreateBlockBuffer(code): "无法创建投屏帧缓冲（\(code)）"
        case let .cannotCopyFrame(code): "无法写入投屏帧（\(code)）"
        case let .cannotCreateSample(code): "无法创建投屏视频样本（\(code)）"
        case let .cannotDecodeFrame(code): "无法解码投屏视频帧（\(code)）"
        case let .cannotCreateDisplaySample(code): "无法创建投屏显示帧（\(code)）"
        }
    }
}
