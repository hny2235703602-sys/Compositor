import AppKit
import ImageIO
import Testing
@testable import Compositor

@MainActor
struct AIContextTests {
    @Test func captureReadsTheSessionAndDoesNotEditIt() async throws {
        let session = EditorSession()
        session.createDocument(width: 120, height: 80, emptyLayer: true)
        let child = try #require(session.activeLayer)
        var folder = ImageLayer(name: "Group", blankSize: CGSize(width: 120, height: 80))
        folder.isGroup = true
        session.document?.layers.insert(folder, at: 0)
        session.document?.layers[1].parentID = folder.id
        session.setLayerOpacity(0.6)
        session.setLayerBlendMode(.multiply)
        session.selectTool(.brush)
        session.brushMode = .erase
        session.projectURL = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/ai-demo.comp")
        session.viewport.resize(to: CGSize(width: 800, height: 600), backingScale: 2, documentSize: session.document?.size)
        session.zoom(to: 2)
        let box = CGRect(x: 10, y: 20, width: 30, height: 40)
        session.document?.selection = DocumentSelection(path: CGPath(rect: box, transform: nil))

        let undo = session.history.undoCount
        let opacity = session.activeLayer?.opacity
        let context = await AIContextBuilder.capture(session)

        #expect(session.history.undoCount == undo)
        #expect(session.activeLayer?.opacity == opacity)
        #expect(session.document?.selection?.path.boundingBoxOfPath == box)

        let document = try #require(context.document)
        #expect(document.width == 120 && document.height == 80)
        #expect(document.path == "~/Desktop/ai-demo.comp")
        #expect(document.isModified)
        #expect(context.viewport.zoom == 2)
        let origin = session.viewport.documentPoint(from: .zero, documentSize: CGSize(width: 120, height: 80))
        #expect(context.viewport.scrollOrigin == [Double(origin.x), Double(origin.y)])
        #expect(context.activeTool == "brush")
        #expect(context.toolMode == "Erase")

        let active = try #require(context.activeLayer)
        #expect(active.id == child.id.uuidString)
        #expect(active.name == "Layer 1")
        #expect(active.opacity == 0.6)
        #expect(active.blendMode == "Multiply")
        #expect(context.selectedLayerIDs == [child.id.uuidString])

        #expect(context.layers.map(\.name) == ["Group", "Layer 1"])
        #expect(context.layers.map(\.depth) == [0, 1])
        #expect(context.layers.map(\.kind) == ["group", "pixels"])
        #expect(context.layers.map(\.visible) == [true, true])

        let selection = try #require(context.selection)
        let bounds = try #require(selection.bounds)
        #expect(selection.hasMask)
        #expect(bounds.x == 10 && bounds.y == 20 && bounds.width == 30 && bounds.height == 40)
        let compositeSide = try longSide(try #require(context.compositePNG))
        let previewSide = try longSide(try #require(selection.previewPNG))
        #expect(compositeSide <= 1024)
        #expect(previewSide <= 768)

        let summary = AIContextBuilder.summary(context)
        #expect(summary.contains("Layer 1"))
        #expect(summary.contains("200%"))
        let json = AIContextBuilder.json(context)
        #expect(json.contains("\"compositePNG\""))
        #expect(json.contains("\"scrollOrigin\""))
    }

    @Test func emptySelectionOmitsTheCrop() async throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 30, emptyLayer: true)
        let open = await AIContextBuilder.capture(session)
        #expect(open.selection == nil)
        #expect(!AIContextBuilder.json(open).contains("previewPNG"))

        session.document?.selection = DocumentSelection(path: CGMutablePath())
        let empty = await AIContextBuilder.capture(session)
        let selection = try #require(empty.selection)
        #expect(!selection.hasMask)
        #expect(selection.bounds == nil)
        #expect(selection.previewPNG == nil)
        #expect(!AIContextBuilder.json(empty).contains("previewPNG"))
    }

