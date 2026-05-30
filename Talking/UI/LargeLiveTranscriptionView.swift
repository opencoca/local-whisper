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

    // MARK: - Display mode (v1.2.0)
    //
    // The large window started life as the live-transcription surface,
    // but in v1.2.0 it doubles as the read-along view for TTS
    // playback. `displayMode` decides which content / footer to render
    // — never both, since a live capture and a TTS playback can't run
    // simultaneously (the speak hotkey is blocked while liveActive,
    // and vice versa).
    private enum DisplayMode {
        case liveTranscription
        case readAlong
    }

    private var displayMode: DisplayMode {
        appState.speakState.isActive ? .readAlong : .liveTranscription
    }

    /// Cached sentence ranges + display strings for the read-along
    /// path. Recomputed whenever `appState.readAlongText` changes.
    /// Each ID-bearing sentence becomes its own Text in the scroll
    /// view so the centering anchor can target whichever sentence
    /// the highlighted word currently lives in.
    @State private var sentenceCache: [SentenceChunk] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusHeader

            // Transcript fills the rest. Live-transcription path keeps
            // its bottom-anchored single-Text layout (always show the
            // newest word as audio streams in). Read-along splits into
            // per-sentence Text views with IDs so we can scroll to the
            // sentence containing the highlighted word with
            // anchor: .center — keeping the active word vertically
            // centered in the modal as playback advances.
            ScrollViewReader { proxy in
                ScrollView {
                    switch displayMode {
                    case .liveTranscription:
                        Text(transcriptContent)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("transcript-bottom")
                    case .readAlong:
                        readAlongSentenceList
                    }
                }
                .onChange(of: appState.liveTranscriptUnconfirmed) {
                    guard case .liveTranscription = displayMode else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("transcript-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: appState.liveTranscriptConfirmed) {
                    guard case .liveTranscription = displayMode else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("transcript-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: appState.readAlongRange) {
                    guard case .readAlong = displayMode,
                          let range = appState.readAlongRange,
                          let sentenceIdx = sentenceIndexContaining(range.location)
                    else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("sentence-\(sentenceIdx)", anchor: .center)
                    }
                }
                .onChange(of: appState.readAlongText) {
                    sentenceCache = computeSentenceChunks(appState.readAlongText)
                }
                .onAppear {
                    sentenceCache = computeSentenceChunks(appState.readAlongText)
                }
            }

            footer
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

    // MARK: - Footer (mode-aware)

    @ViewBuilder
    private var footer: some View {
        switch displayMode {
        case .liveTranscription:
            stopFooter
        case .readAlong:
            readAlongFooter
        }
    }

    /// Read-along mode controls: Pause / Resume / Stop. Save Audio is
    /// available from the popover's SpeakPanel — keeping it off the
    /// large window keeps the footer single-purpose for playback
    /// control while text is being read.
    private var readAlongFooter: some View {
        HStack(spacing: 12) {
            if case .paused = appState.speakState {
                Button {
                    Task { await appState.coordinator.resumeSpeak() }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .font(.system(size: appState.liveLargeWindowFontSize * 0.35))
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button {
                    Task { await appState.coordinator.pauseSpeak() }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .font(.system(size: appState.liveLargeWindowFontSize * 0.35))
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Spacer()

            Button(role: .destructive) {
                Task { await appState.coordinator.stopSpeak() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: appState.liveLargeWindowFontSize * 0.35))
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.top, 16)
    }

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
            switch displayMode {
            case .readAlong:
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: appState.liveLargeWindowFontSize * 0.5))
                    .foregroundColor(.blue)
                Text(readAlongHeaderLabel)
                    .font(.system(size: appState.liveLargeWindowFontSize * 0.45, weight: .semibold))
                    .foregroundColor(.blue)
            case .liveTranscription:
                if appState.isLiveActive {
                    // Spinner is intentionally muted — the red "Live"
                    // label already carries the active-state signal.
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
            }

            // Current toggle hotkey — macOS only. Helps users rediscover
            // the trigger after the popover closes (notepad mode).
            #if os(macOS)
            let hk = displayMode == .readAlong
                ? HotkeyManager.shared.speakShortcutString
                : HotkeyManager.shared.liveShortcutString
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

            // Live mode: elapsed-time counter. Read-along: progress
            // percentage (from the speakState).
            switch displayMode {
            case .liveTranscription:
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
            case .readAlong:
                // Show the percentage in both .speaking and .paused
                // (the new associated-value .paused carries the saved
                // progress so the counter doesn't blank on pause).
                if let progress = appState.speakState.progress {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: appState.liveLargeWindowFontSize * 0.45,
                                      weight: .regular,
                                      design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    /// Header label for read-along: "Read-along" by default, or
    /// "Read-along · Paused" when paused.
    private var readAlongHeaderLabel: String {
        if case .paused = appState.speakState {
            return "Read-along · Paused"
        }
        return "Read-along"
    }

    // MARK: - Transcript

    /// Mode-aware content. In live mode, the two-segment attributed
    /// transcript (confirmed + unconfirmed tail). In read-along mode,
    /// the full source text with the current word range tinted.
    private var transcriptContent: AttributedString {
        switch displayMode {
        case .liveTranscription:
            return attributedTranscript
        case .readAlong:
            return attributedReadAlong
        }
    }

    // MARK: - Sentence-level read-along layout

    /// One sentence pulled out of `readAlongText` by
    /// `NSString.enumerateSubstrings(.bySentences)`. The `range` is
    /// the position of the sentence in the original text — used to
    /// (a) find which sentence contains the current readAlongRange
    /// for scroll-targeting, and (b) translate readAlongRange into a
    /// sentence-local range when applying the highlight.
    private struct SentenceChunk: Hashable {
        let range: NSRange
        let text: String
    }

    private func computeSentenceChunks(_ text: String) -> [SentenceChunk] {
        guard !text.isEmpty else { return [] }
        var chunks: [SentenceChunk] = []
        let ns = text as NSString
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.bySentences, .localized]
        ) { substring, range, _, _ in
            guard let s = substring, !s.isEmpty else { return }
            chunks.append(SentenceChunk(range: range, text: s))
        }
        // Fallback: if .bySentences yielded nothing (text had no
        // sentence-terminating punctuation), treat the whole thing as
        // one chunk so the scroll target still resolves.
        if chunks.isEmpty {
            chunks.append(SentenceChunk(range: NSRange(location: 0, length: ns.length), text: text))
        }
        return chunks
    }

    private func sentenceIndexContaining(_ location: Int) -> Int? {
        sentenceCache.firstIndex { NSLocationInRange(location, $0.range) }
    }

    /// VStack of per-sentence Texts. The sentence containing the
    /// current highlight has its active word range tinted; the rest
    /// render plain. SwiftUI only invalidates the chunk whose attributes
    /// changed, so per-tick updates touch one Text not the whole stack.
    @ViewBuilder
    private var readAlongSentenceList: some View {
        let size = CGFloat(appState.liveLargeWindowFontSize)
        let highlightSentenceIdx: Int? = {
            guard let r = appState.readAlongRange else { return nil }
            return sentenceIndexContaining(r.location)
        }()

        VStack(alignment: .leading, spacing: max(size * 0.25, 8)) {
            if sentenceCache.isEmpty {
                Text("Preparing…")
                    .font(.system(size: size, weight: .regular))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .id("sentence-empty")
            }
            ForEach(Array(sentenceCache.enumerated()), id: \.offset) { idx, chunk in
                Text(attributedSentence(chunk, isHighlightedChunk: idx == highlightSentenceIdx))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("sentence-\(idx)")
            }
        }
    }

    /// Build the AttributedString for one sentence, applying the
    /// word-level highlight ONLY if this is the sentence the
    /// readAlongRange currently lives in.
    private func attributedSentence(_ chunk: SentenceChunk, isHighlightedChunk: Bool) -> AttributedString {
        let size = CGFloat(appState.liveLargeWindowFontSize)
        let highContrast = appState.liveLargeWindowHighContrast

        var s = AttributedString(chunk.text)
        s.font = .system(size: size, weight: highContrast ? .semibold : .regular)
        s.foregroundColor = .primary

        guard isHighlightedChunk,
              let absoluteRange = appState.readAlongRange,
              absoluteRange.length > 0
        else { return s }

        // Translate the absolute range into chunk-local coordinates.
        let localLoc = absoluteRange.location - chunk.range.location
        let localEnd = localLoc + absoluteRange.length
        guard localLoc >= 0,
              localEnd <= chunk.text.utf16.count
        else { return s }

        let startIdx = String.Index(utf16Offset: localLoc, in: chunk.text)
        let endIdx = String.Index(utf16Offset: localEnd, in: chunk.text)
        guard startIdx < chunk.text.endIndex,
              endIdx <= chunk.text.endIndex,
              let lower = AttributedString.Index(startIdx, within: s),
              let upper = AttributedString.Index(endIdx, within: s)
        else { return s }

        let highlightRange = lower..<upper
        s[highlightRange].backgroundColor = Color.yellow.opacity(0.35)
        s[highlightRange].foregroundColor = .primary
        return s
    }

    /// Read-along rendering: full source text + a colored background
    /// on the active word range from `appState.readAlongRange`. SwiftUI
    /// re-renders only the styled run when the range changes, so per-
    /// word updates are cheap.
    private var attributedReadAlong: AttributedString {
        let size = CGFloat(appState.liveLargeWindowFontSize)
        let highContrast = appState.liveLargeWindowHighContrast

        let text = appState.readAlongText
        if text.isEmpty {
            var hint = AttributedString("Preparing…")
            hint.font = .system(size: size, weight: .regular)
            hint.foregroundColor = Color.secondary.opacity(0.6)
            return hint
        }

        var s = AttributedString(text)
        s.font = .system(size: size, weight: highContrast ? .semibold : .regular)
        s.foregroundColor = .primary

        // Apply the highlight to the current word range. AVSpeech
        // delivers NSRange against the utterance's UTF-16 view, which
        // is exactly what NSString uses. We bound-check explicitly
        // (String.Index(utf16Offset:in:) can return indices beyond
        // text.endIndex on overflow), then convert into
        // AttributedString.Index via the failable bridging initializer
        // — that's the real safety net.
        if let range = appState.readAlongRange,
           range.location >= 0,
           range.length > 0 {
            let s16start = String.Index(utf16Offset: range.location, in: text)
            let s16end = String.Index(utf16Offset: range.location + range.length, in: text)
            if s16start < text.endIndex, s16end <= text.endIndex,
               let lower = AttributedString.Index(s16start, within: s),
               let upper = AttributedString.Index(s16end, within: s) {
                let highlightRange = lower..<upper
                s[highlightRange].backgroundColor = Color.yellow.opacity(0.35)
                s[highlightRange].foregroundColor = .primary
            }
        }

        return s
    }

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
