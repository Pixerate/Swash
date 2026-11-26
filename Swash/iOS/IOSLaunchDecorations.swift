//
//  IOSLaunchDecorations.swift
//  Swash
//
//  Prototype pixel decorations for the iPhone and iPad document manager, from docs/BRAND.md: the
//  pixel square (a rounded square, corners about 28% of its side) in the neon accent gradient.
//  Pick one with the `launchDecoration` default (`-launchDecoration trail` or `speckles` as a
//  launch argument); without it the manager shows the wordmark alone.
//

#if os(iOS)
import SwiftUI

/// Which decoration the document manager draws around the wordmark.
enum SwashLaunchDecoration: String, CaseIterable {
    case none
    /// The swash breaking up into pixels off the end of the wordmark, as on the app icon.
    case trail
    /// Faint pixel speckles scattered through the empty space around the wordmark and button.
    case speckles

    static let defaultsKey = "launchDecoration"

    static var current: SwashLaunchDecoration {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .none
    }
}

/// The brand's neon accent colours (docs/BRAND.md), light and dark.
enum SwashPixelPalette {
    /// The accent gradient, pink → fuchsia → violet, ending in deep indigo.
    static func stops(dark: Bool) -> [Color] {
        [
            Color(red: 0xEC / 255, green: 0x48 / 255, blue: 0x99 / 255),
            Color(red: 0xE1 / 255, green: 0x2A / 255, blue: 0xFB / 255),
            Color(red: 0x8E / 255, green: 0x51 / 255, blue: 0xFF / 255),
            dark ? Color(red: 0x6D / 255, green: 0x63 / 255, blue: 0xF0 / 255)
                 : Color(red: 0x43 / 255, green: 0x38 / 255, blue: 0xCA / 255),
        ]
    }

    /// The colour `t` (0 to 1) of the way along the gradient.
    static func color(at t: Double, dark: Bool) -> Color {
        let stops = stops(dark: dark)
        let scaled = min(max(t, 0), 1) * Double(stops.count - 1)
        let index = min(Int(scaled), stops.count - 2)
        return stops[index].mix(with: stops[index + 1], by: scaled - Double(index))
    }
}

/// A pixel square: a rounded square whose corner radius is 28% of its side.
private func pixel(at center: CGPoint, side: CGFloat) -> Path {
    Path(roundedRect: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side),
         cornerRadius: side * 0.28, style: .continuous)
}

/// A small deterministic random sequence, so the pixels sit in the same places every launch.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

// MARK: - Idea 1: pixel trail

/// Pixels breaking off the end of the wordmark, rising and shrinking up and to the right, from
/// fuchsia to indigo, as the swash on the app icon breaks into pixels. They shimmer gently, and
/// hold still under Reduce Motion.
struct SwashPixelTrail: View {
    /// Where the trail starts: by the head of the ribbon, above the wordmark's last letter.
    let anchor: CGPoint
    /// The wordmark's font size, which the trail scales with.
    let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let count = 9

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, _ in
                let dark = colorScheme == .dark
                var random = SeededRandom(seed: 7)
                for index in 0..<Self.count {
                    let t = Double(index) / Double(Self.count - 1)
                    // Breaking up as it goes: close together at first, then sparser, rising gently
                    let jitterX = (random.next() - 0.5) * 0.1 * t
                    let jitterY = (random.next() - 0.5) * 0.3 * t
                    let phase = random.next() * .pi * 2
                    let x = anchor.x + size * (0.1 + 1.6 * pow(t, 1.1) + jitterX)
                    let y = anchor.y - size * (0.45 * t - 0.15 * t * t + jitterY)
                    let drift = reduceMotion ? 0 : sin(time * 1.3 + phase) * size * 0.03 * t
                    let side = size * (0.13 - 0.08 * t)
                    let shimmer = reduceMotion ? 1 : 0.8 + 0.2 * sin(time * 2.1 + phase)
                    context.opacity = (1 - 0.8 * t) * shimmer
                    context.fill(pixel(at: CGPoint(x: x, y: y + drift), side: side),
                                 with: .color(SwashPixelPalette.color(at: t, dark: dark)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Idea 2: speckle field

/// Faint pixel speckles scattered through `area`, kept clear of `keepClear` (the wordmark and the
/// Create Document button). Each one twinkles slowly; under Reduce Motion they hold still.
struct SwashPixelSpeckles: View {
    let area: CGRect
    let keepClear: [CGRect]
    var count = 26

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Speckle {
        let center: CGPoint
        let side: CGFloat
        let tint: Double
        let opacity: Double
        let speed: Double
        let phase: Double
    }

    private var speckles: [Speckle] {
        var random = SeededRandom(seed: 42)
        var result: [Speckle] = []
        var attempts = 0
        while result.count < count, attempts < count * 40 {
            attempts += 1
            let center = CGPoint(x: area.minX + random.next() * area.width, y: area.minY + random.next() * area.height)
            let side = 3 + random.next() * 6
            let speckle = Speckle(center: center, side: side, tint: random.next(), opacity: 0.18 + random.next() * 0.32,
                                  speed: 0.4 + random.next() * 0.8, phase: random.next() * .pi * 2)
            let box = CGRect(x: center.x - side, y: center.y - side, width: side * 2, height: side * 2)
            // Keep clear of the wordmark and button, and of the other speckles
            guard !keepClear.contains(where: { $0.intersects(box) }),
                  !result.contains(where: { hypot($0.center.x - center.x, $0.center.y - center.y) < 28 }) else { continue }
            result.append(speckle)
        }
        return result
    }

    var body: some View {
        let speckles = speckles
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, _ in
                let dark = colorScheme == .dark
                for speckle in speckles {
                    let twinkle = reduceMotion ? 1 : 0.55 + 0.45 * sin(time * speckle.speed + speckle.phase)
                    context.opacity = speckle.opacity * twinkle * (dark ? 1.2 : 1)
                    context.fill(pixel(at: speckle.center, side: speckle.side),
                                 with: .color(SwashPixelPalette.color(at: speckle.tint, dark: dark)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("Pixel trail") {
    @Previewable @State var size: CGFloat = 52
    ZStack(alignment: .topLeading) {
        SwashWordmark(animated: false)
            .position(x: 180, y: 120)
        SwashPixelTrail(anchor: CGPoint(x: 180 + 77, y: 120 - 14), size: size)
    }
    .frame(width: 402, height: 240)
}

#Preview("Speckle field, dark") {
    ZStack {
        SwashPixelSpeckles(area: CGRect(x: 0, y: 0, width: 402, height: 360),
                           keepClear: [CGRect(x: 110, y: 120, width: 180, height: 70),
                                       CGRect(x: 20, y: 205, width: 362, height: 54)])
        SwashWordmark(animated: false)
            .position(x: 201, y: 155)
    }
    .frame(width: 402, height: 360)
    .background(Color(uiColor: .systemBackground))
    .environment(\.colorScheme, .dark)
}
#endif
