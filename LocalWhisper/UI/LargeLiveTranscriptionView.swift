import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Accessibility-oriented large live-transcription view. Hosted in its
/// own opaque `NSWindow` so users who can't comfortably read the small
/// translucent menu-bar popover have a big, high-contrast surface for
/// their dictation. Confirmed segments are weighted/coloured stronger
/// than the still-in-flux tail; both are font-size-controllable.
struct LargeLiveTranscriptionView: View {
    @EnvironmentObject var appState: AppState

    /// Snapshot of the transcript text taken right before Clear wipes it.
    /// Held for ~4 s so the user can Undo. Nil = nothing to restore.
    @State private var clearSnapshot: (last: String, confirmed: String, unconfirmed: String)?
    @State private var showUndoToast: Bool = false
    /// Tokenizes each Clear so multiple Clears within the window don't
    /// race with each other's auto-dismiss timers.
    @State private var clearToken: UUID = UUID()

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

            stopFooter
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 40)
        .frame(minWidth: 600, minHeight: 360)
        // Explicitly opaque — defends against any vibrancy SwiftUI's
        // hosting context might otherwise inherit. The user specifically
        // called out the popover's translucency as hard to read.
        #if os(macOS)
        .background(Color(nsColor: .windowBackgroundColor))
        #else
        .background(Color(uiColor: .systemBackground))
        #endif
        // Undo toast for Clear — only safety net against accidental
        // destroy. Auto-dismisses after 4 s.
        .overlay(alignment: .bottom) {
            if showUndoToast {
                undoToast
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Footer (Clear · Stop/Record · Copy)

    /// Three affordances. Routing through `handleLiveHotkey()` keeps the
    /// record/stop button and the global hotkey on a single code path —
    /// no risk of the two drifting. Pause was deliberately omitted:
    /// `AudioStreamTranscriber` has no native pause, and simulating one
    /// would mislead users about state (anti-poka-yoke).
    ///
    /// Clear and Copy are essential for notepad mode (mobile-style
    /// scratchpad on desktop): after stop, the transcript persists for
    /// review — these buttons let the user act on it without leaving the
    /// window. They're harmless in auto-paste / clipboard-only modes too;
    /// gated on whether there's any text to act on.
    private var stopFooter: some View {
        HStack(spacing: 12) {
            // Clear — destroys all transcript text (live + last). Disabled
            // when nothing's there. This is the ONLY explicit destroy
            // affordance; Stop preserves. Snapshots before wiping and
            // shows an Undo toast for ~4 s.
            Button {
                clearWithUndo()
            } label: {
                Label("Clear", systemImage: "xmark.circle")
                    .font(.system(size: appState.liveLargeWindowFontSize * 0.4,
                                  weight: .regular))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!hasAnyTranscript)

            Spacer()

            // Stop ⇄ Record — toggles based on session state. In notepad
            // mode, tapping Record after Stop continues the existing
            // transcript with a `\n\n` boundary (coordinator handles).
            Button {
                Task { @MainActor in
                    await appState.coordinator.handleLiveHotkey()
                }
            } label: {
                Label(appState.isLiveActive ? "Stop" : "Record",
                      systemImage: appState.isLiveActive ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.system(size: appState.liveLargeWindowFontSize * 0.4,
                                  weight: .semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(appState.isLiveActive ? .red : .accentColor)

            Spacer()

            // Copy — writes the full visible transcript (confirmed +
            // unconfirmed) to NSPasteboard. The user can then switch to
            // their target app and paste manually. Disabled if empty.
            Button {
                let c = appState.liveTranscriptConfirmed
                let u = appState.liveTranscriptUnconfirmed
                let text: String
                if !c.isEmpty && !u.isEmpty { text = c + " " + u }
                else if !c.isEmpty { text = c }
                else if !u.isEmpty { text = u }
                else { text = appState.lastTranscription }
                guard !text.isEmpty else { return }
                #if os(macOS)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                #endif
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.system(size: appState.liveLargeWindowFontSize * 0.4,
                                  weight: .regular))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!hasAnyTranscript)
        }
        .padding(.top, 8)
    }

    /// True iff there's any displayable transcript to act on (whether
    /// from this session's in-flight stream, a preserved notepad-mode
    /// prefix, or a finalized lastTranscription).
    private var hasAnyTranscript: Bool {
        !appState.liveTranscriptConfirmed.isEmpty
            || !appState.liveTranscriptUnconfirmed.isEmpty
            || !appState.lastTranscription.isEmpty
    }

    /// Snapshot the transcript, wipe, show undo toast. The token guards
    /// against races if the user clicks Clear again within the 4 s window.
    private func clearWithUndo() {
        clearSnapshot = (
            last: appState.lastTranscription,
            confirmed: appState.liveTranscriptConfirmed,
            unconfirmed: appState.liveTranscriptUnconfirmed
        )
        appState.lastTranscription = ""
        appState.liveTranscriptConfirmed = ""
        appState.liveTranscriptUnconfirmed = ""

        let token = UUID()
        clearToken = token
        withAnimation { showUndoToast = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            // Only auto-dismiss if THIS Clear's token is still the latest;
            // otherwise a newer Clear (or an Undo) has already moved on.
            if clearToken == token {
                withAnimation { showUndoToast = false }
                clearSnapshot = nil
            }
        }
    }

    /// Small bottom-anchored capsule that lets the user reverse Clear.
    /// Tapping Undo restores the snapshot; auto-dismisses after 4 s if
    /// untouched.
    private var undoToast: some View {
        HStack(spacing: 12) {
            Text("Cleared")
                .font(.callout)
                .foregroundColor(.primary)
            Button("Undo") {
                guard let snap = clearSnapshot else { return }
                appState.lastTranscription = snap.last
                appState.liveTranscriptConfirmed = snap.confirmed
                appState.liveTranscriptUnconfirmed = snap.unconfirmed
                clearSnapshot = nil
                clearToken = UUID()  // invalidate pending auto-dismiss
                withAnimation { showUndoToast = false }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .shadow(radius: 4, y: 2)
    }

    // MARK: - Header (status + timer)

    private var statusHeader: some View {
        statusHeaderRow
            .padding(.bottom, 16)
    }

    private var statusHeaderRow: some View {
        HStack(spacing: 12) {
            if appState.isLiveActive {
                // Spinner is intentionally muted — the red "Live" label
                // already carries the active-state signal; the spinner
                // is supplementary and shouldn't compete with the
                // streaming text for attention.
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.regular)
                    .opacity(0.45)
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

            // Current toggle hotkey — macOS only. Helps users rediscover
            // the trigger after the popover closes (notepad mode).
            #if os(macOS)
            let hk = HotkeyManager.shared.liveShortcutString
            if !hk.isEmpty {
                Text(hk)
                    .font(.system(size: appState.liveLargeWindowFontSize * 0.32,
                                  weight: .regular,
                                  design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            #endif

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
