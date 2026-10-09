import AppKit

/// What one whitelisted call did. `wantsPreview` asks the loop to render and hand the picture back.
struct AIToolOutcome: Equatable {
    var text: String
    var changedDocument: Bool
    var wantsPreview: Bool
    /// Document edits, and a load or save that actually happened, show up in the panel's session list.
    var listInSession: Bool = false

    init(text: String, changedDocument: Bool, wantsPreview: Bool, listInSession: Bool = false) {
        self.text = text
        self.changedDocument = changedDocument
        self.wantsPreview = wantsPreview
        self.listInSession = listInSession
    }

    static func unchanged(_ text: String) -> Self { Self(text: text, changedDocument: false, wantsPreview: false) }
    static func changed(_ text: String) -> Self { Self(text: text, changedDocument: true, wantsPreview: false, listInSession: true) }
}

/// The only commands the model may run. Nilary ones are the command palette's layer commands and tools.
/// The rest are the same kind of entry, or a ProjectStore read/write. Nothing here runs shell or arbitrary code.
enum AIToolRegistry {
    static let opacityTool = "set_layer_opacity"
    static let curvesTool = "use_curves"
    static let balanceTool = "use_color_balance"
    static let hueTool = "use_hue_saturation"
    static let exposureTool = "use_exposure"
    static let levelsTool = "use_levels"
    static let cameraRawTool = "use_camera_raw"
    static let previewTool = "render_preview"
    static let loadTool = "load_project"
    static let saveTool = "save_project"
    private static let emptyParameters = #"{"type":"object","properties":{}}"#
    private static let opacityParameters = """
    {"type":"object","properties":{"percent":{"type":"number","description":"0 to 100. 60 means 60 percent, not 0.6."}},"required":["percent"]}
    """
    private static let curvesParameters = """
    {"type":"object","properties":{"points":{"type":"array","description":"RGB curve points, each with x and y from 0 to 255. The first x is 0, the last x is 255, and x increases. Opening Curves shows this curve."},"revise":{"type":"boolean","description":"True updates the Curves adjustment already added instead of adding another."}},"required":["points"]}
    """
    private static let balanceParameters = """
    {"type":"object","properties":{"shadowCyanRed":{"type":"number"},"shadowMagentaGreen":{"type":"number"},"shadowYellowBlue":{"type":"number"},"midCyanRed":{"type":"number"},"midMagentaGreen":{"type":"number"},"midYellowBlue":{"type":"number"},"highlightCyanRed":{"type":"number"},"highlightMagentaGreen":{"type":"number"},"highlightYellowBlue":{"type":"number"},"revise":{"type":"boolean"}},"required":[]}
    """
    private static let hueParameters = """
    {"type":"object","properties":{"hue":{"type":"number","description":"Master hue, -180 to 180. Omit when bands are set."},"saturation":{"type":"number","description":"Master saturation, -100 to 100."},"lightness":{"type":"number","description":"Master lightness, -100 to 100."},"bands":{"type":"object","description":"One entry per range. Keys are Master, Reds, Yellows, Greens, Cyans, Blues, Magentas. There is no Oranges or Purples key. A hue near 30 degrees is half Reds and half Yellows, so set both. Each entry has hue (-180 to 180), saturation, and lightness (-100 to 100).","additionalProperties":{"type":"object","properties":{"hue":{"type":"number"},"saturation":{"type":"number"},"lightness":{"type":"number"}}}},"revise":{"type":"boolean"}},"required":[]}
    """
    private static let exposureParameters = """
    {"type":"object","properties":{"exposure":{"type":"number","description":"Stops, -20 to 20."},"offset":{"type":"number","description":"-0.5 to 0.5."},"gamma":{"type":"number","description":"0.01 to 9.99. Above 1 brightens midtones."},"revise":{"type":"boolean"}},"required":[]}
    """
    private static let levelsParameters = """
    {"type":"object","properties":{"black":{"type":"number"},"white":{"type":"number"},"gamma":{"type":"number"},"outputBlack":{"type":"number"},"outputWhite":{"type":"number"},"revise":{"type":"boolean"}},"required":[]}
    """
    /// The Camera Raw fields the look catalog actually sets. The rest of Camera Raw stays closed.
    private static let cameraRawParameters = """
    {"type":"object","properties":{"exposure":{"type":"number","description":"Stops, -5 to 5."},"contrast":{"type":"number","description":"-100 to 100."},"highlights":{"type":"number","description":"-100 to 100."},"shadows":{"type":"number","description":"-100 to 100."},"whites":{"type":"number","description":"-100 to 100."},"blacks":{"type":"number","description":"-100 to 100."},"temperature":{"type":"number","description":"-100 to 100. Positive is warmer."},"tint":{"type":"number","description":"-100 to 100. Positive is magenta."},"vibrance":{"type":"number","description":"-100 to 100."},"saturation":{"type":"number","description":"-100 to 100."},"texture":{"type":"number","description":"-100 to 100."},"clarity":{"type":"number","description":"-100 to 100."},"dehaze":{"type":"number","description":"-100 to 100."},"vignette":{"type":"number","description":"-100 to 100. Negative darkens the edges."},"grain":{"type":"number","description":"0 to 100."}},"required":[]}
    """
    private static let pathParameters = """
    {"type":"object","properties":{"path":{"type":"string","description":"A .comp file under the home directory. Omit to use the project that is open."}}}
    """
    static func specs(for session: EditorSession) -> [AIToolSpec] {
        let commands = CommandPaletteEntry.layerCommands(for: session) + CommandPaletteEntry.tools(for: session)
        var specs = commands.map { entry in
            let availability = entry.isEnabled ? "" : " Unavailable right now."
            return AIToolSpec(name: functionName(entry.id), description: entry.id + "." + availability, parameters: emptyParameters)
        }
        let opacity = session.canEditOpacity ? "" : " Unavailable right now."
        specs.append(AIToolSpec(name: opacityTool,
            description: "Set the active layer's opacity. percent is 0 to 100, so 60 means 60%. One undo step." + opacity,
            parameters: opacityParameters))
        let grade = session.canEditLayers ? "" : " Unavailable right now."
        let trail = " Adds an adjustment layer and leaves the original pixels. Opening that adjustment shows these settings. Pass revise true to change the one already added." + grade
        specs.append(AIToolSpec(name: curvesTool,
            description: "Add a Curves adjustment. points is the RGB curve, each point {x, y} from 0 to 255 or from 0 to 1. It must bend; a straight line is refused. The Curves panel will show it." + trail,
            parameters: curvesParameters))
        specs.append(AIToolSpec(name: balanceTool,
            description: "Add a Color Balance adjustment. Each slider is -100 to 100. Positive cyanRed is red, positive magentaGreen is green, positive yellowBlue is blue. Prefix shadow, mid, or highlight." + trail,
            parameters: balanceParameters))
        specs.append(AIToolSpec(name: hueTool,
            description: "Add a Hue/Saturation adjustment. Top-level hue, saturation, and lightness edit Master only. bands sets Master, Reds, Yellows, Greens, Cyans, Blues, or Magentas, each with its own hue (-180 to 180), saturation, and lightness (-100 to 100). There is no Oranges band: a hue near 30° weighs about half on Reds and half on Yellows, so pass both. Pulling reds and yellows toward gold uses different hue values on those two bands, not one Master hue." + trail,
            parameters: hueParameters))
        specs.append(AIToolSpec(name: exposureTool,
            description: "Add an Exposure adjustment. exposure is stops from -20 to 20. offset is -0.5 to 0.5. gamma is 0.01 to 9.99." + trail,
            parameters: exposureParameters))
        specs.append(AIToolSpec(name: levelsTool,
            description: "Add a Levels adjustment on RGB. black and white are 0 to 255. gamma is 0.1 to 9.99." + trail,
            parameters: levelsParameters))
        specs.append(AIToolSpec(name: cameraRawTool,
            description: "Apply Camera Raw to the active layer's pixels. One undo. Pass only the sliders this picture needs: exposure (-5 to 5), contrast, highlights, shadows, whites, blacks, temperature, tint, vibrance, saturation, texture, clarity, dehaze, vignette (-100 to 100), and grain (0 to 100). A look from the catalog is one call with that look's numbers. Do not use this for a plain brightness change." + grade,
            parameters: cameraRawParameters))
        specs.append(AIToolSpec(name: previewTool,
            description: "Render the current document and attach the picture. Does not change the document.",
            parameters: emptyParameters))
        specs.append(AIToolSpec(name: loadTool,
            description: "Open a .comp file with ProjectStore.load. Replaces the open document and clears undo. Format stays the file's own version.",
            parameters: pathParameters))
        specs.append(AIToolSpec(name: saveTool,
            description: "Write the open document with ProjectStore.save, at format version \(ProjectManifest.current). Omit path to save the open project.",
            parameters: pathParameters))
        return specs
    }

