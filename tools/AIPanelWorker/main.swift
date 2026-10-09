import Foundation

/// Network and response parsing for the assistant. This executable is spawned by the editor and is the one
/// that exits if a response blows up. The editor reads the exit status and keeps running.
@main
struct AIPanelWorkerMain {
    static func main() async {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let response: AIPanelWireResponse
        do {
            let request = try JSONDecoder().decode(AIPanelWireRequest.self, from: input)
            response = await handle(request)
        } catch {
            response = AIPanelWireResponse(ok: false, error: "The request could not be read. The editor is unaffected.")
        }
        guard let output = try? JSONEncoder().encode(response) else { exit(1) }
        FileHandle.standardOutput.write(output)
        exit(0)
    }

    private static func handle(_ request: AIPanelWireRequest) async -> AIPanelWireResponse {
        switch request.kind {
        case "ping":
            let report = await AIConnectivity.check(endpoint: request.endpoint)
            return AIPanelWireResponse(ok: true, reachable: report.reachable, detail: report.detail)
        case "complete":
            do {
                let provider = OpenAICompatibleProvider(endpoint: request.endpoint, model: request.model ?? "", apiKey: request.apiKey ?? "")
                let completion = try await provider.complete(request.turns ?? [], tools: request.tools ?? [])
                return AIPanelWireResponse(ok: true, text: completion.text, toolCalls: completion.toolCalls)
            } catch {
                return AIPanelWireResponse(ok: false, error: error.localizedDescription)
            }
        case "crash":
            // Reached only by the isolation test. A real request never asks for this.
            fatalError("assistant helper crash test")
        default:
            return AIPanelWireResponse(ok: false, error: "Unknown request. The editor is unaffected.")
        }
    }
}
