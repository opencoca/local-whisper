import Foundation

/// Metadata for a file currently being transcribed. Drives the large
/// window's header (displayName) and progress bar (durationSeconds).
/// The actual decoded audio is held by `AudioFileLoader.load(_:)` and
/// passed to `TranscriptionService.transcribe(_:)` in chunks — this
/// struct only carries display-layer info.
struct FileTranscriptionSource: Equatable {
    let url: URL
    let durationSeconds: TimeInterval

    var displayName: String {
        url.lastPathComponent
    }
}