    /// Runs one whitelisted command. Anything else returns without touching the document.
    static func perform(_ call: AIToolCall, on session: EditorSession, controller: ProjectController? = nil) async -> AIToolOutcome {
        switch call.name {
        case opacityTool: return setOpacity(call, on: session)
        case curvesTool: return useCurves(call, on: session)
        case balanceTool: return useColorBalance(call, on: session)
        case hueTool: return useHueSaturation(call, on: session)
        case exposureTool: return useExposure(call, on: session)
        case levelsTool: return useLevels(call, on: session)
        case cameraRawTool: return await useCameraRaw(call, on: session)
        case previewTool: return AIToolOutcome(text: "Rendered the current document.", changedDocument: false, wantsPreview: true)
        case loadTool: return await loadProject(call, on: session, controller: controller)
        case saveTool: return await saveProject(call, on: session, controller: controller)
        default: break
        }
        let commands = CommandPaletteEntry.layerCommands(for: session) + CommandPaletteEntry.tools(for: session)
        guard let entry = commands.first(where: { functionName($0.id) == call.name }) else {
            return .unchanged("Unknown tool \(call.name). Only listed commands can run, and the document was not changed.")
        }
        return run(entry, on: session)
    }

    /// The flattened canvas as a JPEG, long side at most 1,024, for the model to look at.
    static func renderedPreview(of session: EditorSession) async -> Data? {
        guard let snapshot = session.projectSnapshot() else { return nil }
        do {
            let raster = try await ImageExporter.shared.render(snapshot)
            return await Task.detached { AIImageEncoder.jpeg(raster.image, longSide: AIImageEncoder.compositeLongSide) }.value
        } catch { return nil }
    }

