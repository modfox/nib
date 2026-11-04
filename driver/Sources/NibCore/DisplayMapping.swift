import Foundation
import CoreGraphics

/// Maps tablet logical coordinates to a screen rectangle (in global display points).
///
/// The pen's *active glass area* usually corresponds to a sub-range of the full logical
/// coordinate range, and may be slightly offset. `xMin...xMax` / `yMin...yMax` describe
/// the raw pen range that spans `targetBounds`; a fresh calibration overwrites them.
public struct DisplayMapping: Sendable {
    public var targetBounds: CGRect
    public var xMin: Double
    public var xMax: Double
    public var yMin: Double
    public var yMax: Double

    public init(targetBounds: CGRect,
                xMin: Double = 0, xMax: Double = Double(PenSample.xLogicalMax),
                yMin: Double = 0, yMax: Double = Double(PenSample.yLogicalMax)) {
        self.targetBounds = targetBounds
        self.xMin = xMin; self.xMax = xMax
        self.yMin = yMin; self.yMax = yMax
    }

    /// Map raw tablet (x, y) to a global display point.
    public func point(x: Int, y: Int) -> CGPoint {
        let fx = fraction(Double(x), xMin, xMax)
        let fy = fraction(Double(y), yMin, yMax)
        return CGPoint(
            x: targetBounds.minX + fx * targetBounds.width,
            y: targetBounds.minY + fy * targetBounds.height
        )
    }

    /// Position of `v` within `lo...hi`, clamped to [0,1]. A degenerate (zero-width or
    /// non-finite) range maps to 0 rather than producing NaN.
    private func fraction(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        let span = hi - lo
        guard span != 0, span.isFinite else { return 0 }
        let f = (v - lo) / span
        return f.isFinite ? min(1, max(0, f)) : 0
    }
}

/// Calibration constants (the raw pen active-range), persisted to disk so `run` picks
/// them up. Bounds are recomputed live from the Cintiq display each launch.
public struct Calibration: Codable, Sendable, Equatable {
    public var xMin, xMax, yMin, yMax: Double
    public init(xMin: Double, xMax: Double, yMin: Double, yMax: Double) {
        self.xMin = xMin; self.xMax = xMax; self.yMin = yMin; self.yMax = yMax
    }

    public static var fileURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/nib", isDirectory: true)
        return dir.appendingPathComponent("calibration.json")
    }

    public func save() throws {
        try FileManager.default.createDirectory(
            at: Calibration.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Calibration.fileURL)
    }

    public static func load() -> Calibration? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Calibration.self, from: data)
    }

    public func apply(to m: inout DisplayMapping) {
        m.xMin = xMin; m.xMax = xMax; m.yMin = yMin; m.yMax = yMax
    }
}
