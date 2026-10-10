import AppKit
import CoreImage
import Vision

nonisolated struct ObjectSelectionSettings: Equatable, Sendable {
    /// Read the visible composite rather than just the active layer.
    var sampleAllLayers = true
    /// Positive values erode the detected mask inward; negative values expand it outward.
    var edgeOffset = 0
}

/// Selects the foreground object under a clicked point using Vision's instance mask,
/// then traces that mask into the document's normal path-based selection.
nonisolated enum ObjectSelection {
    enum Failure: LocalizedError {
        case unsupported
        case render

        var errorDescription: String? {
            switch self {
            case .unsupported: "Object Selection requires macOS 14 or later."
            case .render: "The object mask could not be rendered."
            }
        }
    }

    /// The outline, in the image's top-left pixel coordinates, of the foreground object
    /// at `point`. Nil when the point is outside the image, on background, or no object is found.
    static func select(in image: CGImage, at point: CGPoint, edgeOffset: Int, smoothEdges: Bool) throws -> CGPath? {
        let width = image.width, height = image.height
        let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))
        guard point.x.isFinite, point.y.isFinite, (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        guard #available(macOS 14.0, *) else { throw Failure.unsupported }
        return try selectAvailable(in: image, at: point, edgeOffset: edgeOffset, smoothEdges: smoothEdges)
    }

    @available(macOS 14.0, *)
    private static func selectAvailable(in image: CGImage, at point: CGPoint, edgeOffset: Int, smoothEdges: Bool) throws -> CGPath? {
        // The instance mask is a small grid over the whole picture, so a small object is only a few cells.
        // A first pass finds which object and where it sits; a second pass looks only at that area, and the
        // original pixels there decide where the edge falls.
        let probe = scaledDown(image, maxSide: 1280)
        let probePoint = CGPoint(x: point.x * CGFloat(probe.width) / CGFloat(image.width),
                                 y: point.y * CGFloat(probe.height) / CGFloat(image.height))
        guard let found = try foreground(in: probe, at: probePoint) else { return nil }
        let maskSize = (CVPixelBufferGetWidth(found), CVPixelBufferGetHeight(found))
        let maskBytes = try grayscaleBytes(from: found, width: maskSize.0, height: maskSize.1, interpolation: .none)
        var source = image
        var sourcePoint = point
        var coarse = found
        if let crop = analysisCrop(of: maskBytes, maskWidth: maskSize.0, maskHeight: maskSize.1,
                                   imageWidth: image.width, imageHeight: image.height),
           let cropped = image.cropping(to: crop),
           let closer = try foreground(in: cropped, at: CGPoint(x: point.x - crop.minX, y: point.y - crop.minY)) {
            source = cropped
            sourcePoint = CGPoint(x: point.x - crop.minX, y: point.y - crop.minY)
            coarse = closer
        }
        let rgba = try rgbaBytes(source)
        let soft = try edgePreservedSoftMask(from: coarse, guide: source,
                                              lumaSigma: lumaSigma(rgba: rgba, width: source.width, height: source.height, at: sourcePoint))
        var binary = snappedMask(soft: soft, rgba: rgba, width: source.width, height: source.height)
        binary = adjusted(binaryMask: binary, width: source.width, height: source.height, edgeOffset: edgeOffset)
        let full = placed(binary, localWidth: source.width, localHeight: source.height,
                          originX: source === image ? 0 : Int((point.x - sourcePoint.x).rounded()),
                          originY: source === image ? 0 : Int((point.y - sourcePoint.y).rounded()),
                          width: image.width, height: image.height)
        guard let outline = try MagicWand.outline(of: full, width: image.width, height: image.height) else { return nil }
        return smoothEdges ? smoothed(outline) : outline
    }

    /// Vision's low-resolution instance mask stores 0 for background and instance indices for objects.
    /// A click that lands on background takes the nearest object within a few cells, so a thin edge still selects.
    @available(macOS 14.0, *)
    private static func nearestInstance(in pixelBuffer: CVPixelBuffer, at point: CGPoint, imageSize: CGSize, allowed: IndexSet) throws -> Int? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let bytes = try grayscaleBytes(from: pixelBuffer, width: width, height: height, interpolation: .none)
        let x = min(width - 1, max(0, Int((point.x / imageSize.width) * CGFloat(width))))
        let y = min(height - 1, max(0, Int((point.y / imageSize.height) * CGFloat(height))))
        return nearestInstanceValue(bytes, width: width, height: height, x: x, y: y,
                                    radius: max(4, min(24, width / 48)), allowed: allowed)
    }

    /// The object index under `(x, y)`, or the closest allowed index inside `radius` when that cell is background.
    static func nearestInstanceValue(_ pixels: [UInt8], width: Int, height: Int, x: Int, y: Int, radius: Int, allowed: IndexSet) -> Int? {
        guard width > 0, height > 0, pixels.count == width * height, (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        let here = Int(pixels[y * width + x])
        if here != 0, allowed.contains(here) { return here }
        guard radius > 0 else { return nil }
        var best: (distance: Int, value: Int)?
        for py in max(0, y - radius)...min(height - 1, y + radius) {
            for px in max(0, x - radius)...min(width - 1, x + radius) {
                let value = Int(pixels[py * width + px])
                guard value != 0, allowed.contains(value) else { continue }
                let distance = (px - x) * (px - x) + (py - y) * (py - y)
                if best == nil || distance < best!.distance || (distance == best!.distance && value < best!.value) {
                    best = (distance, value)
                }
            }
        }
        return best?.value
    }

    /// Where a second, closer look should run: the object's box plus room for the background around it.
    /// Nil when that box already covers most of the picture, so a second look would see the same thing.
    static func analysisCrop(of mask: [UInt8], maskWidth: Int, maskHeight: Int, imageWidth: Int, imageHeight: Int) -> CGRect? {
        guard maskWidth > 0, maskHeight > 0, imageWidth > 0, imageHeight > 0, mask.count == maskWidth * maskHeight else { return nil }
        var minX = maskWidth, minY = maskHeight, maxX = -1, maxY = -1
        for index in mask.indices where mask[index] >= 128 {
            let x = index % maskWidth, y = index / maskWidth
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
        guard maxX >= minX else { return nil }
        let image = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let scaleX = CGFloat(imageWidth) / CGFloat(maskWidth)
        let scaleY = CGFloat(imageHeight) / CGFloat(maskHeight)
        var rect = CGRect(x: CGFloat(minX) * scaleX, y: CGFloat(minY) * scaleY,
                          width: CGFloat(maxX - minX + 1) * scaleX, height: CGFloat(maxY - minY + 1) * scaleY)
        let pad = max(48, 0.25 * max(rect.width, rect.height))
        rect = rect.insetBy(dx: -pad, dy: -pad).integral.intersection(image)
        guard rect.width >= 8, rect.height >= 8, rect.width * rect.height <= image.width * image.height * 0.8 else { return nil }
        return rect
    }

    /// Soft mask values are certain well inside and well outside. Along the band between, each pixel joins
    /// whichever side its color is closer to, so the outline follows the picture instead of a fixed cutoff.
    static func snappedMask(soft: [UInt8], rgba: [UInt8], width: Int, height: Int) -> [UInt8] {
        let count = width * height
        guard width > 0, height > 0, soft.count == count, rgba.count == count * 4 else {
            return soft.map { $0 >= 128 ? 255 : 0 }
        }
        var minX = width, minY = height, maxX = -1, maxY = -1
        var inside = (red: 0, green: 0, blue: 0, n: 0)
        for y in 0..<height {
            for x in 0..<width where soft[y * width + x] >= 192 {
                let pixel = (y * width + x) * 4
                inside.red += Int(rgba[pixel])
                inside.green += Int(rgba[pixel + 1])
                inside.blue += Int(rgba[pixel + 2])
                inside.n += 1
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard inside.n >= 16, maxX >= minX else { return soft.map { $0 >= 128 ? 255 : 0 } }
        let box = (minX: max(0, minX - 12), minY: max(0, minY - 12), maxX: min(width - 1, maxX + 12), maxY: min(height - 1, maxY + 12))
        var outside = (red: 0, green: 0, blue: 0, n: 0)
        for y in box.minY...box.maxY {
            for x in box.minX...box.maxX where soft[y * width + x] <= 64 {
                let pixel = (y * width + x) * 4
                outside.red += Int(rgba[pixel])
                outside.green += Int(rgba[pixel + 1])
                outside.blue += Int(rgba[pixel + 2])
                outside.n += 1
            }
        }
        guard outside.n >= 16 else { return soft.map { $0 >= 128 ? 255 : 0 } }
        let inMean = (inside.red / inside.n, inside.green / inside.n, inside.blue / inside.n)
        let outMean = (outside.red / outside.n, outside.green / outside.n, outside.blue / outside.n)
        var mask = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            let value = soft[index]
            if value >= 192 { mask[index] = 255 }
            else if value > 64 {
                let pixel = index * 4
                let toInside = abs(Int(rgba[pixel]) - inMean.0) + abs(Int(rgba[pixel + 1]) - inMean.1) + abs(Int(rgba[pixel + 2]) - inMean.2)
                let toOutside = abs(Int(rgba[pixel]) - outMean.0) + abs(Int(rgba[pixel + 1]) - outMean.1) + abs(Int(rgba[pixel + 2]) - outMean.2)
                if toInside <= toOutside { mask[index] = 255 }
            }
        }
        return mask
    }

    @available(macOS 14.0, *)
    private static func foreground(in image: CGImage, at point: CGPoint) throws -> CVPixelBuffer? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first,
              let instance = try nearestInstance(in: observation.instanceMask, at: point,
                                                 imageSize: CGSize(width: image.width, height: image.height),
                                                 allowed: observation.allInstances) else { return nil }
        return try observation.generateMask(forInstances: IndexSet(integer: instance))
    }

    /// A smaller copy when the picture is large. The first pass only needs to know which object was clicked.
    private static func scaledDown(_ image: CGImage, maxSide: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxSide, maxSide > 0 else { return image }
        let scale = CGFloat(maxSide) / CGFloat(longest)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = try? BrushRaster.context(width: width, height: height, mask: false) else { return image }
        // The shared draw forces nearest-neighbor, which would alias the probe the first pass depends on.
        context.saveGState()
        context.interpolationQuality = .medium
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
        return context.makeImage() ?? image
    }

    /// How tightly color must agree for the edge to follow it: a busy edge stays tight, a flat one may look a little further.
    private static func lumaSigma(rgba: [UInt8], width: Int, height: Int, at point: CGPoint) -> Double {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return 0.06 }
        let x = min(width - 1, max(0, Int(point.x.rounded(.down))))
        let y = min(height - 1, max(0, Int(point.y.rounded(.down))))
        var values: [Double] = []
        for py in max(0, y - 10)...min(height - 1, y + 10) {
            for px in max(0, x - 10)...min(width - 1, x + 10) {
                let pixel = (py * width + px) * 4
                values.append(0.2126 * Double(rgba[pixel]) + 0.7152 * Double(rgba[pixel + 1]) + 0.0722 * Double(rgba[pixel + 2]))
            }
        }
        guard values.count > 1 else { return 0.06 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let spread = min(1, sqrt(variance) / 40)
        return 0.10 - spread * 0.07
    }

    @available(macOS 14.0, *)
    private static func edgePreservedSoftMask(from pixelBuffer: CVPixelBuffer, guide: CGImage, lumaSigma: Double) throws -> [UInt8] {
        let coarse = CIImage(cvPixelBuffer: pixelBuffer)
        let guideImage = CIImage(cgImage: guide)
        let refined: CIImage
        if let filter = CIFilter(name: "CIEdgePreserveUpsampleFilter") {
            filter.setValue(guideImage, forKey: kCIInputImageKey)
            filter.setValue(coarse, forKey: "inputSmallImage")
            filter.setValue(3, forKey: "inputSpatialSigma")
            filter.setValue(lumaSigma, forKey: "inputLumaSigma")
            refined = filter.outputImage ?? coarse
        } else {
            refined = coarse
        }
        return try grayscaleBytes(from: refined, width: guide.width, height: guide.height, interpolation: .high)
    }

    private static func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        guard let data = context.data else { throw Failure.render }
        let source = data.assumingMemoryBound(to: UInt8.self)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let row = image.width * 4
        bytes.withUnsafeMutableBytes { destination in
            guard let base = destination.baseAddress else { return }
            for y in 0..<image.height {
                memcpy(base + y * row, source + y * context.bytesPerRow, row)
            }
        }
        return bytes
    }

    /// Copies a crop's mask back onto the full picture. The origin is the crop's top-left pixel.
    private static func placed(_ local: [UInt8], localWidth: Int, localHeight: Int, originX: Int, originY: Int, width: Int, height: Int) -> [UInt8] {
        guard localWidth > 0, localHeight > 0, local.count == localWidth * localHeight, width > 0, height > 0 else { return local }
        if originX == 0, originY == 0, localWidth == width, localHeight == height { return local }
        var full = [UInt8](repeating: 0, count: width * height)
        for y in 0..<localHeight {
            let destinationY = originY + y
            guard (0..<height).contains(destinationY) else { continue }
            for x in 0..<localWidth {
                let destinationX = originX + x
                guard (0..<width).contains(destinationX) else { continue }
                full[destinationY * width + destinationX] = local[y * localWidth + x]
            }
        }
        return full
    }

    private static func adjusted(binaryMask: [UInt8], width: Int, height: Int, edgeOffset: Int) -> [UInt8] {
        var mask = binaryMask
        let steps = min(10, abs(edgeOffset))
        guard steps > 0, width > 0, height > 0 else { return mask }
        for _ in 0..<steps {
            mask = edgeOffset > 0 ? eroded(mask, width: width, height: height) : dilated(mask, width: width, height: height)
        }
        return mask
    }

    private static func eroded(_ mask: [UInt8], width: Int, height: Int) -> [UInt8] {
        var result = mask
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] != 0 {
                var keep = true
                for ny in max(0, y - 1)...min(height - 1, y + 1) {
                    for nx in max(0, x - 1)...min(width - 1, x + 1) where mask[ny * width + nx] == 0 {
                        keep = false
                    }
                }
                result[y * width + x] = keep ? 255 : 0
            }
        }
        return result
    }

    private static func dilated(_ mask: [UInt8], width: Int, height: Int) -> [UInt8] {
        var result = mask
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] == 0 {
                var fill = false
                for ny in max(0, y - 1)...min(height - 1, y + 1) {
                    for nx in max(0, x - 1)...min(width - 1, x + 1) where mask[ny * width + nx] != 0 {
                        fill = true
                    }
                }
                if fill { result[y * width + x] = 255 }
            }
        }
        return result
    }

    /// Rounds off the one-pixel stair steps created by tracing a binary mask. The winding and
    /// subpath order are preserved, so holes continue to subtract from the selected region.
    private static func smoothed(_ path: CGPath) -> CGPath {
        var subpaths: [[CGPoint]] = []
        var current: [CGPoint] = []
        func finishCurrent() {
            guard current.count >= 3 else { current.removeAll(); return }
            subpaths.append(current)
            current.removeAll()
        }
        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint:
                finishCurrent()
                current = [element.points[0]]
            case .addLineToPoint:
                current.append(element.points[0])
            case .addQuadCurveToPoint:
                current.append(element.points[1])
            case .addCurveToPoint:
                current.append(element.points[2])
            case .closeSubpath:
                finishCurrent()
            @unknown default:
                break
            }
        }
        finishCurrent()

        let result = CGMutablePath()
        for subpath in subpaths {
            let simplified = simplifyClosed(subpath, tolerance: 1.6)
            let points = chaikin(simplified, iterations: 3)
            guard let first = points.first else { continue }
            result.move(to: first)
            result.addLines(between: Array(points.dropFirst()))
            result.closeSubpath()
        }
        return result
    }

    private static func simplifyClosed(_ input: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        var points = input
        if points.first == points.last { points.removeLast() }
        guard points.count >= 4 else { return points }
        // Break at a stable extreme so the open-polyline simplifier can preserve the whole closed contour.
        let start = points.indices.min { lhs, rhs in
            points[lhs].x == points[rhs].x ? points[lhs].y < points[rhs].y : points[lhs].x < points[rhs].x
        } ?? points.startIndex
        let rotated = Array(points[start...]) + Array(points[..<start])
        var open = rotated + [rotated[0]]
        open = simplifyOpen(open, from: 0, to: open.count - 1, tolerance: tolerance)
        if open.first == open.last { open.removeLast() }
        return open.count >= 3 ? open : points
    }

    private static func simplifyOpen(_ points: [CGPoint], from first: Int, to last: Int, tolerance: CGFloat) -> [CGPoint] {
        guard last > first + 1 else { return [points[first], points[last]] }
        var farthest = first + 1
        var greatestDistance: CGFloat = 0
        for index in (first + 1)..<last {
            let distance = perpendicularDistance(points[index], toLineFrom: points[first], to: points[last])
            if distance > greatestDistance {
                greatestDistance = distance
                farthest = index
            }
        }
        guard greatestDistance > tolerance else { return [points[first], points[last]] }
        var left = simplifyOpen(points, from: first, to: farthest, tolerance: tolerance)
        let right = simplifyOpen(points, from: farthest, to: last, tolerance: tolerance)
        left.removeLast()
        return left + right
    }

    private static func perpendicularDistance(_ point: CGPoint, toLineFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        return abs(dy * point.x - dx * point.y + b.x * a.y - b.y * a.x) / length
    }

    private static func chaikin(_ input: [CGPoint], iterations: Int) -> [CGPoint] {
        var points = input
        if points.first == points.last { points.removeLast() }
        guard points.count >= 3 else { return points }
        for _ in 0..<iterations {
            var next: [CGPoint] = []
            next.reserveCapacity(points.count * 2)
            for index in points.indices {
                let a = points[index]
                let b = points[(index + 1) % points.count]
                next.append(CGPoint(x: a.x * 0.75 + b.x * 0.25, y: a.y * 0.75 + b.y * 0.25))
                next.append(CGPoint(x: a.x * 0.25 + b.x * 0.75, y: a.y * 0.25 + b.y * 0.75))
            }
            points = next
        }
        return points
    }

    @available(macOS 14.0, *)
    private static func grayscaleBytes(from pixelBuffer: CVPixelBuffer, width: Int, height: Int,
                                       interpolation: CGInterpolationQuality) throws -> [UInt8] {
        try grayscaleBytes(from: CIImage(cvPixelBuffer: pixelBuffer), width: width, height: height, interpolation: interpolation)
    }

    @available(macOS 14.0, *)
    private static func grayscaleBytes(from image: CIImage, width: Int, height: Int,
                                       interpolation: CGInterpolationQuality) throws -> [UInt8] {
        let renderer = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        guard let cgImage = renderer.createCGImage(image, from: image.extent) else { throw Failure.render }
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        context.saveGState()
        context.interpolationQuality = interpolation
        context.setBlendMode(.copy)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
        guard let data = context.data else { throw Failure.render }
        let source = data.assumingMemoryBound(to: UInt8.self)
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                bytes[y * width + x] = source[y * context.bytesPerRow + x]
            }
        }
        return bytes
    }
}

