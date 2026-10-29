import SwiftUI
import AppKit

enum CallPalette {
    static let accent = adaptive(light:0x333333,dark:0xDDDDDD)
    static let onAccent = adaptive(light:0xFFFFFF,dark:0x191919)
    static let canvas = adaptive(light:0xF7F7F5,dark:0x1C1C1B)
    static let sidebar = adaptive(light:0xEFEFED,dark:0x161615)
    static let surface = adaptive(light:0xFFFFFF,dark:0x252524)
    static let outline = adaptive(light:0xDDDDD8,dark:0x454542)
    static let muted = adaptive(light:0x5E5E58,dark:0xB9B9B1)
    private static func adaptive(light:Int,dark:Int) -> Color {
        Color(nsColor:NSColor(name:nil) { appearance in
            let hex=appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? dark:light
            return NSColor(srgbRed:Double((hex >> 16) & 255)/255,green:Double((hex >> 8) & 255)/255,blue:Double(hex & 255)/255,alpha:1)
        })
    }
}

struct CallPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.font(.system(size:13,weight:.semibold))
            .padding(.horizontal,16).padding(.vertical,9)
            .foregroundStyle(CallPalette.onAccent)
            .background(CallPalette.accent,in:RoundedRectangle(cornerRadius:8))
            .contentShape(RoundedRectangle(cornerRadius:8))
            .opacity(enabled ? (configuration.isPressed ? 0.75:1):0.45)
    }
}

struct CallInputStyle: ViewModifier {
    func body(content:Content) -> some View {
        content.textFieldStyle(.plain).padding(10)
            .background(CallPalette.canvas,in:RoundedRectangle(cornerRadius:10))
            .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(CallPalette.outline))
    }
}

struct CallActionStyle: ViewModifier {
    func body(content:Content) -> some View {
        content.buttonStyle(CallPrimaryButtonStyle())
    }
}

struct CallActivationClicks: ViewModifier {
    func body(content:Content) -> some View {
        if #available(macOS 15.0, *) {
            content.allowsWindowActivationEvents(true)
        } else {
            content
        }
    }
}

