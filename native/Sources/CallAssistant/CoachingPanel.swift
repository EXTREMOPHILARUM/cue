import AppKit
import WebKit
import Combine

@MainActor final class CoachingPanel: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let panel: NSPanel
    private let backdrop=NSVisualEffectView()
    let web: WKWebView
    private weak var model: AppModel?
    private var ready = false
    private var current: [String: Any]?
    private let collapsedLabel=NSButton(title:"Coach · Listening",target:nil,action:nil)
    private var contentHeight:CGFloat=320
    private var manuallyCollapsed=false
    private var targetDisplayID:NSNumber?
    @Published private(set) var expanded=false
    @Published private(set) var hiddenByUser=true
    var frame:NSRect {panel.frame}
    var isVisible:Bool {panel.isVisible}
    init(model: AppModel) {
        self.model = model
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        web = WKWebView(frame:.zero,configuration:config)
        web.underPageBackgroundColor = .clear
        // shortcut: macOS WebKit transparency is KVC-only; replace when a public background switch exists.
        if web.responds(to:NSSelectorFromString("_setDrawsBackground:")) {web.setValue(false,forKey:"drawsBackground")}
        panel = NSPanel(contentRect:NSRect(x:0,y:0,width:440,height:52),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        super.init()
        panel.title = "Cue"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=true
        let content=NSView();content.wantsLayer=true;content.layer?.cornerRadius=16;content.layer?.masksToBounds=true
        backdrop.wantsLayer=true;backdrop.material = .popover;backdrop.blendingMode = .behindWindow;backdrop.state = .active
        updateTransparency()
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(updateTransparency),name:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil)
        collapsedLabel.target=self;collapsedLabel.action=#selector(toggleExpanded)
        collapsedLabel.isBordered=false;collapsedLabel.alignment = .center
        collapsedLabel.image=NSImage(systemSymbolName:"chevron.down",accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:12,weight:.medium))
        collapsedLabel.imagePosition = .imageRight
        collapsedLabel.setAccessibilityLabel("Expand coaching")
        collapsedLabel.font = .systemFont(ofSize:13,weight:.medium)
        for view in [backdrop,collapsedLabel,web] {view.translatesAutoresizingMaskIntoConstraints=false;content.addSubview(view)}
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo:content.topAnchor),backdrop.leadingAnchor.constraint(equalTo:content.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo:content.trailingAnchor),backdrop.bottomAnchor.constraint(equalTo:content.bottomAnchor),
            collapsedLabel.centerYAnchor.constraint(equalTo:content.centerYAnchor),collapsedLabel.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:18),
            collapsedLabel.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-18),
            web.topAnchor.constraint(equalTo:content.topAnchor),web.leadingAnchor.constraint(equalTo:content.leadingAnchor),
            web.trailingAnchor.constraint(equalTo:content.trailingAnchor),web.bottomAnchor.constraint(equalTo:content.bottomAnchor)
        ])
        web.isHidden=true;panel.contentView=content
        NotificationCenter.default.addObserver(self,selector:#selector(screenChanged),name:NSApplication.didChangeScreenParametersNotification,object:nil)
        web.navigationDelegate = self
        config.userContentController.add(self,name:"ready")
        config.userContentController.add(self,name:"feedback")
        config.userContentController.add(self,name:"resize")
        if let folder = Bundle.module.url(forResource:"Canvas",withExtension:nil) {
            web.loadFileURL(folder.appendingPathComponent("index.html"),allowingReadAccessTo:folder)
        } else { model.errorMessage = "Bundled canvas not found; rebuild with scripts/build-native.sh" }
    }
    func show() {if targetDisplayID==nil {chooseDisplay()};hiddenByUser=false;setExpanded(true);panel.orderFrontRegardless()}
    func beginSession() {chooseDisplay();hiddenByUser=false;manuallyCollapsed=false;setExpanded(false);panel.orderFrontRegardless()}
    func showSuggestion() {if !hiddenByUser {if !manuallyCollapsed {setExpanded(true)};position();panel.orderFrontRegardless()}}
    func hide() {hiddenByUser=true;panel.orderOut(nil)}
    @objc func toggleExpanded() {manuallyCollapsed=expanded;setExpanded(!expanded)}
    private func setExpanded(_ value:Bool) {
        expanded=value;web.isHidden = !value;collapsedLabel.isHidden=value;position()
    }
    func updateControls() {collapsedLabel.title=(model?.coachingPaused == true ? "Coach · Paused":current?["headline"] as? String ?? "Coach · Listening")}
    @objc private func screenChanged() {position()}
    private static func displayID(_ screen:NSScreen) -> NSNumber? {screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber}
    private func chooseDisplay() {
        if let screen=NSScreen.screens.first(where:{$0.frame.contains(NSEvent.mouseLocation)}) ?? NSScreen.main {targetDisplayID=Self.displayID(screen)}
    }
    @objc func updateTransparency() {
        let override=model?.coachingTransparencyOverride ?? false
        let reduce=NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency && !override
        backdrop.alphaValue=reduce ? 1:CGFloat(model?.coachingBackdropOpacity ?? 0.72)
        backdrop.layer?.backgroundColor=reduce ? NSColor.windowBackgroundColor.cgColor:NSColor.clear.cgColor
        if ready {
            web.callAsyncJavaScript("document.documentElement.classList.toggle('translucent-coaching', enabled)",arguments:["enabled":override],in:nil,in:.page) { [weak self] result in
                if case .failure(let error)=result {self?.model?.errorMessage="Cannot update coaching appearance: "+error.localizedDescription}
            }
        }
    }
    private func position() {
        guard let screen=NSScreen.screens.first(where:{Self.displayID($0)==targetDisplayID}) ?? panel.screen ?? NSScreen.main else {return}
        // Persist the display's stable ID; main screen follows focus, and NSScreen objects can change.
        targetDisplayID=Self.displayID(screen)
        let usable=screen.visibleFrame
        panel.setFrame(Self.layout(screen:screen.frame,usable:usable,expanded:expanded,contentHeight:contentHeight),display:true)
    }
    static func layout(screen:NSRect,usable:NSRect,expanded:Bool,contentHeight:CGFloat) -> NSRect {
        let width=min(expanded ? 480:360,usable.width-16)
        let height=expanded ? min(max(160,contentHeight),usable.height-16):52
        let x=min(max(screen.midX-width/2,usable.minX+8),usable.maxX-width-8)
        return NSRect(x:x,y:usable.maxY-height-6,width:width,height:height)
    }
    func update(_ value: [String: Any]?) {
        current = value
        updateControls()
        guard ready else { return }
        web.callAsyncJavaScript("window.callAssistant.update(value, owner)",arguments:["value":value as Any? ?? NSNull(),"owner":model?.activeSession as Any? ?? NSNull()],in:nil,in:.page) { [weak self] result in
            if case .failure(let error) = result { self?.model?.errorMessage = "Canvas update failed: \(error.localizedDescription)" }
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true, let value = message.body as? [String: Any] else { return }
        if message.name == "ready", let prompt = value["prompt"] as? String {
            model?.prompt = prompt; ready = true; updateTransparency(); update(current)
        } else if message.name == "resize",let height=value["height"] as? Double,height.isFinite,height>0 {
            contentHeight=CGFloat(height);if expanded {position()}
        } else if message.name == "feedback",value["action"] as? String == "collapse" {toggleExpanded()
        } else if message.name == "feedback", let action = value["action"] as? String, ["asked","dismiss","check","hide","render-error"].contains(action) {
            model?.feedback(value)
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        model?.errorMessage = "Coaching canvas stopped. Restart the app outside your call; the meeting is unaffected by this panel process."
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.isFileURL == true && navigationAction.navigationType == .other ? .allow : .cancel)
    }
}
