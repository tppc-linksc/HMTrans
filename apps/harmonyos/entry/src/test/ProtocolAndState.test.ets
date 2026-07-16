import { describe, expect, it } from '@ohos/hypium'
import {
  createFileMeta,
  createPairingRequest,
  createReceiveDecision,
  createUnpairRequest,
  encodeJsonLine,
} from '../main/ets/common/Protocol'
import { TransferListItem } from '../main/ets/models/TransferListItem'
import { TransferStateService } from '../main/ets/services/TransferStateService'
import { validateZipEntryName } from '../main/ets/services/ZipSafetyService'
import { ControlLineInbox } from '../main/ets/services/ControlLineInbox'
import { stringToArrayBuffer } from '../main/ets/common/Bytes'
import {
  buildCastHeader,
  castPacket,
  CastMessageType,
  CastPacketFlags,
  concatBuffers,
  parseCastHeader,
  ScreenCastCipher,
} from '../main/ets/common/ScreenCastProtocol'

export default function protocolAndStateTest(): void {
  describe('HMTrans protocol and state', () => {
    it('normalizes pairing code and keeps identity fields', 0, () => {
      const request = createPairingRequest(
        'pad-id', 'MatePad', 'HarmonyOS', '6.1.0', '192.168.1.10', 51888, '246 810', 'fingerprint',
      )
      expect(request.code).assertEqual('246810')
      expect(request.requesterFingerprint).assertEqual('fingerprint')
      expect(request.version).assertEqual('0.2.0')
    })

    it('advertises resumable one-megabyte chunks', 0, () => {
      const meta = createFileMeta('large.bin', 3 * 1048576 + 1, 'digest')
      expect(meta.totalChunks).assertEqual(4)
      expect(meta.resumeSupported).assertTrue()
      const decision = createReceiveDecision(true, undefined, 1048576)
      expect(decision.resumeOffset).assertEqual(1048576)
      expect(encodeJsonLine(meta).endsWith('\n')).assertTrue()
    })

    it('binds unpair request to both stable device identities', 0, () => {
      const request = createUnpairRequest('pad-id', 'pad-fingerprint', 'mac-id')
      expect(request.type).assertEqual('unpair_request')
      expect(request.requesterDeviceId).assertEqual('pad-id')
      expect(request.requesterFingerprint).assertEqual('pad-fingerprint')
      expect(request.targetDeviceId).assertEqual('mac-id')
    })

    it('moves a completed task into durable history', 0, () => {
      const state = new TransferStateService()
      const item = new TransferListItem({
        id: 'transfer-1', fileName: 'photo.jpg', peerName: 'Mac', direction: '发送', progress: 50,
        detail: '传输中', state: '传输中', timeText: '12:00', startedAt: Date.now(), fileSize: 100,
        fileType: 'JPG', deviceId: 'mac-id',
      })
      const result = state.complete([item], item.id, true, '发送完成', undefined, 'mac-id')
      expect(result.current.length).assertEqual(0)
      expect(result.historyItem?.state).assertEqual('已完成')
      expect(result.historyItem?.progress).assertEqual(100)
    })

    it('rejects zip traversal and absolute entry names', 0, () => {
      expect(() => validateZipEntryName('../escape.txt')).assertThrowError('文件夹归档包含不安全路径')
      expect(() => validateZipEntryName('safe/../../escape.txt')).assertThrowError('文件夹归档包含不安全路径')
      expect(() => validateZipEntryName('/absolute/file.txt')).assertThrowError('文件夹归档包含不安全路径')
      expect(() => validateZipEntryName('C:/absolute/file.txt')).assertThrowError('文件夹归档包含不安全路径')
      expect(() => validateZipEntryName('safe\\..\\escape.txt')).assertThrowError('文件夹归档包含不安全路径')
      validateZipEntryName('folder/nested/photo.jpg')
    })

    it('keeps an early final response until the sender awaits it', 0, async () => {
      const inbox = new ControlLineInbox()
      inbox.append(stringToArrayBuffer('{"type":"receive_decision","accepted":true}\n' +
        '{"type":"transfer_success","transferId":"transfer-1"}\n'))
      const decision = await inbox.nextLine()
      const result = await inbox.nextLine()
      expect(decision.indexOf('receive_decision') >= 0).assertTrue()
      expect(result.indexOf('transfer_success') >= 0).assertTrue()
    })

    it('encodes HMCS header fields with big-endian lengths', 0, () => {
      const payload = stringToArrayBuffer('frame')
      const packet = castPacket(CastMessageType.VIDEO_FRAME,
        CastPacketFlags.ENCRYPTED | CastPacketFlags.KEY_FRAME, payload, 42, 9000)
      const header = parseCastHeader(packet.slice(0, 32))
      expect(header.type).assertEqual(CastMessageType.VIDEO_FRAME)
      expect(header.flags).assertEqual(CastPacketFlags.ENCRYPTED | CastPacketFlags.KEY_FRAME)
      expect(header.sequence).assertEqual(42)
      expect(header.ptsUs).assertEqual(9000)
      expect(header.payloadLength).assertEqual(payload.byteLength)
    })

    it('encrypts cast frames and rejects modified authentication data', 0, async () => {
      const secret = '11'.repeat(32)
      const cipher = new ScreenCastCipher(secret)
      const plain = stringToArrayBuffer('screen-frame')
      const header = buildCastHeader(CastMessageType.VIDEO_FRAME, CastPacketFlags.ENCRYPTED,
        plain.byteLength + 28, 1, 100)
      const sealed = await cipher.encrypt(plain, header)
      const opened = await cipher.decrypt(sealed, header)
      expect(new Uint8Array(opened).length).assertEqual(new Uint8Array(plain).length)
      const modifiedHeader = concatBuffers([header.slice(0, 31), new Uint8Array([1]).buffer])
      let rejected = false
      try { await cipher.decrypt(sealed, modifiedHeader) } catch (_) { rejected = true }
      expect(rejected).assertTrue()
    })
  })
}
