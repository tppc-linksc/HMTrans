import { taskpool } from '@kit.ArkTS'
import { fileIo as fs } from '@kit.CoreFileKit'
import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { DEFAULT_CHUNK_SIZE } from '../common/Protocol'
import { sliceArrayBuffer, toHex } from '../common/Bytes'
import { errorText } from '../common/ErrorText'

function closeFileQuietly(file?: fs.File): void {
  if (!file) {
    return
  }
  try {
    fs.closeSync(file)
  } catch (_) {
  }
}

export function fileSize(uri: string): number {
  let file: fs.File | undefined
  try {
    file = fs.openSync(uri, fs.OpenMode.READ_ONLY)
    return fs.statSync(file.fd).size
  } catch (err) {
    throw new Error(`Unable to read file size: ${errorText(err)}`)
  } finally {
    closeFileQuietly(file)
  }
}

@Concurrent
function sha256FileTask(uri: string): string {
  let file: fs.File | undefined
  try {
    file = fs.openSync(uri, fs.OpenMode.READ_ONLY)
    const md = cryptoFramework.createMd('SHA256')
    const buffer = new ArrayBuffer(DEFAULT_CHUNK_SIZE)

    while (true) {
      const count = fs.readSync(file.fd, buffer)
      if (count <= 0) {
        break
      }
      const blob: cryptoFramework.DataBlob = {
        data: new Uint8Array(sliceArrayBuffer(buffer, count)),
      }
      md.updateSync(blob)
    }
    const digest = md.digestSync()
    return toHex(digest.data)
  } catch (err) {
    throw new Error(`Unable to hash file: ${errorText(err)}`)
  } finally {
    if (file) {
      try {
        fs.closeSync(file)
      } catch (_) {
      }
    }
  }
}

export async function sha256FileAsync(uri: string): Promise<string> {
  try {
    return await taskpool.execute(sha256FileTask, uri) as string
  } catch (err) {
    throw new Error(`Unable to run hash task: ${errorText(err)}`)
  }
}
