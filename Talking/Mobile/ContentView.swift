import SwiftUI
import UIKit

/// Single-screen iOS UI. The product shape is a focused scratchpad:
/// tap to record → live transcript streams → stop → Copy → user swaps
/// apps and pastes. No global hotkey, no auto-paste — that's the macOS
/// app's job. This one stays focused.
struct ContentView: View {
    @EnvironmentObject var appState: MobileAppState
    @State private var showingSettings = false
    @State private var showCopiedToast = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                MobileLiveTranscriptionView()
                    .environmentObject(appState)
                    .frame(maxHeight: .infinity)

                actionRow
            }
            .padding(20)
            .navigationTitle("Talking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .environmentObject(appState)
            }
            .overlay(alignment: .bottom) {
                if showCopiedToast {
                    toast
                        .padding(.bottom, 120)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .alert("Error",
                   isPresented: Binding(
                       get: { appState.errorMessage != nil },
                       set: { if !$0 { appState.errorMessage = nil } }
                   ),
                   actions: {
                       Button("OK") { appState.errorMessage = nil }
                   },
                   message: {
                       Text(appState.errorMessage ?? "")
                   })
        }
    }

    // MARK: - Action row

    /// Three buttons:
    /// 1. Big primary record/stop — the only thing most users will tap.
    /// 2. Copy — visible only when there's a transcript.
    /// 3. Clear — visible only when there's a transcript.
    private var actionRow: some View {
        VStack(spacing: 16) {
            recordButton

            if !appState.lastTranscription.isEmpty
                || !appState.liveTranscriptConfirmed.isEmpty
                || !appState.liveTranscriptUnconfirmed.isEmpty {
                HStack(spacing: 16) {
                    Button {
                        copyToClipboard()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        clearTranscript()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
        }
    }

    private var recordButton: some View {
        Button {
            Task { await appState.coordinator.handleLiveHotkey() }
        } label: {
            HStack(spacing: 12) {
                // Three states: model-loading / idle / recording. The
                // loading state shows a spinner instead of an icon and
                // disables the button — much better than the silent
                // "Model not loaded yet. Please wait…" error toast that
                // appeared when users tapped during the WhisperKit
                // prewarm + load window (5-10 s on iPad Mini A15 first launch).
                if !appState.isModelLoaded {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.regular)
                        .tint(.white)
                        .opacity(0.85)
                    Text("Loading model…")
                        .font(.title2)
                        .fontWeight(.semibold)
                } else {
                    Image(systemName: appState.isLiveActive ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 36))
                    Text(appState.isLiveActive ? "Stop" : "Tap to Record")
                        .font(.title2)
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(loadingTint)
        .disabled(!appState.isModelLoaded)
        .animation(.easeOut(duration: 0.2), value: appState.isModelLoaded)
        .animation(.easeOut(duration: 0.2), value: appState.isLiveActive)
    }

    /// Button color logic: gray while loading, accent when ready to record,
    /// red while recording. Distinct enough that the loading state is
    /// visually unmistakable.
    private var loadingTint: Color {
        if !appState.isModelLoaded { return .gray }
        return appState.isLiveActive ? .red : .accentColor
    }

    private var toast: some View {
        Text("Copied. Switch apps and paste.")
            .font(.callout)
            .fontWeight(.medium)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
            .shadow(radius: 4, y: 2)
    }

    // MARK: - Actions

    /// Prefer the finalized `lastTranscription` (after Stop). If a live
    /// session is still active, fall back to the running confirmed+unconfirmed
    /// concatenation so the Copy button works mid-stream too.
    private func copyToClipboard() {
        let text: String
        if !appState.lastTranscription.isEmpty {
            text = appState.lastTranscription
        } else {
            let parts = [appState.liveTranscriptConfirmed, appState.liveTranscriptUnconfirmed]
                .filter { !$0.isEmpty }
            text = parts.joined(separator: " ")
        }
        guard !text.isEmpty else { return }

        UIPasteboard.general.string = text

        withAnimation { showCopiedToast = true }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { showCopiedToast = false }
        }
    }

    private func clearTranscript() {
        appState.lastTranscription = ""
        appState.liveTranscriptConfirmed = ""
        appState.liveTranscriptUnconfirmed = ""
    }
}
