import Darwin
import Dispatch
import Foundation
import RebornQuotaCore

/// Converts launchd's SIGTERM/SIGINT into the same bounded lifecycle shutdown
/// used by AppKit termination. Signals are ignored before Dispatch sources are
/// installed so default handling cannot race source delivery.
@MainActor
final class SignalTerminationHandler {
    private weak var appDelegate: AppDelegate?
    private var state = TerminationCoordinatorState()
    private var sources: [DispatchSourceSignal] = []
    private var forcedCompletion: DispatchWorkItem?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    func start() {
        guard sources.isEmpty else { return }
        for signalNumber in [SIGTERM, SIGINT] {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.receivedSignal() }
            }
            source.resume()
            sources.append(source)
        }
    }

    private func receivedSignal() {
        apply(state.receiveSignal())
    }

    private func shutdownFinished() {
        apply(state.shutdownFinished())
    }

    private func shutdownTimedOut() {
        apply(state.shutdownTimedOut())
    }

    private func apply(_ effects: [TerminationCoordinatorEffect]) {
        for effect in effects {
            switch effect {
            case .beginLifecycleShutdown:
                appDelegate?.beginExternalTermination { [weak self] in
                    self?.shutdownFinished()
                }
            case .scheduleForcedCompletion(let delay):
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { self?.shutdownTimedOut() }
                }
                forcedCompletion = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            case .markCleanExit:
                forcedCompletion?.cancel()
                forcedCompletion = nil
                appDelegate?.forceCleanExitState()
            case .exitSuccessfully:
                sources.forEach { $0.cancel() }
                sources.removeAll()
                Darwin.exit(EXIT_SUCCESS)
            case .exitFailure:
                sources.forEach { $0.cancel() }
                sources.removeAll()
                Darwin.exit(EXIT_FAILURE)
            }
        }
    }
}