@main struct CallAssistantApp: App {
    @StateObject private var state = Startup()
    @State private var menuBarInserted = true
    var body: some Scene {
        MenuBarExtra(isInserted: $menuBarInserted) {
            if let model=state.model {
                MenuContent(model:model,openHistory:state.showLibrary)
            } else { VStack { Text(state.error); Button("Quit") { NSApp.terminate(nil) } }.padding() }
        } label: {
            Label("Cue",systemImage:MenuContent.symbol).labelStyle(.iconOnly)
        }.menuBarExtraStyle(.window)
    }
}
struct MenuContent: View {
    static let symbol="waveform"
    @ObservedObject var model: AppModel
    @ObservedObject private var runtime=AgentRuntime.shared
    let openHistory: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(spacing:10) {
                Image(systemName:Self.symbol).font(.system(size:22,weight:.medium))
                    .frame(width:42,height:42).background(CallPalette.canvas,in:RoundedRectangle(cornerRadius:12)).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:3) {
                    Text("Cue").font(.headline)
                    Text(model.paused ? "Capture paused":model.modelStatus.hasPrefix("Ready") ? "Ready for calls":model.modelStatus)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength:0)
            }
            Divider()
            Button {openHistory()} label: {Label("Open call library",systemImage:"rectangle.stack").frame(maxWidth:.infinity,alignment:.leading)}
                .padding(.vertical,4)
            if let panel=model.panel {CoachingMenuControls(model:model,panel:panel)}
            Divider()
            if !model.captureConsentGranted {Label("Setup needed · recording permission",systemImage:"exclamationmark.circle").font(.caption)}
            if model.aiConsentGranted,!runtime.installed.contains(model.aiProvider) {Label("Setup needed · \(model.aiProvider.title) tools",systemImage:"arrow.down.circle").font(.caption)}
            Toggle("Pause capture",isOn:Binding(get:{model.paused},set:{model.setPaused($0)})).toggleStyle(.switch).controlSize(.small).disabled(!model.captureConsentGranted)
            Label(model.extensionConnected ? "Chrome connected":"Chrome not connected",systemImage:model.extensionConnected ? "checkmark.circle":"circle.dashed")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("Quit Cue",systemImage:"power") {NSApp.terminate(nil)}.keyboardShortcut("q")
        }.buttonStyle(.borderless).padding(20).frame(width:300)
            .background(CallPalette.surface).tint(CallPalette.accent).modifier(CallActivationClicks()).onAppear {runtime.refresh()}
    }
}
struct CoachingMenuControls:View {
    @ObservedObject var model:AppModel
    @ObservedObject var panel:CoachingPanel
    var body:some View {
        Button {
            if panel.hiddenByUser {panel.show()} else {panel.toggleExpanded()}
        } label: {Label(panel.hiddenByUser ? "Show coaching":panel.expanded ? "Collapse coaching":"Expand coaching",systemImage:panel.hiddenByUser ? "bubble.left.and.text.bubble.right":panel.expanded ? "chevron.up":"chevron.down").frame(maxWidth:.infinity,alignment:.leading)}
        if !panel.hiddenByUser {Button("Hide coaching",systemImage:"eye.slash") {panel.hide()}}
        if model.liveAISession != nil {
            Button(model.coachingPaused ? "Resume coaching":"Pause coaching",systemImage:model.coachingPaused ? "play":"pause") {model.setCoachingPaused(!model.coachingPaused)}
            Button("Stop coaching",systemImage:"stop") {model.stopAI()}
        } else {
            Button("Start live coaching",systemImage:"waveform") {model.startLiveAI()}
                .disabled(model.paused || model.aiBusy || model.activeSession==nil || (model.selectedDetail?["meta"] as? [String:Any])?["ended"] as? Bool == true)
        }
    }
}
@MainActor final class Startup: ObservableObject {
    let model: AppModel?
    let error: String
    private var libraryWindow: NSWindow?
    init() {
        do {
            let m=try AppModel();model=m;error="";m.attachPanel()
            if m.speechModelDownloaded {m.loadModel()} else {m.modelStatus="Not downloaded"}
            DispatchQueue.main.async { [weak self] in self?.showLibrary() }
        } catch { model=nil;self.error=error.localizedDescription }
    }
    func showLibrary() {
        guard let model else{return}
        NSApp.setActivationPolicy(.regular)
        if let libraryWindow { libraryWindow.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);return }
        let window=makeLibraryWindow(model:model)
        window.center();libraryWindow=window
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
}
@MainActor func makeLibraryWindow(model:AppModel) -> NSWindow {
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1120,height:760),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
    window.title="Cue";window.isReleasedWhenClosed=false;window.minSize=NSSize(width:800,height:540)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unifiedCompact
    window.backgroundColor = NSColor(CallPalette.canvas)
    window.contentViewController=NSHostingController(rootView:LibraryView(model:model))
    window.setContentSize(NSSize(width:1120,height:760))
    return window
}