    /// OpenAI function names are letters, digits, and underscores. "Tool › Brush" becomes `tool_brush`.
    static func functionName(_ id: String) -> String {
        let letters = CharacterSet.alphanumerics
        var name = ""
        var separator = false
        for scalar in id.lowercased().unicodeScalars {
            if letters.contains(scalar) {
                if separator, !name.isEmpty { name.append("_") }
                separator = false
                name.append(Character(scalar))
            } else {
                separator = true
            }
        }
        return name
    }

    /// 60 and 0.6 both mean 60%. Values above 100 are refused.
    static func opacityValue(from percent: Double) -> Double? {
        guard percent.isFinite, percent >= 0 else { return nil }
        if percent > 1 {
            guard percent <= 100 else { return nil }
            return percent / 100
        }
        return percent
    }

    private static func setOpacity(_ call: AIToolCall, on session: EditorSession) -> AIToolOutcome {
        guard let percent = argument(named: "percent", in: call.arguments) ?? argument(named: "opacity", in: call.arguments),
              let value = opacityValue(from: percent) else {
            return .unchanged("set_layer_opacity needs percent from 0 to 100. The document was not changed.")
        }
        let entry = CommandPaletteEntry(id: "Layer Opacity", shortcut: nil, isEnabled: session.canEditOpacity,
            perform: { session.setLayerOpacity(value) })
        let outcome = run(entry, on: session)
        guard outcome.changedDocument else { return outcome }
        return .changed("Ran Layer Opacity. Opacity is now \(Int((value * 100).rounded()))%.")
    }

    private static func useCurves(_ call: AIToolCall, on session: EditorSession) -> AIToolOutcome {
        guard let curve = curve(from: call.arguments) else {
            return .unchanged("use_curves needs an RGB curve that is not a straight line. The document was not changed.")
        }
        return place(.curves, revise: flag("revise", in: call.arguments), on: session) { $0.curves = curve }
    }

    private static func useColorBalance(_ call: AIToolCall, on session: EditorSession) -> AIToolOutcome {
        guard let balance = colorBalance(from: call.arguments) else {
            return .unchanged("use_color_balance needs a slider from -100 to 100. The document was not changed.")
        }
        return place(.colorBalance, revise: flag("revise", in: call.arguments), on: session) { $0.colorBalance = balance }
    }

    private static func useHueSaturation(_ call: AIToolCall, on session: EditorSession) -> AIToolOutcome {
        guard let settings = hueSettings(from: call.arguments) else {
            return .unchanged("use_hue_saturation needs a Master slider or a bands entry. The document was not changed.")
        }
        return place(.hsv, revise: flag("revise", in: call.arguments), on: session) { $0.hsvSettings = settings }
    }

