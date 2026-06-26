import Cocoa
import WebKit
import Carbon.HIToolbox
import CoreImage

private let ciContext = CIContext(options: nil)

extension NSImage {
    // Average color of the top `frac` of the image (the strip just under the title bar).
    func topAverageColor(_ frac: CGFloat) -> NSColor? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ci = CIImage(cgImage: cg)
        let e = ci.extent
        let region = CGRect(x: e.minX, y: e.maxY - e.height * frac, width: e.width, height: e.height * frac)
        guard let f = CIFilter(name: "CIAreaAverage",
                               parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: region)]),
              let out = f.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        ciContext.render(out, toBitmap: &px, rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255,
                       blue: CGFloat(px[2]) / 255, alpha: 1)
    }
}

func lerp(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return b }
    return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
                   green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                   blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t, alpha: 1)
}

// Windo — floating web window that stays on top of everything, including
// other apps' native fullscreen. Menu-bar utility, no Dock icon.
// Controls live in a floating Liquid Glass bar that collapses to a pill.
// ponytail: one file, AppKit + WKWebView, no deps. State in UserDefaults.

let kDefaultURL = "https://www.youtube.com"
let kUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

extension Notification.Name { static let windoToggle = Notification.Name("windoToggle") }

// Make the page's Fullscreen API fill the webview (= the Windo window) instead of
// the screen. We replace requestFullscreen/exitFullscreen with CSS that pins the
// element to the viewport, and fake fullscreenElement + fullscreenchange so sites
// like YouTube believe the request succeeded.
let kFullscreenShim = """
(function () {
  if (window.__windoFS) return; window.__windoFS = true;
  var d = document, E = Element.prototype, cur = null;
  function def(name, getter) {
    try { Object.defineProperty(d, name, { get: getter, configurable: true }); } catch (e) {}
  }
  // Fake the Fullscreen API so the page believes it entered fullscreen; YouTube
  // calls requestFullscreen on <html> and then resizes its own player to fill the
  // window. We don't reparent or hard-size anything — just report state + fire the
  // event, and let the site lay itself out.
  def('fullscreenElement', function () { return cur; });
  def('webkitFullscreenElement', function () { return cur; });
  def('webkitCurrentFullScreenElement', function () { return cur; });
  def('fullscreenEnabled', function () { return true; });
  def('webkitFullscreenEnabled', function () { return true; });
  def('webkitIsFullScreen', function () { return !!cur; });   // YouTube checks this one
  function post(o) { try { window.webkit.messageHandlers.windo.postMessage(JSON.stringify(o)); } catch (e) {} }
  function fire() {
    setTimeout(function () {   // native dispatches async; let listeners attach first
      ['fullscreenchange','webkitfullscreenchange'].forEach(function (n) { d.dispatchEvent(new Event(n)); });
    }, 0);
  }
  function enter(el) { if (cur || !el) return; cur = el; el.classList && el.classList.add('windo-fs'); fire(); post({fs:true}); }
  function leave() { if (!cur) return; cur.classList && cur.classList.remove('windo-fs'); cur = null; fire(); post({fs:false}); }
  E.requestFullscreen = function () { enter(this); return Promise.resolve(); };
  E.webkitRequestFullscreen = E.webkitRequestFullScreen = function () { enter(this); };
  d.exitFullscreen = function () { leave(); return Promise.resolve(); };
  d.webkitExitFullscreen = function () { leave(); };
  d.addEventListener('keydown', function (e) { if (e.key === 'Escape' && cur) leave(); }, true);
  // Size with viewport units, not %, so the video doesn't collapse to 0 height
  // against YouTube's unsized (faked-fullscreen) player container. object-fit
  // keeps aspect / letterboxes against the black root.
  var css = '.windo-fs{position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;' +
            'max-width:none!important;max-height:none!important;margin:0!important;overflow:hidden!important;background:#000!important;}' +
            '.windo-fs #movie_player,.windo-fs .html5-video-player,.windo-fs .html5-video-container{' +
            'left:0!important;top:0!important;width:100vw!important;height:100vh!important;max-width:none!important;max-height:none!important;}' +
            '.windo-fs video{position:absolute!important;left:0!important;top:0!important;width:100vw!important;height:100vh!important;' +
            'max-width:none!important;max-height:none!important;object-fit:contain!important;transform:none!important;}';
  var s = d.createElement('style'); s.textContent = css;
  (d.head || d.documentElement).appendChild(s);
})();
"""

