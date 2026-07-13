import { util } from '@kit.ArkTS'
import { fileIo as fs } from '@kit.CoreFileKit'

const MAX_EOCD_SEARCH: number = 65557
const MAX_CENTRAL_DIRECTORY: number = 32 * 1024 * 1024
const MAX_ARCHIVE_ENTRIES: number = 100000
const MAX_ENTRY_EXPANDED_BYTES: number = 256 * 1024 * 1024 * 1024
const MAX_ARCHIVE_EXPANDED_BYTES: number = 512 * 1024 * 1024 * 1024
const MAX_COMPRESSION_RATIO: number = 1000
const RATIO_CHECK_MIN_BYTES: number = 16 * 1024 * 1024

export interface ZipValidationResult {
  entryCount: number
  expandedSize: number
  compressedSize: number
}

interface ZipEntrySizes {
  expanded: number
  compressed: number
}

/** 在系统 ZIP 解压器运行前拒绝路径穿越和绝对路径。 */
export function validateZipEntryName(rawName: string): void {
  const name = rawName.replace(/\\/g, '/')
  const components = name.split('/')
  if (name.startsWith('/') || /^[A-Za-z]:\//.test(name) || components.indexOf('..') >= 0) {
    throw new Error('文件夹归档包含不安全路径')
  }
}

/** 在系统解压器写入任何条目前校验 ZIP 条目名称。 */
export class ZipSafetyService {
  validate(archivePath: string): ZipValidationResult {
    let file: fs.File | undefined
    try {
      file = fs.openSync(archivePath, fs.OpenMode.READ_ONLY)
      const size = fs.statSync(file.fd).size
      const tailSize = Math.min(size, MAX_EOCD_SEARCH)
      const tail = this.read(file.fd, size - tailSize, tailSize)
      const eocd = this.findSignature(tail, 0x06054B50)
      if (eocd < 0) throw new Error('ZIP 缺少中央目录结束记录')
      const view = new DataView(tail)
      let entryCount = view.getUint16(eocd + 10, true)
      let centralSize = view.getUint32(eocd + 12, true)
      let centralOffset = view.getUint32(eocd + 16, true)
      if (entryCount === 0xFFFF || centralSize === 0xFFFFFFFF || centralOffset === 0xFFFFFFFF) {
        const locator = this.findSignature(tail.slice(0, eocd), 0x07064B50)
        if (locator < 0 || locator + 20 > tail.byteLength) throw new Error('ZIP64 定位记录损坏')
        const zip64Offset = this.readUint64(view, locator + 8)
        const zip64 = this.read(file.fd, zip64Offset, 56)
        const zip64View = new DataView(zip64)
        if (zip64View.getUint32(0, true) !== 0x06064B50) throw new Error('ZIP64 中央目录损坏')
        entryCount = this.readUint64(zip64View, 32)
        centralSize = this.readUint64(zip64View, 40)
        centralOffset = this.readUint64(zip64View, 48)
      }
      if (entryCount > MAX_ARCHIVE_ENTRIES || centralSize > MAX_CENTRAL_DIRECTORY) {
        throw new Error('文件夹归档条目过多')
      }
      if (centralOffset < 0 || centralSize < 0 || centralOffset + centralSize > size) {
        throw new Error('ZIP 中央目录范围越界')
      }
      const central = this.read(file.fd, centralOffset, centralSize)
      return this.validateCentralDirectory(central, entryCount)
    } finally {
      if (file) try { fs.closeSync(file) } catch (_) {}
    }
  }

