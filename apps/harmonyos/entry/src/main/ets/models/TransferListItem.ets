/** 控制器与视图共享的稳定持久化状态。 */
export enum TransferState {
  Preparing = '准备中',
  Active = '传输中',
  Verifying = '校验中',
  Paused = '已暂停',
  Waiting = '等待重连',
  Done = '已完成',
  Failed = '失败',
  Cancelled = '已取消',
}

export enum TransferDirection {
  Sending = '发送',
  Receiving = '接收',
}

export interface TransferListItemOptions {
  id: string
  fileName: string
  peerName: string
  direction: TransferDirection
  progress: number
  detail: string
  state: TransferState
  timeText: string
  startedAt: number
  fileSize: number
  fileType: string
  localPath?: string
  stagingPath?: string
  deviceId?: string
  groupId?: string
  errorCode?: string
  confirmedOffset?: number
  updatedAt?: number
  sourceSize?: number
  sourceFileCount?: number
}

@ObservedV2
export class TransferListItem {
  @Trace id: string
  @Trace fileName: string
  @Trace peerName: string
  @Trace direction: TransferDirection
  @Trace progress: number
  @Trace detail: string
  @Trace state: TransferState
  @Trace timeText: string
  @Trace startedAt: number
  @Trace fileSize: number
  @Trace fileType: string
  @Trace localPath?: string
  @Trace stagingPath?: string
  @Trace deviceId: string
  @Trace groupId: string
  @Trace errorCode?: string
  @Trace confirmedOffset: number
  @Trace updatedAt: number
  @Trace sourceSize: number
  @Trace sourceFileCount: number

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
    this.stagingPath = options.stagingPath
    this.deviceId = options.deviceId ?? ''
    this.groupId = options.groupId ?? options.id
    this.errorCode = options.errorCode
    this.confirmedOffset = options.confirmedOffset ?? 0
    this.updatedAt = options.updatedAt ?? Date.now()
    this.sourceSize = options.sourceSize ?? options.fileSize
    this.sourceFileCount = options.sourceFileCount ?? 1
  }

  copyWith(progress: number, detail: string, state: TransferState, timeText: string): TransferListItem {
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
      stagingPath: this.stagingPath,
      deviceId: this.deviceId,
      groupId: this.groupId,
      errorCode: this.errorCode,
      confirmedOffset: this.confirmedOffset,
      updatedAt: Date.now(),
      sourceSize: this.sourceSize,
      sourceFileCount: this.sourceFileCount,
    })
  }

  toOptions(): TransferListItemOptions {
    return {
      id: this.id,
      fileName: this.fileName,
      peerName: this.peerName,
      direction: this.direction,
      progress: this.progress,
      detail: this.detail,
      state: this.state,
      timeText: this.timeText,
      startedAt: this.startedAt,
      fileSize: this.fileSize,
      fileType: this.fileType,
      localPath: this.localPath,
      stagingPath: this.stagingPath,
      deviceId: this.deviceId,
      groupId: this.groupId,
      errorCode: this.errorCode,
      confirmedOffset: this.confirmedOffset,
      updatedAt: this.updatedAt,
      sourceSize: this.sourceSize,
      sourceFileCount: this.sourceFileCount,
    }
  }
}
