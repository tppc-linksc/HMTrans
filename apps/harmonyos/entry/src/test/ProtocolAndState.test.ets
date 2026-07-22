import { describe, expect, it } from '@ohos/hypium'
import {
  createFileMeta,
  createDeviceInfo,
  createPairingRequest,
  createReceiveDecision,
  encodeJsonLine,
  wifiIpAddress,
} from '../main/ets/common/Protocol'
import { TransferDirection, TransferListItem, TransferState } from '../main/ets/models/TransferListItem'
import { TransferStateService } from '../main/ets/services/TransferStateService'
import { validateZipEntryName } from '../main/ets/services/ZipSafetyService'
import { ControlLineInbox } from '../main/ets/services/ControlLineInbox'
import { stagingEntryBelongsToTransfer } from '../main/ets/services/StagingStorageService'
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
import {
  authenticateFileMeta,
  authenticatedUnpairRequest,
  verifyFileMetaAuthentication,
  verifyUnpairRequest,
} from '../main/ets/common/PairingSecurity'

export default function protocolAndStateTest(): void {
  describe('HMTrans protocol and state', () => {
    it('normalizes pairing code and keeps identity fields', 0, () => {
      const request = createPairingRequest(
        'pad-id', 'MatePad', 'HarmonyOS', '6.1.0', '192.168.1.10', 51888, 'fingerprint',
        'mac-id', 'mac-fingerprint', 'request-1', 'public-key', 1,
      )
      expect(request.requesterFingerprint).assertEqual('fingerprint')
      expect(request.targetDeviceId).assertEqual('mac-id')
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
      const secret = '33'.repeat(32)
      const request = authenticatedUnpairRequest('pad-id', 'pad-fingerprint', 'mac-id', secret)
      expect(request.type).assertEqual('unpair_request')
      expect(request.requesterDeviceId).assertEqual('pad-id')
      expect(request.requesterFingerprint).assertEqual('pad-fingerprint')
      expect(request.targetDeviceId).assertEqual('mac-id')
      expect(verifyUnpairRequest(request, secret)).assertTrue()
    })

    it('rejects tampered authenticated file metadata', 0, () => {
      const secret = '44'.repeat(32)
      const signed = authenticateFileMeta(
        createFileMeta('report.pdf', 123, 'a'.repeat(64), 'mac-id', 'Mac', 'macOS', 'transfer-1',
          'file', 'report.pdf', 123, 1, 'mac-fingerprint'),
        secret,
      )
      expect(verifyFileMetaAuthentication(signed, secret)).assertTrue()
      signed.senderName = '伪造名称'
      expect(verifyFileMetaAuthentication(signed, secret)).assertFalse()
    })

    it('advertises and displays the Pad local IPv4 address', 0, () => {
      const localIp = wifiIpAddress(0xC0A80121)
      expect(localIp).assertEqual('192.168.1.33')
      expect(wifiIpAddress(0xC0A803CC)).assertEqual('192.168.3.204')
      const device = createDeviceInfo('Linksc的MatePad Pro', 51888, 'pad-id', localIp,
        'HUAWEI Q6', 'HarmonyOS6.1.0', 'fingerprint')
      expect(device.deviceName).assertEqual('Linksc的MatePad Pro')
      expect(device.ip).assertEqual('192.168.1.33')
    })

    it('moves a completed task into durable history', 0, () => {
      const state = new TransferStateService()
      const item = new TransferListItem({
        id: 'transfer-1', fileName: 'photo.jpg', peerName: 'Mac', direction: TransferDirection.Sending, progress: 50,
        detail: '传输中', state: TransferState.Active, timeText: '12:00', startedAt: Date.now(), fileSize: 100,
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

    it('matches only exact staging artifacts for an active transfer', 0, () => {
      expect(stagingEntryBelongsToTransfer('transfer-1.part', 'transfer-1')).assertTrue()
      expect(stagingEntryBelongsToTransfer('transfer-1.meta.json', 'transfer-1')).assertTrue()
      expect(stagingEntryBelongsToTransfer('transfer-1-folder.zip', 'transfer-1')).assertTrue()
      expect(stagingEntryBelongsToTransfer('transfer-10.part', 'transfer-1')).assertFalse()
      expect(stagingEntryBelongsToTransfer('old-transfer-1.part', 'transfer-1')).assertFalse()
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
      const cipher = new ScreenCastCipher(secret, 'session-1')
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

    it('rejects media ciphertext replayed after a TCP reconnect', 0, async () => {
      const secret = '22'.repeat(32)
      const previous = new ScreenCastCipher(secret, 'session|connection-a')
      const reconnected = new ScreenCastCipher(secret, 'session|connection-b')
      const plain = stringToArrayBuffer('old-frame')
      const header = buildCastHeader(CastMessageType.VIDEO_FRAME, CastPacketFlags.ENCRYPTED,
        plain.byteLength + 28, 1, 100)
      const sealed = await previous.encrypt(plain, header)
      let rejected = false
      try { await reconnected.decrypt(sealed, header) } catch (_) { rejected = true }
      expect(rejected).assertTrue()
    })
  })
}
