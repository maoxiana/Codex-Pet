import AppKit
import Foundation
import RebornQuotaCore

if CommandLine.arguments.contains("--smoke-exit") {
    exit(EXIT_SUCCESS)
}

let instanceLock: SingleInstanceLock
do {
    guard let acquiredLock = try SingleInstanceLock.acquire() else {
        exit(EXIT_SUCCESS)
    }
    instanceLock = acquiredLock
} catch {
    exit(EXIT_FAILURE)
}
_ = instanceLock

let runtimeStateURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/RebornQuota/runtime-state.json")
var crashGuard = CrashLoopGuard(storage: JSONFileCrashLoopStorage(url: runtimeStateURL))
let crashDecision: CrashLoopLaunchDecision
do {
    crashDecision = try crashGuard.beginLaunch()
} catch {
    exit(EXIT_FAILURE)
}
guard crashDecision == .continueLaunching else {
    exit(EXIT_SUCCESS)
}

let application = NSApplication.shared
let runtime = AppDelegate(crashGuard: crashGuard)
#if REBORN_QUOTA_QA
runtime.configureQA(QAControlOptions.parse(CommandLine.arguments))
#endif
application.delegate = runtime
application.setActivationPolicy(.accessory)
let signalTerminationHandler = SignalTerminationHandler(appDelegate: runtime)
signalTerminationHandler.start()
application.run()
