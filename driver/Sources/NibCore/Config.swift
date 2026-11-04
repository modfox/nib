import Foundation

/// User-configurable driver settings, persisted to ~/.config/nib/config.json.
/// All fields have defaults and decoding tolerates missing keys (forward-compatible).
public struct NibConfig: Codable, Sendable, Equatable {
    public var touchEnabled: Bool = true
    public var palmRejection: Bool = true
    public var tapToClick: Bool = true
    public var threeFingerSwipe: Bool = true
    public var scrollGain: Double = 0.35
    /// nil = follow the system "natural scrolling" setting; true/false = explicit override.
    public var naturalScrolling: Bool? = nil
    public var lowerBarrel: PenButtonAction = .rightClick
    public var upperBarrel: PenButtonAction = .middleClick
    public var pressureCurve: PressureCurve = .linear

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let def = NibConfig()
        touchEnabled     = try c.decodeIfPresent(Bool.self, forKey: .touchEnabled) ?? def.touchEnabled
        palmRejection    = try c.decodeIfPresent(Bool.self, forKey: .palmRejection) ?? def.palmRejection
        tapToClick       = try c.decodeIfPresent(Bool.self, forKey: .tapToClick) ?? def.tapToClick
        threeFingerSwipe = try c.decodeIfPresent(Bool.self, forKey: .threeFingerSwipe) ?? def.threeFingerSwipe
        scrollGain       = try c.decodeIfPresent(Double.self, forKey: .scrollGain) ?? def.scrollGain
        naturalScrolling = try c.decodeIfPresent(Bool.self, forKey: .naturalScrolling)
        lowerBarrel      = try c.decodeIfPresent(PenButtonAction.self, forKey: .lowerBarrel) ?? def.lowerBarrel
        upperBarrel      = try c.decodeIfPresent(PenButtonAction.self, forKey: .upperBarrel) ?? def.upperBarrel
        pressureCurve    = try c.decodeIfPresent(PressureCurve.self, forKey: .pressureCurve) ?? def.pressureCurve
    }

    /// Natural scrolling to apply: the explicit override if set, else the system setting
    /// (`com.apple.swipescrolldirection`, read from `defaults`; macOS defaults to true).
    public func effectiveNaturalScrolling(defaults: UserDefaults = .standard) -> Bool {
        if let v = naturalScrolling { return v }
        if defaults.object(forKey: "com.apple.swipescrolldirection") != nil {
            return defaults.bool(forKey: "com.apple.swipescrolldirection")
        }
        return true
    }

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/nib/config.json")
    }

    public static func load() -> NibConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let cfg = try? JSONDecoder().decode(NibConfig.self, from: data)
        else { return NibConfig() }
        return cfg
    }

    public func save() throws {
        try FileManager.default.createDirectory(
            at: NibConfig.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: NibConfig.fileURL)
    }
}
