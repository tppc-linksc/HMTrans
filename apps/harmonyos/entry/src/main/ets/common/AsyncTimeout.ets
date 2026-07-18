/** 为网络控制响应增加明确时限，调用方可统一获得领域化超时原因。 */
export function withTimeout<T>(operation: Promise<T>, timeoutMs: number, reason: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(reason)), timeoutMs)
    operation.then((value: T) => {
      clearTimeout(timer)
      resolve(value)
    }).catch((err: Error) => {
      clearTimeout(timer)
      reject(err)
    })
  })
}
