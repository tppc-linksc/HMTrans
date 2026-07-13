import Foundation

struct ZipArchiveSummary: Sendable {
    let entryCount: Int
    let compressedSize: Int64
    let expandedSize: Int64
}

/// 直接读取 ZIP 中央目录，在系统解压器写入磁盘前完成路径、链接、体积和压缩比校验。
enum ZipArchiveInspector {
    private static let maximumEOCDSearch = 65_557
    private static let maximumCentralDirectory = 32 * 1_024 * 1_024
    private static let maximumEntries = 100_000
    private static let maximumEntrySize: Int64 = 256 * 1_024 * 1_024 * 1_024
    private static let maximumExpandedSize: Int64 = 512 * 1_024 * 1_024 * 1_024
    private static let ratioCheckMinimum: Int64 = 16 * 1_024 * 1_024
    private static let maximumCompressionRatio: Int64 = 1_000

    static func inspect(_ archiveURL: URL) throws -> ZipArchiveSummary {
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        let tailSize = Int(min(fileSize, UInt64(maximumEOCDSearch)))
        try handle.seek(toOffset: fileSize - UInt64(tailSize))
        guard let tail = try handle.read(upToCount: tailSize),
              let eocd = tail.lastSignature(0x0605_4B50), eocd + 22 <= tail.count else {
            throw HMTransError.protocolError("ZIP 缺少中央目录结束记录")
        }

        var entryCount = Int(tail.uint16(at: eocd + 10))
        var centralSize = UInt64(tail.uint32(at: eocd + 12))
        var centralOffset = UInt64(tail.uint32(at: eocd + 16))
        if entryCount == 0xFFFF || centralSize == 0xFFFF_FFFF || centralOffset == 0xFFFF_FFFF {
            guard let locator = Data(tail.prefix(eocd)).lastSignature(0x0706_4B50), locator + 20 <= eocd else {
                throw HMTransError.protocolError("ZIP64 定位记录损坏")
            }
            let zip64Offset = tail.uint64(at: locator + 8)
            try handle.seek(toOffset: zip64Offset)
            guard let zip64 = try handle.read(upToCount: 56), zip64.count == 56,
                  zip64.uint32(at: 0) == 0x0606_4B50 else {
                throw HMTransError.protocolError("ZIP64 中央目录损坏")
            }
            entryCount = try checkedInt(zip64.uint64(at: 32), label: "ZIP64 条目数")
            centralSize = zip64.uint64(at: 40)
            centralOffset = zip64.uint64(at: 48)
        }
        guard entryCount <= maximumEntries, centralSize <= UInt64(maximumCentralDirectory) else {
            throw HMTransError.protocolError("文件夹压缩包条目或目录信息过多")
        }
        guard centralOffset <= fileSize, centralSize <= fileSize - centralOffset else {
            throw HMTransError.protocolError("ZIP 中央目录范围越界")
        }
        try handle.seek(toOffset: centralOffset)
        guard let central = try handle.read(upToCount: Int(centralSize)), central.count == Int(centralSize) else {
            throw HMTransError.protocolError("ZIP 中央目录读取不完整")
        }
        return try inspectCentralDirectory(central, expectedCount: entryCount)
    }

