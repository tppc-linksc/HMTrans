import { util } from '@kit.ArkTS'

export function stringToArrayBuffer(value: string): ArrayBuffer {
  const encoder = new util.TextEncoder()
  return encoder.encodeInto(value).buffer
}

export function arrayBufferToString(buffer: ArrayBuffer): string {
  const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true })
  return decoder.decodeToString(new Uint8Array(buffer))
}

export function toHex(bytes: Uint8Array): string {
  let result = ''
  for (let index = 0; index < bytes.length; index++) {
    result += bytes[index].toString(16).padStart(2, '0')
  }
  return result
}

export function sliceArrayBuffer(buffer: ArrayBuffer, length: number): ArrayBuffer {
  return buffer.slice(0, length)
}
