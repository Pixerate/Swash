//
//  GlassAccessoryBar.swift
//  Swash
//
//  The bars above the iOS keyboard and the format panel that can replace it, built from system
//  pieces: Liquid Glass (`UIGlassEffect`, glass button configurations) and a horizontal scroll
//  view, so no item is squeezed or clipped on a narrow screen (#72).
//

#if os(iOS)
import SwiftUI
import UIKit
import PixerateMarkdown

/// A keyboard accessory in the iOS 26 style: glass floating over the text, not an opaque strip.
/// The items scroll sideways when they don't fit; the trailing button stays put.
class GlassAccessoryBar: UIView {
    static let height: CGFloat = 60

    private let stack: UIStackView

    /// The scrolling item views currently arranged in the bar.
    var itemViews: [UIView] { stack.arrangedSubviews }

    /// - Parameters:
    ///   - items: The scrolling items, in order.
    ///   - trailing: A button kept at the trailing edge in its own glass circle (Hide Keyboard, Close).
    ///   - groupedInCapsule: Puts the items in one glass capsule (plain buttons inside), as the
    ///     system keyboard toolbars do. Otherwise each item brings its own glass (chips).
    init(items: [UIView], trailing: UIButton?, groupedInCapsule: Bool) {
        stack = UIStackView(arrangedSubviews: items)
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.height))
        autoresizingMask = .flexibleWidth
        backgroundColor = .clear

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = groupedInCapsule ? 2 : 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let container: UIView
        if groupedInCapsule {
            let glass = UIVisualEffectView(effect: UIGlassEffect())
            glass.cornerConfiguration = .capsule()
            glass.contentView.addSubview(scroll)
            container = glass
        } else {
            container = scroll
        }
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        var constraints = [
            container.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            container.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: groupedInCapsule ? 8 : 0),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: groupedInCapsule ? -8 : 0),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ]
        if groupedInCapsule {
            constraints += [
                scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: container.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                // Hug the items when they fit, as the system bars do; scroll when they don't
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: 16).withPriority(.defaultHigh),
            ]
        }

        if let trailing {
            var configuration = trailing.configuration ?? .glass()
            configuration.cornerStyle = .capsule
            trailing.configuration = configuration
            trailing.translatesAutoresizingMaskIntoConstraints = false
            addSubview(trailing)
            constraints += [
                trailing.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
                trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
                trailing.heightAnchor.constraint(equalTo: container.heightAnchor),
                trailing.widthAnchor.constraint(equalTo: trailing.heightAnchor),
                container.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8),
            ]
        } else {
            constraints.append(container.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -12))
        }
        if !groupedInCapsule {
            constraints.append(container.trailingAnchor.constraint(equalTo: trailing?.leadingAnchor ?? safeAreaLayoutGuide.trailingAnchor,
                                                                     constant: trailing == nil ? -12 : -8))
        }
        NSLayoutConstraint.activate(constraints)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Replaces the scrolling items in place without recreating the bar.
    func setItems(_ items: [UIView]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for item in items {
            stack.addArrangedSubview(item)
        }
    }

    /// A plain icon button for a capsule bar.
    static func iconButton(symbol: String, label: String, action: UIAction? = nil, menu: UIMenu? = nil) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body, scale: .large)
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        // Not `primaryAction:` in the initializer, which would show the action's title too
        let button = UIButton(configuration: configuration)
        button.configurationUpdateHandler = { button in
            var configuration = button.configuration
            configuration?.baseForegroundColor = button.isSelected ? .tintColor : .label
            button.configuration = configuration
        }
        if let action { button.addAction(action, for: .primaryActionTriggered) }
        if let menu {
            button.menu = menu
            button.showsMenuAsPrimaryAction = true
        }
        button.accessibilityLabel = label
        button.largeContentTitle = label
        button.showsLargeContentViewer = true
        button.addInteraction(UILargeContentViewerInteraction())
        return button
    }

    /// A compact text button for a Markdown character in the capsule bar (#191).
    static func characterButton(character: String, label: String, action: UIAction? = nil, variants: [String] = [], onVariant: ((String) -> Void)? = nil) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        var title = AttributedString(character)
        title.font = UIFont.monospacedSystemFont(ofSize: 17, weight: .medium)
        configuration.attributedTitle = title
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        let button = UIButton(configuration: configuration)
        if let action { button.addAction(action, for: .primaryActionTriggered) }
        if !variants.isEmpty, let onVariant {
            let actions = variants.map { variant in
                UIAction(title: variant) { _ in
                    onVariant(variant)
                }
            }
            button.menu = UIMenu(title: label, children: actions)
            button.showsMenuAsPrimaryAction = false
        }
        button.accessibilityLabel = label
        button.largeContentTitle = "\(character) (\(label))"
        button.showsLargeContentViewer = true
        button.addInteraction(UILargeContentViewerInteraction())
        return button
    }

    /// A vertical divider separating bar groups (e.g. format buttons and Markdown characters).
    static func separatorView() -> UIView {
        let view = UIView()
        view.backgroundColor = .separator.withAlphaComponent(0.4)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isAccessibilityElement = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 1),
            view.heightAnchor.constraint(equalToConstant: 22),
        ])
        return view
    }

    /// The trailing glass circle (Hide Keyboard, Close).
    static func trailingButton(symbol: String, label: String, action: UIAction) -> UIButton {
        var configuration = UIButton.Configuration.glass()
        configuration.image = UIImage(systemName: symbol)
        configuration.baseForegroundColor = .label
        let button = UIButton(configuration: configuration)
        button.addAction(action, for: .primaryActionTriggered)
        button.accessibilityLabel = label
        return button
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

// MARK: - Format panel

/// The format panel that replaces the keyboard when Aa is tapped, as in Notes: text styles,
/// inline formats and block types in one place, at keyboard height.
final class FormatPanelInputView: UIInputView {
    private let entries: [FormatMenuEntry]
    private let apply: (FormatCommand) -> Void
    private let close: () -> Void
    private let host: UIHostingController<FormatPanel>

    init(entries: [FormatMenuEntry], activeFormats: Set<FormatCommand> = [], apply: @escaping (FormatCommand) -> Void, close: @escaping () -> Void) {
        self.entries = entries
        self.apply = apply
        self.close = close
        host = UIHostingController(rootView: FormatPanel(entries: entries, activeFormats: activeFormats, apply: apply, close: close))
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 300), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = .flexibleWidth
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 300),
        ])
    }

    func update(activeFormats: Set<FormatCommand>) {
        host.rootView = FormatPanel(entries: entries, activeFormats: activeFormats, apply: apply, close: close)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Insert panel

/// The insert panel that replaces the keyboard when "+" is tapped (in the keyboard bar or at an
/// empty line): block insertion options in a grid at keyboard height, on iPhone and iPad alike.
final class InsertPanelInputView: UIInputView {
    private let host: UIHostingController<InsertPanelView>

    init(onSelect: @escaping (BlockInsertKind) -> Void = { _ in }, close: @escaping () -> Void = {}) {
        host = UIHostingController(rootView: InsertPanelView(onSelect: onSelect, close: close))
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 300), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = .flexibleWidth
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 300),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// The panel's content. Commands and labels come from the format manifest; only the layout
/// and icons are Swash's.
struct FormatPanel: View {
    let entries: [FormatMenuEntry]
    var activeFormats: Set<FormatCommand> = []
    let apply: (FormatCommand) -> Void
    let close: () -> Void

    var textStyles: [FormatMenuEntry] {
        entries.filter {
            if case .heading = $0.command { return true }
            return $0.command == .paragraph
        }
    }

    /// Non-text-style entries split by their manifest group (`Format`, `Block`, `Insert`).
    var groups: [[FormatMenuEntry]] {
        let rest = entries.filter { entry in
            !textStyles.contains { $0.command == entry.command }
        }
        return FormatManifestLayout.groups(rest)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Format")
                    .font(.headline)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Close Format Panel")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(textStyles, id: \.label) { entry in
                        let isSelected = activeFormats.contains(entry.command)
                        Button { apply(entry.command) } label: {
                            Text(entry.label)
                                .font(Self.font(for: entry.command))
                                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.glass)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                GlassEffectContainer {
                    HStack(spacing: 8) {
                        ForEach(group, id: \.label) { entry in iconButton(entry) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private func iconButton(_ entry: FormatMenuEntry) -> some View {
        let isSelected = activeFormats.contains(entry.command)
        return Button { apply(entry.command) } label: {
            Image(systemName: entry.command.symbolName)
                .font(.body.weight(.medium))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(entry.label.replacingOccurrences(of: "…", with: ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Each text style previews its own size, as in Notes.
    private static func font(for command: FormatCommand) -> Font {
        switch command {
        case .heading(1): return .title2.bold()
        case .heading(2): return .title3.bold()
        case .heading: return .headline
        default: return .body
        }
    }
}

// MARK: - Previews

#Preview("Format Panel") {
    FormatPanel(
        entries: FormatManifestLayout.formatPanelEntries,
        apply: { _ in },
        close: {}
    )
    .frame(height: 220)
}

#Preview("Format Panel - Active Formats") {
    FormatPanel(
        entries: FormatManifestLayout.formatPanelEntries,
        activeFormats: [.heading(2), .bold, .bulletList],
        apply: { _ in },
        close: {}
    )
    .frame(height: 220)
}
#endif
