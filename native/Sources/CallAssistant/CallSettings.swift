import SwiftUI

struct CallSettings:View {
    @ObservedObject var model:AppModel
    @ObservedObject private var runtime=AgentRuntime.shared
    @Environment(\.dismiss) private var dismiss
    @State private var extensionSetup=false
    @State private var section="assistant"
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(alignment:.top) {
                CallSectionHeading(title:"Settings",subtitle:"Make Cue work your way.")
                Spacer()
                Button("Done") {dismiss()}.keyboardShortcut(.defaultAction).modifier(CallActionStyle())
            }.padding(24)
            Picker("Settings category",selection:$section) {
                Text("Assistant").tag("assistant")
                Text("Connections").tag("connections")
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal,24).padding(.bottom,20)
            Divider()
            Form {
                if section=="assistant" {
                    Section("Intelligence") {
                        Picker("AI provider",selection:$model.aiProvider) {
                            ForEach(AIProvider.allCases,id:\.self){Text($0.title).tag($0)}
                        }.disabled(model.aiBusy || model.liveAISession != nil)
                        Text(runtime.status[model.aiProvider] ?? "AI tools download when first used. Only the selected provider is installed.")
                            .font(.caption).foregroundStyle(CallPalette.muted)
                        if runtime.downloading.contains(model.aiProvider) {
                            ProgressView().controlSize(.small).accessibilityLabel("Downloading AI tools")
                        } else {
                            Button("Download / check AI tools",systemImage:"arrow.down.circle") {
                                let provider=model.aiProvider
                                Task {do {_ = try await runtime.prepare(provider)} catch { /* Status shows the retryable error. */ }}
                            }
                        }
                        Toggle("Summarize completed calls automatically",isOn:$model.automaticSummaries)
                        Text("Call text and attached context are shared with this provider for summaries and coaching. Audio stays on this Mac.")
                            .font(.caption).foregroundStyle(CallPalette.muted)
                    }
                    Section("On-device transcription") {
                        LabeledContent("Speech model",value:model.modelStatus)
                        Button("Download / load speech model",systemImage:"arrow.clockwise") {model.loadModel()}.disabled(model.modelStatus=="Loading")
                        Text("Downloads the Roman Hinglish + English model on first use (about 824 MB). Internet is required for setup; transcription runs locally afterward.").font(.caption).foregroundStyle(CallPalette.muted)
                    }
                    Section("Live coaching") {
                        Toggle("Translucent coaching despite Reduce Transparency",isOn:$model.coachingTransparencyOverride)
                        Text("Overrides the macOS setting for the coaching panel only.").font(.caption).foregroundStyle(CallPalette.muted)
                        VStack(alignment:.leading,spacing:8) {
                            HStack {
                                Text("Backdrop opacity")
                                Spacer()
                                Text(model.coachingBackdropOpacity,format:.percent.precision(.fractionLength(0))).monospacedDigit()
                            }
                            Slider(value:$model.coachingBackdropOpacity,in:0...1,step:0.01) {
                                Text("Coaching backdrop opacity")
                            } minimumValueLabel:{Text("Clear").font(.caption)} maximumValueLabel:{Text("Opaque").font(.caption)}
                            Text("Text and controls stay fully opaque. Reduce Transparency takes priority unless the override above is on.")
                                .font(.caption).foregroundStyle(CallPalette.muted)
                        }
                        Button("Show coaching panel",systemImage:"bubble.left") {model.panel?.show()}
                        Label("Screen sharing may expose coaching. Hide the panel before sharing.",systemImage:"eye")
                            .font(.caption).foregroundStyle(CallPalette.muted)
                    }
                } else {
                    Section("Google Chrome") {
                        Label(model.extensionConnected ? "Extension connected":"Extension not connected",systemImage:model.extensionConnected ? "checkmark.circle":"circle.dashed")
                        Button("Set up Chrome extension…") {extensionSetup=true}
                        LabeledContent("Extension ID") {
                            TextField("Chrome extension ID",text:$model.extensionID).labelsHidden().textFieldStyle(.roundedBorder)
                        }
                        Text(model.bridgeStatus).font(.caption.monospaced()).foregroundStyle(CallPalette.muted).textSelection(.enabled)
                        Text("No pairing code. Local programs can connect; browser origins are checked.").font(.caption).foregroundStyle(CallPalette.muted)
                    }
                    CalendarSettings(calendar:model.calendar)
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
        }.frame(width:580,height:620).background(CallPalette.canvas).tint(CallPalette.accent)
            .modifier(CallActivationClicks()).sheet(isPresented:$extensionSetup) {ExtensionSetup(model:model)}
    }
}