struct Favorite: Codable { var name: String; var url: String }

// One browser tab = one WKWebView. Title KVO keeps the tab label live.
final class Tab {
    let webView: WKWebView
    var titleObs: NSKeyValueObservation?
    init(webView: WKWebView) { self.webView = webView }
}

// Transparent overlay over the webview: hold Option to drag the window from
// anywhere (the page itself otherwise swallows drag events, e.g. Plex).
final class DragOverlay: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        NSEvent.modifierFlags.contains(.option) ? self : nil
    }
    override func mouseDown(with e: NSEvent) { window?.performDrag(with: e) }
    override var mouseDownCanMoveWindow: Bool { true }
}

// Icon button: dim when idle, brightens with a soft fill on hover, deeper on press.
final class HoverButton: NSButton {
    private var hover: NSTrackingArea?
    var idleTint: NSColor = .secondaryLabelColor
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let h = hover { removeTrackingArea(h) }
        let h = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(h); hover = h
    }
    override func mouseEntered(with e: NSEvent) { paint(fill: 0.10, bright: true) }
    override func mouseExited(with e: NSEvent) { paint(fill: 0, bright: false) }
    override func mouseDown(with e: NSEvent) {
        paint(fill: 0.18, bright: true)
        super.mouseDown(with: e)   // blocks until mouseUp
        let inside = bounds.contains(convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
        paint(fill: inside ? 0.10 : 0, bright: inside)
    }
    private func paint(fill: CGFloat, bright: Bool) {
        wantsLayer = true
        layer?.cornerRadius = 8
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.18
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            c.allowsImplicitAnimation = true
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(fill).cgColor
            animator().contentTintColor = bright ? .labelColor : idleTint   // icons "light up"
        }
    }
}

// Floating Liquid Glass control bar in the bottom-left. A fixed window-glyph
// handle on the left; the bar grows from it on hover. Grab the handle to drag.
final class GlassBar: NSView {
    private let glass = NSGlassEffectView()
    private let content = NSView()
    private let icon = NSImageView()
    private let controls: NSStackView
    private let row: NSStackView
    private var widthC: NSLayoutConstraint!
    private let collapsedW: CGFloat = 40
    private let minExpandedW: CGFloat
    private let barH: CGFloat = 38
    private(set) var expanded = false

    // Expanded width fits the controls (tabs make this variable), never below the minimum.
    private var expandedW: CGFloat { max(minExpandedW, 11 + row.fittingSize.width + 14) }

