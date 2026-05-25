import SwiftUI

/// Accessibility-oriented large live-transcription view. Hosted in its
/// own opaque `NSWindow` so users who can't comfortably read the small
/// translucent menu-bar popover have a big, high-contrast surface for
/// their dictation. Confirmed segments are weighted/coloured stronger
/// than the still-in-flux tail; both are font-size-controllable.
struct LargeLiveTranscriptionView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusHeader

            // Transcript fills the rest. ScrollView with bottom-anchored
            // content keeps the latest text visible as it streams in.
            ScrollViewReader { proxy in
                ScrollView {
                    Text(attributedTranscript)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("transcript-bottom")
                }
                .onChange(of: appState.liveTranscriptUnconfirmed) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("transcript-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: appState.liveTranscriptConfirmed) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("transcript-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .padding(40)
        .frame(minWidth: 600, minHeight: 360)
    }

    // MARK: - Header (status + timer)

    private var statusHeader: some View {
        HStack(spacing: 12) {
            if appState.isLiveActive {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.regular)
                Text("Live")
                    .font(.system(size: appState.liveLargeWindowFontSize * 0.45, weight: .semibold))
                    .foregroundColor(.red)
            } else {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: appState.liveLargeWindowFontSize * 0.5))
                    .foregroundColor(.secondary)
                Text("Stopped")
                    .font(.system(size: appState.liveLargeWindowFontSize * 0.45, weight: .regular))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if let startedAt = appState.transcriptionStartedAt {
                Text(timerInterval: startedAt...Date.distantFuture,
                     pauseTime: nil,
                     countsDown: false,
                     showsHours: true)
                    .font(.system(size: appState.liveLargeWindowFontSize * 0.45,
                                  weight: .regular,
                                  design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Transcript

    /// Two-segment attributed string: confirmed (settled) text + the
    /// unconfirmed tail still being revised. In high-contrast mode the
    /// distinction is also encoded in font weight so it survives the
    /// user's system colour preferences.
    private var attributedTranscript: AttributedString {
        let size = CGFloat(appState.liveLargeWindowFontSize)
        let highContrast = appState.liveLargeWindowHighContrast

        var s = AttributedString(appState.liveTranscriptConfirmed)
        s.font = .system(size: size, weight: highContrast ? .semibold : .regular)
        s.foregroundColor = .primary

        if !appState.liveTranscriptUnconfirmed.isEmpty {
            let prefix = appState.liveTranscriptConfirmed.isEmpty ? "" : " "
            var tail = AttributedString(prefix + appState.liveTranscriptUnconfirmed)
            tail.font = .system(size: size, weight: .regular)
            tail.foregroundColor = highContrast ? .secondary : Color.primary.opacity(0.55)
            s.append(tail)
        }

        // Empty-state hint when nothing has been transcribed yet.
        if appState.liveTranscriptConfirmed.isEmpty
            && appState.liveTranscriptUnconfirmed.isEmpty {
            var hint = AttributedString("Speak now…")
            hint.font = .system(size: size, weight: .regular)
            hint.foregroundColor = Color.secondary.opacity(0.6)
            return hint
        }
        return s
    }
}
