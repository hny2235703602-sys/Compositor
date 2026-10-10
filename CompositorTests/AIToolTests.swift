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
        let added = ["set_layer_opacity", "set_layer_blend_mode", "use_curves", "use_color_balance", "use_hue_saturation", "use_exposure", "use_levels", "use_gradient_map", "use_camera_raw", "render_preview", "load_project", "save_project"]
        #expect(names.contains("tool_brush"))
        #expect(names.contains("layer_add_layer_mask"))
        #expect(added.allSatisfy(names.contains))
        #expect(Set(names).count == names.count)
        #expect(names.count == commands.count + added.count)
        #expect(names.allSatisfy { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } })
        let reply = await AIToolRegistry.perform(AIToolCall(id: "2", name: "tool_brush", arguments: "{}"), on: session)
        #expect(reply.text == String(format: String(localized: "Ran %@. The document was unchanged."), "Tool › Brush"))
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

    @Test func cameraRawWithoutAnActiveLayerDoesNotStart() async throws {
        let session = try makeSession()
        session.activeLayerID = nil
        let steps = session.history.undoCount
        let reply = await AIToolRegistry.perform(AIToolCall(id: "r", name: "use_camera_raw", arguments: #"{"exposure":0.4}"#), on: session)
        #expect(reply.changedDocument == false)
        #expect(session.filterEdit == nil)
        #expect(session.history.undoCount == steps)
    }

    @Test func cameraRawRefusesWhileAnotherFilterIsOpen() async throws {
        let session = try graySession()
        session.beginFilter(.gaussianBlur)
        let open = try #require(session.filterEdit)
        #expect(open.kind == .gaussianBlur)
        let steps = session.history.undoCount
        let reply = await AIToolRegistry.perform(AIToolCall(id: "r", name: "use_camera_raw", arguments: #"{"exposure":0.4}"#), on: session)
        #expect(reply.changedDocument == false)
        #expect(session.filterEdit?.kind == .gaussianBlur)
        #expect(session.history.undoCount == steps)
    }

    @Test func cameraRawExposureIsOneUndo() async throws {
        let session = try graySession()
        let steps = session.history.undoCount
        let reply = await AIToolRegistry.perform(AIToolCall(id: "r", name: "use_camera_raw", arguments: #"{"exposure":0.4}"#), on: session)
        #expect(!reply.text.isEmpty)
        #expect(reply.changedDocument)
        #expect(session.filterEdit == nil)
        #expect(session.history.undoCount == steps + 1)
    }

    @Test func unknownCommandsDoNotTouchTheDocument() async throws {
        let session = try makeSession()
        let steps = session.history.undoCount
        let opacity = try #require(session.activeLayer?.opacity)
        for name in ["shell", "swift", "eval", "setOpacity"] {
            let reply = await AIToolRegistry.perform(AIToolCall(id: name, name: name, arguments: #"{"percent":60}"#), on: session)
            #expect(reply.text == String(format: String(localized: "Unknown tool %@. Only listed commands can run, and the document was not changed."), name))
            #expect(!reply.changedDocument)
        }
        #expect(session.activeLayer?.opacity == opacity)
        #expect(session.history.undoCount == steps)
        #expect(session.tool == .move)
    }

    @Test func opacityOutsideTheRangeIsRefused() async throws {
        let session = try makeSession()
        let reply = await AIToolRegistry.perform(AIToolCall(id: "1", name: "set_layer_opacity", arguments: #"{"percent":160}"#), on: session)
        #expect(reply.text == String(localized: "set_layer_opacity needs percent from 0 to 100. The document was not changed."))
        #expect(session.activeLayer?.opacity == 1)
        #expect(AIToolRegistry.opacityValue(from: 60) == 0.6)
        #expect(AIToolRegistry.opacityValue(from: 0.6) == 0.6)
        #expect(AIToolRegistry.opacityValue(from: 160) == nil)
        #expect(AIToolRegistry.functionName("Tool › Move / Transform") == "tool_move_transform")
    }

    @Test func blendModeUsesTheLayerNamesAndIsOneUndo() async throws {
        #expect(LayerBlendMode.allCases.count == 24)
        #expect(LayerBlendMode.allCases.allSatisfy { AIToolRegistry.blendMode(named: $0.rawValue) == $0 })
        #expect(AIToolRegistry.blendMode(named: "soft light") == .softLight)
        #expect(AIToolRegistry.blendMode(named: "Linear Dodge (Add)") == .linearDodge)
        #expect(AIToolRegistry.blendMode(named: "softLight") == nil)
        #expect(AIToolRegistry.blendMode(named: "滤色") == nil)

        let session = try makeSession()
        let steps = session.history.undoCount
        let reply = await AIToolRegistry.perform(AIToolCall(id: "1", name: "set_layer_blend_mode", arguments: #"{"blendMode":"Screen","opacity":40}"#), on: session)
        #expect(reply.changedDocument)
        #expect(reply.text.contains("Screen"))
        #expect(reply.text.contains("40%"))
        #expect(session.activeLayer?.blendMode == .screen)
        #expect(session.activeLayer?.opacity == 0.4)
        #expect(session.history.undoCount == steps + 1)
        #expect(session.history.undoName == "Layer Blend Mode")
        session.undo()
        #expect(session.activeLayer?.blendMode == .normal)
        #expect(session.activeLayer?.opacity == 1)
        #expect(session.history.undoCount == steps)

        let refused = await AIToolRegistry.perform(AIToolCall(id: "2", name: "set_layer_blend_mode", arguments: #"{"blendMode":"Glow"}"#), on: session)
        #expect(!refused.changedDocument)
        #expect(session.activeLayer?.blendMode == .normal)
        #expect(session.history.undoCount == steps)
    }

    @Test func gradientMapThenLuminosityAreTwoUndos() async throws {
        let session = try makeSession()
        let steps = session.history.undoCount
        let added = await AIToolRegistry.perform(AIToolCall(id: "1", name: "use_gradient_map", arguments: "{}"), on: session)
        #expect(added.changedDocument)
        let map = try #require(session.activeLayer?.adjustment)
        #expect(map.kind == .gradientMap)
        #expect(map.gradientMap.shadows == AdjustmentColor(red: 0, green: 0, blue: 0))
        #expect(map.gradientMap.highlights == AdjustmentColor(red: 1, green: 1, blue: 1))
        #expect(!map.gradientMap.reversed)
        #expect(session.history.undoCount == steps + 1)
        #expect(session.history.undoName == "New Gradient Map Adjustment")

        let blend = await AIToolRegistry.perform(AIToolCall(id: "2", name: "set_layer_blend_mode", arguments: #"{"blendMode":"Luminosity"}"#), on: session)
        #expect(blend.changedDocument)
        #expect(session.activeLayer?.blendMode == .luminosity)
        #expect(session.history.undoCount == steps + 2)
        session.undo()
        #expect(session.activeLayer?.adjustment?.kind == .gradientMap)
        #expect(session.activeLayer?.blendMode == .normal)
        session.undo()
        #expect(session.document?.layers.contains { $0.adjustment != nil } == false)
        #expect(session.history.undoCount == steps)

        let colored = await AIToolRegistry.perform(AIToolCall(id: "3", name: "use_gradient_map", arguments: #"{"shadows":{"red":0,"green":0,"blue":255},"highlights":{"red":1,"green":1,"blue":1},"reversed":true}"#), on: session)
        #expect(colored.changedDocument)
        #expect(session.activeLayer?.adjustment?.gradientMap.shadows == AdjustmentColor(red: 0, green: 0, blue: 1))
        #expect(session.activeLayer?.adjustment?.gradientMap.reversed == true)
        let bad = await AIToolRegistry.perform(AIToolCall(id: "4", name: "use_gradient_map", arguments: #"{"highlights":{"red":300}}"#), on: session)
        #expect(!bad.changedDocument)
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
        #expect(AILookNotes.directMatch(in: "照片发闷") == nil)
        #expect(!AILookNotes.index.contains("发闷"))
        let dull = AIKnowledge.note(for: "照片发闷")
        #expect(dull.contains("230"))
        #expect(dull.contains("use_levels"))
        #expect(dull.contains("Do not raise vibrance"))
        #expect(AIKnowledge.note(for: "什么是发闷？") == "")
        #expect(AIKnowledge.matches(in: "这张高调刺眼").first?.phrase == "高调刺眼")
        #expect(AIKnowledge.matches(in: "远景发灰").map(\.id) == ["distant_haze"])

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
        #expect(refused.text == String(localized: "use_curves needs an RGB curve that is not a straight line. The document was not changed."))
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("compositor-ai-tool-test-\(UUID().uuidString).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        let saved = await AIToolRegistry.perform(AIToolCall(id: "s", name: "save_project", arguments: #"{"path":"\#(url.path)"}"#), on: session)
        #expect(saved.text == String(format: String(localized: "Saved %@, format version %lld."), url.lastPathComponent, Int64(ProjectManifest.current)))
        #expect(ProjectManifest.current == 11)
        let snapshot = try await ProjectStore.shared.load(from: url)
        #expect(snapshot.manifest.version == 11)
        #expect(snapshot.manifest.width == 8 && snapshot.manifest.height == 8)
        let opened = EditorSession()
        let loaded = await AIToolRegistry.perform(AIToolCall(id: "l", name: "load_project", arguments: #"{"path":"\#(url.path)"}"#), on: opened, controller: ProjectController(session: opened))
        #expect(loaded.wantsPreview)
        #expect(opened.document?.width == 8 && opened.document?.height == 8)
        #expect(opened.projectURL?.standardizedFileURL.path == url.standardizedFileURL.path)
        let outside = await AIToolRegistry.perform(AIToolCall(id: "x", name: "save_project", arguments: #"{"path":"/tmp/nope.comp"}"#), on: session)
        #expect(outside.text == String(localized: "save_project needs the open project, or a .comp path under the home directory. Nothing was written."))
    }

    @Test func loadProjectCancelLeavesTheUnsavedDocument() async throws {
        let session = try makeSession()
        let original = FileManager.default.temporaryDirectory.appendingPathComponent("compositor-ai-load-original-\(UUID().uuidString).comp")
        session.projectURL = original
        let documentID = try #require(session.document).id
        session.setLayerOpacity(0.4)
        let undo = session.history.undoCount
        #expect(session.isModified && undo > 0)
        let incoming = try toneSession(level: 20)
        let url = try await writeProject(incoming, name: "compositor-ai-load-cancel.comp")
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = ProjectController(session: session)
        controller.unsavedChangesReply = { .alertSecondButtonReturn }
        let outcome = await AIToolRegistry.perform(AIToolCall(id: "l", name: "load_project", arguments: #"{"path":"\#(url.path)"}"#), on: session, controller: controller)
        #expect(outcome.changedDocument == false)
        #expect(outcome.listInSession == false)
        #expect(outcome.text == String(localized: "Opening was cancelled. The document was not changed."))
        #expect(!outcome.text.contains("Undo was cleared"))
        #expect(session.document?.id == documentID)
        #expect(session.projectURL == original)
        #expect(session.history.undoCount == undo)
        #expect(session.activeLayer?.opacity == 0.4)
    }

    @Test func loadProjectDontSaveReplacesTheDocument() async throws {
        let session = try makeSession()
        session.setLayerOpacity(0.4)
        let incoming = try toneSession(level: 20)
        let url = try await writeProject(incoming, name: "compositor-ai-load-replace.comp")
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = ProjectController(session: session)
        controller.unsavedChangesReply = { .alertThirdButtonReturn }
        let outcome = await AIToolRegistry.perform(AIToolCall(id: "l", name: "load_project", arguments: #"{"path":"\#(url.path)"}"#), on: session, controller: controller)
        #expect(outcome.changedDocument == false)
        #expect(outcome.listInSession)
        #expect(outcome.text == String(format: String(localized: "Opened %@, format version %lld. Undo was cleared."), url.lastPathComponent, Int64(ProjectManifest.current)))
        #expect(session.document?.width == 8 && session.document?.height == 8)
        #expect(session.projectURL?.standardizedFileURL.path == url.standardizedFileURL.path)
        #expect(session.history.undoCount == 0)
    }

    @Test func loadProjectReadFailureLeavesTheDocumentByteForByte() async throws {
        let session = try toneSession(level: 180)
        let live = FileManager.default.temporaryDirectory.appendingPathComponent("compositor-ai-load-live-\(UUID().uuidString).comp")
        session.projectURL = live
        session.setLayerOpacity(0.7)
        let documentID = try #require(session.document).id
        let undo = session.history.undoCount
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("compositor-ai-load-corrupt-\(UUID().uuidString).comp")
        try? FileManager.default.removeItem(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a project".utf8).write(to: url)
        let before = try await brightest(session)
        let controller = ProjectController(session: session)
        controller.unsavedChangesReply = { .alertThirdButtonReturn }
        let outcome = await AIToolRegistry.perform(AIToolCall(id: "l", name: "load_project", arguments: #"{"path":"\#(url.path)"}"#), on: session, controller: controller)
        #expect(outcome.changedDocument == false)
        #expect(outcome.text == String(format: String(localized: "Could not open %@ (%@). The document was not changed."), url.lastPathComponent, "This is not a valid Compositor project, or its metadata is damaged."))
        #expect(!outcome.text.contains("Undo was cleared"))
        #expect(session.document?.id == documentID)
        #expect(session.projectURL == live)
        #expect(session.history.undoCount == undo)
        #expect(session.activeLayer?.opacity == 0.7)
        #expect(try await brightest(session) == before)
    }

    @Test func loadProjectWithoutTheControllerRefusesInsteadOfCrashing() async throws {
        let session = try makeSession()
        let url = try await writeProject(session, name: "compositor-ai-load-no-controller.comp")
        defer { try? FileManager.default.removeItem(at: url) }
        session.projectURL = url
        let documentID = try #require(session.document).id
        let layerCount = try #require(session.document).layers.count
        let undo = session.history.undoCount
        let reply = await AIToolRegistry.perform(AIToolCall(id: "l", name: "load_project", arguments: #"{"path":"\#(url.path)"}"#), on: session)
        #expect(reply.text == "load_project needs the project window. The document was not changed.")
        #expect(reply.changedDocument == false && reply.wantsPreview == false && reply.listInSession == false)
        #expect(session.document?.id == documentID)
        #expect(session.document?.layers.count == layerCount)
        #expect(session.history.undoCount == undo)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// save 的 controller 调用全是可选链，load 的却是硬 guard。两者不一致是当前事实，不是设计决定；将来若要统一，这个测试会红，届时是有意改动而不是误改。
    @Test func saveProjectWithoutTheControllerStillWrites() async throws {
        let session = try makeSession()
        session.projectURL = nil
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("compositor-ai-save-no-controller-\(UUID().uuidString).comp")
        defer { try? FileManager.default.removeItem(at: dest) }
        let reply = await AIToolRegistry.perform(AIToolCall(id: "s", name: "save_project", arguments: #"{"path":"\#(dest.path)"}"#), on: session)
        #expect(reply.text.hasPrefix("Saved "))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("manifest.json").path))
        _ = try await ProjectStore.shared.load(from: dest)
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
        #expect(model.messages.contains { $0.role == .error && $0.text.contains("offline") })
        #expect(model.changes.isEmpty)
        let reply = await AIToolRegistry.perform(AIToolCall(id: "1", name: "set_layer_opacity", arguments: #"{"percent":60}"#), on: session)
        #expect(reply.changedDocument)
        #expect(session.activeLayer?.opacity == 0.6)
    }

    /// A model that never stops calling tools hits the round limit. That notice is not replayed as the model's own words.
    @Test func roundLimitNoticeIsNotReplayedAsTheAssistant() async throws {
        let session = try graySession()
        let model = AIPanelModel()
        model.draft = "keep adjusting"
        model.send(session: session, endpoint: "https://example.invalid", modelName: "test", provider: LoopingToolProvider())
        await waitUntilIdle(model)
        #expect(model.isSending == false)
        let notice = String(format: String(localized: "Stopped after %lld rounds."), Int64(AIPanelModel.roundLimit))
        let last = try #require(model.messages.last)
        #expect(last.role == .error)
        #expect(last.role != .assistant)
        #expect(last.text == notice)

        let recorder = RecordingProvider()
        model.draft = "what is the zoom?"
        model.send(session: session, endpoint: "https://example.invalid", modelName: "test", provider: recorder)
        await waitUntilIdle(model)
        #expect(model.isSending == false)
        #expect(recorder.texts.contains(notice) == false)
    }

    @Test func aFailedRequestStaysInTheConversation() async throws {
        let session = try makeSession()
        let model = AIPanelModel()
        await model.run(question: "cool it", session: session, provider: FailingProvider())
        #expect(model.error?.contains("offline") == true)
        #expect(model.messages.contains { $0.role == .error && $0.text.contains("offline") })
        await model.run(question: "调成冷色调", session: session, provider: ScriptedGrade())
        #expect(model.messages.contains { $0.role == .error && $0.text.contains("offline") })
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

    @Test func theOtherDiagnosesNameTheToolTheyMean() {
        let expected: [(String, String, String)] = [
            ("两端没像素", "short_range", "use_levels"),
            ("层次平", "weak_separation", "use_curves"),
            ("反差太大", "excess_contrast", "use_camera_raw"),
            ("做成灰调", "gray_tone", "inverse S"),
            ("颜色发淡", "pale_color", "vibrance raised"),
            ("颜色太艳", "loud_color", "Lower vibrance"),
            ("只改一种颜色", "one_color", "use_hue_saturation"),
        ]
        for (phrase, id, instruction) in expected {
            let note = AIKnowledge.note(for: phrase)
            #expect(AIKnowledge.matches(in: phrase).map(\.id) == [id])
            #expect(note.contains("Diagnosis for 「\(phrase)」"))
            #expect(note.contains(instruction))
        }
        #expect(AIKnowledge.note(for: "两端没像素").contains("outputWhite near 200"))
        #expect(AIKnowledge.note(for: "层次平").contains("255,255"))
        #expect(AIKnowledge.note(for: "反差太大").contains("Do not raise vibrance"))
        #expect(AIKnowledge.note(for: "做成灰调").contains("lower saturation"))
        #expect(AIKnowledge.note(for: "颜色发淡").contains("Do not push saturation"))
        #expect(AIKnowledge.note(for: "颜色太艳").contains("Do not raise saturation"))
        #expect(AIKnowledge.note(for: "只改一种颜色").contains("30 degrees"))
        let mixed = AIKnowledge.note(for: "照片发闷而且颜色发淡")
        #expect(mixed.contains("low_key_dull"))
        #expect(mixed.contains("pale_color"))
        #expect(mixed.contains("low_key_dull outranks the other diagnoses, and any catalog recipe yields"))
        #expect(!AIKnowledge.note(for: "照片发闷").contains("outranks"))
    }

    @Test func dullLevelsLiftsTheBrightestToneToAbout230() async throws {
        let session = try toneSession(level: 200)
        let before = try await brightest(session)
        #expect(before == 200)
        let steps = session.history.undoCount
        let provider = ScriptedDullLevels(white: 200.0 * 255.0 / 230.0)
        let model = AIPanelModel()
        await model.run(question: "照片发闷", session: session, provider: provider)
        #expect(provider.sawDiagnosis)
        #expect(model.error == nil)
        #expect(session.history.undoCount == steps + 1)
        #expect(session.history.undoName == "New Levels Adjustment")
        let after = try await brightest(session)
        #expect((225...235).contains(after))
    }

    @Test func aCancelledSendDoesNotClearTheNextOne() async throws {
        let session = try makeSession()
        let model = AIPanelModel()
        let first = PauseProvider(pause: .seconds(30), reply: "first")
        model.draft = "one"
        model.send(session: session, endpoint: "http://127.0.0.1", modelName: "test", provider: first)
        let started = Date()
        while !first.didStart(), Date().timeIntervalSince(started) < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(first.didStart())
        #expect(model.isSending)
        model.cancel()
        #expect(model.status == String(localized: "Stopped."))
        #expect(model.error == nil)
        #expect(!model.isSending)
        let second = PauseProvider(pause: .milliseconds(200), reply: "second-done")
        model.draft = "two"
        model.send(session: session, endpoint: "http://127.0.0.1", modelName: "test", provider: second)
        #expect(model.isSending)
        let waiting = Date()
        while !second.didStart(), Date().timeIntervalSince(waiting) < 3 {
            #expect(model.isSending)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(second.didStart())
        #expect(model.isSending)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.isSending)
        let deadline = Date().addingTimeInterval(3)
        while model.isSending, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!model.isSending)
        #expect(model.error == nil)
        #expect(model.messages.contains { $0.text == "second-done" })
    }

    @Test func cancellingOnePanelLeavesTheOtherRunning() async throws {
        let session = try makeSession()
        let stopped = AIPanelModel()
        let kept = AIPanelModel()
        let hanging = PauseProvider(pause: .seconds(30), reply: "should-not-finish")
        let finishing = PauseProvider(pause: .milliseconds(150), reply: "from-b")
        stopped.draft = "stop me"
        kept.draft = "keep me"
        stopped.send(session: session, endpoint: "http://127.0.0.1", modelName: "test", provider: hanging)
        kept.send(session: session, endpoint: "http://127.0.0.1", modelName: "test", provider: finishing)
        let started = Date()
        while (!hanging.didStart() || !finishing.didStart()), Date().timeIntervalSince(started) < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(hanging.didStart() && finishing.didStart())
        stopped.cancel()
        #expect(stopped.status == String(localized: "Stopped."))
        #expect(stopped.error == nil)
        #expect(kept.isSending)
        let deadline = Date().addingTimeInterval(3)
        while kept.isSending, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!kept.isSending)
        #expect(kept.error == nil)
        #expect(kept.status == String(localized: "Finished."))
        #expect(kept.messages.contains { $0.text == "from-b" })
        #expect(!stopped.messages.contains { $0.text == "should-not-finish" })
    }

    @Test func aDeadHelperDoesNotEscape() async {
        let launch = await AIPanelProcess.launch(executable: URL(fileURLWithPath: "/usr/bin/false"), request: Data(), timeout: 5)
        #expect(launch.output == nil)
        #expect(launch.fault?.contains("not affected") == true)
    }

    private func writeProject(_ session: EditorSession, name: String) async throws -> URL {
        let stem = (name as NSString).deletingPathExtension
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(stem)-\(UUID().uuidString).comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        return url
    }

    private func makeSession() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 80, height: 40, emptyLayer: true)
        _ = try #require(session.activeLayer)
        return session
    }

    private func toneSession(level: UInt8) throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 8, height: 8)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let unit = CGFloat(level) / 255
        context.setFillColor(CGColor(srgbRed: unit, green: unit, blue: unit, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray"))
        return session
    }

    private func brightest(_ session: EditorSession) async throws -> Int {
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var peak = 0
        for index in 0..<(image.width * image.height) {
            peak = max(peak, Int(bytes[index * 4]), Int(bytes[index * 4 + 1]), Int(bytes[index * 4 + 2]))
        }
        return peak
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

/// Holds the first model call, then answers. Used to overlap a cancelled request with the next one.
private final class PauseProvider: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var started = false
    private let pause: Duration
    private let reply: String
    init(pause: Duration, reply: String) {
        self.pause = pause
        self.reply = reply
    }
    func didStart() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }
    func complete(_ turns: [AITurn], tools: [AIToolSpec]) async throws -> AICompletion {
        let call: Int
        lock.lock()
        call = calls
        calls += 1
        started = true
        lock.unlock()
        if call == 0 { try await Task.sleep(for: pause) }
        if tools.isEmpty { return AICompletion(text: "plan", toolCalls: []) }
        return AICompletion(text: reply, toolCalls: [])
    }
}

private func waitUntilIdle(_ model: AIPanelModel) async {
    for _ in 0..<400 where model.isSending {
        try? await Task.sleep(for: .milliseconds(25))
    }
}

/// Returns a tool call on every completion, so the panel stops at the round limit.
private final class LoopingToolProvider: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func complete(_ turns: [AITurn], tools: [AIToolSpec]) async throws -> AICompletion {
        lock.lock()
        count += 1
        let id = "loop-\(count)"
        lock.unlock()
        return AICompletion(text: nil, toolCalls: [AIToolCall(id: id, name: "shell", arguments: "{}")])
    }
}

/// Remembers every turn it is shown, then answers without calling a tool.
private final class RecordingProvider: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    var texts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
    func complete(_ turns: [AITurn], tools: [AIToolSpec]) async throws -> AICompletion {
        lock.lock()
        seen.append(contentsOf: turns.map(\.text))
        lock.unlock()
        return AICompletion(text: "Zoom is in the sample.", toolCalls: [])
    }
}

private final class FailingProvider: AIProvider, @unchecked Sendable {
    func complete(_ turns: [AITurn], tools: [AIToolSpec]) async throws -> AICompletion {
        throw AIProviderError.status(-1, "offline")
    }
}

/// Reads the dull-frame diagnosis, then sets the Levels white point so a tone of 200 lands near 230.
private final class ScriptedDullLevels: AIProvider, @unchecked Sendable {
    var sawDiagnosis = false
    private var calls = 0
    private let white: Double
    init(white: Double) { self.white = white }
    func complete(_ turns: [AITurn], tools: [AIToolSpec]) async throws -> AICompletion {
        if turns.contains(where: { $0.text.contains("Diagnosis for 「发闷」") }) { sawDiagnosis = true }
        if tools.isEmpty {
            return AICompletion(text: "理解：发闷。方案：用色阶把最亮收到大约 230。", toolCalls: [])
        }
        if calls == 0 {
            calls = 1
            return AICompletion(text: nil, toolCalls: [AIToolCall(id: "L", name: "use_levels", arguments: #"{"white":\#(white)}"#)])
        }
        return AICompletion(text: "审阅：最亮大约到 230。", toolCalls: [])
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
        if turns.contains(where: { $0.text.contains("temperature -30") }) { sawRecipe = true }
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
