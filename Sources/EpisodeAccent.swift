import SwiftUI
import UIKit
import CoreImage

/// A visual accent for the Now Playing screen, derived from the podcast's own
/// artwork (from its RSS feed or Apple Podcasts listing) when the publisher
/// provided one. Shows without artwork keep the app's standard look.
struct EpisodeAccent: Equatable {
    let primary: Color
    let secondary: Color

    var gradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [primary, secondary]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var glow: RadialGradient {
        RadialGradient(
            gradient: Gradient(colors: [primary.opacity(0.4), .clear]),
            center: .center,
            startRadius: 10,
            endRadius: 160
        )
    }

    static let standard = EpisodeAccent(
        primary: Color(red: 0.77, green: 0.55, blue: 0.24),
        secondary: Color(red: 0.74, green: 0.33, blue: 0.23)
    )

    @MainActor
    private static var cache: [URL: EpisodeAccent] = [:]

    /// Resolves the accent for `artworkURL`, or `.standard` if there is no
    /// artwork or it could not be downloaded/read.
    @MainActor
    static func resolved(for artworkURL: URL?) async -> EpisodeAccent {
        guard let artworkURL else { return .standard }
        if let cached = cache[artworkURL] { return cached }
        guard let extracted = await extractAccent(from: artworkURL) else { return .standard }
        cache[artworkURL] = extracted
        return extracted
    }

    private static func extractAccent(from url: URL) async -> EpisodeAccent? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        return await Task.detached(priority: .utility) {
            guard let image = UIImage(data: data), let cgImage = image.cgImage else { return nil }
            guard let averageColor = averageColor(of: CIImage(cgImage: cgImage)) else { return nil }
            let base = readable(averageColor)
            let deepened = base.adjusted(brightnessDelta: -0.22, saturationDelta: 0.05)
            return EpisodeAccent(primary: Color(base), secondary: Color(deepened))
        }.value
    }

    /// A fast 1x1 downsample rather than scanning every pixel.
    private static func averageColor(of image: CIImage) -> UIColor? {
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: image.extent), forKey: kCIInputExtentKey)
        guard let outputImage = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        guard bitmap[3] > 0 else { return nil }
        return UIColor(
            red: CGFloat(bitmap[0]) / 255,
            green: CGFloat(bitmap[1]) / 255,
            blue: CGFloat(bitmap[2]) / 255,
            alpha: 1
        )
    }

    /// Clamps saturation/brightness so pale or near-white artwork still yields
    /// a legible accent behind white icon glyphs, while keeping its hue.
    private static func readable(_ color: UIColor) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let clampedSaturation = min(max(saturation, 0.38), 0.9)
        let clampedBrightness = min(max(brightness, 0.4), 0.72)
        return UIColor(hue: hue, saturation: clampedSaturation, brightness: clampedBrightness, alpha: 1)
    }
}

private extension UIColor {
    func adjusted(brightnessDelta: CGFloat, saturationDelta: CGFloat) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return UIColor(
            hue: hue,
            saturation: min(max(saturation + saturationDelta, 0), 1),
            brightness: min(max(brightness + brightnessDelta, 0), 1),
            alpha: alpha
        )
    }
}
