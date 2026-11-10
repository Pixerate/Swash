// Open-source stub of PixerateStickers (MIT).
// Contains no proprietary artwork: StickerCatalog.isAvailable is false and all collections are empty.
import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(SwiftUI)
import SwiftUI
#endif

#if canImport(Messages) && os(iOS)
import Messages
#endif

public let DEFAULT_STICKER_PAGE = 24
public let MAX_STICKER_PAGE = 100

public struct StickerSetID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: StringLiteralType) { self.rawValue = value }
    public var description: String { rawValue }

    public static let pixerate = StickerSetID("pixerate")
    public static let slopMachine = StickerSetID("slop-machine")
    public static let swash = StickerSetID("swash")
    public static let uchiage = StickerSetID("uchiage")
}

public enum StickerVariant: String, CaseIterable, Codable, Hashable, Sendable {
    case light
    case dark

    public var displayName: String {
        self == .light ? "Light" : "Dark"
    }
}

public enum StickerPixelSize: Int, CaseIterable, Sendable {
    case small = 300
    case regular = 408
    case large = 618
}

public struct StickerLicence: Equatable, Hashable, Codable, Sendable {
    public let spdx: String?
    public let name: String
    public let attribution: String?
    public let url: String?
    public let commercial: Bool

    public init(spdx: String? = nil, name: String, attribution: String? = nil, url: String? = nil, commercial: Bool) {
        self.spdx = spdx
        self.name = name
        self.attribution = attribution
        self.url = url
        self.commercial = commercial
    }
}

public struct StickerSet: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: StickerSetID
    public let name: String
    public let description: String
    public let style: String
    public let count: Int
}

public struct StickerMeta: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let set: StickerSetID
    public let category: String
    public let tags: [String]
    public let description: String?
    public let width: Double
    public let height: Double
    public let formats: [String]
    public let licence: StickerLicence
    public let aiGenerated: Bool
    public let tintable: Bool
    public let animated: Bool
    public let variants: [StickerVariant]
    public let colours: [String]
    public let darkColours: [String]?
    public let frameCount: Int
    public let frameDelay: Double

    public var accessibilityLabel: String {
        if let description, !description.isEmpty { return "\(name): \(description)" }
        return name
    }

    public func resolvedVariant(_ requested: StickerVariant) -> StickerVariant {
        variants.contains(requested) ? requested : .light
    }

    public func svg(variant: StickerVariant = .light, colour: String? = nil) throws -> String {
        throw StickerError(.unknownSticker, "Proprietary stickers are not bundled in this build.")
    }

    public func frameSvgs(variant: StickerVariant = .light) -> [String] { [] }

    public func cgImage(
        variant: StickerVariant = .light,
        dimension: Int = StickerPixelSize.regular.rawValue,
        colour: String? = nil,
        frame: Int? = nil
    ) -> CGImage? { nil }

    public func pngData(
        variant: StickerVariant = .light,
        dimension: Int = StickerPixelSize.regular.rawValue,
        colour: String? = nil,
        animated: Bool = true
    ) -> Data? { nil }

    public func pngFileURL(
        variant: StickerVariant = .light,
        dimension: Int = StickerPixelSize.regular.rawValue,
        colour: String? = nil,
        animated: Bool = true,
        cacheDirectory: URL? = nil
    ) throws -> URL {
        throw StickerError(.renderFailed, "Proprietary stickers are not bundled in this build.")
    }

    #if canImport(UIKit)
    public func uiImage(variant: StickerVariant = .light, dimension: Int = StickerPixelSize.regular.rawValue, colour: String? = nil) -> UIImage? { nil }
    #endif

    #if canImport(AppKit)
    public func nsImage(variant: StickerVariant = .light, dimension: Int = StickerPixelSize.regular.rawValue, colour: String? = nil) -> NSImage? { nil }
    #endif

    #if canImport(Messages) && os(iOS)
    public func msSticker(
        variant: StickerVariant = .light,
        dimension: Int = StickerPixelSize.regular.rawValue,
        colour: String? = nil,
        animated: Bool = true,
        cacheDirectory: URL? = nil
    ) throws -> MSSticker {
        throw StickerError(.renderFailed, "Proprietary stickers are not bundled in this build.")
    }
    #endif
}

public struct StickerArt: Equatable, Hashable, Codable, Sendable {
    public let kind: String
    public let svg: String
    public let silhouette: String?
}

public struct StickerSummary: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let category: String
    public let tags: [String]
    public let description: String?
    public let width: Double
    public let height: Double
    public let formats: [String]
    public let licence: StickerLicence
    public let tintable: Bool
    public let aiGenerated: Bool
    public let animated: Bool
    public let variants: [StickerVariant]
}

public struct StickerVariantInfo: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
}

public struct StickerDescription: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let category: String
    public let tags: [String]
    public let description: String?
    public let width: Double
    public let height: Double
    public let formats: [String]
    public let licence: StickerLicence
    public let tintable: Bool
    public let aiGenerated: Bool
    public let animated: Bool
    public let silhouette: String?
    public let colours: [String]?
    public let variants: [StickerVariantInfo]
}

public struct StickerCategoryCount: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let count: Int
}

public struct StickerPage: Equatable, Sendable {
    public let items: [StickerSummary]
    public let total: Int
    public let next: String?
}

