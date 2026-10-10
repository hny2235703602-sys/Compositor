import Foundation

struct AIChatMessage: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant }
    var id = UUID()
    var role: Role
    var text: String
}

/// One document edit, load, or save the assistant finished during this panel's lifetime.
struct AISessionChange: Identifiable, Equatable {
    var id = UUID()
    var summary: String
}

@Observable
final class AIPanelModel {
    var draft = ""
    var messages: [AIChatMessage] = []
    var changes: [AISessionChange] = []
    var isSending = false
    var connectionChecking = false
    var connectionReport: AIConnectivity.Report?
    var availableModels: [String] = []
    var fetchingModels = false
    var modelsError: String?
    var error: String?
    /// What the assistant is doing, or that the last request finished or stopped.
    var status: String?
    private var task: Task<Void, Never>?

    func send(session: EditorSession, endpoint: String, modelName: String, controller: ProjectController? = nil) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isSending else { return }
        guard let key = AICredentials.load(), !key.isEmpty else {
            error = AIProviderError.missingKey.localizedDescription
            return
        }
        draft = ""
        error = nil
        status = String(localized: "Reading the picture…")
        isSending = true
        messages.append(AIChatMessage(role: .user, text: question))
        let provider = AIIsolatedProvider(endpoint: endpoint, model: modelName, apiKey: key)
        task = Task { [weak self] in
            await self?.run(question: question, session: session, provider: provider, controller: controller)
        }
    }

    /// Asks the endpoint for any HTTP response. A failure is stored on the panel and does not leave this method.
    func checkConnection(endpoint: String) async {
        guard !connectionChecking else { return }
        connectionChecking = true
        defer { connectionChecking = false }
        connectionReport = await AIPanelProcess.ping(endpoint: endpoint)
    }

    /// Fills `availableModels` from the endpoint's model list. A failure stays on the panel.
    func fetchModels(endpoint: String, apiKey: String) async {
        guard !fetchingModels else { return }
        fetchingModels = true
        defer { fetchingModels = false }
        let result = await AIModelCatalog.fetch(endpoint: endpoint, apiKey: apiKey)
        modelsError = result.error
        if result.error == nil { availableModels = result.models }
    }

    func cancel() {
        AIPanelWorkerHandle.shared.stopAll()
        task?.cancel()
        task = nil
        if isSending {
            status = String(localized: "Stopped.")
            isSending = false
        }
    }

    /// Change, render, and hand the picture back, until the model replies with no tool call. `roundLimit` stops a model that never finishes.
    static let roundLimit = 8

    func run(question: String, session: EditorSession, provider: any AIProvider, controller: ProjectController? = nil) async {
        defer { isSending = false }
        do {
            status = String(localized: "Reading the picture…")
            let context = await AIContextBuilder.capture(session)
            var turns = [AITurn(role: .system, text: Self.instructions)]
            for message in messages.dropLast() {
                turns.append(AITurn(role: message.role == .user ? .user : .assistant, text: message.text))
            }
            let asked = question + "\n\n" + AIContextBuilder.summary(context) + "\n\n" + AIContextBuilder.promptJSON(context)
                + Self.catalogNote(for: question, earlier: messages.dropLast().map(\.self))
                + AIKnowledge.note(for: question)
            let preview = context.modelJPEG.map { [$0] } ?? []
            turns.append(AITurn(role: .user, text: asked, images: preview))
            if AILookNotes.isQuestion(question) {
                status = String(localized: "Answering…")
                _ = try await performTurns(&turns, session: session, provider: provider, controller: controller,
                                            reviewing: false, speakWhenIdle: true)
                status = String(localized: "Finished.")
                return
            }
            // Understand the request, then decide which adjustments this picture needs. No tools yet.
            try Task.checkCancellation()
            status = String(localized: "Deciding what the request means…")
            let plan = try await provider.complete(turns, tools: [])
            let planText = plan.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !planText.isEmpty {
                messages.append(AIChatMessage(role: .assistant, text: planText))
                turns.append(AITurn(role: .assistant, text: planText))
            }
            turns.append(AITurn(role: .user, text: Self.operate, images: preview))
            status = String(localized: "Adding the adjustments…")
            let changed = try await performTurns(&turns, session: session, provider: provider, controller: controller,
                                                  reviewing: false, speakWhenIdle: true)
            guard changed else {
                status = String(localized: "Finished.")
                return
            }
            status = String(localized: "Checking the result…")
            let reviewImage = await AIToolRegistry.renderedPreview(of: session)
            turns.append(AITurn(role: .user, text: Self.review, images: reviewImage.map { [$0] } ?? []))
            _ = try await performTurns(&turns, session: session, provider: provider, controller: controller,
                                        reviewing: true, speakWhenIdle: true)
            status = String(localized: "Finished.")
        } catch is CancellationError {
            status = String(localized: "Stopped.")
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            status = String(localized: "Stopped.")
            return
        } catch {
            status = nil
            self.error = error.localizedDescription
        }
    }

    private static let instructions = """
    You are looking at the user's Compositor document. The latest user message carries a context sample taken at the moment they pressed Send. Answer from that sample. Earlier messages do not include a fresh sample.

    document.width and document.height are canvas pixels. document.path is the project file, or null when the canvas has never been saved. document.isModified means there are unsaved edits.
    viewport.zoom is the scale factor: 1 is 100% (actual pixels). viewport.scrollOrigin is [x, y], the document pixel under the top-left corner of the view. Document coordinates start at the top-left and increase down and to the right.
    activeTool is the current tool. toolMode, when present, is that tool's mode (Paint or Erase, Liquify, and so on).
    selection is null when nothing is selected. Otherwise bounds is {x, y, width, height} in document pixels, hasMask is true when the selection has coverage, and previewPNG is a base64 PNG of that region. previewPNG is omitted when the selection is empty.
    activeLayer is the primary selected layer. opacity runs from 0 to 1. selectedLayerIDs lists every selected layer, bottom to top.
    layers lists every layer, bottom to top. depth is how deep the layer sits in a folder (0 is the root). kind is pixels, group, adjustment, shape, or text. visible is the layer's own flag. opacity runs from 0 to 1. blendMode is that layer's blend mode.
    compositePNG is a base64 PNG of the flattened canvas with its long side at or under 1024 pixels. It is omitted when the canvas could not be rendered; compositeError then says why.

    You may change the document only by calling the listed tools. There is no shell and no way to run Swift or any other code. If a tool result says the command is unknown or unavailable, the document was not changed; say so.

    set_layer_opacity sets the active layer's opacity. percent is 0 to 100: for 60% pass 60. That change is one undo (Edit > Undo).
    set_layer_blend_mode sets the active layer's blend mode. blendMode is one of: \(LayerBlendMode.allCases.map(\.rawValue).joined(separator: ", ")). Screen is 滤色, Soft Light is 柔光, Luminosity is 明度. Optional opacity is 0 to 100. That change is one undo. A blend mode change is this tool, not an adjustment.
    A picture change is made the way a person uses the app. Do not replace pixel layers. Add an adjustment layer, then the user can open it and see the settings.
    use_curves adds Curves. points is the RGB curve, each point {x, y} from 0 to 255 or from 0 to 1. It must bend. If a straight line is refused, call use_curves again with a bent curve before moving on.
    use_color_balance adds Color Balance. Each slider is -100 to 100. Positive cyanRed is red, negative is cyan. Positive magentaGreen is green. Positive yellowBlue is blue. Name them shadowCyanRed, midCyanRed, highlightCyanRed, and the same for MagentaGreen and YellowBlue.
    use_hue_saturation adds Hue/Saturation. Top-level hue, saturation, and lightness edit Master only, from -180 to 180 and -100 to 100. bands sets each range on its own: Master, Reds, Yellows, Greens, Cyans, Blues, Magentas. There is no Oranges or Purples key. A hue near 30° weighs about half on Reds and half on Yellows, so a shift of orange sets both, and the two hue numbers can differ. Black and gold pulls Reds and Yellows toward gold and lowers saturation on Greens, Cyans, Blues, and Magentas. It is not one Master hue.
    use_exposure adds Exposure. exposure is stops from -20 to 20. offset is -0.5 to 0.5. gamma is 0.01 to 9.99.
    use_levels adds Levels on the RGB channel. black and white are 0 to 255. gamma is 0.1 to 9.99. outputBlack and outputWhite are 0 to 255.
    use_gradient_map adds a Gradient Map adjustment. Omit the colors for black shadows and white highlights. shadows and highlights are each {red, green, blue} from 0 to 255 or 0 to 1. reversed swaps the ends. A request for a gradient map plus 明度 is this tool, then set_layer_blend_mode with Luminosity on the new layer. Those are two undos. It is not the clear Camera Raw recipe.
    use_camera_raw applies Camera Raw to the active layer. One call, one undo. The only sliders are exposure (-5 to 5), contrast, highlights, shadows, whites, blacks, temperature, tint, vibrance, saturation, texture, clarity, dehaze, vignette (-100 to 100), and grain (0 to 100). A catalog look is those numbers in one call. Do not call it for a plain "too bright" or "too dark" request; that is use_exposure.
    Pass revise true only when reviewing, to change the adjustment of that kind already in the document.
    When the first reply allows no tools, write two parts in the user's language: 理解, what they asked for, and 方案, which of these adjustments this picture needs and the settings. A catalog look that names clarity, texture, dehaze, vibrance, vignette, or grain is one use_camera_raw call with the recipe's numbers, including its exposure, contrast, highlights, shadows, whites, blacks, temperature, tint, and saturation. A request that is only too bright or too dark is use_exposure, not Camera Raw. Change any number the attached picture requires.
    The next request asks you to call those tools, one adjustment at a time. A later request shows the result. Compare it with the request. Revise what is still wrong, then reply with 审阅 and no tool call when it is right.
    render_preview renders without changing anything. load_project and save_project read and write a .comp file at the current format. They do not invent a new format.
    The other tools switch tools or add a layer mask, and only when the user asks for that.
    \(AILookNotes.index)

    Answer in the language the user writes in. When asked which layer is selected, where the selection is, or what the zoom is, quote the active layer name, the selection bounds, and the zoom from the sample.
    """

    /// The catalog recipe for this request, or for the look an earlier message already started. Questions get none.
    private static func catalogNote(for question: String, earlier: [AIChatMessage]) -> String {
        let current = AILookNotes.directMatch(in: question).flatMap { match -> (AILookNotes.Match, Bool)? in
            AILookNotes.look(named: match.id).map { _ in (match, true) }
        }
        let match = current ?? earlier.reversed().lazy.compactMap { message -> (AILookNotes.Match, Bool)? in
            guard message.role == .user, let found = AILookNotes.directMatch(in: message.text) else { return nil }
            return (found, false)
        }.first
        guard let match, let look = AILookNotes.look(named: match.0.id) else { return "" }
        let role = match.1
            ? "Catalog starting point for 「\(match.0.phrase)」 (\(look.id)). \(look.use)"
            : "The picture already includes an earlier 「\(match.0.phrase)」 grade (\(look.id)). \(look.use) The user is correcting that result."
        return """

        \(role)
        \(AILookNotes.recipe(of: look))
        Read those numbers as the method. A look that needs clarity, texture, dehaze, vibrance, vignette, or grain is one use_camera_raw call with these numbers. A grading wheel is not a Camera Raw slider: express that hue with use_hue_saturation bands, not a Master hue. Black and gold sets Reds and Yellows toward gold and lowers saturation on the other ranges. A look whose use says it is only an exposure change is use_exposure, not Camera Raw. If the user asks for a gradient map, call use_gradient_map instead of this recipe, then set Luminosity when they ask for 明度. Follow the user's words when they differ from the recipe.
        """
    }

    private static let operate = """
    Now make that change in the software. If the plan is a Camera Raw look, call use_camera_raw once with its sliders. Otherwise use use_curves, use_color_balance, use_hue_saturation, use_exposure, use_levels, or use_gradient_map, one adjustment at a time, and leave the original pixels in place. A request that is only too bright or too dark is use_exposure. A request for a gradient map calls use_gradient_map. Black to white is the default. 明度 on that new layer is a following set_layer_blend_mode with Luminosity. A request to change the blend mode calls set_layer_blend_mode. Screen is 滤色, Soft Light is 柔光, Luminosity is 明度. Follow the plan, and change any number this picture requires. When the planned change exists, reply with no tool call.
    """

    private static let review = """
    This picture is the result of the adjustments you added. Compare it with the request. If a color the user wanted gone is still obvious, or the grade is only partly there, call the same tool with revise true and stronger numbers, or add the adjustment that failed. Do not call the result done while that is still true. If it is right, reply in the user's language, starting with 审阅, and say what you checked. Do not call a tool when it is right.
    """

    /// Runs tool rounds until the model stops. `speakWhenIdle` stores that closing reply in the chat.
    private func performTurns(_ turns: inout [AITurn], session: EditorSession, provider: any AIProvider,
                              controller: ProjectController?, reviewing: Bool, speakWhenIdle: Bool) async throws -> Bool {
        var changed = false
        for _ in 0..<Self.roundLimit {
            try Task.checkCancellation()
            status = reviewing ? String(localized: "Checking the result…") : status
            let completion = try await provider.complete(turns, tools: AIToolRegistry.specs(for: session))
            if completion.toolCalls.isEmpty {
                let text = completion.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if speakWhenIdle, !text.isEmpty {
                    messages.append(AIChatMessage(role: .assistant, text: text))
                }
                return changed
            }
            turns.append(AITurn(role: .assistant, text: completion.text ?? "", toolCalls: completion.toolCalls))
            var outcomes: [(AIToolCall, AIToolOutcome)] = []
            for call in completion.toolCalls {
                status = Self.activity(call.name)
                let outcome = await AIToolRegistry.perform(call, on: session, controller: controller)
                if !outcome.changedDocument {
                    status = String(localized: "\(Self.toolTitle(call.name)) was not added. Continuing…")
                }
                outcomes.append((call, outcome))
            }
            if outcomes.contains(where: \.1.changedDocument) { changed = true }
            let needsPicture = outcomes.contains { $0.1.changedDocument || $0.1.wantsPreview }
            let preview = needsPicture ? await AIToolRegistry.renderedPreview(of: session) : nil
            for (index, item) in outcomes.enumerated() {
                if item.1.listInSession {
                    changes.append(AISessionChange(summary: item.1.text))
                }
                let attach = index == outcomes.count - 1 ? preview : nil
                var text = item.1.text
                if index == outcomes.count - 1, needsPicture {
                    text += preview == nil
                        ? " The render failed, so there is no picture to judge."
                        : reviewing
                        ? " Render attached. Revise an adjustment that is still wrong, or add the one that is missing. If the picture meets the request, reply with no tool call."
                        : " Render attached. Add the next adjustment from the plan. When every planned adjustment exists, reply with no tool call."
                }
                turns.append(AITurn(role: .tool, text: text, toolCallID: item.0.id, images: attach.map { [$0] } ?? []))
            }
        }
        messages.append(AIChatMessage(role: .assistant, text: "Stopped after \(Self.roundLimit) rounds."))
        return changed
    }

    private static func activity(_ tool: String) -> String {
        String(localized: "Adding \(toolTitle(tool))…")
    }

    private static func toolTitle(_ tool: String) -> String {
        switch tool {
        case AIToolRegistry.curvesTool: String(localized: "Curves")
        case AIToolRegistry.balanceTool: String(localized: "Color Balance")
        case AIToolRegistry.hueTool: String(localized: "Hue/Saturation")
        case AIToolRegistry.exposureTool: String(localized: "Exposure")
        case AIToolRegistry.levelsTool: String(localized: "Levels")
        case AIToolRegistry.gradientMapTool: String(localized: "Gradient Map")
        case AIToolRegistry.cameraRawTool: String(localized: "Camera Raw")
        case AIToolRegistry.blendTool: String(localized: "Blend Mode")
        default: tool
        }
    }
}
