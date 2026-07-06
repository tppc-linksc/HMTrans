import { TransferListItem } from '../models/TransferListItem'

export function fileTypeLabel(fileName: string): string {
  const index = fileName.lastIndexOf('.')
  if (index < 0 || index === fileName.length - 1) {
    return '文件'
  }
  return fileName.substring(index + 1).toUpperCase()
}

export function fileNameFromUri(uri: string): string {
  const index = uri.lastIndexOf('/')
  return index >= 0 ? uri.substring(index + 1) : uri
}

export function nowText(): string {
  const date = new Date()
  const hour = `${date.getHours()}`.padStart(2, '0')
  const minute = `${date.getMinutes()}`.padStart(2, '0')
  return `${hour}:${minute}`
}

export function formatBytes(bytes: number): string {
  const units: Array<string> = ['B', 'KB', 'MB', 'GB', 'TB']
  let value = bytes
  let index = 0
  while (value >= 1024 && index < units.length - 1) {
    value = value / 1024
    index++
  }
  return `${value.toFixed(index === 0 ? 0 : 1)} ${units[index]}`
}

export function completionDetail(prefix: string, item: TransferListItem): string {
  const elapsed = Math.max((Date.now() - item.startedAt) / 1000, 0.15)
  const sizeText = item.fileSize > 0 ? formatBytes(item.fileSize) : '未知大小'
  const typeText = item.fileType.length > 0 ? item.fileType : fileTypeLabel(item.fileName)
  const averageText = item.fileSize > 0 ? `${formatBytes(item.fileSize / elapsed)}/s` : '-'
  return `${prefix} · ${sizeText} · ${typeText} · 平均 ${averageText}`
}
