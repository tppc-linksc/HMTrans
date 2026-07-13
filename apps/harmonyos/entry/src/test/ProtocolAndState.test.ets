import { describe, expect, it } from '@ohos/hypium'
import { createFileMeta, createPairingRequest, createReceiveDecision, encodeJsonLine } from '../main/ets/common/Protocol'
import { TransferListItem } from '../main/ets/models/TransferListItem'
import { TransferStateService } from '../main/ets/services/TransferStateService'
import { validateZipEntryName } from '../main/ets/services/ZipSafetyService'

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
  })
}