    /// Master sliders stay at the top level. `bands` writes each range into `adjustments` and leaves the default hue bands in place.
    private static func hueSettings(from arguments: String) -> HueSaturationSettings? {
        var settings = HueSaturationSettings()
        settings.adjustments = [:]
        var any = false
        if let bands = object("bands", in: arguments) {
            for (key, value) in bands {
                guard let range = colorRange(named: key), let item = value as? [String: Any] else { continue }
                let adjustment = RangeAdjustment(hue: clamp(number(item["hue"]) ?? 0, -180, 180),
                                                 saturation: clamp(number(item["saturation"]) ?? 0, -100, 100),
                                                 lightness: clamp(number(item["lightness"]) ?? 0, -100, 100))
                guard adjustment != RangeAdjustment() else { continue }
                any = true
                settings.adjustments[range] = adjustment
            }
        }
        if settings.adjustments[.master] == nil {
            let hue = argument(named: "hue", in: arguments) ?? 0
            let saturation = argument(named: "saturation", in: arguments) ?? 0
            let lightness = argument(named: "lightness", in: arguments) ?? 0
            if hue != 0 || saturation != 0 || lightness != 0 {
                any = true
                settings.adjustments[.master] = RangeAdjustment(hue: clamp(hue, -180, 180),
                                                                saturation: clamp(saturation, -100, 100),
                                                                lightness: clamp(lightness, -100, 100))
            }
        }
        settings.range = .master
        guard any, !settings.isIdentity else { return nil }
        return settings
    }

    /// The seven ranges the panel has. Orange and purple are not names here.
    private static func colorRange(named key: String) -> ColorRange? {
        let folded = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ColorRange.allCases.first { $0.rawValue.lowercased() == folded }
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(high, max(low, value))
    }

    private static func useExposure(_ call: AIToolCall, on session: EditorSession) -> AIToolOutcome {
        var settings = ExposureSettings()
        settings.exposure = argument(named: "exposure", in: call.arguments) ?? 0
        settings.offset = argument(named: "offset", in: call.arguments) ?? 0
        settings.gamma = argument(named: "gamma", in: call.arguments) ?? 1
        settings = settings.normalized
        guard settings != ExposureSettings() else {
            return .unchanged("use_exposure needs an exposure, offset, or gamma. The document was not changed.")
        }
        return place(.exposure, revise: flag("revise", in: call.arguments), on: session) { $0.exposure = settings }
    }

    private static func useLevels(_ call: AIToolCall, on session: EditorSession) -> AIToolOutcome {
        var range = LevelRange()
        if let black = argument(named: "black", in: call.arguments) { range.black = black }
        if let white = argument(named: "white", in: call.arguments) { range.white = white }
        if let gamma = argument(named: "gamma", in: call.arguments) { range.gamma = gamma }
        if let outputBlack = argument(named: "outputBlack", in: call.arguments) { range.outputBlack = outputBlack }
        if let outputWhite = argument(named: "outputWhite", in: call.arguments) { range.outputWhite = outputWhite }
        range = range.normalized
        guard range != LevelRange() else {
            return .unchanged("use_levels needs a black point, white point, gamma, or output level. The document was not changed.")
        }
        var settings = LevelsSettings()
        settings.ranges[0] = range
        return place(.levels, revise: flag("revise", in: call.arguments), on: session) { $0.levels = settings }
    }

    /// Bakes Camera Raw into the active layer. `commitFilter` records the one undo step.
    private static func useCameraRaw(_ call: AIToolCall, on session: EditorSession) async -> AIToolOutcome {
        guard let raw = cameraRaw(from: call.arguments) else {
            return .unchanged("use_camera_raw needs one of its sliders set. The document was not changed.")
        }
        guard session.filterEdit == nil else {
            return .unchanged("A filter is already open. The document was not changed.")
        }
        session.beginFilter(.cameraRaw)
        guard let edit = session.filterEdit, edit.kind == .cameraRaw else {
            return .unchanged("Camera Raw could not start. The document was not changed.")
        }
        edit.settings.cameraRaw = raw
        let steps = session.history.undoCount
        await session.commitFilter()
        guard session.filterEdit == nil, session.history.undoCount > steps else {
            session.cancelFilter()
            return .unchanged("Camera Raw was not applied. The document was not changed.")
        }
        return .changed("Applied Camera Raw. Undo puts the layer's pixels back.")
    }

