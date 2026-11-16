import Foundation
import Testing
@testable import GoblinEngines

@Test(arguments: ["offline", "fast32", "fast128"])
func theMeetingSpeakerModelIsPinnedLikeTheSpeechModels(preset: String) throws {
    let manifest = SpeechModelAssets.manifest(for: "nemotron-3-diarization-\(preset)")
    let bundle = "Nemotron3Diarizer_\(preset).mlmodelc/"
    #expect(Set(manifest.files.map(\.destination)) == [bundle + "analytics/coremldata.bin", bundle + "coremldata.bin",
                                                       bundle + "model.mil", bundle + "weights/weight.bin", "learnable_sil_emb.bin"])
    #expect(manifest.files.allSatisfy { $0.repository == "FluidInference/nemotron-3-diarization-coreml" })
    #expect(Set(manifest.files.map(\.revision)).count == 1)
    #expect(manifest.files.allSatisfy { $0.revision.count == 40 && $0.revision.allSatisfy(\.isHexDigit) })
    #expect(manifest.files.allSatisfy { $0.sha256.count == 64 && $0.sha256.allSatisfy(\.isHexDigit) && $0.size > 0 })
    // The model's own files come from the FluidAudio 0.17.7 layout (monolithic/v2), the silence embedding from the root.
    #expect(manifest.files.allSatisfy { $0.path == ($0.destination == "learnable_sil_emb.bin" ? "" : "monolithic/v2/") + $0.destination })
}

@Test func pinnedFilesInAnEmptyFolderAreNotDownloaded() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pinned-\(UUID().uuidString)")
    let files = PinnedModelFiles(manifestID: "nemotron-3-diarization-offline", directory: directory)
    #expect(!files.isDownloaded)
    #expect(files.downloadBytes > 190_000_000)
}

@Test func onlyParakeetsWithTheMeetingsLanguagesAreLentToMeetings() {
    #expect(SpeechModelCatalog.parakeet.servesMeetings)
    // English-only Parakeets would fail a meeting held in another language.
    #expect(!SpeechModelCatalog.phonon.servesMeetings)
    #expect(!SpeechModelCatalog.parakeetCompact.servesMeetings)
    #expect(!SpeechModelCatalog.whisperLarge.servesMeetings)
}