func sessionTitle(_ record: [String:Any]) -> String {
    for field in ["summaryTitle","topic","title","callID"] { if let text=record[field] as? String,!text.trimmingCharacters(in:.whitespaces).isEmpty{return text} }
    return "Untitled call"
}
struct CallTranscript: View {
    let segments:[TranscriptSegment]
    var body:some View {
        LazyVStack(alignment:.leading,spacing:0) {
            ForEach(segments) { entry in
                let segment=entry.value
                let source=segment["source"] as? String ?? ""
                HStack(alignment:.top,spacing:16) {
                    Image(systemName:"person.crop.circle").font(.system(size:24,weight:.light))
                        .foregroundStyle(CallPalette.muted).frame(width:28).padding(.top,2).accessibilityHidden(true)
                    VStack(alignment:.leading,spacing:8) {
                        ViewThatFits(in:.horizontal) {
                            HStack(alignment:.firstTextBaseline) {
                                Text(segment["speaker"] as? String ?? "Unknown").font(.headline)
                                Spacer(minLength:12)
                                metadata(segment,source:source)
                            }
                            VStack(alignment:.leading,spacing:4) {
                                Text(segment["speaker"] as? String ?? "Unknown").font(.headline)
                                metadata(segment,source:source)
                            }
                        }
                        Text(segment["text"] as? String ?? "").font(.body).textSelection(.enabled).lineSpacing(6)
                        if let uncertainty=segment["uncertainty"] as? String,!uncertainty.isEmpty {
                            Label("Uncertain: "+uncertainty,systemImage:"questionmark.circle").font(.caption).foregroundStyle(CallPalette.muted)
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.padding(.vertical,20).padding(.horizontal,24)
                    .accessibilityElement(children:.combine)
                Divider().padding(.leading,68)
            }
        }.background(CallPalette.surface,in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(CallPalette.outline))
    }
    private func metadata(_ segment:[String:Any],source:String) -> some View {
        HStack(spacing:8) {
            Text(source.hasPrefix("whisper") ? "Whisper":source=="meet" ? "Meet captions":source)
            if let timestamp=segment["t"] as? Double,timestamp>0 {
                Text(Date(timeIntervalSince1970:timestamp/1000),format:.dateTime.hour().minute().second()).monospacedDigit()
            }
        }.font(.caption).foregroundStyle(CallPalette.muted)
    }
}
struct LibraryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var runtime=AgentRuntime.shared
    @State private var settings=false
    @State private var expandedSeries=Set<String>()
    @State private var selectedTab="transcript"
    private var callTabs: some View {
        Picker("Call view",selection:$selectedTab) {
            Text("Transcript").tag("transcript")
            Text("Summary").tag("summary")
        }.pickerStyle(.segmented).labelsHidden().frame(width:210)
    }
    private func historyRow(_ call:[String:Any],title:String?) -> some View {
        VStack(alignment:.leading,spacing:5){
            if let title=(call["summaryTitle"] as? String).flatMap({$0.isEmpty ? nil:$0}) ?? title {Text(title).font(.system(size:13,weight:.semibold)).lineLimit(2).help(title)}
            if let time=call["startedAt"] as? Double {
                Text(Date(timeIntervalSince1970:time/1000),format:.dateTime.day().month(.abbreviated).year().hour().minute()).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            let people=(call["participants"] as? [String] ?? []).joined(separator:", ")
            if !people.isEmpty {Text(people).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(people)}
        }.padding(.vertical,8)
    }
    @ViewBuilder private func callMetadata(_ meta:[String:Any]) -> some View {
        if let time=meta["startedAt"] as? Double {
            Label {Text(Date(timeIntervalSince1970:time/1000),format:.dateTime.day().month(.abbreviated).year().hour().minute())} icon:{Image(systemName:"calendar")}
                .font(.caption).foregroundStyle(CallPalette.muted)
        }
        let people=(meta["participants"] as? [String] ?? []).joined(separator:", ")
        if !people.isEmpty {Label(people,systemImage:"person.2").font(.caption).foregroundStyle(CallPalette.muted).lineLimit(2).help(people)}
    }
    private func toggleSeries(_ id:String) {
        if expandedSeries.contains(id) {expandedSeries.remove(id)}
        else {expandedSeries.insert(id)}
    }
    var body: some View {
        let groups=groupedCallHistory(model.sessions)
        let rows=historyListRows(groups,expanded:expandedSeries)
        NavigationSplitView {
                List(selection:Binding<String?>(get:{model.activeSession},set:{ selection in
                    guard let selection else {return}
                    let id=groups.first{$0.id==selection}?.latestCallID ?? selection
                    if model.sessions.contains(where:{$0["id"] as? String==id}) {model.select(id)}
                })) {
                    HStack {Text("LIBRARY").tracking(1);Spacer();Text("\(model.sessions.count)").monospacedDigit()}.font(.caption).foregroundStyle(CallPalette.muted)
                        .padding(.vertical,8).accessibilityElement(children:.combine)
                    ForEach(rows) { row in
                        HStack(spacing:8) {
                            if let group=row.series,let latestID=group.latestCallID {
                                Button { model.select(latestID) } label: {
                                VStack(alignment:.leading,spacing:5){
                                    Text(group.title).font(.system(size:13,weight:.semibold)).lineLimit(2).help(group.title)
                                    Text("\(group.calls.count) calls").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()).padding(.vertical,8)
                                }.buttonStyle(.plain)
                                Button {toggleSeries(group.id)} label: {
                                    Image(systemName:expandedSeries.contains(group.id) ? "chevron.up":"chevron.down")
                                        .font(.system(size:12,weight:.semibold)).frame(width:34,height:34)
                                        .background(CallPalette.surface,in:RoundedRectangle(cornerRadius:10))
                                }.buttonStyle(.plain)
                                    .accessibilityLabel((expandedSeries.contains(group.id) ? "Hide":"Show")+" past calls for "+group.title)
                            } else {
                                historyRow(row.call,title:row.title).padding(.leading,row.title==nil ? 16:0)
                            }
                        }.tag(row.selectionID)
                            .listRowBackground(row.series?.calls.contains{$0["id"] as? String==model.activeSession} == true ? CallPalette.accent.opacity(0.18):Color.clear)
                            .accessibilityAction(named:Text("Open call")) {model.select(row.call["id"] as! String)}
                            .accessibilityActions {
                                if let group=row.series {
                                    Button(expandedSeries.contains(group.id) ? "Hide past calls":"Show past calls") {toggleSeries(group.id)}
                                }
                            }
                    }
                }.listStyle(.sidebar).navigationTitle("")
                .overlay {
                    if rows.isEmpty {
                        Text(model.historyQuery.isEmpty ? "Your calls will appear here.":"No matching calls. Try another search.")
                            .font(.callout).foregroundStyle(CallPalette.muted).multilineTextAlignment(.center).padding(24)
                    }
                }
                .scrollContentBackground(.hidden).background(CallPalette.sidebar)
                .searchable(text:$model.historyQuery,placement:.sidebar,prompt:"Search calls and transcripts")
                .onChange(of:model.historyQuery){_,_ in model.refreshHistory()}
                .safeAreaInset(edge:.top,spacing:0) {
                HStack(spacing:10) {
                    Image(systemName:"waveform").font(.title2).frame(width:36,height:36)
                        .background(CallPalette.surface,in:RoundedRectangle(cornerRadius:10)).accessibilityHidden(true)
                    VStack(alignment:.leading,spacing:2) {
                        Text("Cue").font(.title3.weight(.semibold))
                        Text("MEETING ASSISTANT").font(.system(size:9,weight:.semibold)).tracking(1.5).foregroundStyle(CallPalette.muted)
                    }
                }.padding(20)
                }
                .safeAreaInset(edge:.bottom,spacing:0) {
                    VStack(spacing:0) {
                Divider()
                HStack(spacing:8) {
                    Image(systemName:model.extensionConnected ? "checkmark.circle":"circle.dashed")
                    Text(model.extensionConnected ? "Chrome connected":"Chrome disconnected")
                    Spacer(minLength:0)
                    Button {settings=true} label:{Image(systemName:"gearshape").frame(width:28,height:28)}
                        .buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
                }.font(.caption).foregroundStyle(CallPalette.muted).padding(.horizontal,20).padding(.vertical,12)
                    }.background(CallPalette.sidebar)
                }
                .navigationSplitViewColumnWidth(min:250,ideal:290,max:380)
        } detail: {
            VStack(alignment:.leading,spacing:0){
                if !model.errorMessage.isEmpty {
                    Label(model.errorMessage,systemImage:"exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                        .textSelection(.enabled).padding(16).frame(maxWidth:.infinity,alignment:.leading).background(CallPalette.surface)
                }
                if let detail=model.selectedDetail,let meta=detail["meta"] as? [String:Any] {
                    VStack(alignment:.leading,spacing:18) {
                        VStack(alignment:.leading,spacing:10) {
                            HStack {
                                Text("CONVERSATION").font(.system(size:10,weight:.semibold)).tracking(1.4).foregroundStyle(CallPalette.muted)
                                Spacer()
                                Label(meta["ended"] as? Bool == true ? "Completed":"Call record",systemImage:meta["ended"] as? Bool == true ? "checkmark.circle":"waveform")
                                    .font(.caption).foregroundStyle(CallPalette.muted)
                            }
                            Text(sessionTitle(meta)).font(.title.weight(.semibold)).textSelection(.enabled)
                                .lineLimit(3).help(sessionTitle(meta)).accessibilityAddTraits(.isHeader)
                            ViewThatFits(in:.horizontal) {
                                HStack(spacing:16) {callMetadata(meta)}
                                VStack(alignment:.leading,spacing:6) {callMetadata(meta)}
                            }
                            CallCalendarContext(calendar:model.calendar,meta:meta)
                        }
                        ViewThatFits(in:.horizontal) {
                            HStack {callTabs;Spacer(minLength:16);CallAttachments(model:model)}
                            VStack(alignment:.leading,spacing:12) {callTabs;CallAttachments(model:model)}
                        }
                    }.padding(28).background(CallPalette.surface)
                    Divider()
                    ScrollView {
                        VStack(alignment:.leading,spacing:20){
                            if selectedTab=="summary" {
                                AIControls(model:model,detail:detail)
                            } else {
                            let segments=detail["segments"] as? [[String:Any]] ?? []
                            if segments.isEmpty {
                                VStack(alignment:.leading,spacing:8) {
                                    Label("No transcript yet",systemImage:"text.alignleft").font(.headline)
                                    Text("Queued audio is processed locally when WhisperKit is ready.").foregroundStyle(.secondary)
                                }.padding(24).frame(maxWidth:.infinity,alignment:.leading)
                                    .background(CallPalette.surface,in:RoundedRectangle(cornerRadius:16))
                            }
                            let refined=(try? model.store.refinedTranscript(detail)) ?? []
                            if !refined.isEmpty {
                                Text("AI-refined turns with pending originals · Whisper + Meet captions").font(.caption).foregroundStyle(.secondary)
                                CallTranscript(segments:refined.compactMap(TranscriptSegment.init))
                                DisclosureGroup("Original source transcripts") {CallTranscript(segments:segments.compactMap(TranscriptSegment.init))}
                            } else {CallTranscript(segments:segments.compactMap(TranscriptSegment.init))}
                            }
                        }.padding(28).frame(maxWidth:860,alignment:.leading).frame(maxWidth:.infinity)
                    }
                } else {
                    VStack(alignment:.leading,spacing:32) {
                        CallEmptyState(symbol:"waveform",title:"Every conversation,\nwith a little more clarity.",message:"Choose a call from your library to read the transcript, revisit decisions, and find the next step.")
                        VStack(alignment:.leading,spacing:14) {
                            Label("Transcripts processed on this Mac",systemImage:"internaldrive")
                            Label("Summaries and next steps in one place",systemImage:"text.alignleft")
                            Label("Live guidance when you need it",systemImage:"bubble.left")
                        }.font(.callout).foregroundStyle(CallPalette.muted)
                        Divider().frame(maxWidth:420)
                        Text("New browser calls appear automatically when capture is running.")
                            .font(.caption).foregroundStyle(CallPalette.muted).frame(maxWidth:420,alignment:.leading)
                    }.padding(40).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.center)
                }
            }.background(CallPalette.canvas)
        }.tint(CallPalette.accent).modifier(CallActivationClicks())
        .onAppear {runtime.refresh();if !model.captureConsentGranted {settings=true}}
        .onChange(of:model.completedAutomaticSummary) {_,completion in
            if let completion,completion.session==model.activeSession {selectedTab="summary"}
        }.toolbar {
            ToolbarItem(placement:.principal) {
                Button {model.setPaused(!model.paused)} label: {
                    Label(model.paused ? "Resume capture":"Pause capture",systemImage:model.paused ? "play.fill":"pause.fill")
                        .labelStyle(.titleAndIcon).font(.callout)
                        .padding(.horizontal,10).padding(.vertical,5)
                }.buttonStyle(.plain).help(model.paused ? "Resume automatic call capture":"Pause automatic call capture").disabled(!model.captureConsentGranted)
            }
            ToolbarItem(placement:.primaryAction) {
                Button { settings=true } label:{Label(!model.captureConsentGranted || !model.modelReady || !model.extensionConnected || (model.aiConsentGranted && !runtime.installed.contains(model.aiProvider)) ? "Finish setup":"Settings",systemImage:"gearshape")}.help("Setup, permissions, and settings")
            }
        }.sheet(isPresented:$settings){
            CallSettings(model:model)
        }
    }
}
