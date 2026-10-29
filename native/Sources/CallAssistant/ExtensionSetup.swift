import AppKit
import SwiftUI
import CallCore
import Darwin

enum ExtensionInstall {
    static func destination(home:URL,support:URL,extensionID:String,preparedPath:String="") -> URL {
        let visible=home.appendingPathComponent("Cue Extension",isDirectory:true)
        let legacy=support.appendingPathComponent("Cue/Extension",isDirectory:true)
        // Moving a linked unpacked extension can change its ID and strand its browser history.
        if preparedPath==visible.path {return visible}
        if !extensionID.isEmpty,FileManager.default.fileExists(atPath:legacy.appendingPathComponent("manifest.json").path) {return legacy}
        return visible
    }
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
            let existing=try? JSONSerialization.jsonObject(with:Data(contentsOf:destination.appendingPathComponent("manifest.json"))) as? [String:Any]
            guard existing?["name"] as? String == "Cue" else {
                throw BridgeError("The destination folder already exists but is not a Cue extension. Rename or move that folder before preparing Cue.")
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
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(alignment:.top) {
                CallSectionHeading(title:"Connect Chrome",subtitle:"Three steps to bring your calls into Cue.")
                Spacer()
                Button("Done") {dismiss()}.keyboardShortcut(.defaultAction).modifier(CallActionStyle())
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    Label("Set up outside a call. Loading or reloading the extension can interrupt capture.",systemImage:"exclamationmark.triangle")
                        .font(.callout).foregroundStyle(CallPalette.muted)
                    VStack(alignment:.leading,spacing:12) {
                        step("1","Prepare the extension")
                        Text("New installs use Cue Extension in your Home folder. Existing linked installs keep their prepared folder. This opens Chrome but does not install the extension.").font(.callout).foregroundStyle(CallPalette.muted)
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
                        Text("In your existing Chrome profile:\n1. Turn on Developer mode (top right).\n2. Click Load unpacked.\n3. Click Copy folder path above. In Chrome’s folder picker, press ⌘⇧G, paste the path, and press Return.\n4. Click Open. Keep the folder in place.").font(.callout)
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
                    if !error.isEmpty {Label(error,systemImage:"exclamationmark.circle").foregroundStyle(.red).textSelection(.enabled)}
                }.padding(24)
            }
        }.frame(width:580,height:680).background(CallPalette.canvas).tint(CallPalette.accent).modifier(CallActivationClicks())
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
            folder=try ExtensionInstall.prepare(source:source,destination:ExtensionInstall.destination(home:FileManager.default.homeDirectoryForCurrentUser,support:support,extensionID:model.extensionID,preparedPath:UserDefaults.standard.string(forKey:"preparedExtensionPath") ?? ""))
            UserDefaults.standard.set(folder!.path,forKey:"preparedExtensionPath")
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
