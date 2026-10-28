import SwiftUI
import AppKit

struct CallAttachments:View {
    @ObservedObject var model:AppModel
    private enum Dialog:String,Identifiable {case conversation,project;var id:String {rawValue}}
    @State private var dialog:Dialog?
    @State private var draft=AIProject()
    @State private var conversations=[AIConversation]()
    @State private var search=""
    @State private var error=""
    @State private var refresh=UUID()
    @State private var editingSession=""
    @State private var loading=false
    private var visibleConversations:[AIConversation] {
        Array(conversations.filter{search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)}.prefix(50))
    }
    var body:some View {
        HStack(spacing:8) {
            Button {open(.conversation)} label:{Label("Conversation",systemImage:model.aiProject.conversation.isEmpty ? "bubble.left":"bubble.left.fill")}
            Button {open(.project)} label:{Label("Project",systemImage:model.hasProjectAttachment(model.aiProject) ? "folder.fill":"folder")}
        }.controlSize(.small).buttonStyle(.bordered).disabled(model.aiBusy || model.liveAISession != nil)
            .sheet(item:$dialog) { choice in
                VStack(alignment:.leading,spacing:20) {
                    CallSectionHeading(title:choice == .conversation ? "Conversation":"Project context",subtitle:choice == .conversation ? "Keep the thread going.":"Give your assistant the background.")
                    if choice == .conversation {
                        Text("Continue a saved conversation or start a new one for this call.").foregroundStyle(.secondary)
                        HStack {
                            TextField("Find a conversation",text:$search).modifier(CallInputStyle())
                            if loading {ProgressView().controlSize(.small).accessibilityLabel("Loading saved conversations")}
                        }
                        List {
                            Button {draft.conversation=""} label: {
                                HStack {Text("New conversation for this call");Spacer();if draft.conversation.isEmpty {Image(systemName:"checkmark")}}
                            }.buttonStyle(.plain).padding(.vertical,6)
                            ForEach(visibleConversations) { conversation in
                                Button {draft.path=conversation.project;draft.conversation=conversation.id} label: {
                                    HStack {Text(conversation.title).lineLimit(2);Spacer();if draft.conversation==conversation.id {Image(systemName:"checkmark")}}
                                }.buttonStyle(.plain).padding(.vertical,6)
                            }
                        }.frame(height:220)
                        HStack {
                            VStack(alignment:.leading,spacing:6) {
                                Text("Conversation ID · optional").font(.caption).foregroundStyle(CallPalette.muted)
                                TextField("Conversation ID",text:$draft.conversation).modifier(CallInputStyle())
                            }
                            Button {refresh=UUID()} label:{Label("Refresh",systemImage:"arrow.clockwise")}.labelStyle(.iconOnly).help("Refresh conversations")
                        }
                    } else {
                        Text("Attach a folder to give this call project context. For recurring calls, the folder and background apply to every occurrence.").foregroundStyle(.secondary)
                        Label(model.hasProjectAttachment(draft) ? draft.path:"No project attached",systemImage:"folder")
                            .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                        HStack {
                            Button("Choose folder…") {
                                let picker=NSOpenPanel();picker.canChooseDirectories=true;picker.canChooseFiles=false;picker.allowsMultipleSelection=false
                                if picker.runModal() == .OK,let url=picker.url {draft.path=url.resolvingSymlinksInPath().path;draft.conversation="";draft.skill=nil}
                            }
                            if model.hasProjectAttachment(draft) {Button("Remove attachment",role:.destructive) {draft.path="";draft.conversation="";draft.skill=nil}}
                        }
                        VStack(alignment:.leading,spacing:6) {
                            Text("Goal or background").font(.callout.weight(.medium))
                            TextField("What would you like to accomplish?",text:$draft.background,axis:.vertical)
                                .modifier(CallInputStyle()).lineLimit(3...6).accessibilityLabel("Goal or background for this call")
                        }
                        Picker("Coaching skill",selection:Binding(get:{draft.skill ?? ""},set:{draft.skill=$0.isEmpty ? nil:$0})) {
                            Text("None").tag("")
                            ForEach(draft.skills(),id:\.self) {path in Text(URL(fileURLWithPath:path).deletingLastPathComponent().lastPathComponent).tag(path)}
                        }
                        Text("Project briefing files and attached context are shared with the AI provider selected in Settings. Audio stays on this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !error.isEmpty {Text(error).font(.caption).foregroundStyle(.red)}
                    HStack {
                        Button("Cancel") {dialog=nil}.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Save") {
                            do {try model.saveAIProject(draft,for:editingSession,shareProject:choice == .project);dialog=nil}
                            catch {self.error=error.localizedDescription}
                        }.modifier(CallActionStyle()).keyboardShortcut(.defaultAction)
                    }
                }.padding(28).frame(width:540).background(CallPalette.canvas).tint(CallPalette.accent)
                    .modifier(CallActivationClicks())
                    .task(id:refresh) {
                        guard choice == .conversation else {return}
                        loading=true
                        defer {loading=false}
                        let project=draft
                        do {
                            let found=try await Task.detached {try project.conversations(allProjects:true)}.value
                            if !Task.isCancelled {conversations=found}
                        } catch {if !Task.isCancelled {self.error="Cannot read saved conversations: \(error.localizedDescription)"}}
                    }
            }.onChange(of:model.activeSession){_,_ in dialog=nil}
    }
    private func open(_ dialog:Dialog) {
        draft=model.aiProject;editingSession=model.activeSession ?? "";search="";error="";conversations=[];refresh=UUID();self.dialog=dialog
    }
}

