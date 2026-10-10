import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// One sample of the session, taken when the user sends. Nothing here is observed, and nothing here writes the document.
struct AIContext: Equatable {
    var document: Document?
    var viewport: Viewport
    var activeTool: String
    var toolMode: String?
    /// Null when nothing is selected. An empty selection is present with `hasMask == false` and no preview.
    var selection: Selection?
    var activeLayer: Layer?
    /// Every selected layer, bottom to top. The primary one is `activeLayer`.
    var selectedLayerIDs: [String]
    /// Every layer, bottom to top.
    var layers: [LayerNode]
    /// The rendered canvas. Reading `compositePNG` encodes it; a send's prompt never does.
    var compositePicture: CanvasPicture?
    /// `.none` encodes from `compositePicture`. `.some` is an explicit string, including null.
    private var compositePNGOverride: String?? = nil
    var compositePNG: String? {
        get {
            if let compositePNGOverride { return compositePNGOverride }
            return compositePicture?.png()
        }
        set { compositePNGOverride = .some(newValue) }
    }
    var compositeError: String?
    /// Small JPEG for the model. Kept out of the JSON so the prompt does not carry the picture twice.
    var modelJPEG: Data? = nil

    static func == (lhs: AIContext, rhs: AIContext) -> Bool {
        lhs.document == rhs.document && lhs.viewport == rhs.viewport && lhs.activeTool == rhs.activeTool
            && lhs.toolMode == rhs.toolMode && lhs.selection == rhs.selection && lhs.activeLayer == rhs.activeLayer
            && lhs.selectedLayerIDs == rhs.selectedLayerIDs && lhs.layers == rhs.layers
            && lhs.compositePicture == rhs.compositePicture && lhs.compositePNGOverride == rhs.compositePNGOverride
            && lhs.compositeError == rhs.compositeError && lhs.modelJPEG == rhs.modelJPEG
    }

    struct Document: Equatable {
        var width: Int
        var height: Int
        var path: String?
        var isModified: Bool
    }
    struct Viewport: Equatable {
        var zoom: Double
        /// Document pixel under the view's top-left corner. `CanvasViewport` stores a pan, not this origin.
        var scrollOrigin: [Double]
    }
    struct Selection: Equatable {
        var bounds: Bounds?
        var hasMask: Bool
        /// Crop of the selection. Reading `previewPNG` encodes it; a send's prompt never does.
        var previewPicture: CanvasPicture?
        /// `.none` encodes from `previewPicture`. `.some` is an explicit string, including null.
        private var previewPNGOverride: String?? = nil
        var previewPNG: String? {
            get {
                if let previewPNGOverride { return previewPNGOverride }
                return previewPicture?.png()
            }
            set { previewPNGOverride = .some(newValue) }
        }

        static func == (lhs: Selection, rhs: Selection) -> Bool {
            lhs.bounds == rhs.bounds && lhs.hasMask == rhs.hasMask && lhs.previewPicture == rhs.previewPicture
                && lhs.previewPNGOverride == rhs.previewPNGOverride
        }
    }
    struct Bounds: Equatable {
        var x, y, width, height: Double
    }
    struct Layer: Equatable {
        var id: String
        var name: String
        var opacity: Double
        var blendMode: String
    }
    struct LayerNode: Equatable {
        var id: String
        var name: String
        var opacity: Double
        var blendMode: String
        var depth: Int
        var visible: Bool
        var kind: String
    }
}

enum AIContextBuilder {
    /// Reads `session` once, then renders. Later edits are invisible until the next send.
    static func capture(_ session: EditorSession) async -> AIContext {
        let document = session.document
        let viewport = ViewportSample(session: session, documentSize: document?.size)
        var context = AIContext(
            document: document.map {
                AIContext.Document(width: $0.width, height: $0.height,
                    path: session.projectURL.map { ($0.path as NSString).abbreviatingWithTildeInPath },
                    isModified: session.isModified)
            },
            viewport: AIContext.Viewport(zoom: Double(viewport.zoom), scrollOrigin: viewport.scrollOrigin),
            activeTool: session.tool.rawValue,
            toolMode: toolMode(of: session),
            selection: nil,
            activeLayer: session.activeLayer.map(layerSummary),
            selectedLayerIDs: selectedIDs(in: session),
            layers: document.map(layerTree) ?? [],
            compositeError: nil)
        if let selection = session.selection {
            context.selection = AIContext.Selection(bounds: bounds(of: selection), hasMask: !selection.isEmpty)
        }
        guard let snapshot = session.projectSnapshot() else { return context }
        let selectionBox = context.selection?.bounds.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        do {
            let raster = try await ImageExporter.shared.render(snapshot)
            // Hold the rendered image. PNG strings are encoded only when something reads them. The prompt
            // clears those strings, so a send pays for the JPEG the model actually sees and not for the PNGs.
            let encoded = await Task.detached {
                let jpeg = AIImageEncoder.jpeg(raster.image, longSide: AIImageEncoder.compositeLongSide)
                let preview: CGImage? = selectionBox.flatMap { box in
                    guard let rect = AIImageEncoder.cropRect(documentBounds: box, imageWidth: raster.image.width, imageHeight: raster.image.height) else { return nil }
                    return raster.image.cropping(to: rect)
                }
                return (raster.image, preview, jpeg)
            }.value
            context.compositePicture = CanvasPicture(image: encoded.0, longSide: AIImageEncoder.compositeLongSide)
            if let preview = encoded.1 {
                context.selection?.previewPicture = CanvasPicture(image: preview, longSide: AIImageEncoder.selectionLongSide)
            }
            context.modelJPEG = encoded.2
        } catch {
            context.compositeError = error.localizedDescription
        }
        return context
    }

