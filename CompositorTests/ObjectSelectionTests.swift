import CoreGraphics
import Testing
@testable import Compositor

struct ObjectSelectionTests {
    @Test func aClickOnBackgroundTakesTheNearestObject() {
        var pixels = [UInt8](repeating: 0, count: 25)
        pixels[4 * 5 + 4] = 2
        let allowed: IndexSet = [2]
        #expect(ObjectSelection.nearestInstanceValue(pixels, width: 5, height: 5, x: 4, y: 4, radius: 2, allowed: allowed) == 2)
        #expect(ObjectSelection.nearestInstanceValue(pixels, width: 5, height: 5, x: 0, y: 0, radius: 6, allowed: allowed) == 2)
        #expect(ObjectSelection.nearestInstanceValue(pixels, width: 5, height: 5, x: 0, y: 0, radius: 1, allowed: allowed) == nil)
        #expect(ObjectSelection.nearestInstanceValue(pixels, width: 5, height: 5, x: 0, y: 0, radius: 6, allowed: [7]) == nil)
    }

    @Test func theCloserLookCoversTheObjectAndSkipsAPictureThatIsAlreadyTheObject() {
        var mask = [UInt8](repeating: 0, count: 100)
        mask[2 * 10 + 2] = 255
        let crop = ObjectSelection.analysisCrop(of: mask, maskWidth: 10, maskHeight: 10, imageWidth: 1000, imageHeight: 1000)
        #expect(crop?.contains(CGPoint(x: 250, y: 250)) == true)
        #expect((crop?.width ?? 1000) < 500 && (crop?.height ?? 1000) < 500)
        let filled = [UInt8](repeating: 255, count: 100)
        #expect(ObjectSelection.analysisCrop(of: filled, maskWidth: 10, maskHeight: 10, imageWidth: 100, imageHeight: 100) == nil)
    }

    @Test func theEdgeFollowsColorThroughTheUncertainBand() {
        let width = 8, height = 8
        var soft = [UInt8](repeating: 0, count: width * height)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let red = x == 5 || x <= 2
                soft[index] = x <= 2 ? 255 : (x >= 5 ? 100 : 0)
                rgba[index * 4] = red ? 200 : 20
                rgba[index * 4 + 3] = 255
            }
        }
        let mask = ObjectSelection.snappedMask(soft: soft, rgba: rgba, width: width, height: height)
        #expect(mask[5] == 255, "a red pixel in the uncertain band joins the red object")
        #expect(mask[6] == 0, "a blue pixel in the uncertain band stays with the background")
        #expect(mask[0] == 255 && mask[3] == 0)
    }
}
