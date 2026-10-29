import SwiftUI

struct SetupChecklist:View {
    @ObservedObject var model:AppModel
    @ObservedObject private var runtime=AgentRuntime.shared
    let onConnectChrome:()->Void
    var body:some View {
        Section("Readiness") {
            Label(model.extensionConnected ? "Chrome extension connected":"Chrome extension needs setup",systemImage:model.extensionConnected ? "checkmark.circle":"exclamationmark.circle")
            Label(model.modelReady ? "Speech model ready":model.speechModelDownloaded ? "Speech model found · needs loading":"Speech model needs downloading",systemImage:model.modelReady ? "checkmark.circle":"arrow.down.circle")
            Label(runtime.installed.contains(model.aiProvider) ? "\(model.aiProvider.title) tools already installed":model.aiConsentGranted ? "\(model.aiProvider.title) tools need downloading":"AI tools optional · not downloaded",systemImage:runtime.installed.contains(model.aiProvider) ? "checkmark.circle":"arrow.down.circle")
        }
        Section("1 · Recording permission") {
            Toggle("Allow Cue to save and process call audio and captions",isOn:Binding(get:{model.captureConsentGranted},set:{model.setCaptureConsent($0)}))
            Text("Joined Meet calls save automatically while capture is enabled. Recordings and transcription stay on this Mac, with a browser backup. Get the participants’ permission before recording. Turning this off pauses capture and intake; existing recordings are kept.")
                .font(.caption).foregroundStyle(CallPalette.muted)
            Text("Chrome handles Meet microphone permission. Cue does not request separate microphone or screen-recording access. Optional Calendar permission is requested when you connect Calendar below.")
                .font(.caption).foregroundStyle(CallPalette.muted)
        }
        Section("2 · Chrome extension") {
            Label(model.extensionConnected ? "Connected":model.extensionID.isEmpty ? "Not configured":"ID saved · waiting for Chrome",systemImage:model.extensionConnected ? "checkmark.circle":"exclamationmark.circle")
            Button("Install / connect extension…",action:onConnectChrome)
            Text("Use your existing Chrome profile. New extension files are prepared in Home → Cue Extension.").font(.caption).foregroundStyle(CallPalette.muted)
        }
        Section("3 · On-device speech model") {
            Label(model.modelReady ? "Loaded and ready":model.modelStatus,systemImage:model.modelReady ? "checkmark.circle":"exclamationmark.circle")
            if model.modelStatus=="Loading" {ProgressView().controlSize(.small)}
            else if !model.modelReady {
                Button(model.speechModelDownloaded ? "Load existing speech model":"Download speech model (about 824 MB)") {model.loadModel()}
            }
            Text(model.speechModelDownloaded ? "Model files already exist on this Mac; Cue reuses them.":"Download once for Roman Hinglish and English transcription. Transcription runs locally afterward.").font(.caption).foregroundStyle(CallPalette.muted)
            if !model.modelReady,!model.errorMessage.isEmpty {Text(model.errorMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
        }
        Section("4 · Optional AI coaching and summaries") {
            Toggle("Allow call text and attached context to be sent to my AI provider",isOn:Binding(get:{model.aiConsentGranted},set:{model.setAIConsent($0)}))
            Picker("Provider",selection:$model.aiProvider) {ForEach(AIProvider.allCases,id:\.self){Text($0.title).tag($0)}}
                .disabled(model.aiBusy || model.liveAISession != nil)
            Label(runtime.status[model.aiProvider] ?? "Checking installed tools…",systemImage:runtime.installed.contains(model.aiProvider) ? "checkmark.circle":"exclamationmark.circle")
            if runtime.downloading.contains(model.aiProvider) {ProgressView().controlSize(.small)}
            else if !runtime.installed.contains(model.aiProvider) {
                Button("Download \(model.aiProvider.title) tools") {
                    let provider=model.aiProvider
                    Task {do {_ = try await runtime.prepare(provider)} catch { /* The retryable error is shown above. */ }}
                }.disabled(!model.aiConsentGranted)
            }
            Button("Check existing installations") {runtime.refresh()}
            Text("Only the selected provider’s missing connector tools are downloaded. Existing provider sign-in can be reused, but Cue still needs its own ACP tools. Tools and account access are separate: sign in to your provider on this Mac. Account access and usage limits are checked when coaching starts; installing tools does not confirm them.").font(.caption).foregroundStyle(CallPalette.muted)
            if !model.aiError.isEmpty {Text(model.aiError).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
        }
        CalendarSettings(calendar:model.calendar)
    }
}