  private validateCentralDirectory(buffer: ArrayBuffer, expectedCount: number): ZipValidationResult {
    const view = new DataView(buffer)
    const bytes = new Uint8Array(buffer)
    const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true })
    let offset = 0
    let count = 0
    let expandedSize = 0
    let compressedSize = 0
    while (offset + 46 <= buffer.byteLength && count < expectedCount) {
      if (view.getUint32(offset, true) !== 0x02014B50) throw new Error('ZIP 中央目录损坏')
      const nameLength = view.getUint16(offset + 28, true)
      const extraLength = view.getUint16(offset + 30, true)
      const commentLength = view.getUint16(offset + 32, true)
      const externalAttributes = view.getUint32(offset + 38, true)
      const end = offset + 46 + nameLength + extraLength + commentLength
      if (end > buffer.byteLength) throw new Error('ZIP 条目长度越界')
      const name = decoder.decodeToString(bytes.slice(offset + 46, offset + 46 + nameLength))
      validateZipEntryName(name)
      const unixMode = (externalAttributes >>> 16) & 0xF000
      if (unixMode === 0xA000) throw new Error('文件夹归档包含符号链接')
      let entryCompressed = view.getUint32(offset + 20, true)
      let entryExpanded = view.getUint32(offset + 24, true)
      if (entryCompressed === 0xFFFFFFFF || entryExpanded === 0xFFFFFFFF) {
        const sizes = this.readZip64Sizes(view, offset + 46 + nameLength, extraLength,
          entryExpanded === 0xFFFFFFFF, entryCompressed === 0xFFFFFFFF)
        if (entryExpanded === 0xFFFFFFFF) entryExpanded = sizes.expanded
        if (entryCompressed === 0xFFFFFFFF) entryCompressed = sizes.compressed
      }
      if (entryExpanded > MAX_ENTRY_EXPANDED_BYTES) throw new Error('ZIP 单个条目解压后过大')
      expandedSize += entryExpanded
      compressedSize += entryCompressed
      if (expandedSize > MAX_ARCHIVE_EXPANDED_BYTES) throw new Error('ZIP 解压后总大小超过 512 GiB 上限')
      offset = end
      count += 1
    }
    if (count !== expectedCount) throw new Error('ZIP 条目数量不一致')
    if (expandedSize >= RATIO_CHECK_MIN_BYTES &&
      (compressedSize <= 0 || expandedSize / compressedSize > MAX_COMPRESSION_RATIO)) {
      throw new Error('ZIP 压缩比异常，已拒绝可能的解压炸弹')
    }
    return { entryCount: count, expandedSize, compressedSize }
  }

  /** ZIP64 扩展字段只按中央目录标记的顺序读取 64 位大小。 */
  private readZip64Sizes(view: DataView, extraOffset: number, extraLength: number,
    needsExpanded: boolean, needsCompressed: boolean): ZipEntrySizes {
    let offset = extraOffset
    const end = extraOffset + extraLength
    while (offset + 4 <= end) {
      const tag = view.getUint16(offset, true)
      const length = view.getUint16(offset + 2, true)
      const valueStart = offset + 4
      const valueEnd = valueStart + length
      if (valueEnd > end) throw new Error('ZIP 扩展字段长度越界')
      if (tag === 0x0001) {
        let cursor = valueStart
        let expanded = 0
        let compressed = 0
        if (needsExpanded) {
          if (cursor + 8 > valueEnd) throw new Error('ZIP64 缺少解压大小')
          expanded = this.readUint64(view, cursor); cursor += 8
        }
        if (needsCompressed) {
          if (cursor + 8 > valueEnd) throw new Error('ZIP64 缺少压缩大小')
          compressed = this.readUint64(view, cursor)
        }
        const sizes: ZipEntrySizes = { expanded, compressed }
        return sizes
      }
      offset = valueEnd
    }
    throw new Error('ZIP64 条目缺少大小扩展字段')
  }

  private read(fd: number, offset: number, length: number): ArrayBuffer {
    if (offset < 0 || length < 0) throw new Error('ZIP 读取范围无效')
    const buffer = new ArrayBuffer(length)
    fs.lseek(fd, offset, fs.WhenceType.SEEK_SET)
    const count = fs.readSync(fd, buffer)
    if (count !== length) throw new Error('ZIP 数据读取不完整')
    return buffer
  }

  private findSignature(buffer: ArrayBuffer, signature: number): number {
    const view = new DataView(buffer)
    for (let offset = buffer.byteLength - 4; offset >= 0; offset -= 1) {
      if (view.getUint32(offset, true) === signature) return offset
    }
    return -1
  }

  /** ZIP 以小端序保存 64 位计数；对实际本地文件规模，JavaScript 数值仍可保持精确。 */
  private readUint64(view: DataView, offset: number): number {
    const low = view.getUint32(offset, true)
    const high = view.getUint32(offset + 4, true)
    const value = high * 4294967296 + low
    if (!Number.isSafeInteger(value)) throw new Error('ZIP64 数值超出支持范围')
    return value
  }
}
