import CoreGraphics

/// Finds the pen display's own screen so the pen maps 1:1 onto it.
///
/// Matching order: EDID vendor+model from the profile, then the panel's *native* pixel
/// size. The native size is read from the display's native mode rather than the current
/// one, so a scaled mode (e.g. "looks like 2560×1440", backed by 5120×2880) still matches.
public enum DisplayLocator {
    /// What we know about one active display (plain data, so selection is unit-testable).
    public struct Candidate: Equatable, Sendable {
        public var id: CGDirectDisplayID
        public var vendor: UInt32
        public var model: UInt32
        public var nativePixelSize: CGSize?
        public init(id: CGDirectDisplayID, vendor: UInt32, model: UInt32, nativePixelSize: CGSize?) {
            self.id = id; self.vendor = vendor; self.model = model; self.nativePixelSize = nativePixelSize
        }
    }

    /// Pick the tablet's display among `candidates`, or nil if none matches.
    public static func choose(_ candidates: [Candidate], for profile: DeviceProfile) -> CGDirectDisplayID? {
        if let v = profile.displayVendor, let m = profile.displayModel,
           let hit = candidates.first(where: { $0.vendor == v && $0.model == m }) {
            return hit.id
        }
        guard let panel = profile.panelSize else { return nil }
        return candidates.first(where: { $0.nativePixelSize == panel })?.id
    }

    /// The tablet's display among the currently active displays, or nil.
    public static func tabletDisplayID(for profile: DeviceProfile) -> CGDirectDisplayID? {
        choose(activeCandidates(), for: profile)
    }

    public static func activeCandidates() -> [Candidate] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map {
            Candidate(id: $0, vendor: CGDisplayVendorNumber($0), model: CGDisplayModelNumber($0),
                      nativePixelSize: nativePixelSize($0))
        }
    }

    /// Pixel size of the display's native mode (IOKit kDisplayModeNativeFlag), falling back
    /// to the current mode's pixel size if no mode is flagged native.
    static func nativePixelSize(_ id: CGDirectDisplayID) -> CGSize? {
        let kDisplayModeNativeFlag: UInt32 = 0x0200_0000
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        if let modes = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode],
           let native = modes.first(where: { $0.ioFlags & kDisplayModeNativeFlag != 0 }) {
            return CGSize(width: native.pixelWidth, height: native.pixelHeight)
        }
        guard let cur = CGDisplayCopyDisplayMode(id) else { return nil }
        return CGSize(width: cur.pixelWidth, height: cur.pixelHeight)
    }
}
