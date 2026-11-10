import Testing
import PixerateStickers

@Suite("PixerateStickers Open-Source Stub")
struct PixerateStickersStubTests {
    @Test("Reports stickers as unavailable in open-source builds")
    func unavailableByDefault() {
        #expect(StickerCatalog.isAvailable == false)
        #expect(StickerCatalog.sets.isEmpty)
        #expect(StickerCatalog.all.isEmpty)
        #expect(StickerCatalog.stickers(in: [.pixerate, .uchiage]).isEmpty)
    }
}
