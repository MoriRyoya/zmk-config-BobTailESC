import Foundation
import CoreGraphics

// swiftc tools/macos/BobTailBar/OverlayGeometry.swift tools/macos/tests/OverlayGeometryTests.swift -o /tmp/bobtail-overlay-tests
@main
enum OverlayGeometryTests {
    static func near(_ actual: CGFloat, _ expected: CGFloat, _ message: String) {
        precondition(abs(actual - expected) < 0.000001, "\(message): \(actual) != \(expected)")
    }

    static func main() {
        let start = CGRect(x: 100, y: 200, width: 820, height: 320)
        for corner in OverlayResizeCorner.allCases {
            let outward = CGSize(width: corner.isLeft ? -100 : 100,
                                 height: corner.isTop ? 70 : -70)
            let resized = OverlayResizeGeometry.frame(from: start, delta: outward, corner: corner,
                                                       preservingAspectRatio: false)
            near(resized.width, 920, "width grows at \(corner)")
            near(resized.height, 390, "height grows at \(corner)")
            near(corner.isLeft ? resized.maxX : resized.minX,
                 corner.isLeft ? start.maxX : start.minX, "opposite x is anchored")
            near(corner.isTop ? resized.minY : resized.maxY,
                 corner.isTop ? start.minY : start.maxY, "opposite y is anchored")

            for amount in [-10000.0, -200.0, 0.0, 100.0, 10000.0] {
                // Pure horizontal, pure vertical and diagonal drags all preserve ratio.
                for delta in [CGSize(width: amount, height: 0),
                              CGSize(width: 0, height: amount),
                              CGSize(width: amount, height: amount)] {
                    let locked = OverlayResizeGeometry.frame(from: start, delta: delta, corner: corner,
                                                              preservingAspectRatio: true)
                    near(locked.width / locked.height, start.width / start.height, "ratio remains exact")
                    precondition(locked.width >= 420 && locked.width <= 1400)
                    precondition(locked.height >= 180 && locked.height <= 900)
                    near(corner.isLeft ? locked.maxX : locked.minX,
                         corner.isLeft ? start.maxX : start.minX, "locked opposite x")
                    near(corner.isTop ? locked.minY : locked.maxY,
                         corner.isTop ? start.minY : start.maxY, "locked opposite y")
                }
            }
            let tiny = OverlayResizeGeometry.frame(from: start,
                delta: CGSize(width: corner.isLeft ? 10000 : -10000,
                              height: corner.isTop ? -10000 : 10000),
                corner: corner, preservingAspectRatio: false)
            precondition(tiny.size == OverlayResizeGeometry.minimumSize)
            let huge = OverlayResizeGeometry.frame(from: start,
                delta: CGSize(width: corner.isLeft ? -10000 : 10000,
                              height: corner.isTop ? 10000 : -10000),
                corner: corner, preservingAspectRatio: false)
            precondition(huge.size == OverlayResizeGeometry.maximumSize)

            let grip = corner.gripRect(in: start, size: 20)
            precondition(start.contains(grip))
            precondition(grip.contains(CGPoint(x: corner.isLeft ? start.minX + 5 : start.maxX - 5,
                                              y: corner.isTop ? start.minY + 5 : start.maxY - 5)))
            precondition(!grip.contains(CGPoint(x: start.midX, y: start.midY)))
        }
        print("Overlay geometry: 4 corners, anchored bounds, 60 ratio drags, and grip regions passed.")
    }
}