private nonisolated struct ObjectSelectionJob: @unchecked Sendable {
    let image: CGImage
    let point: CGPoint
    let edgeOffset: Int
    let smoothEdges: Bool
}

private nonisolated struct ObjectSelectionResult: @unchecked Sendable {
    let path: CGPath?
    let error: Error?
}

extension EditorSession {
    /// Object Selection: selects the Vision foreground instance under `point`, read from
    /// the active layer or every visible layer, combined with the current selection by `mode`.
    func selectObject(at point: CGPoint, mode: SelectionMode) async {
        guard canEditSelection, !isProjectBusy, selectionMoveOrigin == nil, let document,
              point.x >= 0, point.y >= 0, point.x < document.size.width, point.y < document.size.height,
              let sample = selectionSample(document, sampleAllLayers: objectSelectionSettings.sampleAllLayers) else { return }
        let job = ObjectSelectionJob(image: sample, point: point,
                                     edgeOffset: min(10, max(-10, objectSelectionSettings.edgeOffset)),
                                     smoothEdges: selectionAntialiased)
        isProjectBusy = true
        let result = await Task.detached(priority: .userInitiated) { () -> ObjectSelectionResult in
            do { return ObjectSelectionResult(path: try ObjectSelection.select(in: job.image, at: job.point, edgeOffset: job.edgeOffset, smoothEdges: job.smoothEdges), error: nil) }
            catch { return ObjectSelectionResult(path: nil, error: error) }
        }.value
        isProjectBusy = false
        if let error = result.error { brushError = error.localizedDescription; return }
        guard self.document?.id == document.id else { return }
        guard let path = result.path else {
            if mode == .replace { deselect() }
            return
        }
        if mode == .replace {
            setSelection(DocumentSelection(path: path, antialiased: selectionAntialiased), name: "Object Selection")
        } else {
            applySelection(path, mode: mode, name: "Object Selection")
        }
    }
}
