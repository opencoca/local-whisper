import SwiftUI

/// iOS-tailored live-transcription display. Functionally mirrors
/// [LargeLiveTranscriptionView.swift] but is typed against
/// `MobileAppState` and uses iOS-appropriate background semantics so the
/// two platforms can evolve their UI without dragging each other.
struct MobileLiveTranscriptionView: View {
    @EnvironmentObject var appState: MobileAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusHeader

            ScrollViewReader { proxy in
                ScrollView {
                    Text(attributedTranscript)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("transcript-bottom")
                        .padding(.vertical, 4)
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
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Status header

    private var statusHeader: some View {
        HStack(spacing: 10) {
            if appState.isLiveActive {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
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
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Transcript

    /// Two-segment attributed string: settled confirmed text + the
    /// unconfirmed tail still being revised by WhisperKit. In high-contrast
    /// mode the distinction is also encoded in font weight so the cue
    /// survives the user's system colour preferences.
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

        if appState.liveTranscriptConfirmed.isEmpty
            && appState.liveTranscriptUnconfirmed.isEmpty {
            var hint = AttributedString(
                appState.isLiveActive ? "Speak now…" : "Tap the mic to start"
            )
            hint.font = .system(size: size, weight: .regular)
            hint.foregroundColor = Color.secondary.opacity(0.6)
            return hint
        }
        return s
    }
}
