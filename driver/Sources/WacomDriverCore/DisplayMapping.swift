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
        let fx = clamp((Double(x) - xMin) / (xMax - xMin))
        let fy = clamp((Double(y) - yMin) / (yMax - yMin))
        return CGPoint(
            x: targetBounds.minX + fx * targetBounds.width,
            y: targetBounds.minY + fy * targetBounds.height
        )
    }

    private func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
}

/// Calibration constants (the raw pen active-range), persisted to disk so `run` picks
/// them up. Bounds are recomputed live from the Cintiq display each launch.
public struct Calibration: Codable, Sendable {
    public var xMin, xMax, yMin, yMax: Double
    public init(xMin: Double, xMax: Double, yMin: Double, yMax: Double) {
        self.xMin = xMin; self.xMax = xMax; self.yMin = yMin; self.yMax = yMax
    }

    public static var fileURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/wacomdriver", isDirectory: true)
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
