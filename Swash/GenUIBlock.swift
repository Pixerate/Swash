//
//  GenUIBlock.swift
//  Swash
//
//  Native Swift contracts and fenced-block parser mirroring @pixerate/genui-core
//  and @pixerate/schemas/genui.
//

import Foundation

/// Built-in and extensible GenUI fenced-block kinds supported by Swash.
enum GenUIBlockKind: String, CaseIterable, Sendable, Hashable {
    case stats
    case callout
    case actions
    case chart
    case tree
    case orgchart
    case proposals
    case form
    case widget
}

/// Registry mapping Markdown code-fence language tags to `GenUIBlockKind`.
/// Mirrors `EphemeralBlockRegistry` in `@pixerate/genui-core`.
enum GenUIBlockRegistry {
    private static let aliases: [String: GenUIBlockKind] = [
        "stats": .stats,
        "callout": .callout,
        "actions": .actions,
        "chart": .chart,
        "tree": .tree,
        "node-diagram": .tree,
        "node_diagram": .tree,
        "orgchart": .orgchart,
        "proposals": .proposals,
        "proposal": .proposals,
        "followup": .proposals,
        "follow-up": .proposals,
        "followups": .proposals,
        "follow-ups": .proposals,
        "follow-proposal": .proposals,
        "follow_proposal": .proposals,
        "followup-proposal": .proposals,
        "followup_proposal": .proposals,
        "follow-proposals": .proposals,
        "follow_proposals": .proposals,
        "followup-proposals": .proposals,
        "followup_proposals": .proposals,
        "form": .form,
        "clarification": .form,
        "question": .form,
        "widget": .widget,
        "genui-widget": .widget,
    ]

    static var supportedLanguages: [String] {
        Array(aliases.keys).sorted()
    }

    static func kind(for infoString: String) -> GenUIBlockKind? {
        guard let token = infoString.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else {
            return nil
        }
        return aliases[token.lowercased()]
    }
}

// MARK: - Block Payloads (@pixerate/schemas/genui)

struct GenUIStatItem: Codable, Equatable, Sendable {
    let label: String
    let value: String
    let change: String?
    let trend: String?
}

struct GenUIStatsBlock: Codable, Equatable, Sendable {
    let title: String?
    let items: [GenUIStatItem]
}

struct GenUICalloutBlock: Codable, Equatable, Sendable {
    let severity: String?
    let type: String?
    let title: String
    let body: String?
    let message: String?

    var effectiveSeverity: String {
        (severity ?? type ?? "info").lowercased()
    }

    var effectiveBody: String? {
        body ?? message
    }
}

struct GenUIActionItem: Codable, Equatable, Sendable {
    let id: String
    let label: String
    let variant: String?
    let description: String?
}

struct GenUIActionsBlock: Codable, Equatable, Sendable {
    let title: String?
    let actions: [GenUIActionItem]
}

struct GenUIChartSeries: Codable, Equatable, Sendable {
    let name: String
    let data: [Double]
    let color: String?
}

struct GenUIChartBlock: Codable, Equatable, Sendable {
    let chartType: String?
    let title: String?
    let unit: String?
    let categories: [String]?
    let series: [GenUIChartSeries]
}

struct GenUITreeNode: Codable, Equatable, Sendable {
    let id: String
    let label: String
    let detail: String?
    let parentId: String?
}

struct GenUITreeBlock: Codable, Equatable, Sendable {
    let title: String?
    let nodes: [GenUITreeNode]
}

struct GenUIOrgChartPerson: Codable, Equatable, Sendable {
    let id: String?
    let name: String
    let role: String?
    let title: String?
    let managerId: String?
}

struct GenUIOrgChartBlock: Codable, Equatable, Sendable {
    let title: String?
    let people: [GenUIOrgChartPerson]?
    let root: GenUIOrgChartPerson?
}

struct GenUIProposalItem: Codable, Equatable, Sendable {
    let id: String?
    let title: String
    let summary: String?
    let description: String?
    let recommended: Bool?
}

struct GenUIProposalsBlock: Codable, Equatable, Sendable {
    let title: String?
    let items: [GenUIProposalItem]?
    let proposals: [GenUIProposalItem]?

    var effectiveItems: [GenUIProposalItem] {
        items ?? proposals ?? []
    }
}

struct GenUIFormQuestion: Codable, Equatable, Sendable {
    let id: String
    let label: String?
    let prompt: String?
    let type: String?
    let options: [String]?
    let placeholder: String?
    let required: Bool?

    var effectiveLabel: String {
        label ?? prompt ?? id
    }
}

struct GenUIFormBlock: Codable, Equatable, Sendable {
    let title: String?
    let description: String?
    let questions: [GenUIFormQuestion]?
    let fields: [GenUIFormQuestion]?

    var effectiveQuestions: [GenUIFormQuestion] {
        questions ?? fields ?? []
    }
}

struct GenUICustomWidgetBlock: Codable, Equatable, Sendable {
    let title: String?
    let height: Double?
    let html: String?
    let script: String?
}

// MARK: - Parsed Union

enum GenUIParsedBlock: Equatable, Sendable {
    case stats(GenUIStatsBlock)
    case callout(GenUICalloutBlock)
    case actions(GenUIActionsBlock)
    case chart(GenUIChartBlock)
    case tree(GenUITreeBlock)
    case orgchart(GenUIOrgChartBlock)
    case proposals(GenUIProposalsBlock)
    case form(GenUIFormBlock)
    case widget(GenUICustomWidgetBlock)

    var kind: GenUIBlockKind {
        switch self {
        case .stats: return .stats
        case .callout: return .callout
        case .actions: return .actions
        case .chart: return .chart
        case .tree: return .tree
        case .orgchart: return .orgchart
        case .proposals: return .proposals
        case .form: return .form
        case .widget: return .widget
        }
    }
}

/// Parses fenced Markdown code blocks into `GenUIParsedBlock` values,
/// falling back to `nil` (regular code block) on unknown languages or invalid JSON.
enum GenUIBlockParser {
    static func parse(info: String, source: String) -> GenUIParsedBlock? {
        guard let kind = GenUIBlockRegistry.kind(for: info) else { return nil }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()

        do {
            switch kind {
            case .stats:
                return .stats(try decoder.decode(GenUIStatsBlock.self, from: data))
            case .callout:
                return .callout(try decoder.decode(GenUICalloutBlock.self, from: data))
            case .actions:
                return .actions(try decoder.decode(GenUIActionsBlock.self, from: data))
            case .chart:
                return .chart(try decoder.decode(GenUIChartBlock.self, from: data))
            case .tree:
                return .tree(try decoder.decode(GenUITreeBlock.self, from: data))
            case .orgchart:
                return .orgchart(try decoder.decode(GenUIOrgChartBlock.self, from: data))
            case .proposals:
                return .proposals(try decoder.decode(GenUIProposalsBlock.self, from: data))
            case .form:
                return .form(try decoder.decode(GenUIFormBlock.self, from: data))
            case .widget:
                let widget = try decoder.decode(GenUICustomWidgetBlock.self, from: data)
                guard widget.html != nil || widget.script != nil else { return nil }
                return .widget(widget)
            }
        } catch {
            return nil
        }
    }
}
