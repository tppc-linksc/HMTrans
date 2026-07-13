import Foundation

/// 先进先出的并发闸门，用于限制相互独立的 Mac 网络会话，且不耦合各自的进度、错误和重试状态。
actor AsyncConcurrencyGate {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
            if active == 0 {
                let pending = idleWaiters
                idleWaiters.removeAll()
                pending.forEach { $0.resume() }
            }
        } else {
            waiters.removeFirst().resume()
        }
    }

    func waitUntilIdle() async {
        guard active > 0 || !waiters.isEmpty else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }
}
