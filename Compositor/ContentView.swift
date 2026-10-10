import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    /// The Layers panel's width, remembered across launches.
    @AppStorage("layersPanelWidth") private var layersPanelWidth = 252.0
    /// White, gray, or black around the canvas.
    @AppStorage("canvasSurround") private var surroundRaw = "gray"
    /// White, gray, or black for the rest of the interface.
    @AppStorage("interfaceChrome") private var chromeRaw = "gray"
    /// `en` or `zh-Hans`. Empty until the user picks one, so a fresh launch keeps the system language.
    @AppStorage("interfaceLanguage") private var languageRaw = ""
    /// The AI panel's width, remembered across launches. The panel itself stays closed until it is opened.
    @AppStorage("aiPanelWidth") private var aiPanelWidth = 320.0
    @AppStorage("aiPanelShown") private var aiPanelShown = false
    @Bindable var session: EditorSession
    var applicationDelegate: CompositorApplicationDelegate? = nil
    @Environment(\.openWindow) private var openWindow
    @State private var canvasFrame: CGRect = .zero
    @State private var levelsPanel = FloatingPanelController(name: "levelsPanel")
    @State private var adjustmentPanel = FloatingPanelController(name: "adjustmentPanel")
    @State private var selectionAmountPanel = FloatingPanelController(name: "selectionAmountPanel")
    @State private var colorRangePanel = FloatingPanelController(name: "colorRangePanel")
    @State private var filterPanel = FloatingPanelController(name: "filterPanel")
    @State private var effectsPanel = FloatingPanelController(name: "effectsPanel")
    @State private var isDropTargeted = false
    /// The window's width, so the tab strip can use the toolbar's free space.
    @State private var windowWidth: CGFloat = 1180
    /// Which tool the pointer is over, and where its button sits in the window, so the name can sit beside the rail.
    @State private var hoveredTool: NavigationTool?
    @State private var toolFrames: [NavigationTool: CGRect] = [:]
    /// Outlives the drawer. Closing the panel, or Canvas Only, removes the view and must not drop the conversation.
    @State private var assistant = AIPanelModel()
    /// A layer dragged from this canvas's own tab has nowhere to go, so the canvas doesn't light up for it.
    private var acceptsDrop: Bool {
        guard let workspace = applicationDelegate?.workspace else { return true }
        return workspace.canReceiveDrag(into: workspace.current.id)
    }
    // Extracted from `body`: as one expression the type checker times out (Xcode 26.1).
    @ViewBuilder private var toolHeaders: some View {
        Group {
            if session.tool == .move {
                TransformInspector(session: session).id(session.activeLayerID)
                Divider()
            }
            if session.tool.isBrushTool {
                BrushControls(session: session)
                Divider()
            }
            if session.tool.isSelectionTool {
                LassoControls(session: session)
                Divider()
            }
            if session.tool == .gradient {
                GradientControls(session: session)
                Divider()
            }
            if session.tool == .type {
                TypeControls(session: session)
                Divider()
            }
            if session.tool == .shape {
                ShapeControls(session: session)
                Divider()
            }
            if session.tool == .eyedropper {
                HStack(spacing: 16) {
                    Text("Eyedropper").font(ToolHeaderStyle.titleFont)
                    Toggle("Sample Ring", isOn: $session.showsSampleRing).toggleStyle(.checkbox)
                    Spacer()
                }.padding(.horizontal, 18).toolHeaderBar()
                Divider()
            }
            if session.tool == .hand || session.tool == .zoom {
                NavigationToolHeader(session: session)
                Divider()
            }
            if session.tool == .crop {
                CropControls(session: session)
                Divider()
            }
            // No tool (A) keeps the header, so the canvas doesn't jump.
            if session.tool == .idle {
                HStack(spacing: 16) {
                    Text("Select a tool").font(ToolHeaderStyle.titleFont)
                    Spacer()
                }.padding(.horizontal, 18).toolHeaderBar()
                Divider()
            }
        }
    }

    @ViewBuilder private var editorStack: some View {
        VStack(spacing: 0) {
            if !session.canvasOnly { toolHeaders }
            HStack(spacing: 0) {
                if !session.canvasOnly {
                    toolRail
                    Divider()
                }
                VStack(spacing: 0) {
                    if session.showsRulers, session.document != nil, !session.canvasOnly {
                        HStack(spacing: 0) {
                            CanvasRulerCorner()
                            CanvasRulerView(session: session, axis: .horizontal)
                                .frame(height: CanvasRuler.thickness)
                        }
                    }
                    HStack(spacing: 0) {
                        if session.showsRulers, session.document != nil, !session.canvasOnly {
                            CanvasRulerView(session: session, axis: .vertical)
                                .frame(width: CanvasRuler.thickness)
                        }
                        ZStack {
                            EditorCanvas(session: session)
                            if session.document == nil { welcome }
                            if let layer = session.maskAloneLayer {
                                // At the foot of the canvas, clear of the transform box's rotation handle.
                                MaskAloneBadge(session: session, layer: layer).fixedSize()
                                    .padding(.bottom, 14)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            }
                        }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("editor")) } action: { canvasFrame = $0 }
                    }
                }
                if !session.canvasOnly {
                    PanelResizeEdge(width: $layersPanelWidth, range: LayersPanel.widths)
                    LayersPanel(session: session, width: layersPanelWidth)
                    if aiPanelShown {
                        PanelResizeEdge(width: $aiPanelWidth, range: AIPanelView.widths)
                        AIPanelView(session: session, width: aiPanelWidth, controller: applicationDelegate?.projects,
                                    onClose: { aiPanelShown = false }, model: assistant)
                    }
                }
            }
            if !session.canvasOnly {
                Divider()
                // Keeps its own height however short the window gets; the tools scroll instead.
                statusBar.fixedSize(horizontal: false, vertical: true)
                    .modifier(WidthReader(width: $windowWidth))
            }
        }
        .overlay { toolHoverTip }
    }

    // Split again for 1.1: the chain outgrew the type checker once more.
    @ViewBuilder private var editorChrome: some View {
        editorStack
        .background(Color(white: InterfaceTheme.chrome(named: chromeRaw).body))
        .background {
            if let applicationDelegate, applicationDelegate.projects.workspace == nil {
                ProjectWindowBridge(controller: applicationDelegate.projects).frame(width: 0, height: 0)
            }
        }
        .frame(minWidth: 800, minHeight: 520)
        .coordinateSpace(name: "editor")
        .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier, ProjectWorkspace.layerType], isTargeted: $isDropTargeted) { providers, location in
            guard session.levels == nil, !session.isProjectBusy, !session.showsNewDocument, !session.showsImporter, session.renamingLayerID == nil else { return false }
            let point: CGPoint?
            if let document = session.document, canvasFrame.contains(location) {
                point = session.viewport.documentPoint(
                    from: CGPoint(x: location.x - canvasFrame.minX, y: location.y - canvasFrame.minY),
                    documentSize: document.size)
            } else { point = nil }
            if let workspace = applicationDelegate?.workspace {
                let destination = workspace.current.id
                guard workspace.canSwitch, workspace.canReceiveDrag(into: destination) else { return false }
                Task { await workspace.receiveProviders(providers, into: destination, at: point) }
            } else {
                Task { await ImageFileDrop.importProviders(providers, into: session, at: point) }
            }
            return true
        }
        .overlay {
            if isDropTargeted, acceptsDrop {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3)
                    .frame(width: max(0, canvasFrame.width - 6), height: max(0, canvasFrame.height - 6))
                    .position(x: canvasFrame.midX, y: canvasFrame.midY)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { applicationDelegate?.showEditor = { openWindow(id: "editor") } }
        .preferredColorScheme(InterfaceTheme.chrome(named: chromeRaw).light ? .light : .dark)
        .environment(\.locale, themeLocale)
        .onAppear { InterfaceTheme.applyChrome(chromeRaw) }
        .onChange(of: surroundRaw) { _, _ in session.refreshCanvasPreview?() }
        .onChange(of: chromeRaw) { _, value in
            InterfaceTheme.applyChrome(value)
            session.refreshCanvasPreview?()
        }
        // Canvas Only (F): the canvas runs up under where the title bar was, so no gray strip is left across the top.
        // The toolbar itself is hidden and shown by the window (see `toggleCanvasOnly`), which lays its buttons out
        // again properly; hidden here instead, it came back with the tabs over the window buttons.
        .ignoresSafeArea(.container, edges: session.canvasOnly ? .top : [])
        .navigationTitle(session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                fileMenu
            }
            ToolbarItem(placement: .navigation) {
                settingsMenu
            }
            ToolbarItem(placement: .navigation) {
                themeMenu
            }
            ToolbarSpacer(.fixed, placement: .navigation)
            if let workspace = applicationDelegate?.workspace {
                ToolbarItem(placement: .navigation) {
                    ProjectTabStrip(workspace: workspace)
                        // As wide as the toolbar allows: the window less the traffic lights and New button before it
                        // and the zoom controls after it. Bounded, so adding tabs never pushes those aside; the
                        // strip scrolls instead.
                        .frame(width: max(200, windowWidth - 352), height: 34, alignment: .center)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            // Absorb all remaining navigation-toolbar width before the zoom controls.
            // Without this spacer, the growing tab strip pushes the primary actions left.
            ToolbarSpacer(.flexible, placement: .navigation)
            ToolbarItem(placement: .primaryAction) {
                Button { aiPanelShown.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        if assistant.isSending {
                            ProgressView().controlSize(.mini)
                                .accessibilityIdentifier("aiToggle")
                        } else if !aiPanelShown, assistant.error != nil {
                            Circle().fill(.red).frame(width: 8, height: 8)
                                .accessibilityIdentifier("aiToggle")
                        }
                    }
                }
                .help(assistantToolbarHelp)
                .accessibilityLabel(assistantToolbarHelp)
                .accessibilityIdentifier("toggleAssistant")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Fit") { session.fit() }.help("Fit canvas in window (⌘0)")
                    .accessibilityIdentifier("fitCanvas").disabled(session.document == nil)
                    .padding(.horizontal, 4)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("100%") { session.zoom(to: 1) }.help("Actual pixels (⌘1)")
                    .accessibilityIdentifier("actualPixels").disabled(session.document == nil)
                    .padding(.horizontal, 4)
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 0) {
                    Button { session.zoomKeyboard(by: 1) } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }.help("Zoom in (⌘+)").disabled(session.document == nil)
                    Button { session.zoomKeyboard(by: -1) } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }.help("Zoom out (⌘−)").disabled(session.document == nil)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    var body: some View {
        editorChrome
        .onChange(of: session.levels == nil) { _, closed in
            if closed { levelsPanel.close() }
            else {
                levelsPanel.onClose = { session.cancelLevels() }
                levelsPanel.show(title: uiName("Levels"), content: LevelsSheet(session: session))
            }
        }
        .onChange(of: session.colorRange == nil) { _, closed in
            if closed { colorRangePanel.close() }
            else {
                colorRangePanel.onClose = { session.cancelColorRange() }
                colorRangePanel.show(title: uiName("Color Range"), content: ColorRangeSheet(session: session))
            }
        }
        .onChange(of: session.hueSaturation == nil) { _, closed in
            if closed { adjustmentPanel.close() }
            else {
                adjustmentPanel.onClose = { session.cancelHueSaturation() }
                adjustmentPanel.show(title: uiName("Hue/Saturation"), content: HueSaturationSheet(session: session))
            }
        }
        .onChange(of: session.effectsEditing) { _, selection in
            if let selection {
                effectsPanel.onClose = { session.finishEffectsEditing(commit: false) }
                effectsPanel.show(title: uiName(selection.kind.rawValue), content: EffectsSheet(session: session, kind: selection.kind))
            } else { effectsPanel.close() }
        }
        .onChange(of: session.document?.layers) { _, layers in
            if let editing = session.effectsEditing,
               layers?.first(where: { $0.id == editing.layerID })?.effects?.contains(editing.kind) != true {
                if let picker = session.colorPicker, case .effect = picker.target { session.closeColorPicker(commit: false) }
                session.effectsEditing = nil
                session.effectsEditingOriginal = nil
            }
        }
        .onChange(of: session.selectionAmountOperation) { _, operation in
            if let operation {
                selectionAmountPanel.onClose = { session.selectionAmountOperation = nil }
                selectionAmountPanel.show(title: uiName(operation.rawValue + " Selection"),
                    content: SelectionAmountSheet(session: session, operation: operation))
            } else { selectionAmountPanel.close() }
        }
        // Last Filter applies without the panel.
        .onChange(of: session.filterEdit == nil || session.filterEdit?.repeating == true) { _, closed in
            if closed { filterPanel.close() }
            else {
                filterPanel.onClose = { session.cancelFilter() }
                let placement: FloatingPanelPlacement = session.filterEdit?.kind == .cameraRaw ? .dockedToMainWindowRight : .automatic
                filterPanel.show(title: uiName(session.filterEdit?.kind.rawValue ?? "Filter"), content: FilterSheet(session: session),
                                 placement: placement)
            }
        }
        .onChange(of: session.document == nil) { _, empty in
            if !empty { session.canvasFocusRequest += 1 }
        }
        .fileImporter(isPresented: $session.showsImporter,
                      allowedContentTypes: UTType.importableImages, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await session.importImages(urls) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { session.importError = error.localizedDescription }
            }
        }
        .alert("Import couldn’t finish", isPresented: Binding(
            get: { session.importError != nil }, set: { if !$0 { session.importError = nil } })) {
                // No cancel role: an alert with only a cancel button gets a second OK of its own.
                Button("OK") { session.importError = nil }
            } message: { Text(session.importError ?? "") }
        .alert("Couldn’t paint", isPresented: Binding(get: { session.brushError != nil },
            set: { if !$0 { session.brushError = nil } })) {
                Button("OK") { session.brushError = nil }
            } message: { Text(session.brushError ?? "") }
        .alert("Couldn’t crop", isPresented: Binding(get: { session.cropError != nil },
            set: { if !$0 { session.cropError = nil } })) {
                Button("OK") { session.cropError = nil }
            } message: { Text(session.cropError ?? "") }
    }
    /// The same file commands as the File menu. Shortcuts stay on that menu, so they are not offered twice.
    private var fileMenu: some View {
        let projects = applicationDelegate?.projects
        let canStart = projects?.canStart ?? true
        return Menu {
            Group {
                Button("New Canvas…") { requestNewCanvas() }
                    .disabled(!canStart)
                Button("Open Project…") { Task { await projects?.open() } }
                    .disabled(!canStart || projects == nil)
                Menu("Open Recent") {
                    ForEach(RecentProjects.shared.urls, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            Task { await projects?.open(url) }
                        }
                    }
                    Divider()
                    Button("Clear Menu") { RecentProjects.shared.clear() }
                        .disabled(RecentProjects.shared.urls.isEmpty)
                }
                .disabled(!canStart || projects == nil)
                Button("Import Images…") { session.showsImporter = true }
                    .disabled(session.levels != nil || session.showsBusy || session.isImporting || session.showsNewDocument)
            }
            Group {
                Divider()
                Button("Save") { Task { await projects?.save() } }
                    .disabled(session.document == nil || !canStart)
                Button("Save As…") { Task { await projects?.save(asNew: true) } }
                    .disabled(session.document == nil || !canStart)
                Divider()
                Button("Export PNG…") { Task { await projects?.exportPNG() } }
                    .disabled(session.document == nil || !canStart)
                Button("Export JPEG…") { Task { await projects?.exportJPEG() } }
                    .disabled(session.document == nil || !canStart)
                Divider()
                Button("Close Project") {
                    if let window = projects?.window { Task { await projects?.close(window) } }
                }
                .disabled(!canStart || projects == nil)
            }
        } label: {
            Image(systemName: "doc")
        }
        .accessibilityLabel(uiName("File"))
        .accessibilityIdentifier("fileMenu")
        .modifier(NewProjectDropTarget(workspace: applicationDelegate?.workspace))
    }

    /// Preferences that also live in the menus. No shortcuts here: the menus already own those keys.
    private var settingsMenu: some View {
        Menu {
            Button("Keyboard Shortcuts…") { ShortcutSettings.shared.show() }
            Button("Grid Settings…") { Task { await applicationDelegate?.projects.gridSettings() } }
                .disabled(session.document == nil)
            Divider()
            Group {
                Toggle("Pixel Grid (800% and above)", isOn: Binding(get: { session.showsPixelGrid }, set: { session.showsPixelGrid = $0 }))
                Toggle("Show Transform Controls", isOn: Binding(get: { session.showsTransformControls }, set: { session.showsTransformControls = $0 }))
                    .disabled(session.tool != .move || session.document == nil)
                Toggle("Rulers", isOn: Binding(get: { session.showsRulers }, set: { session.showsRulers = $0 }))
                    .disabled(session.document == nil)
                Toggle("Grid", isOn: Binding(get: { session.showsGrid }, set: { session.showsGrid = $0 }))
                    .disabled(session.document == nil)
                Toggle("Guides", isOn: Binding(get: { session.showsGuides }, set: { session.showsGuides = $0 }))
                    .disabled(session.document == nil)
                Toggle("Lock Guides", isOn: Binding(get: { session.locksGuides }, set: { session.locksGuides = $0 }))
                    .disabled(session.document == nil)
            }
            Group {
                Toggle("Snap", isOn: Binding(get: { session.snapEnabled }, set: { session.snapEnabled = $0 }))
                    .disabled(session.document == nil)
                Menu("Snap To") {
                    Toggle("Guides", isOn: Binding(get: { session.snapToGuides }, set: { session.snapToGuides = $0 }))
                    Toggle("Grid", isOn: Binding(get: { session.snapToGrid }, set: { session.snapToGrid = $0 }))
                    Toggle("Layers", isOn: Binding(get: { session.snapToLayers }, set: { session.snapToLayers = $0 }))
                    Toggle("Document Bounds", isOn: Binding(get: { session.snapToDocumentBounds }, set: { session.snapToDocumentBounds = $0 }))
                }
                .disabled(session.document == nil)
                Button("Clear Guides") { session.clearGuides() }
                    .disabled(!session.canClearGuides)
            }
        } label: {
            Image(systemName: "gearshape")
        }
        .help(uiName("Settings"))
        .accessibilityLabel(uiName("Settings"))
        .accessibilityIdentifier("settings")
    }

    /// Canvas backdrop and the language of the interface. Plain menu items, so a click actually changes them.
    private var themeMenu: some View {
        Menu {
            Menu("Background Color") {
                surroundChoice("White", "white")
                surroundChoice("Gray", "gray")
                surroundChoice("Black", "black")
            }
            Menu("Theme Color") {
                chromeChoice("White", "white")
                chromeChoice("Gray", "gray")
                chromeChoice("Black", "black")
            }
            Menu("Language") {
                languageChoice("中文", "zh-Hans")
                languageChoice("English", "en")
            }
        } label: {
            Image(systemName: "paintpalette")
        }
        .help(uiName("Theme"))
        .accessibilityLabel(uiName("Theme"))
        .accessibilityIdentifier("theme")
    }

    private func surroundChoice(_ title: LocalizedStringKey, _ value: String) -> some View {
        Button {
            surroundRaw = value
        } label: {
            if surroundRaw == value { Image(systemName: "checkmark") }
            Text(title)
        }
    }

    private func chromeChoice(_ title: LocalizedStringKey, _ value: String) -> some View {
        Toggle(title, isOn: Binding(get: { chromeRaw == value }, set: { if $0 { chromeRaw = value } }))
    }

    private func languageChoice(_ title: String, _ value: String) -> some View {
        Toggle(isOn: Binding(get: { activeLanguage == value }, set: { chosen in
            guard chosen else { return }
            languageRaw = value
            InterfaceTheme.applyLanguage(value)
        })) {
            Text(title)
        }
    }

    private var activeLanguage: String {
        languageRaw.isEmpty ? InterfaceTheme.startingLanguage : languageRaw
    }

    private var themeLocale: Locale {
        Locale(identifier: languageRaw.isEmpty ? InterfaceTheme.startingLanguage : languageRaw)
    }

    /// The toolbar sparkles button, including what is happening while the drawer is closed.
    private var assistantToolbarHelp: String {
        if assistant.isSending { return uiName("Assistant is working") }
        if !aiPanelShown, assistant.error != nil { return uiName("Assistant needs attention") }
        return uiName(aiPanelShown ? "Hide Assistant" : "Show Assistant")
    }

    private func requestNewCanvas() {
        if let applicationDelegate { Task { await applicationDelegate.projects.newCanvas() } }
        else { session.clearProject() }
    }
    private var toolRail: some View {
        // Scrolls when the window is too short for every tool, rather than pushing the bars above and below away.
        IndicatorlessScrollView {
        VStack(spacing: 10) {
            ForEach(NavigationTool.allCases.filter { $0 != .idle }, id: \.self) { tool in
                let tip = toolTip(for: tool)
                Button { session.selectTool(tool) } label: {
                    Group {
                        if tool == .type { Text("T").font(.system(size: 17, weight: .medium, design: .serif)) }
                        else if tool == .gradient { GradientToolIcon().frame(width: 18, height: 18) }
                        else if tool == .cloneStamp { CloneStampToolIcon().frame(width: 18, height: 18) }
                        else if tool == .lasso, session.lassoKind == .polygonal { PolygonalLassoToolIcon().frame(width: 18, height: 18) }
                        else if tool == .wand, session.wandMode == .object { ObjectSelectionToolIcon().frame(width: 18, height: 18) }
                        // The Marquee's icon follows its shape: a dashed circle in Ellipse mode.
                        else { Image(systemName: tool == .marquee && session.marqueeKind == .ellipse ? "circle.dashed" : session.symbol(for: tool)).font(.system(size: 17)) }
                    }
                    .frame(width: 36, height: 36)
                        .background(session.tool == tool ? Color.primary.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(session.tool == tool ? Color.primary.opacity(0.18) : .clear)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tip.name) (\(tip.shortcut))")
                .onHover { inside in
                    if inside { hoveredTool = tool }
                    else if hoveredTool == tool { hoveredTool = nil }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { toolFrames[tool] = $0 }
                .foregroundStyle(.primary)
                .accessibilityAddTraits(session.tool == tool ? .isSelected : [])
            }
            ColorPaletteControls(session: session).padding(.top, 8)
        }
        .padding(.top, 16).padding(.bottom, 12)
        .frame(width: 56)
        }
        .frame(width: 56)
    }

    /// Name and key of the tool as its button shows it now, including a remapped shortcut.
    private func toolTip(for tool: NavigationTool) -> (name: String, shortcut: String) {
        let (name, definitionTitle): (String, String) = switch tool {
        case .move: ("Move", "Move / Transform tool")
        case .marquee: (session.marqueeKind == .ellipse ? "Elliptical Marquee" : "Rectangular Marquee", "Marquee / cycle shape")
        case .lasso: (session.lassoKind == .polygonal ? "Polygonal Lasso" : "Lasso", "Lasso / cycle mode")
        case .wand: (session.wandMode == .object ? "Object Selection" : "Magic Wand", "Magic")
        case .crop: ("Crop", "Crop tool")
        case .brush: session.brushMode == .erase ? ("Eraser", "Eraser") : ("Brush", "Brush tool")
        case .spotHealing: ("Spot Healing Brush", "Spot Healing")
        case .cloneStamp: ("Clone Stamp", "Clone Stamp")
        case .blur: (session.blurMode.rawValue, "Blur / Smudge / Liquify")
        case .gradient: ("Gradient", "Gradient tool")
        case .shape: (session.shapeKind.rawValue, "Shape tool")
        case .type: ("Type", "Type tool")
        case .eyedropper: ("Eyedropper", "Eyedropper tool")
        case .hand: ("Hand", "Hand tool")
        case .zoom: ("Zoom", "Zoom tool")
        case .idle: ("", "")
        }
        let shortcut = ShortcutDefinition.all.first { !$0.isMenu && $0.title == definitionTitle }
            .map { ShortcutSettings.shared.chord($0).label } ?? ""
        return (uiName(name), shortcut)
    }

    /// The label beside a tool button. The rail is only as wide as the icons, so the name is drawn over the canvas.
    @ViewBuilder private var toolHoverTip: some View {
        if let tool = hoveredTool, let frame = toolFrames[tool] {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global)
                let tip = toolTip(for: tool)
                Color.clear
                    .frame(width: 0, height: 0)
                    .overlay(alignment: .leading) { ToolRailTip(name: tip.name, shortcut: tip.shortcut).fixedSize() }
                    .position(x: frame.maxX - origin.minX + 8, y: frame.midY - origin.minY)
            }
            .allowsHitTesting(false)
        }
    }

    private var welcome: some View {
        NewCanvasSheet(session: session,
            onCreate: { session.createNewProject(width: $0, height: $1, resolution: $2, background: $3) },
            onOpen: { Task { await applicationDelegate?.projects.open() } })
    }
    private var statusBar: some View {
        HStack(spacing: 16) {
            if let document = session.document {
                Text(session.viewport.zoom, format: .percent.precision(.fractionLength(0...1)))
                    .frame(width: 62, alignment: .leading).accessibilityIdentifier("zoomStatus")
                Text("\(document.width) × \(document.height) px").accessibilityIdentifier("canvasDimensions")
                Text("sRGB · Transparent")
            } else { Text("Ready when you are") }
            Spacer()
            if session.showsBusy {
                ProgressView().controlSize(.mini)
                Text("Working…")
            } else if session.isImporting {
                ProgressView().controlSize(.mini)
                Text("Importing images…")
            } else {
                Text(session.tool == .marquee ? (session.marqueeKind == .ellipse ? "Drag an ellipse · Shift add · Option subtract · Shift again mid-drag circle · Drag inside to move · Delete clears · ⌘D deselect" : "Drag a rectangle · Shift add · Option subtract · Shift again mid-drag square · Drag inside to move · ⌘-drag moves pixels · Delete clears · ⌘D deselect") : session.tool == .wand ? (session.wandMode == .object ? "Click an object to select its outline · Tab for Wand · Shift add · Option subtract · Drag inside to move · ⌘-drag moves pixels · Delete clears · ⌘D deselect" : "Click to select similar colors · Tab for Object · Shift add · Option subtract · Drag inside to move · ⌘-drag moves pixels · Delete clears · ⌘D deselect") : session.tool == .lasso ? (session.lassoKind == .freehand ? "Drag to select · Drag inside to move · Shift add · Option subtract · Delete clears · ⌥⌫/⌘⌫ fill · ⌘D deselect" : "Click corners · Click start, double-click or Enter to close · Delete removes corner · Escape cancel") : session.tool == .brush ? (session.brushMode == .erase ? "Drag to erase" : "Drag to paint") + " · [ ] size · Shift-[ ] hardness · 1–0 opacity · Escape cancel · Space to pan" : session.tool == .blur ? (session.blurMode == .blur ? "Drag to soften" : session.blurMode == .smudge ? "Drag to smudge" : "Drag to push pixels") + " · [ ] size · Shift-[ ] hardness · 1–0 strength · Space to pan" : session.tool == .cloneStamp ? "Option-click to set the source · Drag to clone · [ ] size · Shift-[ ] hardness · 1–0 opacity · Space to pan" : session.tool == .spotHealing ? "Drag over blemishes to heal · [ ] size · Shift-[ ] hardness · Escape cancel · Space to pan" : session.tool == .type ? "Drag a text box · Click text to edit · Drag box handles to resize · ⌘Return finish · Escape cancel" : session.tool == .shape ? "Drag to draw a shape on a new layer · Shift \(session.shapeKind == .line ? "45°" : session.shapeKind == .rectangle ? "square" : "circle") · Option from center · Shift-U or Tab for the next shape · Escape cancel · Space to pan" : session.tool == .gradient ? "Drag to draw · Drag ends to adjust · Shift 45° · 1–0 opacity · Enter apply · Escape cancel" : session.tool == .crop ? "Drag to crop · Enter apply · Escape cancel · Space to pan" : session.tool == .move ? "Drag to move · Handles to resize · Circle to rotate · 1–0 layer opacity · Space to pan" : session.tool == .hand ? "Drag to pan · Pinch to zoom" : session.tool == .idle ? "No tool selected · Press a tool's key to pick one · Space to pan" : "Click to zoom in · Option-click to zoom out · Drag right or left to zoom smoothly · Space to pan")
            }
        }
        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
        .padding(.horizontal, 18).frame(height: 30)
        .accessibilityElement(children: .contain)
    }
}