    /// The fifteen catalog sliders. Anything else in the arguments is ignored. All zeros are refused.
    private static func cameraRaw(from arguments: String) -> CameraRawSettings? {
        var raw = CameraRawSettings()
        var any = false
        func take(_ key: String, _ write: (inout CameraRawSettings, Double) -> Void) {
            guard let value = argument(named: key, in: arguments) else { return }
            any = true
            write(&raw, value)
        }
        take("exposure") { $0.exposure = $1 }
        take("contrast") { $0.contrast = $1 }
        take("highlights") { $0.highlights = $1 }
        take("shadows") { $0.shadows = $1 }
        take("whites") { $0.whites = $1 }
        take("blacks") { $0.blacks = $1 }
        take("temperature") { $0.temperature = $1 }
        take("tint") { $0.tint = $1 }
        take("vibrance") { $0.vibrance = $1 }
        take("saturation") { $0.saturation = $1 }
        take("texture") { $0.texture = $1 }
        take("clarity") { $0.clarity = $1 }
        take("dehaze") { $0.dehaze = $1 }
        take("vignette") { $0.vignetteAmount = $1 }
        take("grain") { $0.grainAmount = $1 }
        raw = raw.normalized
        guard any, raw.isValid, !raw.isIdentity else { return nil }
        return raw
    }

    /// Adds the adjustment, or updates the newest one of that kind when `revise` is set.
    private static func place(_ kind: AdjustmentKind, revise: Bool, on session: EditorSession,
                              configure: (inout LayerAdjustment) -> Void) -> AIToolOutcome {
        let name = uiName(kind.rawValue)
        if revise, session.document?.layers.contains(where: { $0.adjustment?.kind == kind }) == true {
            guard session.reviseAdjustment(kind, configure: configure) else {
                return .unchanged("The \(kind.rawValue) adjustment was not changed.")
            }
            return .changed(String(localized: "Revised the \(name) adjustment. Opening it shows the settings that were used."))
        }
        guard session.insertAdjustment(kind, configure: configure) else {
            return .unchanged("The \(kind.rawValue) adjustment was not changed.")
        }
        return .changed(String(localized: "Added an adjustment layer (\(name)). Opening it shows the settings that were used."))
    }

    private static func curve(from arguments: String) -> CurvesSettings? {
        guard let points = objectArray("points", in: arguments) else { return nil }
        var curve = points.compactMap { item -> CurvePoint? in
            guard let x = number(item["x"]), let y = number(item["y"]) else { return nil }
            return CurvePoint(x: x, y: y)
        }
        guard curve.count >= 2 else { return nil }
        // Models often write the curve in 0…1. The Curves panel stores 0…255.
        if curve.map({ max($0.x, $0.y) }).max() ?? 0 <= 1.5 {
            curve = curve.map { CurvePoint(x: $0.x * 255, y: $0.y * 255) }
        }
        curve = curve.map { CurvePoint(x: min(255, max(0, $0.x)), y: min(255, max(0, $0.y))) }
        curve.sort { $0.x < $1.x }
        var unique: [CurvePoint] = []
        for point in curve {
            if let last = unique.last, abs(last.x - point.x) < 0.5 { unique[unique.count - 1] = point }
            else { unique.append(point) }
        }
        if unique.first?.x != 0 { unique.insert(CurvePoint(x: 0, y: 0), at: 0) }
        if unique.last?.x != 255 { unique.append(CurvePoint(x: 255, y: 255)) }
        var settings = CurvesSettings()
        settings.channels[0] = unique
        guard settings.isValid, settings.channels[0] != CurvesSettings().channels[0] else { return nil }
        return settings
    }

    private static func colorBalance(from arguments: String) -> ColorBalanceSettings? {
        var balance = ColorBalanceSettings()
        var any = false
        func take(_ key: String, _ write: (inout ColorBalanceSettings, Double) -> Void) {
            guard let value = argument(named: key, in: arguments) else { return }
            any = true
            write(&balance, min(100, max(-100, value)))
        }
        take("shadowCyanRed") { $0.shadowCyanRed = $1 }
        take("shadowMagentaGreen") { $0.shadowMagentaGreen = $1 }
        take("shadowYellowBlue") { $0.shadowYellowBlue = $1 }
        take("midCyanRed") { $0.midCyanRed = $1 }
        take("midMagentaGreen") { $0.midMagentaGreen = $1 }
        take("midYellowBlue") { $0.midYellowBlue = $1 }
        take("highlightCyanRed") { $0.highlightCyanRed = $1 }
        take("highlightMagentaGreen") { $0.highlightMagentaGreen = $1 }
        take("highlightYellowBlue") { $0.highlightYellowBlue = $1 }
        guard any, balance.isValid, !balance.isIdentity else { return nil }
        return balance
    }

