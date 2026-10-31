import Foundation

/// Upright, white-balanced linear RGB. Values above display white are retained.
/// This is demosaiced RGB, not sensor mosaic data or newly captured scene detail.
public struct HDRImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let rgb: [Float]

    public init(width: Int, height: Int, rgb: [Float]) throws {
        guard width > 0, height > 0, width <= 100_000, height <= 100_000,
              width <= Int.max / height / 3, rgb.count == width * height * 3,
              rgb.allSatisfy({ $0.isFinite }) else { throw HDRError.invalidImage }
        self.width = width; self.height = height; self.rgb = rgb
    }
}

public enum HDRError: Error, LocalizedError {
    case invalidImage, invalidSettings, unsupportedImage, invalidProject(String)
    public var errorDescription: String? {
        switch self {
        case .invalidImage: return "The HDR image has invalid dimensions or pixel values."
        case .invalidSettings: return "The HDR settings are outside their supported range."
        case .unsupportedImage: return "This image could not be decoded for HDR processing."
        case .invalidProject(let reason): return "The HDR project could not be opened: \(reason)"
        }
    }
}

public enum HDRMethod: String, Codable, CaseIterable, Sendable {
    case direct, virtualExposureFusion
}

/// Candidate controls for qualification. Zero texture adjustments preserve the base tone map.
public struct HDRSettings: Codable, Equatable, Sendable {
    public var method: HDRMethod = .direct
    public var toneEnabled = true
    public var artifactsEnabled = true
    public var exposure: Float = 0
    public var compression: Float = 0.65
    public var microcontrast: Float = 0.6
    public var detail: Float = 0.35
    public var shadowProtection: Float = 0.5
    public var highlightProtection: Float = 0.5
    public init() {}

    enum CodingKeys: String, CodingKey {
        case method, toneEnabled, artifactsEnabled, exposure, compression, microcontrast, detail, shadowProtection, highlightProtection
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = try c.decodeIfPresent(HDRMethod.self, forKey: .method) ?? .direct
        toneEnabled = try c.decodeIfPresent(Bool.self, forKey: .toneEnabled) ?? true
        artifactsEnabled = try c.decodeIfPresent(Bool.self, forKey: .artifactsEnabled) ?? true
        exposure = try c.decodeIfPresent(Float.self, forKey: .exposure) ?? 0
        compression = try c.decodeIfPresent(Float.self, forKey: .compression) ?? 0.65
        microcontrast = try c.decodeIfPresent(Float.self, forKey: .microcontrast) ?? 0.6
        detail = try c.decodeIfPresent(Float.self, forKey: .detail) ?? 0.35
        shadowProtection = try c.decodeIfPresent(Float.self, forKey: .shadowProtection) ?? 0.5
        highlightProtection = try c.decodeIfPresent(Float.self, forKey: .highlightProtection) ?? 0.5
        try validate()
    }

    public func validate() throws {
        guard exposure.isFinite, (-5...5).contains(exposure),
              [compression, shadowProtection, highlightProtection].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              [microcontrast, detail].allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else {
            throw HDRError.invalidSettings
        }
    }
}