/// A panel's divider that resizes the panel to its right: drag left to widen, right to narrow, within `range`.
private struct PanelResizeEdge: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var startWidth: Double?

    var body: some View {
        Divider().overlay {
            Color.clear.frame(width: 8).contentShape(Rectangle())
                .pointerStyle(.columnResize)
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? width
                        startWidth = start
                        width = min(range.upperBound, max(range.lowerBound, (start - value.translation.width).rounded()))
                    }
                    .onEnded { _ in startWidth = nil })
                .help("Drag to resize the panel")
        }
    }
}

extension View {
    /// Bordered buttons and pop-up menus drawn as capsules throughout the app. Borderless and plain buttons (the tool
    /// rail, the Layers panel footer) have no border to shape, so they're unaffected.
    func roundedControls() -> some View { buttonBorderShape(.capsule) }
}

extension View {
    /// Return or Escape in a property field gives up its focus and hands it back to the canvas, so a tool's key
    /// works straight away instead of typing into the field.
    func releasesFocusOnCommit(_ session: EditorSession) -> some View {
        onSubmit { session.canvasFocusRequest += 1 }
            .onExitCommand { session.canvasFocusRequest += 1 }
    }
}

/// What a field's key monitor reads. The monitor outlives the view value that installed it, so reading the value
/// and applying the step go through here, refreshed on every redraw.
@MainActor final class ArrowStepper {
    var editing = false
    var value: () -> Double = { 0 }
    var change: (Double) -> Void = { _ in }
    private var monitor: Any?

