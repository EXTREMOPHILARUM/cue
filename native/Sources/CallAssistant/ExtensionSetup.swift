import AppKit
import SwiftUI
import CallCore
import Darwin

enum ExtensionInstall {
    static func prepare(source:URL, destination:URL) throws -> URL {
        let files=FileManager.default
        guard files.fileExists(atPath:source.appendingPathComponent("manifest.json").path) else {
            throw BridgeError("The bundled extension is missing. Rebuild the app with scripts/build-native.sh.")
        }
        try files.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        let staged=destination.deletingLastPathComponent().appendingPathComponent(".extension-\(UUID().uuidString)")
        defer { try? files.removeItem(at:staged) }
        try files.copyItem(at:source,to:staged)
        guard try JSONSerialization.jsonObject(with:Data(contentsOf:staged.appendingPathComponent("manifest.json"))) is [String:Any] else {
            throw BridgeError("The bundled extension manifest is invalid.")
        }
        if files.fileExists(atPath:destination.path) {
            guard try destination.resourceValues(forKeys:[.isDirectoryKey]).isDirectory == true else {
                throw BridgeError("The extension destination is not a folder.")
            }
            // A same-volume directory exchange keeps the stable path complete, even on failure.
            guard renameatx_np(AT_FDCWD,staged.path,AT_FDCWD,destination.path,UInt32(RENAME_SWAP)) == 0 else {
                throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))
            }
        } else {
            try files.moveItem(at:staged,to:destination)
        }
        return destination
    }
}

