import Foundation

/// Talks to `AIPanelWorker`, the copy of the network client embedded in the app. If that process exits, this
/// one reports it and returns. Document edits stay here so they can be undone.
enum AIPanelProcess {
    struct Launch: Sendable {
        var output: Data? = nil
        var fault: String? = nil
        var spawnFailed = false
        var cancelled = false
    }

    static func workerURL() -> URL? {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "AIPanelWorker"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    static func complete(endpoint: String, model: String, apiKey: String, turns: [AITurn], tools: [AIToolSpec], workers: AIPanelWorkerHandle = .shared) async throws -> AICompletion {
        let fallback = OpenAICompatibleProvider(endpoint: endpoint, model: model, apiKey: apiKey)
        guard let worker = workerURL() else { return try await fallback.complete(turns, tools: tools) }
        let request = AIPanelWireRequest(kind: "complete", endpoint: endpoint, model: model, apiKey: apiKey, turns: turns, tools: tools)
        let launch = await launch(executable: worker, request: try JSONEncoder().encode(request), timeout: OpenAICompatibleProvider.replyTimeout + 30, workers: workers)
        if launch.cancelled { throw CancellationError() }
        if let output = launch.output { return try completion(from: output) }
        if launch.spawnFailed { return try await fallback.complete(turns, tools: tools) }
        throw AIProviderError.status(-1, launch.fault ?? "The assistant stopped. The editor was not affected.")
    }

    static func ping(endpoint: String) async -> AIConnectivity.Report {
        guard let worker = workerURL() else { return await AIConnectivity.check(endpoint: endpoint) }
        let request = AIPanelWireRequest(kind: "ping", endpoint: endpoint)
        guard let data = try? JSONEncoder().encode(request) else {
            return AIConnectivity.Report(reachable: false, detail: "The connection check could not start. The editor is unaffected.")
        }
        let launch = await launch(executable: worker, request: data, timeout: 12)
        if launch.cancelled {
            return AIConnectivity.Report(reachable: false, detail: "The connection check was stopped. The editor is unaffected.")
        }
        if let output = launch.output, let report = report(from: output) { return report }
        if launch.spawnFailed { return await AIConnectivity.check(endpoint: endpoint) }
        return AIConnectivity.Report(reachable: false, detail: launch.fault ?? "The connection check stopped. The editor was not affected.")
    }

    /// Runs `executable` off the main thread. A non-zero exit, including a crash, becomes `fault` and does not escape.
    static func launch(executable: URL, request: Data, timeout: TimeInterval, workers: AIPanelWorkerHandle = .shared) async -> Launch {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardError = Pipe()
            process.standardOutput = output
            do {
                try process.run()
            } catch {
                return Launch(fault: "The assistant could not be started (\(error.localizedDescription)). The editor was not affected.", spawnFailed: true)
            }
            workers.track(process)
            defer { workers.forget(process) }
            do {
                try input.fileHandleForWriting.write(contentsOf: request)
                try input.fileHandleForWriting.close()
            } catch {
                process.terminate()
                return Launch(fault: "The assistant stopped. The editor was not affected.")
            }
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
            if timedOut {
                process.terminate()
                _ = finished.wait(timeout: .now() + 2)
                return Launch(fault: "The assistant timed out. The editor was not affected.")
            }
            if Task.isCancelled {
                return Launch(cancelled: true)
            }
            let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
            guard process.terminationStatus == 0, !data.isEmpty else {
                return Launch(fault: "The assistant stopped (exit \(process.terminationStatus)). The editor was not affected.")
            }
            return Launch(output: data)
        }.value
    }

    private static func completion(from data: Data) throws -> AICompletion {
        let response = try JSONDecoder().decode(AIPanelWireResponse.self, from: data)
        guard response.ok else {
            throw AIProviderError.status(-1, response.error ?? "The request failed. The editor was not affected.")
        }
        return AICompletion(text: response.text, toolCalls: response.toolCalls ?? [])
    }

    private static func report(from data: Data) -> AIConnectivity.Report? {
        guard let response = try? JSONDecoder().decode(AIPanelWireResponse.self, from: data) else { return nil }
        if !response.ok {
            let message = response.error ?? "Not reachable."
            return AIConnectivity.Report(reachable: false, detail: message.contains("unaffected") ? message : message + " The editor is unaffected.")
        }
        return AIConnectivity.Report(reachable: response.reachable ?? false, detail: response.detail ?? "Not reachable. The editor is unaffected.")
    }
}

/// The chat provider the panel uses. Tests pass their own provider and never come through here.
struct AIIsolatedProvider: AIProvider {
    var endpoint: String
    var model: String
    var apiKey: String

    var workers = AIPanelWorkerHandle.shared

    func complete(_ turns: [AITurn], tools: [AIToolSpec]) async throws -> AICompletion {
        try await AIPanelProcess.complete(endpoint: endpoint, model: model, apiKey: apiKey, turns: turns, tools: tools, workers: workers)
    }
}

/// Processes the panel has spawned, so Stop can end them without touching the editor.
final class AIPanelWorkerHandle: @unchecked Sendable {
    static let shared = AIPanelWorkerHandle()
    private let lock = NSLock()
    private var processes: [Process] = []

    func track(_ process: Process) {
        lock.lock()
        processes.append(process)
        lock.unlock()
    }

    func forget(_ process: Process) {
        lock.lock()
        processes.removeAll { $0 === process }
        lock.unlock()
    }

    /// Ends the processes this handle is tracking. Another handle's processes keep running.
    func stopAll() {
        lock.lock()
        let running = processes
        processes.removeAll()
        lock.unlock()
        for process in running where process.isRunning { process.terminate() }
    }
}
