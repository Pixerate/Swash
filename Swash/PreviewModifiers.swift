//
//  PreviewModifiers.swift
//  Swash
//
//  Created by Jack James on 19/11/2026.
//

import SwiftUI

// Shared helpers for #Preview blocks. Not wrapped in #if DEBUG: #Preview bodies
// are type-checked in Release builds too, so they must resolve there (GOTCHAS #92).

// MARK: - Swash Sample Documents

enum SwashSampleDocument {
    static let empty = SwashDocument(text: "")
    
    static let standard = SwashDocument(text: """
        # Welcome to Swash
        
        Swash is a native, lightweight Markdown editor and previewer built for Apple platforms.
        
        ## Features
        
        - **Live editing** with styled text and split preview.
        - Interactive tables and GitHub Flavored Markdown (GFM).
        - Math rendering with $\\LaTeX$ formulas: $E = mc^2$.
        - Embedded Mermaid diagrams and interactive widgets.
        
        > "Simplicity is prerequisite for reliability." — Edsger W. Dijkstra
        
        ### Code Example
        
        ```swift
        import SwiftUI

        struct GreetingView: View {
            var body: some View {
                Text("Hello, Swash!")
            }
        }
        ```
        """)

    static let tablesAndMath = SwashDocument(text: """
        # Tables & Math
        
        | Feature | Status | Notes |
        | :--- | :---: | ---: |
        | GFM Tables | Supported | Full column alignment |
        | Inline Math | Supported | $f(x) = \\int_{-\\infty}^x e^{-t^2} dt$ |
        | Task Lists | Supported | [x] Completed task |
        
        $$\\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}$$
        """)
}

// MARK: - Preview Modifiers

/// Wraps settings or inspector components in an appropriate Form layout.
struct SectionPreviewContainerModifier: PreviewModifier {
    func body(content: Content, context: Void) -> some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
    }
}

// MARK: - PreviewTrait Extensions

extension PreviewTrait where T == Preview.ViewTraits {
    /// Applies form container styling for settings sections.
    static var sectionContainer: PreviewTrait<Preview.ViewTraits> {
        PreviewTrait.modifier(SectionPreviewContainerModifier())
    }
}
