import Foundation
import CoreGraphics

/// Corner names follow the screen, even though the HUD uses a flipped coordinate system.
enum OverlayResizeCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }

    func gripRect(in bounds: CGRect, size: CGFloat) -> CGRect {
        CGRect(x: isLeft ? bounds.minX : bounds.maxX - size,
               y: isTop ? bounds.minY : bounds.maxY - size,
               width: size, height: size)
    }
}

enum OverlayResizeGeometry {
    static let minimumSize = CGSize(width: 420, height: 180)
    static let maximumSize = CGSize(width: 1400, height: 900)

    /// `delta` is in screen coordinates (positive y points up). The opposite corner
    /// remains stationary, including when either dimension reaches its size limit.
    static func frame(from start: CGRect, delta: CGSize, corner: OverlayResizeCorner,
                      preservingAspectRatio: Bool) -> CGRect {
        guard start.width > 0, start.height > 0 else { return start }
        let deltaWidth = corner.isLeft ? -delta.width : delta.width
        let deltaHeight = corner.isTop ? delta.height : -delta.height
        let size: CGSize
        if preservingAspectRatio {
            // Let a horizontal OR vertical drag control the size. Scale both axes
            // together before applying limits so clamping cannot distort the ratio.
            let widthChange = deltaWidth / start.width
            let heightChange = deltaHeight / start.height
            let proposedScale = 1 + (abs(widthChange) >= abs(heightChange) ? widthChange : heightChange)
            let minimumScale = max(minimumSize.width / start.width, minimumSize.height / start.height)
            let maximumScale = min(maximumSize.width / start.width, maximumSize.height / start.height)
            let scale = min(maximumScale, max(minimumScale, proposedScale))
            size = CGSize(width: start.width * scale, height: start.height * scale)
        } else {
            size = CGSize(width: min(maximumSize.width, max(minimumSize.width, (start.width + deltaWidth).rounded())),
                          height: min(maximumSize.height, max(minimumSize.height, (start.height + deltaHeight).rounded())))
        }
        return CGRect(x: corner.isLeft ? start.maxX - size.width : start.minX,
                      y: corner.isTop ? start.minY : start.maxY - size.height,
                      width: size.width, height: size.height)
    }
}
