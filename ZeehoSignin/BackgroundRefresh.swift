import BackgroundTasks
import os
import UIKit
import WidgetKit

private let backgroundLog = Logger(subsystem: "com.jieyu.zeeho.signin", category: "background")

enum ZeehoBackground {
    /// 必须和 Info.plist 里的 BGTaskSchedulerPermittedIdentifiers 一致。
    static let id = "com.jieyu.zeeho.signin.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refresh)
        }
    }

    static func schedule(status: SigninStatus?, replace: Bool) {
        let status = status ?? ZeehoFiles.loadStatus() ?? .missingToken()
        if replace {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id)
        }
        let request = BGAppRefreshTaskRequest(identifier: id)
        let when = ZeehoScheduler.nextRefresh(after: Date(), status: status)
        request.earliestBeginDate = max(when, Date().addingTimeInterval(60))
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            backgroundLog.error("预约后台刷新失败 \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        let box = CompletionBox()
        let work = Task {
            let signed = await ZeehoEngine.refresh(ignoreGate: true)
            let watched = await ZeehoEngine.watchIfDue()
            let status = (watched.updatedAtUnix ?? 0) > (signed.updatedAtUnix ?? 0) ? watched : signed
            WidgetCenter.shared.reloadAllTimelines()
            schedule(status: status, replace: true)
            box.finish(task, success: true)
        }
        task.expirationHandler = {
            work.cancel()
            box.finish(task, success: false)
        }
    }
}

private final class CompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func finish(_ task: BGTask, success: Bool) {
        lock.lock()
        let shouldFinish = !finished
        finished = true
        lock.unlock()
        guard shouldFinish else { return }
        task.setTaskCompleted(success: success)
    }
}