    @Test func cropRectUsesTheImageLowerLeft() {
        let rect = AIImageEncoder.cropRect(documentBounds: CGRect(x: 10, y: 20, width: 30, height: 40), imageWidth: 120, imageHeight: 100)
        #expect(rect == CGRect(x: 10, y: 40, width: 30, height: 40))
        #expect(AIImageEncoder.cropRect(documentBounds: CGRect(x: 0, y: 0, width: 0, height: 10), imageWidth: 20, imageHeight: 20) == nil)
    }

    @Test func scaleKeepsTheLongSideUnderTheCap() throws {
        let wide = try solid(width: 2000, height: 500)
        let scaled = try #require(AIImageEncoder.scale(wide, longSide: 1024))
        #expect(scaled.width == 1024)
        #expect(scaled.height == 256)
        let small = try solid(width: 30, height: 20)
        let same = try #require(AIImageEncoder.scale(small, longSide: 1024))
        #expect(same.width == 30 && same.height == 20)
    }

    @Test func completionsURLAcceptsABaseOrAFullPath() {
        #expect(OpenAICompatibleProvider.completionsURL(from: "https://api.openai.com/v1")?.absoluteString
                == "https://api.openai.com/v1/chat/completions")
        #expect(OpenAICompatibleProvider.completionsURL(from: "https://api.openai.com/v1/")?.absoluteString
                == "https://api.openai.com/v1/chat/completions")
        #expect(OpenAICompatibleProvider.completionsURL(from: "https://example.com/v1/chat/completions")?.absoluteString
                == "https://example.com/v1/chat/completions")
        #expect(OpenAICompatibleProvider.completionsURL(from: "https://zhongkey.com")?.absoluteString
                == "https://zhongkey.com/v1/chat/completions")
        #expect(OpenAICompatibleProvider.completionsURL(from: "  ") == nil)
        #expect(OpenAICompatibleProvider.redact("rejected sk-test", key: "sk-test") == "rejected ••••")
    }

    @Test func modelListURLAndNames() async throws {
        #expect(AIModelCatalog.modelsURL(from: "https://api.openai.com/v1")?.absoluteString
                == "https://api.openai.com/v1/models")
        #expect(AIModelCatalog.modelsURL(from: "https://api.openai.com/v1/chat/completions")?.absoluteString
                == "https://api.openai.com/v1/models")
        #expect(AIModelCatalog.modelsURL(from: "https://example.com/v1/models/")?.absoluteString
                == "https://example.com/v1/models")
        #expect(AIModelCatalog.modelsURL(from: "https://zhongkey.com/")?.absoluteString
                == "https://zhongkey.com/v1/models")
        #expect(AIModelCatalog.modelsURL(from: "file:///etc/passwd") == nil)
        #expect(AIModelCatalog.pageError(in: Data("<!doctype html><title>New API</title>".utf8)) != nil)
        let listed = AIModelCatalog.ids(in: Data(#"{"data":[{"id":"gpt-4o"},{"id":"gpt-4o"},{"id":"gpt-4o-mini"}]}"#.utf8))
        #expect(listed == ["gpt-4o", "gpt-4o-mini"])
        let named = AIModelCatalog.ids(in: Data(#"{"models":["b","a"]}"#.utf8))
        #expect(named == ["a", "b"])
        let saved = "sk-unit-test-key-value"
        let testAccount = "ai.openai.apiKey.unit-test"
        defer { AICredentials.remove(account: testAccount) }
        try AICredentials.write(saved, account: testAccount)
        #expect(AICredentials.read(account: testAccount) == saved)
        let missing = await AIModelCatalog.fetch(endpoint: "https://api.openai.com/v1", apiKey: " ")
        #expect(missing.models.isEmpty)
        #expect(missing.error?.contains("API") == true)
    }

    private func longSide(_ base64: String) throws -> Int {
        let data = try #require(Data(base64Encoded: base64))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return max(image.width, image.height)
    }

    private func solid(width: Int, height: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
