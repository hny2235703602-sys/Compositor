import AppKit
import ImageIO
import Testing
@testable import Compositor

@MainActor
struct AIToolTests {
    @Test func opacityOfSixtyIsOneUndo() async throws {
        let session = try makeSession()
        let steps = session.history.undoCount
        let reply = await AIToolRegistry.perform(AIToolCall(id: "1", name: "set_layer_opacity", arguments: #"{"percent":60}"#), on: session)
        #expect(reply.text.contains("60%"))
        #expect(session.activeLayer?.opacity == 0.6)
        #expect(session.history.undoCount == steps + 1)
        #expect(session.history.undoName == "Layer Opacity")
        session.undo()
        #expect(session.activeLayer?.opacity == 1)
        #expect(session.history.undoCount == steps)
    }

    @Test func fractionSixtyIsTheSameChange() async throws {
        let session = try makeSession()
        _ = await AIToolRegistry.perform(AIToolCall(id: "1", name: "set_layer_opacity", arguments: #"{"opacity":0.6}"#), on: session)
        #expect(session.activeLayer?.opacity == 0.6)
        session.undo()
        #expect(session.activeLayer?.opacity == 1)
    }

    @Test func paletteToolsSwitchTheToolWithoutAnUndoStep() async throws {
        let session = try makeSession()
        let steps = session.history.undoCount
        let names = AIToolRegistry.specs(for: session).map(\.name)
        let commands = CommandPaletteEntry.layerCommands(for: session) + CommandPaletteEntry.tools(for: session)
        let added = ["set_layer_opacity", "use_curves", "use_color_balance", "use_hue_saturation", "use_exposure", "use_levels", "use_camera_raw", "render_preview", "load_project", "save_project"]
        #expect(names.contains("tool_brush"))
        #expect(names.contains("layer_add_layer_mask"))
        #expect(added.allSatisfy(names.contains))
        #expect(Set(names).count == names.count)
        #expect(names.count == commands.count + added.count)
        #expect(names.allSatisfy { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } })
        let reply = await AIToolRegistry.perform(AIToolCall(id: "2", name: "tool_brush", arguments: "{}"), on: session)
        #expect(reply.text.contains("Ran"))
        #expect(!reply.changedDocument)
        #expect(session.tool == .brush)
        #expect(session.brushMode == .paint)
        #expect(session.history.undoCount == steps)
    }

    @Test func hueBandsShiftRedsAndYellowsSeparately() async throws {
        let session = try graySession()
        let arguments = #"{"bands":{"Reds":{"hue":24,"saturation":20},"Yellows":{"hue":-12,"saturation":15},"Greens":{"saturation":-100},"Cyans":{"saturation":-100},"Blues":{"saturation":-100},"Magentas":{"saturation":-100}}}"#
        let reply = await AIToolRegistry.perform(AIToolCall(id: "h", name: "use_hue_saturation", arguments: arguments), on: session)
        #expect(reply.changedDocument)
        let settings = try #require(session.activeLayer?.adjustment?.resolvedHSV)
        #expect(settings.adjustments[.master] == nil)
        #expect(settings.adjustments[.reds]?.hue == 24)
        #expect(settings.adjustments[.yellows]?.hue == -12)
        #expect(settings.adjustments[.greens]?.saturation == -100)
        #expect(abs(ColorRange.reds.defaultBand.weight(of: 30) - 0.5) < 0.001)
        #expect(abs(ColorRange.yellows.defaultBand.weight(of: 30) - 0.5) < 0.001)
        let alias = await AIToolRegistry.perform(AIToolCall(id: "o", name: "use_hue_saturation", arguments: #"{"bands":{"orange":{"hue":20}}}"#), on: session)
        #expect(!alias.changedDocument)
    }

    @Test func cameraRawLookIsOneUndo() async throws {
        let session = try graySession()
        let before = try sample(session)
        let steps = session.history.undoCount
        let reply = await AIToolRegistry.perform(AIToolCall(id: "r", name: "use_camera_raw",
            arguments: #"{"exposure":0.4,"dehaze":18,"clarity":12,"contrast":12,"shadows":18,"blacks":-10,"vibrance":10}"#), on: session)
        #expect(reply.changedDocument)
        #expect(session.filterEdit == nil)
        #expect(session.history.undoCount == steps + 1)
        #expect(session.history.undoName == "Camera Raw Filter")
        let after = try sample(session)
        #expect(after.red != before.red)
        session.undo()
        let restored = try sample(session)
        #expect(restored.red == before.red && restored.blue == before.blue)
        #expect(session.history.undoCount == steps)
        let refused = await AIToolRegistry.perform(AIToolCall(id: "z", name: "use_camera_raw", arguments: "{}"), on: session)
        #expect(!refused.changedDocument)
        #expect(session.filterEdit == nil)
        #expect(session.history.undoCount == steps)
    }

    @Test func unknownCommandsDoNotTouchTheDocument() async throws {
        let session = try makeSession()
        let steps = session.history.undoCount
        let opacity = try #require(session.activeLayer?.opacity)
        for name in ["shell", "swift", "eval", "setOpacity"] {
            let reply = await AIToolRegistry.perform(AIToolCall(id: name, name: name, arguments: #"{"percent":60}"#), on: session)
            #expect(reply.text.contains("Unknown"))
            #expect(!reply.changedDocument)
        }
        #expect(session.activeLayer?.opacity == opacity)
        #expect(session.history.undoCount == steps)
        #expect(session.tool == .move)
    }

    @Test func opacityOutsideTheRangeIsRefused() async throws {
        let session = try makeSession()
        let reply = await AIToolRegistry.perform(AIToolCall(id: "1", name: "set_layer_opacity", arguments: #"{"percent":160}"#), on: session)
        #expect(reply.text.contains("not changed"))
        #expect(session.activeLayer?.opacity == 1)
        #expect(AIToolRegistry.opacityValue(from: 60) == 0.6)
        #expect(AIToolRegistry.opacityValue(from: 0.6) == 0.6)
        #expect(AIToolRegistry.opacityValue(from: 160) == nil)
        #expect(AIToolRegistry.functionName("Tool › Move / Transform") == "tool_move_transform")
    }

    @Test func coolerGradeIsOneUndoAndThePreviewFits() async throws {
        let session = try graySession()
        let before = try sample(session)
        let steps = session.history.undoCount
        let reply = await AIToolRegistry.perform(AIToolCall(id: "t", name: "use_color_balance", arguments: #"{"midCyanRed":-40,"midYellowBlue":40}"#), on: session)
        #expect(reply.changedDocument)
        #expect(session.history.undoCount == steps + 1)
        #expect(session.history.undoName == "New Color Balance Adjustment")
        #expect(session.activeLayer?.adjustment?.colorBalance.midCyanRed == -40)
        #expect(session.activeLayer?.adjustment?.colorBalance.midYellowBlue == 40)
        session.activeLayerID = session.document?.layers.first { $0.name == "Gray" }?.id
        let cooled = try sample(session)
        #expect(cooled.red == before.red && cooled.blue == before.blue)
        let preview = try #require(await AIToolRegistry.renderedPreview(of: session))
        #expect(try longSide(preview) <= 1024)
        session.undo()
        let restored = try sample(session)
        #expect(restored.red == before.red && restored.blue == before.blue)
    }

    @Test func darkAndBlackGoldLooksAreOneUndo() async throws {
        #expect(AILookNotes.index.contains("通透"))
        #expect(AILookNotes.index.contains("黑金"))
        #expect(AILookNotes.index.contains("胶片"))
        #expect(AILookNotes.matches(in: "把图片变通透").first?.id == "clear")
        #expect(AILookNotes.matches(in: "做成黑金色调").first?.id == "black_gold")
        #expect(AILookNotes.matches(in: "加点胶片颗粒").first?.id == "grain")
        #expect(AILookNotes.look(named: "不通透")?.undoName == "Clear")
        #expect(AILookNotes.look(named: "黑金色调")?.undoName == "Black and Gold")
        #expect(AILookNotes.look(named: "暗色调")?.undoName == "Dark Tone")
        #expect(AILookNotes.look(named: "sharper") == nil)

        let session = try graySession()
        let before = try sample(session)
        let steps = session.history.undoCount
        let reply = await AIToolRegistry.perform(AIToolCall(id: "g", name: "use_exposure", arguments: #"{"exposure":-0.45}"#), on: session)
        #expect(reply.changedDocument)
        #expect(reply.text.contains("adjustment") || reply.text.contains("调整"))
        #expect(session.history.undoCount == steps + 1)
        #expect(session.history.undoName == "New Exposure Adjustment")
        #expect(session.activeLayer?.adjustment?.kind == .exposure)
        #expect(session.activeLayer?.adjustment?.exposure.exposure == -0.45)
        session.activeLayerID = session.document?.layers.first { $0.name == "Gray" }?.id
        let kept = try sample(session)
        #expect(kept.red == before.red)
        session.undo()
        let restored = try sample(session)
        #expect(restored.red == before.red)
        #expect(session.document?.layers.contains { $0.adjustment != nil } == false)

        let refused = await AIToolRegistry.perform(AIToolCall(id: "n", name: "use_curves", arguments: #"{"points":[{"x":1,"y":1}]}"#), on: session)
        #expect(refused.text.contains("not changed"))
        #expect(session.history.undoCount == steps)

        let curved = await AIToolRegistry.perform(AIToolCall(id: "c", name: "use_curves", arguments: #"{"points":[{"x":0,"y":0},{"x":0.3,"y":0.08},{"x":1,"y":1}]}"#), on: session)
        #expect(curved.changedDocument)
        #expect(session.activeLayer?.adjustment?.kind == .curves)
        let points = session.activeLayer?.adjustment?.curves.channels[0] ?? []
        #expect(points.contains { abs($0.x - 76.5) < 0.01 && abs($0.y - 20.4) < 0.01 })
    }

    @Test func aCatalogPhraseShowsThePictureAndTheRecipe() async throws {
        let cool = try #require(AILookNotes.look(named: "冷色调"))
        #expect(AILookNotes.recipe(of: cool) == "temperature -30")
        let session = try graySession()
        let before = try sample(session)
        let provider = ScriptedGrade()
        let model = AIPanelModel()
        await model.run(question: "调成冷色调", session: session, provider: provider)
        #expect(provider.sawImage)
        #expect(provider.sawRecipe)
        #expect(model.error == nil)
        #expect(model.changes.count == 1)
        #expect(model.messages.contains { $0.text.contains("理解") })
        #expect(model.messages.contains { $0.text.contains("审阅") })
        #expect(model.status != nil)
        #expect(model.isSending == false)
        #expect(session.document?.layers.contains { $0.adjustment?.kind == .colorBalance && $0.adjustment?.colorBalance.midCyanRed == -50 } == true)
        session.activeLayerID = session.document?.layers.first { $0.name == "Gray" }?.id
        let kept = try sample(session)
        #expect(kept.red == before.red && kept.blue == before.blue)

        model.messages.insert(AIChatMessage(role: .user, text: "调成冷色调"), at: 0)
        let correction = ScriptedGrade(arguments: #"{"midMagentaGreen":-30}"#, reply: "审阅：按画面把绿色往品红拉了。")
        await model.run(question: "还是偏绿", session: session, provider: correction)
        #expect(correction.sawImage)
        #expect(correction.sawCorrection)
        #expect(model.changes.count == 2)

        let asking = AIPanelModel()
        await asking.run(question: "什么是通透？", session: session, provider: FailingProvider())
        #expect(asking.error?.contains("offline") == true)
        #expect(asking.changes.isEmpty)
    }

    @Test func saveAndLoadKeepFormatVersionEleven() async throws {
        let session = try graySession()
        let url = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Caches/compositor-ai-tool-test.comp")
        defer { try? FileManager.default.removeItem(at: url) }
        let saved = await AIToolRegistry.perform(AIToolCall(id: "s", name: "save_project", arguments: #"{"path":"\#(url.path)"}"#), on: session)
        #expect(saved.text.contains("format version \(ProjectManifest.current)"))
        #expect(ProjectManifest.current == 11)
        let snapshot = try await ProjectStore.shared.load(from: url)
        #expect(snapshot.manifest.version == 11)
        #expect(snapshot.manifest.width == 8 && snapshot.manifest.height == 8)
        let opened = EditorSession()
        let loaded = await AIToolRegistry.perform(AIToolCall(id: "l", name: "load_project", arguments: #"{"path":"\#(url.path)"}"#), on: opened)
        #expect(loaded.wantsPreview)
        #expect(opened.document?.width == 8 && opened.document?.height == 8)
        #expect(opened.projectURL?.lastPathComponent == url.lastPathComponent)
        #expect(opened.projectURL?.path.hasPrefix(NSHomeDirectory() + "/") == true)
        let outside = await AIToolRegistry.perform(AIToolCall(id: "x", name: "save_project", arguments: #"{"path":"/tmp/nope.comp"}"#), on: session)
        #expect(outside.text.contains("home directory"))
    }

    @Test func coolerRequestRendersAndContinuesUntilTheModelStops() async throws {
        let session = try graySession()
        let before = try sample(session)
        let provider = ScriptedCooling()
        let model = AIPanelModel()
        await model.run(question: "Cool the whole picture", session: session, provider: provider)
        #expect(provider.sawPreview)
        #expect(provider.adjustments == 2)
        #expect(model.messages.last?.text == "Cool enough.")
        #expect(model.changes.count == 2)
        #expect(model.changes.allSatisfy { $0.summary.contains("adjustment") || $0.summary.contains("调整") })
        #expect(session.document?.layers.filter { $0.adjustment?.kind == .colorBalance }.count == 2)
        session.undo()
        session.undo()
        session.activeLayerID = session.document?.layers.first { $0.name == "Gray" }?.id
        let restored = try sample(session)
        #expect(restored.red == before.red && restored.blue == before.blue)
        #expect(session.document?.layers.contains { $0.adjustment != nil } == false)
    }

    @Test func aToolSwitchIsNotListedAsAChange() async throws {
        let session = try makeSession()
        let model = AIPanelModel()
        await model.run(question: "use the brush", session: session, provider: ScriptedTool(name: "tool_brush"))
        #expect(model.changes.isEmpty)
        #expect(session.tool == .brush)
        #expect(model.messages.last?.text == "Done.")
    }

    @Test func aFailedRequestLeavesTheDocumentEditable() async throws {
        let session = try makeSession()
        let model = AIPanelModel()
        await model.run(question: "cool it", session: session, provider: FailingProvider())
        #expect(model.error?.contains("offline") == true)
        #expect(model.changes.isEmpty)
        let reply = await AIToolRegistry.perform(AIToolCall(id: "1", name: "set_layer_opacity", arguments: #"{"percent":60}"#), on: session)
        #expect(reply.changedDocument)
        #expect(session.activeLayer?.opacity == 0.6)
    }

    @Test func aBadEndpointStaysInTheCheck() async {
        let missing = await AIConnectivity.check(endpoint: "not a url")
        #expect(!missing.reachable)
        #expect(missing.detail.contains("unaffected"))
        let file = await AIConnectivity.check(endpoint: "file:///etc/passwd")
        #expect(!file.reachable)
        let refused = await AIConnectivity.check(endpoint: "http://127.0.0.1:9")
        #expect(!refused.reachable)
        #expect(refused.detail.contains("unaffected"))
    }

    @Test func aDeadHelperDoesNotEscape() async {
        let launch = await AIPanelProcess.launch(executable: URL(fileURLWithPath: "/usr/bin/false"), request: Data(), timeout: 5)
        #expect(launch.output == nil)
        #expect(launch.fault?.contains("not affected") == true)
    }

    private func makeSession() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 80, height: 40, emptyLayer: true)
        _ = try #require(session.activeLayer)
        return session
    }

    private func graySession() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 8, height: 8)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray"))
        return session
    }

    private func sample(_ session: EditorSession) throws -> (red: Int, blue: Int) {
        let image = try #require(session.activeLayer?.asset?.image)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (Int(bytes[0]), Int(bytes[2]))
    }

    private func longSide(_ data: Data) throws -> Int {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return max(image.width, image.height)
    }
}

private final class ScriptedTool: AIProvider, @unchecked Sendable {
    var name: String
    private var calls = 0
    init(name: String) { self.name = name }
    func complete(_ turns: [AITurn], tools: [AIToolSpec]) async throws -> AICompletion {
        if tools.isEmpty { return AICompletion(text: "Switch to the brush.", toolCalls: []) }
        if calls == 0 {
            calls = 1
            return AICompletion(text: nil, toolCalls: [AIToolCall(id: "1", name: name, arguments: "{}")])
        }
        return AICompletion(text: "Done.", toolCalls: [])
    }
}

private final class FailingProvider: AIProvider, @unchecked Sendable {
    func complete(_ turns: [AITurn], tools: [AIToolSpec]) async throws -> AICompletion {
        throw AIProviderError.status(-1, "offline")
    }
}

/// Looks at the picture and the catalog recipe, then grades with its own numbers.
private final class ScriptedGrade: AIProvider, @unchecked Sendable {
    var sawImage = false
    var sawRecipe = false
    var sawCorrection = false
    private var calls = 0
    private let arguments: String
    private let reply: String
    init(arguments: String = #"{"midCyanRed":-50,"midYellowBlue":50}"#, reply: String = "审阅：色彩平衡已经按这张图把中间调推向青和蓝。") {
        self.arguments = arguments
        self.reply = reply
    }
    func complete(_ turns: [AITurn], tools: [AIToolSpec]) async throws -> AICompletion {
        if turns.contains(where: { !$0.images.isEmpty }) { sawImage = true }
        if turns.contains(where: { $0.text.contains("temperature -30") && $0.text.contains("Color Balance") }) { sawRecipe = true }
        if turns.contains(where: { $0.text.contains("correcting that result") }) { sawCorrection = true }
        if tools.isEmpty {
            return AICompletion(text: "理解：要冷色调。方案：用色彩平衡把中间调推向青和蓝。", toolCalls: [])
        }
        if calls == 0 {
            calls = 1
            return AICompletion(text: nil, toolCalls: [AIToolCall(id: "g", name: "use_color_balance", arguments: arguments)])
        }
        return AICompletion(text: reply, toolCalls: [])
    }
}

/// First cools, and only cools again after a render comes back, then stops.
private final class ScriptedCooling: AIProvider, @unchecked Sendable {
    var sawPreview = false
    var adjustments = 0
    func complete(_ turns: [AITurn], tools: [AIToolSpec]) async throws -> AICompletion {
        if turns.contains(where: { !$0.images.isEmpty }) { sawPreview = true }
        if tools.isEmpty { return AICompletion(text: "Cool the picture with Color Balance.", toolCalls: []) }
        if adjustments == 0 {
            adjustments = 1
            return AICompletion(text: nil, toolCalls: [AIToolCall(id: "c1", name: "use_color_balance", arguments: #"{"midCyanRed":-40,"midYellowBlue":40}"#)])
        }
        if adjustments == 1 {
            guard sawPreview else { return AICompletion(text: "missing render", toolCalls: []) }
            adjustments = 2
            return AICompletion(text: nil, toolCalls: [AIToolCall(id: "c2", name: "use_color_balance", arguments: #"{"midCyanRed":-20,"midYellowBlue":20}"#)])
        }
        return AICompletion(text: "Cool enough.", toolCalls: [])
    }
}