struct ExtensionSetup:View {
    @ObservedObject var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var folder:URL?
    @State private var error=""
    @State private var installing=false
    @State private var automaticStatus=""
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(alignment:.top) {
                CallSectionHeading(title:"Connect Chrome",subtitle:"Open Chrome with Cue ready to use.")
                Spacer()
                Button("Done") {dismiss()}.keyboardShortcut(.defaultAction).modifier(CallActionStyle())
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    Label("Set up outside a call. Loading or reloading the extension can interrupt capture.",systemImage:"exclamationmark.triangle")
                        .font(.callout).foregroundStyle(CallPalette.muted)
                    VStack(alignment:.leading,spacing:12) {
                        Text("Automatic setup").font(.headline)
                        Text("Cue opens a separate Chrome profile and loads and links its extension automatically. Sign in to Google there, then use that window for your calls.").font(.callout)
                        Text("Use this button whenever you reopen Cue Chrome. Your regular Chrome profile and its extensions stay separate. Existing users can keep their current setup below.").font(.caption).foregroundStyle(CallPalette.muted)
                        Button(installing ? "Setting up Chrome…":"Open Cue Chrome") {Task {await openAutomatic()}}
                            .disabled(installing)
                        if installing {ProgressView().controlSize(.small)}
                        if !automaticStatus.isEmpty {Text(automaticStatus).font(.callout).textSelection(.enabled)}
                        Label(model.extensionConnected ? "Extension connected":"Waiting for extension connection",systemImage:model.extensionConnected ? "checkmark.circle":"clock").font(.callout)
                    }.modifier(CallCard())
                    DisclosureGroup("Manual setup in your existing Chrome profile") {
                        VStack(alignment:.leading,spacing:16) {
                            VStack(alignment:.leading,spacing:12) {
                                step("1","Prepare the extension")
                                Text("This prepares the files and opens Chrome. You’ll install the extension in Chrome in step 2.").font(.callout).foregroundStyle(CallPalette.muted)
                                Button("Prepare extension and open Chrome") {prepare()}
                                if let folder {
                                    Text(folder.path).font(.caption).foregroundStyle(CallPalette.muted).textSelection(.enabled)
                                    Button("Copy folder path") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(folder.path,forType:.string)
                                    }
                                    Button("Show extension folder") {NSWorkspace.shared.activateFileViewerSelecting([folder])}
                                }
                            }.modifier(CallCard())
                            VStack(alignment:.leading,spacing:12) {
                                step("2","Load in Chrome")
                                Text("1. In Chrome, turn on Developer mode (top right).\n2. Click Load unpacked.\n3. Click Copy folder path above. In Chrome’s folder picker, press ⌘⇧G (Go to Folder), paste the path, and press Return.\n4. Click Open to load the Extension folder. Keep that folder in place.").font(.callout).textSelection(.enabled)
                                Text("Opening the folder in Finder does not install it in Chrome. Manual setup requires the Load unpacked step.").font(.caption).foregroundStyle(CallPalette.muted)
                                Text("Already installed? Keep its existing ID and folder to retain browser history. Reload the same extension card outside a call.").font(.caption).foregroundStyle(CallPalette.muted)
                            }.modifier(CallCard())
                            VStack(alignment:.leading,spacing:12) {
                                step("3","Link your extension")
                                Text("Copy the ID from Chrome’s extension card.").font(.callout).foregroundStyle(CallPalette.muted)
                                VStack(alignment:.leading,spacing:6) {
                                    Text("Chrome extension ID").font(.caption.weight(.medium))
                                    TextField("32-letter extension ID",text:Binding(get:{model.extensionID},set:{model.extensionID=$0.trimmingCharacters(in:.whitespacesAndNewlines)}))
                                        .modifier(CallInputStyle()).accessibilityLabel("Chrome extension ID")
                                }
                                if !model.extensionID.isEmpty,model.extensionID.range(of:"^[a-p]{32}$",options:.regularExpression) == nil {
                                    Text("Copy the 32-letter ID shown on Chrome’s extension card.").font(.caption).foregroundStyle(.red)
                                }
                                Label(model.extensionConnected ? "Extension connected":"Waiting for extension connection",systemImage:model.extensionConnected ? "checkmark.circle":"clock").font(.callout)
                                Text("Chrome retries within 30 seconds; you can also open the extension popup. No meeting is needed.").font(.caption).foregroundStyle(CallPalette.muted)
                                Text(model.bridgeStatus).font(.caption.monospaced()).foregroundStyle(CallPalette.muted)
                            }.modifier(CallCard())
                        }.padding(.top,12)
                    }.disabled(installing)
                    if !error.isEmpty {Label(error,systemImage:"exclamationmark.circle").foregroundStyle(.red).textSelection(.enabled)}
                }.padding(24)
            }
        }.frame(width:580,height:680).background(CallPalette.canvas).tint(CallPalette.accent).modifier(CallActivationClicks())
    }
    @MainActor private func openAutomatic() async {
        guard !installing else {return}
        installing=true;error="";automaticStatus="Opening Cue Chrome…"
        defer {installing=false}
        do {
            guard let source=Bundle.module.url(forResource:"Extension",withExtension:nil) else {throw BridgeError("The app does not contain the Chrome extension.")}
            guard let chrome=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.google.Chrome"),
                  let executable=Bundle(url:chrome)?.executableURL else {throw BridgeError("Install Google Chrome, then retry Open Cue Chrome.")}
            let support=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
                .appendingPathComponent("Cue",isDirectory:true)
            let profile=support.appendingPathComponent("CueChrome",isDirectory:true)
            if ChromeExtensionInstaller.isRunning(profile:profile) {
                guard let saved=ChromeExtensionInstaller.runningInstallation(profile:profile),
                      saved["fingerprint"] == (try ChromeExtensionInstaller.fingerprint(folder:source)),let id=saved["id"] else {
                    throw BridgeError("Quit Cue Chrome (⌘Q), then retry to load Cue for this browser session. Your regular Chrome can stay open.")
                }
                let process=Process()
                process.executableURL=executable
                process.arguments=["--user-data-dir=\(profile.path)","--new-window","https://meet.google.com/"]
                process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
                try process.run()
                model.extensionID=id
            } else {
                let installed=try ExtensionInstall.prepare(source:source,destination:support.appendingPathComponent("AutomaticExtension",isDirectory:true))
                model.extensionID=try await ChromeExtensionInstaller.install(chrome:executable,folder:installed,profile:profile)
            }
            automaticStatus="Cue Chrome is ready. Sign in there and join your meeting. The extension connects within 30 seconds."
        } catch {self.error=error.localizedDescription;automaticStatus=""}
    }
    private func step(_ number:String,_ title:String) -> some View {
        HStack(spacing:10) {
            Text(number).font(.caption.weight(.semibold)).frame(width:24,height:24)
                .background(CallPalette.canvas,in:Circle()).overlay(Circle().strokeBorder(CallPalette.outline))
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
        }
    }
    private func prepare() {
        do {
            guard let source=Bundle.module.url(forResource:"Extension",withExtension:nil) else {
                throw BridgeError("The app does not contain the extension. Rebuild with scripts/build-native.sh.")
            }
            let support=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            folder=try ExtensionInstall.prepare(source:source,destination:support.appendingPathComponent("Cue/Extension",isDirectory:true))
            NSWorkspace.shared.activateFileViewerSelecting([folder!])
            guard let chrome=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.google.Chrome") else {
                throw BridgeError("Google Chrome was not found. Install Chrome, then open chrome://extensions.")
            }
            NSWorkspace.shared.open([URL(string:"chrome://extensions")!],withApplicationAt:chrome,configuration:NSWorkspace.OpenConfiguration()) { _,failure in
                if let failure { Task { @MainActor in error=failure.localizedDescription } }
            }
            error=""
        } catch { self.error=error.localizedDescription }
    }
}
