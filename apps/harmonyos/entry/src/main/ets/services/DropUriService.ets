import { unifiedDataChannel } from '@kit.ArkData'

/** Normalizes every ArkUI drag record into deduplicated picker-style URIs. */
export class DropUriService {
  extract(event: DragEvent): Array<string> {
    try {
      const uris: Array<string> = []
      event.getData().getRecords().forEach((record: unifiedDataChannel.UnifiedRecord) => {
        const uri = this.fromRecord(record)
        if (uri.length > 0 && uris.indexOf(uri) < 0) uris.push(uri)
      })
      return uris
    } catch (_) {
      return []
    }
  }

  private fromRecord(record: unifiedDataChannel.UnifiedRecord): string {
    if (record instanceof unifiedDataChannel.Folder) return (record as unifiedDataChannel.Folder).folderUri
    if (record instanceof unifiedDataChannel.Image) return (record as unifiedDataChannel.Image).imageUri
    if (record instanceof unifiedDataChannel.Video) return (record as unifiedDataChannel.Video).videoUri
    if (record instanceof unifiedDataChannel.Audio) return (record as unifiedDataChannel.Audio).audioUri
    if (record instanceof unifiedDataChannel.File) return (record as unifiedDataChannel.File).uri
    try {
      const value = record.getValue()
      return typeof value === 'string' ? value : ''
    } catch (_) {
      return ''
    }
  }
}