    static func json(_ context: AIContext) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(context.encoded()), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// The same sample without the embedded pictures. The chat sends `modelJPEG` beside this text.
    static func promptJSON(_ context: AIContext) -> String {
        var copy = context
        copy.compositePNG = nil
        copy.modelJPEG = nil
        if var selection = copy.selection {
            selection.previewPNG = nil
            copy.selection = selection
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(copy.encoded()), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// A short reading of the same sample, so the numbers the user will ask about are not buried in the PNG.
    static func summary(_ context: AIContext) -> String {
        let layer: String
        if let active = context.activeLayer {
            layer = "\(active.name) (id \(active.id), opacity \(String(format: "%.2f", active.opacity)), blend mode \(active.blendMode))"
        } else {
            layer = "none"
        }
        let selection: String
        if let bounds = context.selection?.bounds {
            selection = "x \(format(bounds.x)), y \(format(bounds.y)), width \(format(bounds.width)), height \(format(bounds.height))"
        } else if context.selection != nil {
            selection = "empty"
        } else {
            selection = "none"
        }
        let percent = context.viewport.zoom * 100
        let origin = context.viewport.scrollOrigin
        return "Active layer: \(layer). Selection: \(selection). Zoom: \(format(context.viewport.zoom)) (\(format(percent))%). Scroll origin: \(origin.map(format).joined(separator: ", "))."
    }

    private static func format(_ value: Double) -> String {
        String(format: "%g", value)
    }

    private static func toolMode(of session: EditorSession) -> String? {
        switch session.tool {
        case .brush: session.brushMode.rawValue
        case .blur: session.blurMode.rawValue
        case .marquee: session.marqueeKind.rawValue
        case .lasso: session.lassoKind.rawValue
        case .wand: session.wandMode.rawValue
        case .shape: session.shapeKind.rawValue
        case .spotHealing: session.spotHealingMode.rawValue
        default: nil
        }
    }

    private static func layerSummary(_ layer: ImageLayer) -> AIContext.Layer {
        AIContext.Layer(id: layer.id.uuidString, name: layer.name, opacity: layer.opacity, blendMode: layer.blendMode.rawValue)
    }

    private static func selectedIDs(in session: EditorSession) -> [String] {
        (session.document?.layers ?? []).filter { session.selectedLayerIDs.contains($0.id) }.map { $0.id.uuidString }
    }

    private static func layerTree(_ document: CanvasDocument) -> [AIContext.LayerNode] {
        let parents = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0.parentID) })
        return document.layers.map { layer in
            AIContext.LayerNode(id: layer.id.uuidString, name: layer.name, opacity: layer.opacity,
                blendMode: layer.blendMode.rawValue, depth: depth(of: layer.id, parents: parents),
                visible: layer.isVisible, kind: kind(of: layer))
        }
    }

    private static func depth(of id: UUID, parents: [UUID: UUID?]) -> Int {
        var depth = 0
        var current = parents[id] ?? nil
        while let parent = current, depth < 64 {
            depth += 1
            current = parents[parent] ?? nil
        }
        return depth
    }

    private static func kind(of layer: ImageLayer) -> String {
        if layer.isGroup { return "group" }
        if layer.adjustment != nil { return "adjustment" }
        if layer.text != nil { return "text" }
        if layer.shape != nil { return "shape" }
        return "pixels"
    }

    private static func bounds(of selection: DocumentSelection) -> AIContext.Bounds? {
        let box = selection.path.boundingBoxOfPath
        guard !selection.isEmpty, !box.isNull, !box.isInfinite, box.width > 0, box.height > 0 else { return nil }
        return AIContext.Bounds(x: box.minX, y: box.minY, width: box.width, height: box.height)
    }

    /// Zoom and the document point at the view's top-left, copied out before the render await.
    private struct ViewportSample {
        var zoom: CGFloat
        var scrollOrigin: [Double]
        init(session: EditorSession, documentSize: CGSize?) {
            zoom = session.viewport.zoom
            guard let documentSize else { scrollOrigin = [0, 0]; return }
            let origin = session.viewport.documentPoint(from: .zero, documentSize: documentSize)
            scrollOrigin = [Double(origin.x), Double(origin.y)]
        }
    }
}