    init(controls ctrls: [NSView], expandedWidth: CGFloat) {
        controls = NSStackView(views: ctrls)
        minExpandedW = expandedWidth
        row = NSStackView(views: [])
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        glass.cornerRadius = barH / 2
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        icon.image = NSImage(systemSymbolName: "square.split.2x2", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        controls.orientation = .horizontal
        controls.spacing = 5
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        controls.alphaValue = 0

        row.setViews([icon, controls], in: .leading)
        row.orientation = .horizontal
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        content.layer?.cornerRadius = barH / 2
        content.layer?.masksToBounds = true     // rounded clip, no square corners
        content.addSubview(row)
        glass.contentView = content

        widthC = widthAnchor.constraint(equalToConstant: collapsedW)
        NSLayoutConstraint.activate([
            widthC,
            heightAnchor.constraint(equalToConstant: barH),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 11),
            row.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setExpanded(_ on: Bool) {
        guard on != expanded else { return }
        expanded = on
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = on ? 0.34 : 0.26          // open slower, close quicker
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            widthC.animator().constant = on ? expandedW : collapsedW
            controls.animator().alphaValue = on ? 1 : 0    // controls fade in; handle never moves
            icon.animator().contentTintColor = on ? .labelColor : .secondaryLabelColor
            superview?.layoutSubtreeIfNeeded()
        }
    }

    // Tabs changed: regrow to fit the new content while open.
    func relayout() {
        guard expanded else { return }
        layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            widthC.animator().constant = expandedW
            superview?.layoutSubtreeIfNeeded()
        }
    }

    // Buttons/field take their own clicks; the handle and glass drag the window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit is NSButton || hit is NSTextField || hit is NSTextView { return hit }
        return self
    }
    override func mouseDown(with e: NSEvent) { window?.performDrag(with: e) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(collapse), object: nil)
        setExpanded(true)
    }
    override func mouseExited(with e: NSEvent) {
        if window?.firstResponder is NSText { return }   // keep open while typing
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(collapse), object: nil)
        perform(#selector(collapse), with: nil, afterDelay: 0.4)
    }
    @objc private func collapse() { setExpanded(false) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    var pageFullscreen = false
    // The fullscreen shim posts {fs:true/false}. While a video is in (faked) page
    // fullscreen, stop the ambient-tint takeSnapshot — snapshotting the hardware
    // video layer blanks it (black picture, audio keeps playing).
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard m.name == "windo", let s = m.body as? String,
              let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fs = obj["fs"] as? Bool else { return }
        pageFullscreen = fs
    }

    var window: NSWindow!
    var tabs: [Tab] = []
    var activeIndex = 0
    var webView: WKWebView { tabs[activeIndex].webView }   // the visible tab
    var webContainer: NSView!
    var tabBar: NSStackView!
    var urlField: NSTextField!
    var muteButton: NSButton!
    var statusItem: NSStatusItem!
    var glassBar: GlassBar!
    var hotKeyRef: EventHotKeyRef?
    var muted = false
    var pinned = true
    var compact = false
    var opacity: CGFloat = 1.0
    var favorites: [Favorite] = []
    var sampleTimer: Timer?
    var lerpTimer: Timer?
    var targetColor = NSColor(white: 0.1, alpha: 1)
    var currentColor = NSColor(white: 0.1, alpha: 1)

    func applicationDidFinishLaunching(_ note: Notification) {
        opacity = CGFloat(UserDefaults.standard.object(forKey: "opacity") as? Double ?? 1.0)
        compact = UserDefaults.standard.bool(forKey: "compact")
        loadFavorites()
        buildWindow()
        buildStatusItem()
        buildMainMenu()
        registerHotKey()
        NotificationCenter.default.addObserver(self, selector: #selector(hotKeyToggle),
                                               name: .windoToggle, object: nil)
        window.alphaValue = opacity
        addTab(url: UserDefaults.standard.string(forKey: "lastURL") ?? kDefaultURL, activate: true)
        setCompact(compact)
        showWindow()
        startTinting()
    }

    // MARK: - Ambient titlebar: tint the bar to the video's top-strip color

    func startTinting() {
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in self?.sampleTopColor() }
        lerpTimer = Timer.scheduledTimer(withTimeInterval: 0.045, repeats: true) { [weak self] _ in self?.tickTint() }
    }
    func sampleTopColor() {
        guard !compact, !pageFullscreen, window.isVisible, webView.bounds.width > 1 else { return }
        let cfg = WKSnapshotConfiguration()
        cfg.snapshotWidth = 64                      // downscale for speed
        webView.takeSnapshot(with: cfg) { [weak self] img, _ in
            if let c = img?.topAverageColor(0.18) { self?.targetColor = c }
        }
    }
    func tickTint() {
        guard !compact, window.isVisible else { return }
        currentColor = lerp(currentColor, targetColor, 0.12)   // ease toward the sampled color
        window.backgroundColor = currentColor
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    // MARK: - Web view

    func makeWebView() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsAirPlayForMediaPlayback = true
        // Native pref ON so the FS API surface exists and its getters are
        // configurable (with it off, YouTube's button does nothing). The shim then
        // overrides requestFullscreen and reparents into a clean fixed host so the
        // video's compositing layer isn't blacked out.
        if #available(macOS 12.3, *) { cfg.preferences.isElementFullscreenEnabled = true }
        cfg.userContentController.addUserScript(
            WKUserScript(source: kFullscreenShim, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.userContentController.add(self, name: "windo")   // fullscreen state ← shim
        let wv = WKWebView(frame: webContainer.bounds, configuration: cfg)
        wv.autoresizingMask = [.width, .height]
        wv.customUserAgent = kUserAgent
        wv.allowsBackForwardNavigationGestures = true
        wv.navigationDelegate = self
        if #available(macOS 13.3, *) { wv.isInspectable = true }
        return wv
    }

    // MARK: - Tabs

    @objc func newTab() { addTab(url: kDefaultURL, activate: true) }
    @objc func closeActiveTab() { closeTab(activeIndex) }
    @objc func selectTabAction(_ s: NSButton) { selectTab(s.tag) }
    @objc func closeTabAction(_ s: NSButton) { closeTab(s.tag) }

    func addTab(url: String, activate: Bool) {
        let wv = makeWebView()
        wv.isHidden = true
        webContainer.addSubview(wv, positioned: .below, relativeTo: nil)
        let tab = Tab(webView: wv)
        tab.titleObs = wv.observe(\.title) { [weak self] _, _ in self?.refreshTabBar() }
        tabs.append(tab)
        if activate { selectTab(tabs.count - 1) } else { refreshTabBar() }
        wv.load(URLRequest(url: normalizedURL(url) ?? URL(string: kDefaultURL)!))
    }

    func selectTab(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        activeIndex = i
        for (j, t) in tabs.enumerated() { t.webView.isHidden = (j != i) }
        urlField.stringValue = webView.url?.absoluteString ?? ""
        if muted { applyMute() }   // carry mute state onto the now-visible tab
        refreshTabBar()
    }

    func closeTab(_ i: Int) {
        guard tabs.count > 1, tabs.indices.contains(i) else { return }   // keep one tab alive
        tabs[i].titleObs?.invalidate()
        tabs[i].webView.removeFromSuperview()
        tabs.remove(at: i)
        if i < activeIndex { activeIndex -= 1 }
        else if i == activeIndex { activeIndex = min(i, tabs.count - 1) }
        selectTab(activeIndex)
    }

    func refreshTabBar() {
        guard tabBar != nil else { return }
        tabBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, t) in tabs.enumerated() {
            tabBar.addArrangedSubview(tabItem(index: i, title: t.webView.title, active: i == activeIndex))
        }
        let add = button("plus", #selector(newTab))
        add.toolTip = "New Tab"
        tabBar.addArrangedSubview(add)
        glassBar?.relayout()   // grow the bar to fit the new tab count
    }

    func tabItem(index: Int, title: String?, active: Bool) -> NSView {
        let name = (title?.isEmpty == false) ? title! : "New Tab"
        let sel = HoverButton()
        sel.isBordered = false
        sel.title = name.count > 22 ? String(name.prefix(22)) + "…" : name
        sel.font = .systemFont(ofSize: 11, weight: active ? .semibold : .regular)
        sel.idleTint = active ? .labelColor : .secondaryLabelColor
        sel.contentTintColor = sel.idleTint
        sel.tag = index; sel.target = self; sel.action = #selector(selectTabAction(_:))

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 2
        row.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 4)
        row.addArrangedSubview(sel)
        if tabs.count > 1 {
            let close = HoverButton()
            close.isBordered = false
            close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
            close.idleTint = .secondaryLabelColor
            close.contentTintColor = close.idleTint
            close.tag = index; close.target = self; close.action = #selector(closeTabAction(_:))
            close.widthAnchor.constraint(equalToConstant: 18).isActive = true
            row.addArrangedSubview(close)
        }
        if active {
            row.wantsLayer = true
            row.layer?.cornerRadius = 7
            row.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        }
        return row
    }

    // MARK: - Window (pure video; controls float on glass)

    func buildWindow() {
        let frame = NSRect(x: 0, y: 0, width: 860, height: 500)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],  // real titlebar = reliable drag
            backing: .buffered, defer: false)
        window.title = "Windo"
        window.titlebarAppearsTransparent = true   // titlebar shows the window bg color (our ambient tint)
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = currentColor
        window.setFrameAutosaveName("WindoMain")
        window.center()
        window.isReleasedWhenClosed = false

        let container = NSView(frame: frame)
        webContainer = NSView(frame: container.bounds)   // holds all tab webviews
        webContainer.autoresizingMask = [.width, .height]
        container.addSubview(webContainer)
        let overlay = DragOverlay(frame: container.bounds)
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay)
        window.contentView = container

        buildGlassBar(in: container)
        applyPin()
    }

    func buildGlassBar(in container: NSView) {
        let back = button("chevron.left", #selector(goBack))
        let reload = button("arrow.clockwise", #selector(reload))
        muteButton = button("speaker.wave.2.fill", #selector(toggleMute))

        urlField = NSTextField()
        urlField.placeholderString = "URL or search…"
        urlField.delegate = self
        urlField.bezelStyle = .roundedBezel
        urlField.font = .systemFont(ofSize: 12)
        urlField.usesSingleLineMode = true        // never wrap — scroll horizontally
        urlField.lineBreakMode = .byTruncatingHead
        urlField.maximumNumberOfLines = 1
        urlField.cell?.wraps = false
        urlField.cell?.isScrollable = true
        urlField.widthAnchor.constraint(equalToConstant: 160).isActive = true

        tabBar = NSStackView()
        tabBar.orientation = .horizontal
        tabBar.spacing = 4

        glassBar = GlassBar(controls: [back, reload, urlField, muteButton, tabBar], expandedWidth: 300)
        container.addSubview(glassBar)
        NSLayoutConstraint.activate([
            glassBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            glassBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
    }

    func button(_ symbol: String, _ action: Selector) -> NSButton {
        let b = HoverButton()
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imageScaling = .scaleProportionallyDown
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        b.contentTintColor = .labelColor
        b.target = self
        b.action = action
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return b
    }

    // MARK: - Always-on-top, including over other apps' fullscreen

    func applyPin() {
        NSApp.setActivationPolicy(.accessory)  // the unlock for floating over fullscreen apps
        window.level = pinned ? .floating : .normal
        window.collectionBehavior = pinned
            ? [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            : [.fullScreenAuxiliary]
    }

    // MARK: - Menu-bar item

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.split.2x2",
                                           accessibilityDescription: "Windo")  // simple 4-pane window
        rebuildMenu()
    }

    func rebuildMenu() {
        let menu = NSMenu()
        let tw = menu.addItem(withTitle: (window?.isVisible ?? false) ? "Hide Window" : "Show Window",
                              action: #selector(toggleWindow), keyEquivalent: "")
        tw.target = self
        menu.addItem(.separator())

        if favorites.isEmpty {
            menu.addItem(withTitle: "No favorites yet", action: nil, keyEquivalent: "").isEnabled = false
        } else {
            for (i, f) in favorites.enumerated() {
                let item = menu.addItem(withTitle: f.name, action: #selector(openFavorite(_:)), keyEquivalent: "")
                item.target = self; item.tag = i
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Add Current Page…", action: #selector(addFavorite), keyEquivalent: "d").target = self

        if !favorites.isEmpty {
            let manage = NSMenuItem(title: "Manage Favorites", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (i, f) in favorites.enumerated() {
                let rm = sub.addItem(withTitle: "Remove “\(f.name)”", action: #selector(removeFavorite(_:)), keyEquivalent: "")
                rm.target = self; rm.tag = i
            }
            manage.submenu = sub
            menu.addItem(manage)
        }
        menu.addItem(.separator())

        let c = menu.addItem(withTitle: "Compact Mode", action: #selector(toggleCompact), keyEquivalent: "")
        c.target = self; c.state = compact ? .on : .off
        menu.addItem(opacityMenuItem())

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Windo", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func opacityMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 34))
        let label = NSTextField(labelWithString: "Opacity")
        label.frame = NSRect(x: 14, y: 8, width: 54, height: 18)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        let s = NSSlider(value: Double(opacity), minValue: 0.25, maxValue: 1.0,
                         target: self, action: #selector(opacityChanged(_:)))
        s.frame = NSRect(x: 70, y: 7, width: 116, height: 20)
        s.isContinuous = true
        container.addSubview(label)
        container.addSubview(s)
        item.view = container
        return item
    }

    // MARK: - Favorites persistence

    func loadFavorites() {
        if let d = UserDefaults.standard.data(forKey: "favorites"),
           let f = try? JSONDecoder().decode([Favorite].self, from: d) {
            favorites = f
        } else {
            favorites = [Favorite(name: "YouTube", url: "https://www.youtube.com")]
        }
    }
    func saveFavorites() {
        if let d = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(d, forKey: "favorites")
        }
        rebuildMenu()
    }

    @objc func openFavorite(_ s: NSMenuItem) {
        guard favorites.indices.contains(s.tag) else { return }
        showWindow(); load(favorites[s.tag].url)
    }
    @objc func removeFavorite(_ s: NSMenuItem) {
        guard favorites.indices.contains(s.tag) else { return }
        favorites.remove(at: s.tag); saveFavorites()
    }
    @objc func addFavorite() {
        let alert = NSAlert()
        alert.messageText = "Add to Favorites"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = webView.title?.isEmpty == false ? webView.title! : (webView.url?.host ?? "Page")
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        showWindow()
        if alert.runModal() == .alertFirstButtonReturn, let url = webView.url?.absoluteString {
            favorites.append(Favorite(name: field.stringValue, url: url))
            saveFavorites()
        }
    }

    // MARK: - Navigation

    func normalizedURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        if !s.contains("://") {
            if s.contains(" ") || !s.contains(".") {
                s = "https://www.youtube.com/results?search_query=" +
                    (s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s)
            } else {
                s = "https://" + s
            }
        }
        return URL(string: s)
    }

    func load(_ raw: String) {
        guard let url = normalizedURL(raw) else { return }
        webView.load(URLRequest(url: url))
        urlField.stringValue = url.absoluteString
    }

    @objc func goBack() { webView.goBack() }
    @objc func reload() { webView.reload() }
    @objc func focusURL() {
        showWindow()
        glassBar.setExpanded(true)
        window.makeFirstResponder(urlField)
    }
    // ponytail: JS mute — no public WKWebView mute API.
    func applyMute() {
        webView.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(m=>m.muted=\(muted))")
    }
    @objc func toggleMute() {
        muted.toggle()
        applyMute()
        muteButton.image = NSImage(systemSymbolName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                   accessibilityDescription: nil)
    }
    @objc func toggleWindow() {
        if window.isVisible { window.orderOut(nil) } else { showWindow() }
        rebuildMenu()
    }
    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        rebuildMenu()
    }

    // MARK: - Opacity / compact / global hotkey

    @objc func opacityChanged(_ s: NSSlider) {
        opacity = CGFloat(s.doubleValue)
        window.alphaValue = opacity
        UserDefaults.standard.set(Double(opacity), forKey: "opacity")
    }

    @objc func toggleCompact() { setCompact(!compact) }
    func setCompact(_ on: Bool) {
        compact = on
        glassBar?.isHidden = on   // glass bar (now incl. tabs) hides in compact
        // Compact reclaims the titlebar strip for full-bleed video.
        if on { window.styleMask.insert(.fullSizeContentView) }
        else  { window.styleMask.remove(.fullSizeContentView) }
        for b: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(b)?.isHidden = on
        }
        UserDefaults.standard.set(on, forKey: "compact")
        rebuildMenu()
    }

    func registerHotKey() {
        let id = EventHotKeyID(signature: 0x57494e44, id: 1)  // 'WIND'
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            NotificationCenter.default.post(name: .windoToggle, object: nil)
            return noErr
        }, 1, &spec, nil, nil)
        // ⌃⌘H toggles the window from anywhere (global, no permission needed).
        // Not ⌥⌘H: that's the system "Hide Others" command and AppKit eats it
        // while Windo is the front app.
        RegisterEventHotKey(UInt32(kVK_ANSI_H), UInt32(controlKey | cmdKey),
                            id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    @objc func hotKeyToggle() {
        if window.isVisible && window.isKeyWindow { window.orderOut(nil) } else { showWindow() }
        rebuildMenu()
    }

    // MARK: - WKNavigationDelegate (remember where we are)

    func webView(_ wv: WKWebView, didFinish nav: WKNavigation!) {
        guard let u = wv.url?.absoluteString else { return }
        if wv === webView {                       // only the visible tab drives the URL field
            urlField.stringValue = u
            UserDefaults.standard.set(u, forKey: "lastURL")
        }
        refreshTabBar()
    }

    // MARK: - URL field

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            load(urlField.stringValue)
            window.makeFirstResponder(webView)
            glassBar.setExpanded(false)
            return true
        }
        return false
    }

    // Minimal main menu so keyboard shortcuts work without a visible menu bar.
    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "New Tab", action: #selector(newTab), keyEquivalent: "t").target = self
        appMenu.addItem(withTitle: "Close Tab", action: #selector(closeActiveTab), keyEquivalent: "w").target = self
        appMenu.addItem(withTitle: "Focus URL", action: #selector(focusURL), keyEquivalent: "l").target = self
        appMenu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r").target = self
        appMenu.addItem(withTitle: "Add to Favorites", action: #selector(addFavorite), keyEquivalent: "d").target = self
        appMenu.addItem(withTitle: "Compact Mode", action: #selector(toggleCompact), keyEquivalent: ".").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Windo", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Edit menu — required for ⌘A/⌘C/⌘X/⌘V/⌘Z to reach the URL field editor.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