    /// Takes Up and Down while the field holds focus: one step, or ten with Shift.
    func listen(step: Double) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only while a field really is being edited: a field left behind (its tool bar swapped out, say) must not
            // keep taking Up and Down from the canvas, where they nudge the layer.
            guard let self, self.editing, event.keyCode == 126 || event.keyCode == 125,
                  NSApp.keyWindow?.firstResponder is NSTextView else { return event }
            let amount = step * (event.modifierFlags.contains(.shift) ? 10 : 1)
            self.change(self.value() + (event.keyCode == 126 ? amount : -amount))
            return nil
        }
    }
    func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        editing = false
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

/// Name and shortcut shown beside a tool while the pointer is over it.
private struct ToolRailTip: View {
    let name: String
    let shortcut: String
    @AppStorage("interfaceChrome") private var chromeRaw = "gray"
    var body: some View {
        let chrome = InterfaceTheme.chrome(named: chromeRaw)
        HStack(spacing: 8) {
            Text(name)
            Text(shortcut).foregroundStyle(Color.primary.opacity(0.65))
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(white: chrome.ruler), in: RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.16)) }
        .preferredColorScheme(chrome.light ? .light : .dark)
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }
}

/// Up and Down nudge the value in a focused property field, Shift by ten times as much — a text field takes the
/// arrow keys for its insertion point, so they are caught while it holds focus.
private struct ArrowStepping: ViewModifier {
    let step: Double
    let value: () -> Double
    let change: (Double) -> Void
    @FocusState private var focused: Bool
    @State private var stepper = ArrowStepper()
    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onChange(of: focused) { _, editing in
                stepper.editing = editing
                editing ? stepper.listen(step: step) : stepper.stopListening()
            }
            .onDisappear { stepper.stopListening() }
            .onAppear { refresh() }
            .onChange(of: value()) { _, _ in refresh() }
    }
    private func refresh() {
        stepper.value = value
        stepper.change = change
    }
}

extension View {
    /// Up and Down step this field's value; each field's own binding keeps it in range.
    func arrowSteps(_ step: Double = 1, value: @escaping () -> Double, change: @escaping (Double) -> Void) -> some View {
        modifier(ArrowStepping(step: step, value: value, change: change))
    }
    /// The same, for a field that already owns its focus: it says when it is being edited.
    func arrowSteps(_ step: Double = 1, editing: Bool, stepper: ArrowStepper,
                    value: @escaping () -> Double, change: @escaping (Double) -> Void) -> some View {
        onAppear { stepper.value = value; stepper.change = change }
            .onChange(of: value()) { _, _ in stepper.value = value; stepper.change = change }
            .onChange(of: editing) { _, active in
                stepper.editing = active
                stepper.value = value
                stepper.change = change
                active ? stepper.listen(step: step) : stepper.stopListening()
            }
            .onDisappear { stepper.stopListening() }
    }
}

/// Reports the width it is laid out at. Kept out of the editor's body, whose type-checking is already near its limit.
private struct WidthReader: ViewModifier {
    @Binding var width: CGFloat
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
