export interface TransferListItemOptions {
  id: string
  fileName: string
  peerName: string
  direction: string
  progress: number
  detail: string
  state: string
  timeText: string
  startedAt: number
  fileSize: number
  fileType: string
  localPath?: string
}

@ObservedV2
export class TransferListItem {
  @Trace id: string
  @Trace fileName: string
  @Trace peerName: string
  @Trace direction: string
  @Trace progress: number
  @Trace detail: string
  @Trace state: string
  @Trace timeText: string
  @Trace startedAt: number
  @Trace fileSize: number
  @Trace fileType: string
  @Trace localPath?: string

  constructor(options: TransferListItemOptions) {
    this.id = options.id
    this.fileName = options.fileName
    this.peerName = options.peerName
    this.direction = options.direction
    this.progress = options.progress
    this.detail = options.detail
    this.state = options.state
    this.timeText = options.timeText
    this.startedAt = options.startedAt
    this.fileSize = options.fileSize
    this.fileType = options.fileType
    this.localPath = options.localPath
  }

  copyWith(progress: number, detail: string, state: string, timeText: string): TransferListItem {
    return new TransferListItem({
      id: this.id,
      fileName: this.fileName,
      peerName: this.peerName,
      direction: this.direction,
      progress,
      detail,
      state,
      timeText,
      startedAt: this.startedAt,
      fileSize: this.fileSize,
      fileType: this.fileType,
      localPath: this.localPath,
    })
  }
}
