//
//  MessagesViewController.swift
//  SwashStickers
//
//  iMessage sticker pack. The artwork comes from the proprietary PixerateStickers package, which
//  App Store builds swap in for the open-source stub at Packages/PixerateStickers. Open-source
//  builds strip this extension from the app (the "Strip Sticker Pack From Open-Source Builds"
//  phase on the Swash target), so the stub's empty browser is never installed.
//

import Messages
import PixerateStickers

@objc(MessagesViewController)
final class MessagesViewController: PixerateStickerBrowserViewController {
    override var stickerSets: [StickerSetID] { [.swash, .pixerate, .slopMachine, .uchiage] }
    override var stickerSize: MSStickerSize { .regular }
}
