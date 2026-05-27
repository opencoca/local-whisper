import SwiftUI

/// iOS / iPadOS entry point. One WindowGroup that hosts `ContentView`.
/// `MobileAppState.shared` is the single source of truth — same singleton
/// pattern the macOS app uses, but typed against the iOS-only state class
/// so neither platform leaks symbols into the other.
///
/// On first launch, kicks off model loading from the bundled `tiny.en`
/// pack so the user can record immediately without a network round-trip.
@main
struct LocalWhisperMobileApp: App {
    @StateObject private var appState = MobileAppState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .task { await loadModel() }
        }
    }

    /// Resolve the bundled `tiny.en` model folder and hand it to the
    /// transcription service. The model files live under
    /// `Mobile/Resources/Models/openai_whisper-tiny.en/` and are added to
    /// the iOS app bundle as a folder reference (see Xcode project).
    private func loadModel() async {
        // The bundled folder is added as a "folder reference" in Xcode so
        // its directory tree is preserved at runtime. `Bundle.main.url(
        // forResource:withExtension:)` resolves the top-level "Models"
        // directory; WhisperKit then picks the specific variant by name.
        let bundledModelsFolder = Bundle.main.url(
            forResource: "Models",
            withExtension: nil
        )

        await appState.transcriptionService.loadModel(
            modelName: appState.selectedModel,
            modelFolder: bundledModelsFolder?.path
        )
        appState.isModelLoaded = await appState.transcriptionService.isModelLoaded
    }
}