public struct StickerSearchOptions: Equatable, Sendable {
    public var category: String?
    public var tags: [String]?
    public var limit: Int?
    public var after: String?
    public var commercialOnly: Bool?
    public init(category: String? = nil, tags: [String]? = nil, limit: Int? = nil, after: String? = nil, commercialOnly: Bool? = nil) {
        self.category = category
        self.tags = tags
        self.limit = limit
        self.after = after
        self.commercialOnly = commercialOnly
    }
}

public struct StickerLoadOptions: Equatable, Sendable {
    public var format: String?
    public var size: Int?
    public var colour: String?
    public var variant: StickerVariant?
    public init(format: String? = nil, size: Int? = nil, colour: String? = nil, variant: StickerVariant? = nil) {
        self.format = format
        self.size = size
        self.colour = colour
        self.variant = variant
    }
}

public enum StickerErrorCode: String, Equatable, Hashable, Codable, Sendable {
    case unknownSticker = "unknown_sticker"
    case unknownSet = "unknown_set"
    case unsupportedFormat = "unsupported_format"
    case invalidArgument = "invalid_argument"
    case renderFailed = "render_failed"
}

public struct StickerError: Error, LocalizedError, Equatable, Sendable {
    public let code: StickerErrorCode
    public let message: String
    public init(_ code: StickerErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
    public var errorDescription: String? { message }
}

public let STICKER_SETS: [StickerSet] = []
public let STICKER_META: [StickerMeta] = []

public enum StickerCatalog {
    public static var isAvailable: Bool { false }
    public static var sets: [StickerSet] { [] }
    public static var all: [StickerMeta] { [] }
    public static func set(_ id: StickerSetID) -> StickerSet? { nil }
    public static func sticker(_ id: String) -> StickerMeta? { nil }
    public static func stickers(in sets: [StickerSetID]? = nil, category: String? = nil, tag: String? = nil, query: String = "") -> [StickerMeta] { [] }
    public static func categories(in sets: [StickerSetID]? = nil) -> [StickerCategoryCount] { [] }
}

public struct StickerSetProvider: Sendable {
    public let id: String
    public let setID: StickerSetID
    public let name: String
    public let defaultVariant: StickerVariant

    public init(set: StickerSetID, variant: StickerVariant = .light) throws {
        throw StickerError(.unknownSet, "Proprietary sticker sets are not bundled in open-source builds.")
    }

    public func list(_ options: StickerSearchOptions = .init()) throws -> StickerPage { StickerPage(items: [], total: 0, next: nil) }
    public func search(_ query: String, options: StickerSearchOptions = .init()) throws -> StickerPage { StickerPage(items: [], total: 0, next: nil) }
    public func describe(_ id: String) -> StickerDescription? { nil }
    public func load(_ id: String, options: StickerLoadOptions = .init()) throws -> StickerArt {
        throw StickerError(.unknownSticker, "Proprietary stickers are not bundled in open-source builds.")
    }
    public func categories() -> [StickerCategoryCount] { [] }
}

public func stickerSet(_ id: StickerSetID, variant: StickerVariant = .light) throws -> StickerSetProvider {
    try StickerSetProvider(set: id, variant: variant)
}
public func pixerateStickers(variant: StickerVariant = .light) throws -> StickerSetProvider {
    try StickerSetProvider(set: .pixerate, variant: variant)
}
public func slopMachineStickers(variant: StickerVariant = .light) throws -> StickerSetProvider {
    try StickerSetProvider(set: .slopMachine, variant: variant)
}
public func swashStickers(variant: StickerVariant = .light) throws -> StickerSetProvider {
    try StickerSetProvider(set: .swash, variant: variant)
}
public func uchiageStickers(variant: StickerVariant = .light) throws -> StickerSetProvider {
    try StickerSetProvider(set: .uchiage, variant: variant)
}
public func loadSticker(_ id: String, variant: StickerVariant = .light) throws -> StickerArt {
    throw StickerError(.unknownSticker, "Proprietary stickers are not bundled in open-source builds.")
}

#if canImport(SwiftUI)
public struct StickerImage: View {
    public let sticker: StickerMeta
    public let variant: StickerVariant?
    public let animated: Bool

    public init(_ sticker: StickerMeta, variant: StickerVariant? = nil, animated: Bool = true) {
        self.sticker = sticker
        self.variant = variant
        self.animated = animated
    }

    public var body: some View {
        EmptyView()
    }
}
#endif

#if canImport(Messages) && os(iOS)
open class PixerateStickerBrowserViewController: MSMessagesAppViewController, MSStickerBrowserViewDataSource {
    open var stickerSet: StickerSetID? { nil }
    open var stickerSets: [StickerSetID] { [] }
    open var category: String? { nil }
    open var variant: StickerVariant? { nil }
    open var showsSetPicker: Bool { true }
    open var includesAllSetsSegment: Bool { false }
    open var stickerSize: MSStickerSize { .regular }
    open var stickerDimension: Int { StickerPixelSize.regular.rawValue }
    public private(set) var stickerBrowserView: MSStickerBrowserView!

    open override func viewDidLoad() {
        super.viewDidLoad()
        let browser = MSStickerBrowserView(frame: view.bounds, stickerSize: stickerSize)
        browser.dataSource = self
        browser.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(browser)
        self.stickerBrowserView = browser
    }

    open func reloadStickers() {
        stickerBrowserView?.reloadData()
    }

    open func numberOfStickers(in stickerBrowserView: MSStickerBrowserView) -> Int { 0 }
    open func stickerBrowserView(_ stickerBrowserView: MSStickerBrowserView, stickerAt index: Int) -> MSSticker {
        preconditionFailure("No stickers in open-source stub")
    }
}
#endif