struct AIControls:View {
    @ObservedObject var model:AppModel
    let detail:[String:Any]
    private var summary:[String:Any] {detail["aiSummary"] as? [String:Any] ?? [:]}
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            HStack(alignment:.top) {
                CallSectionHeading(title:"The takeaway",subtitle:"Decisions, next steps, and what remains open.")
                Spacer()
                Menu {
                    Button(summary.isEmpty ? "Generate summary":"Regenerate summary") {model.runAI(.summary)}
                    if (detail["meta"] as? [String:Any])?["ended"] as? Bool != true {
                        Button("Get coaching") {model.runAI(.coaching)}
                    }
                } label:{Label("Summary actions",systemImage:"ellipsis")}
                    .labelStyle(.iconOnly).menuIndicator(.hidden).fixedSize().help("Summary actions")
                    .disabled(model.aiBusy || model.paused)
            }
            if model.aiBusy,model.aiSession==model.activeSession {
                HStack(spacing:12) {
                    ProgressView().controlSize(.small)
                    Text(model.aiStatus).font(.callout).foregroundStyle(CallPalette.muted)
                    Spacer()
                    Button("Cancel") {model.stopAI()}
                }.modifier(CallCard())
            }
            let automation=detail["summaryAutomation"] as? [String:Any] ?? [:]
            if automation["state"] as? String == "failed" {
                VStack(alignment:.leading,spacing:8) {
                    Label("Summary could not be generated",systemImage:"exclamationmark.circle").foregroundStyle(.red)
                    Text(automation["error"] as? String ?? "Retry from Summary actions.").font(.callout).foregroundStyle(CallPalette.muted).textSelection(.enabled)
                }.modifier(CallCard())
            } else if model.aiErrorSession==model.activeSession,!model.aiError.isEmpty {
                Label(model.aiError,systemImage:"exclamationmark.circle").foregroundStyle(.red).textSelection(.enabled).modifier(CallCard())
            }
            if !summary.isEmpty {CallAIResult(result:summary)}
            else {
                VStack(alignment:.leading,spacing:16) {
                    if automation["state"] as? String == "queued" {
                        CallEmptyState(symbol:"clock",title:"A little more to process",message:model.automaticSummaries ? "Your summary will appear when transcription finishes.":"Automatic summaries are paused. Enable them in Settings to continue.")
                    } else if model.automaticSummaries,(detail["meta"] as? [String:Any])?["ended"] as? Bool != true {
                        CallEmptyState(symbol:"text.alignleft",title:"Stay in the conversation",message:"Your summary will appear after the call ends.")
                    } else {
                        CallEmptyState(symbol:"text.alignleft",title:"Turn this call into clarity",message:"Create a summary with the key points, decisions, and next steps.")
                        Button("Generate summary",systemImage:"sparkles") {model.runAI(.summary)}
                            .modifier(CallActionStyle()).disabled(model.aiBusy || model.paused)
                    }
                }.modifier(CallCard())
            }
            if model.liveAISession != nil || (detail["meta"] as? [String:Any])?["ended"] as? Bool != true {
                HStack {
                    Label("Live coaching",systemImage:"bubble.left").font(.callout.weight(.semibold))
                    Spacer()
                    if model.liveAISession != nil {
                        Button("Stop coaching") {model.stopAI()}
                    } else {
                        Button("Start coaching") {model.startLiveAI()}.disabled(model.aiBusy || model.paused)
                    }
                }.modifier(CallCard())
            }
            if let result=detail["aiCoaching"] as? [String:Any],!result.isEmpty {
                CallSectionHeading(title:"Latest coaching",subtitle:"")
                CallAIResult(result:result)
            }
        }
    }
}

struct CallAIResult:View {
    let result:[String:Any]
    private let sections=[("points","Key points","list.bullet"),("decisions","Decisions","checkmark.circle"),("actions","Next steps","arrow.right.circle"),("uncertainties","Open questions","questionmark.circle")]
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            VStack(alignment:.leading,spacing:12) {
                if let headline=result["headline"] as? String,!headline.isEmpty {
                    Text(headline).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                }
                ForEach(["question","summary"],id:\.self) {key in
                    if let text=result[key] as? String,!text.isEmpty {Text(text).textSelection(.enabled).lineSpacing(6)}
                }
            }.modifier(CallCard())
            ForEach(sections,id:\.0) {section in
                if let values=result[section.0] as? [String],!values.isEmpty {
                    VStack(alignment:.leading,spacing:16) {
                        Label(section.1,systemImage:section.2).font(.headline).accessibilityAddTraits(.isHeader)
                        Text(values.map{"• "+$0}.joined(separator:"\n\n")).textSelection(.enabled).lineSpacing(5)
                    }.modifier(CallCard())
                }
            }
            Label("AI generated · check important details against the transcript.",systemImage:"info.circle")
                .font(.caption).foregroundStyle(CallPalette.muted)
            if let notices=result["providerNotices"] as? [String],!notices.isEmpty {
                Text(notices.joined(separator:"\n")).font(.caption).foregroundStyle(CallPalette.muted).textSelection(.enabled)
            }
        }
    }
}
