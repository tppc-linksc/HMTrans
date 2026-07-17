export interface ScreenCaptureOptions {
  width: number
  height: number
  frameRate: number
  bitrate: number
}

export interface ScreenCaptureFrame {
  data: ArrayBuffer
  ptsUs: number
  flags: number
}

export interface ScreenCaptureStartResult {
  started: boolean
  stage: string
  errorCode: number
}

export type ScreenCaptureStateCallback = (state: number, message: string) => void
export type ScreenCaptureFrameCallback = (frame: ScreenCaptureFrame) => void

/** 注册原生采集状态回调；再次注册会替换旧回调。 */
export function onState(callback: ScreenCaptureStateCallback): void

/** 注册 H.264 编码帧回调；内部队列已限制为四帧，慢消费者会主动丢弃旧帧。 */
export function onFrame(callback: ScreenCaptureFrameCallback): void

/** 触发系统录屏授权并开始采集。 */
export function startCapture(options: ScreenCaptureOptions): ScreenCaptureStartResult

/** 停止并释放本次系统录屏会话。 */
export function stopCapture(): void

/** 返回当前是否处于采集状态。 */
export function isCapturing(): boolean