extension AIContext {
    fileprivate func encoded() -> Payload { Payload(self) }

    fileprivate struct Payload: Encodable {
        var document: Document?
        var viewport: Viewport
        var activeTool: String
        var toolMode: String?
        var selection: Selection?
        var activeLayer: Layer?
        var selectedLayerIDs: [String]
        var layers: [LayerNode]
        var compositePNG: String?
        var compositeError: String?

        struct Document: Encodable { var width: Int; var height: Int; var path: String?; var isModified: Bool }
        struct Viewport: Encodable { var zoom: Double; var scrollOrigin: [Double] }
        struct Selection: Encodable { var bounds: Bounds?; var hasMask: Bool; var previewPNG: String? }
        struct Bounds: Encodable { var x, y, width, height: Double }
        struct Layer: Encodable { var id, name, blendMode: String; var opacity: Double }
        struct LayerNode: Encodable { var id, name, blendMode, kind: String; var opacity: Double; var depth: Int; var visible: Bool }

        init(_ context: AIContext) {
            document = context.document.map { Document(width: $0.width, height: $0.height, path: $0.path, isModified: $0.isModified) }
            viewport = Viewport(zoom: context.viewport.zoom, scrollOrigin: context.viewport.scrollOrigin)
            activeTool = context.activeTool
            toolMode = context.toolMode
            selection = context.selection.map { Selection(bounds: $0.bounds.map { Bounds(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }, hasMask: $0.hasMask, previewPNG: $0.previewPNG) }
            activeLayer = context.activeLayer.map { Layer(id: $0.id, name: $0.name, blendMode: $0.blendMode, opacity: $0.opacity) }
            selectedLayerIDs = context.selectedLayerIDs
            layers = context.layers.map { LayerNode(id: $0.id, name: $0.name, blendMode: $0.blendMode, kind: $0.kind, opacity: $0.opacity, depth: $0.depth, visible: $0.visible) }
            compositePNG = context.compositePNG
            compositeError = context.compositeError
        }
    }
}

/// A rendered image whose PNG is produced on read, once.
final class CanvasPicture: Equatable, @unchecked Sendable {
    let image: CGImage
    let longSide: CGFloat
    private var cached: String?
    private var encoded = false
    init(image: CGImage, longSide: CGFloat) {
        self.image = image
        self.longSide = longSide
    }
    var didEncodePNG: Bool { encoded }
    func png() -> String? {
        if encoded { return cached }
        encoded = true
        cached = AIImageEncoder.pngBase64(image, longSide: longSide)
        return cached
    }
    static func == (lhs: CanvasPicture, rhs: CanvasPicture) -> Bool { lhs === rhs }
}

/// PNGs for the prompt. The composite's long side stays at or under 1,024; a selection crop stays at or under 768.
nonisolated enum AIImageEncoder {
    static let compositeLongSide: CGFloat = 1024
    static let selectionLongSide: CGFloat = 768

    static func encode(_ image: CGImage, selection: CGRect?) -> (composite: String?, selection: String?) {
        let composite = pngBase64(image, longSide: compositeLongSide)
        guard let selection, let rect = cropRect(documentBounds: selection, imageWidth: image.width, imageHeight: image.height),
              let cropped = image.cropping(to: rect) else { return (composite, nil) }
        return (composite, pngBase64(cropped, longSide: selectionLongSide))
    }

    /// `CGImage.cropping` measures from the lower-left. Document pixels start at the top-left, which is how the
    /// exporter draws, so the crop is flipped on y before it is passed to Core Graphics.
    static func cropRect(documentBounds: CGRect, imageWidth: Int, imageHeight: Int) -> CGRect? {
        let canvas = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let bounds = documentBounds.integral.intersection(canvas)
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }
        return CGRect(x: bounds.minX, y: CGFloat(imageHeight) - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    /// Test instrumentation. A send used to encode PNGs that the prompt then threw away.
    nonisolated(unsafe) static var pngBase64Calls = 0

    static func pngBase64(_ image: CGImage, longSide: CGFloat) -> String? {
        pngBase64Calls += 1
        guard let scaled = scale(image, longSide: longSide), let data = pngData(scaled) else { return nil }
        return data.base64EncodedString()
    }

    /// The picture sent back after a change. Flattened on white, long side at or under `longSide`.
    static func jpeg(_ image: CGImage, longSide: CGFloat) -> Data? {
        guard let scaled = scale(image, longSide: longSide) else { return nil }
        let width = scaled.width, height = scaled.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(scaled, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let flat = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func scale(_ image: CGImage, longSide: CGFloat) -> CGImage? {
        let factor = min(1, longSide / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * factor).rounded()))
        let height = max(1, Int((CGFloat(image.height) * factor).rounded()))
        if width == image.width, height == image.height { return image }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