    private static func loadProject(_ call: AIToolCall, on session: EditorSession, controller: ProjectController?) async -> AIToolOutcome {
        guard let url = fileURL(pathArgument(in: call.arguments), fallback: session.projectURL, allowOpenProject: true) else {
            return .unchanged("load_project needs a .comp file under the home directory. The document was not changed.")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let snapshot = try await ProjectStore.shared.load(from: url)
            session.installProject(snapshot, from: url)
            await controller?.rememberProjectDigest(for: url)
            controller?.watchProject(at: url)
            return AIToolOutcome(text: "Opened \(url.lastPathComponent), format version \(snapshot.manifest.version). Undo was cleared.",
                                 changedDocument: false, wantsPreview: true, listInSession: true)
        } catch {
            return .unchanged("Could not open \(url.lastPathComponent) (\(error.localizedDescription)). The document was not changed.")
        }
    }

    private static func saveProject(_ call: AIToolCall, on session: EditorSession, controller: ProjectController?) async -> AIToolOutcome {
        guard let snapshot = session.projectSnapshot() else { return .unchanged("Nothing to save. The document was not changed.") }
        guard let url = fileURL(pathArgument(in: call.arguments), fallback: session.projectURL, allowOpenProject: true) else {
            return .unchanged("save_project needs the open project, or a .comp path under the home directory. Nothing was written.")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let revision = session.history.currentRevision
        controller?.externalChanges.saving = true
        defer { controller?.externalChanges.saving = false }
        do {
            try await ProjectStore.shared.save(snapshot, to: url)
            session.projectURL = url
            session.history.markSaved(revision)
            await controller?.rememberProjectDigest(for: url)
            controller?.watchProject(at: url)
            return AIToolOutcome(text: "Saved \(url.lastPathComponent), format version \(snapshot.manifest.version).",
                                 changedDocument: false, wantsPreview: false, listInSession: true)
        } catch {
            return .unchanged("Could not save \(url.lastPathComponent) (\(error.localizedDescription)). Nothing was written.")
        }
    }

    /// A `.comp` path under the home directory, or the project already open. No other location is written or read.
    static func fileURL(_ path: String?, fallback: URL?, allowOpenProject: Bool) -> URL? {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            guard allowOpenProject, let fallback else { return nil }
            return fallback.standardizedFileURL
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        guard url.pathExtension.lowercased() == "comp" else { return nil }
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        guard url.path.hasPrefix(home + "/") else { return nil }
        return url
    }

    private static func run(_ entry: CommandPaletteEntry, on session: EditorSession) -> AIToolOutcome {
        guard entry.isEnabled else { return .unchanged("\(entry.id) is not available. The document was not changed.") }
        let steps = session.history.undoCount
        // Nested with the command's own begin/end, so a command that already records history still becomes one undo.
        session.history.begin(entry.id, document: session.document, selection: session.activeLayerID)
        // Caught here so an AppKit exception still closes the undo step and leaves the editor running.
        let failure = AIPanelFence.exception { entry.perform() }
        session.history.end(document: session.document, selection: session.activeLayerID)
        if let failure {
            if session.history.undoCount > steps {
                return AIToolOutcome(text: "\(entry.id) failed (\(failure)). Undo will put it back. The editor is unaffected.",
                                     changedDocument: true, wantsPreview: false, listInSession: true)
            }
            return .unchanged("\(entry.id) failed (\(failure)). The document was not changed. The editor is unaffected.")
        }
        guard session.history.undoCount > steps else { return .unchanged("Ran \(entry.id). The document was unchanged.") }
        return .changed("Ran \(entry.id).")
    }

    private static func flag(_ key: String, in arguments: String) -> Bool {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json[key] as? Bool == true
    }

    private static func object(_ key: String, in arguments: String) -> [String: Any]? {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json[key] as? [String: Any]
    }

    private static func objectArray(_ key: String, in arguments: String) -> [[String: Any]]? {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json[key] as? [[String: Any]]
    }

    private static func number(_ value: Any?) -> Double? {
        // JSON true and false are NSNumber too, but so are 0 and 1. Only a real boolean is refused.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func argument(named key: String, in arguments: String) -> Double? {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return number(json[key])
    }

    private static func pathArgument(in arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["path"] as? String
    }

}
