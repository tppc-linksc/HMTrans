import { util } from '@kit.ArkTS'
import { fileIo as fs } from '@kit.CoreFileKit'

const MAX_EOCD_SEARCH: number = 65557
const MAX_CENTRAL_DIRECTORY: number = 32 * 1024 * 1024
const MAX_ARCHIVE_ENTRIES: number = 100000

/** Rejects traversal and absolute paths before the platform ZIP extractor runs. */
export function validateZipEntryName(rawName: string): void {
  const name = rawName.replace(/\\/g, '/')
  const components = name.split('/')
  if (name.startsWith('/') || /^[A-Za-z]:\//.test(name) || components.indexOf('..') >= 0) {
    throw new Error('文件夹归档包含不安全路径')
  }
}

/** Validates ZIP names before the system extractor can write any entry. */
export class ZipSafetyService {
  validate(archivePath: string): void {
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
      const central = this.read(file.fd, centralOffset, centralSize)
      this.validateCentralDirectory(central, entryCount)
    } finally {
      if (file) try { fs.closeSync(file) } catch (_) {}
    }
  }

  private validateCentralDirectory(buffer: ArrayBuffer, expectedCount: number): void {
    const view = new DataView(buffer)
    const bytes = new Uint8Array(buffer)
    const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true })
    let offset = 0
    let count = 0
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
      offset = end
      count += 1
    }
    if (count !== expectedCount) throw new Error('ZIP 条目数量不一致')
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

  /** ZIP stores 64-bit counters little-endian; JavaScript numbers remain exact for practical local files. */
  private readUint64(view: DataView, offset: number): number {
    const low = view.getUint32(offset, true)
    const high = view.getUint32(offset + 4, true)
    const value = high * 4294967296 + low
    if (!Number.isSafeInteger(value)) throw new Error('ZIP64 数值超出支持范围')
    return value
  }
}
