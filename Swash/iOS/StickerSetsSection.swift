//
//  StickerSetsSection.swift
//  Swash
//
//  Settings section that lists the sticker sets in the Swash Stickers iMessage app. The artwork
//  is proprietary: App Store builds swap the real PixerateStickers package in for the open-source
//  stub at Packages/PixerateStickers. `IOSSettingsView` shows this section only when
//  `StickerCatalog.isAvailable`, which is always false in the stub, so open-source builds show
//  nothing (and don't ship the iMessage extension either).
//

#if os(iOS)
import SwiftUI
import PixerateStickers

struct StickerSetsSection: View {
    var body: some View {
        Section {
            ForEach(StickerCatalog.sets) { set in
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        ForEach(StickerCatalog.stickers(in: [set.id]).prefix(3)) { sticker in
                            StickerImage(sticker)
                                .frame(width: 32, height: 32)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(set.name)
                        Text("\(set.count) stickers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Stickers")
        } footer: {
            Text("Send these stickers from the Swash Stickers app in Messages.")
        }
    }
}
#endif