    private static func inspectCentralDirectory(_ data: Data, expectedCount: Int) throws -> ZipArchiveSummary {
        var offset = 0
        var count = 0
        var totalCompressed: Int64 = 0
        var totalExpanded: Int64 = 0
        while offset + 46 <= data.count, count < expectedCount {
            guard data.uint32(at: offset) == 0x0201_4B50 else {
                throw HMTransError.protocolError("ZIP 中央目录损坏")
            }
            let nameLength = Int(data.uint16(at: offset + 28))
            let extraLength = Int(data.uint16(at: offset + 30))
            let commentLength = Int(data.uint16(at: offset + 32))
            let end = offset + 46 + nameLength + extraLength + commentLength
            guard end <= data.count else { throw HMTransError.protocolError("ZIP 条目长度越界") }
            let nameData = data[(offset + 46)..<(offset + 46 + nameLength)]
            try validateEntryName(String(decoding: nameData, as: UTF8.self))
            let externalAttributes = data.uint32(at: offset + 38)
            if ((externalAttributes >> 16) & 0xF000) == 0xA000 {
                throw HMTransError.protocolError("文件夹压缩包包含符号链接")
            }

            var compressed = UInt64(data.uint32(at: offset + 20))
            var expanded = UInt64(data.uint32(at: offset + 24))
            if compressed == 0xFFFF_FFFF || expanded == 0xFFFF_FFFF {
                let extra = data[(offset + 46 + nameLength)..<(offset + 46 + nameLength + extraLength)]
                let sizes = try zip64Sizes(
                    Data(extra),
                    needsExpanded: expanded == 0xFFFF_FFFF,
                    needsCompressed: compressed == 0xFFFF_FFFF
                )
                if expanded == 0xFFFF_FFFF { expanded = sizes.expanded }
                if compressed == 0xFFFF_FFFF { compressed = sizes.compressed }
            }
            let entryExpanded = try checkedInt64(expanded, label: "ZIP 条目解压大小")
            let entryCompressed = try checkedInt64(compressed, label: "ZIP 条目压缩大小")
            guard entryExpanded <= maximumEntrySize else {
                throw HMTransError.protocolError("ZIP 单个条目解压后过大")
            }
            totalExpanded = try adding(totalExpanded, entryExpanded)
            totalCompressed = try adding(totalCompressed, entryCompressed)
            guard totalExpanded <= maximumExpandedSize else {
                throw HMTransError.protocolError("ZIP 解压后总大小超过 512 GiB 上限")
            }
            offset = end
            count += 1
        }
        guard count == expectedCount else { throw HMTransError.protocolError("ZIP 条目数量不一致") }
        if totalExpanded >= ratioCheckMinimum,
           (totalCompressed == 0 || totalExpanded / max(1, totalCompressed) > maximumCompressionRatio) {
            throw HMTransError.protocolError("ZIP 压缩比异常，已拒绝可能的解压炸弹")
        }
        return ZipArchiveSummary(entryCount: count, compressedSize: totalCompressed, expandedSize: totalExpanded)
    }

    private static func validateEntryName(_ rawName: String) throws {
        let entry = rawName.replacingOccurrences(of: "\\", with: "/")
        let components = entry.split(separator: "/", omittingEmptySubsequences: false)
        let hasDrivePrefix = entry.count >= 3
            && entry[entry.index(entry.startIndex, offsetBy: 1)] == ":"
            && entry[entry.index(entry.startIndex, offsetBy: 2)] == "/"
        if entry.hasPrefix("/") || hasDrivePrefix || components.contains("..") {
            throw HMTransError.protocolError("文件夹压缩包包含不安全路径")
        }
    }

    private static func zip64Sizes(
        _ extra: Data,
        needsExpanded: Bool,
        needsCompressed: Bool
    ) throws -> (expanded: UInt64, compressed: UInt64) {
        var offset = 0
        while offset + 4 <= extra.count {
            let tag = extra.uint16(at: offset)
            let length = Int(extra.uint16(at: offset + 2))
            let valueStart = offset + 4
            let valueEnd = valueStart + length
            guard valueEnd <= extra.count else { throw HMTransError.protocolError("ZIP 扩展字段长度越界") }
            if tag == 0x0001 {
                var cursor = valueStart
                var expanded: UInt64 = 0
                var compressed: UInt64 = 0
                if needsExpanded {
                    guard cursor + 8 <= valueEnd else { throw HMTransError.protocolError("ZIP64 缺少解压大小") }
                    expanded = extra.uint64(at: cursor); cursor += 8
                }
                if needsCompressed {
                    guard cursor + 8 <= valueEnd else { throw HMTransError.protocolError("ZIP64 缺少压缩大小") }
                    compressed = extra.uint64(at: cursor)
                }
                return (expanded, compressed)
            }
            offset = valueEnd
        }
        throw HMTransError.protocolError("ZIP64 条目缺少大小扩展字段")
    }

    private static func checkedInt(_ value: UInt64, label: String) throws -> Int {
        guard value <= UInt64(Int.max) else { throw HMTransError.protocolError("\(label)超出支持范围") }
        return Int(value)
    }

    private static func checkedInt64(_ value: UInt64, label: String) throws -> Int64 {
        guard value <= UInt64(Int64.max) else { throw HMTransError.protocolError("\(label)超出支持范围") }
        return Int64(value)
    }

    private static func adding(_ left: Int64, _ right: Int64) throws -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        guard !overflow else { throw HMTransError.protocolError("ZIP 解压大小溢出") }
        return value
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }

    func uint64(at offset: Int) -> UInt64 {
        UInt64(uint32(at: offset)) | (UInt64(uint32(at: offset + 4)) << 32)
    }

    func lastSignature(_ signature: UInt32) -> Int? {
        guard count >= 4 else { return nil }
        for offset in stride(from: count - 4, through: 0, by: -1) {
            if uint32(at: offset) == signature { return offset }
        }
        return nil
    }
}
