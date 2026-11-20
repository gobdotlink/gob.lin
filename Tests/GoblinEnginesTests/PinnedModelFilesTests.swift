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

@Test func theVoiceModelIsPinnedToTheV2Conversion() throws {
    let manifest = SpeechModelAssets.manifest(for: "campplus-v2")
    let bundles = ["CamPlusPreprocessor_v2.mlmodelc/", "CamPlusPlus_v2.mlmodelc/"]
    let files = ["analytics/coremldata.bin", "coremldata.bin", "metadata.json", "model.mil", "weights/weight.bin"]
    #expect(Set(manifest.files.map(\.destination)) == Set(bundles.flatMap { bundle in files.map { bundle + $0 } }))
    #expect(manifest.files.allSatisfy { $0.repository == "FluidInference/campplus-coreml" && $0.path == $0.destination })
    #expect(Set(manifest.files.map(\.revision)).count == 1)
    #expect(manifest.files.allSatisfy { $0.revision.count == 40 && $0.sha256.count == 64 && $0.size > 0 })
    // v1 gave unrelated voiceprints at some lengths; only v2 may be pinned.
    #expect(!manifest.files.contains { $0.destination.hasPrefix("CamPlusPlus.mlmodelc") || $0.destination.hasPrefix("CamPlusPreprocessor.mlmodelc") })
}

@Test func theEchoCancellerIsPinnedToOneLocalVQEBundle() throws {
    let manifest = SpeechModelAssets.manifest(for: "localvqe-v1.3-256ms")
    // v1.3 in 256 ms calls, the file FluidAudio 0.17.7 loads for that configuration; the other variants aren't needed.
    let bundle = "localvqe-v1.3-4.8M-256ms.mlmodelc/"
    #expect(Set(manifest.files.map(\.destination)) == Set(["analytics/coremldata.bin", "coremldata.bin", "model.mil", "weights/weight.bin"]
        .map { bundle + $0 }))
    #expect(manifest.files.allSatisfy { $0.repository == "FluidInference/localvqe-coreml" && $0.path == $0.destination })
    #expect(Set(manifest.files.map(\.revision)).count == 1)
    #expect(manifest.files.allSatisfy { $0.revision.count == 40 && $0.sha256.count == 64 && $0.size > 0 })
}
