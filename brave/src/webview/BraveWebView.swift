/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import WebKit
import Shared

let kNotificationPageUnload = "kNotificationPageUnload"
let kNotificationAllWebViewsDeallocated = "kNotificationAllWebViewsDeallocated"

func convertNavActionToWKType(type:UIWebViewNavigationType) -> WKNavigationType {
    return WKNavigationType(rawValue: type.rawValue)!
}

class ContainerWebView : WKWebView {
    weak var legacyWebView: BraveWebView?
}

var nullWebView: WKWebView = WKWebView()
var nullWKNavigation: WKNavigation = WKNavigation()

enum KVOStrings: String {
    case kvoCanGoBack = "canGoBack"
    case kvoCanGoForward = "canGoForward"
    case kvoLoading = "loading"
    case kvoURL = "URL"
    case kvoEstimatedProgress = "estimatedProgress"

    // Going to handle URL separately, see broadcast code
    static let allValuesExceptURL = [kvoCanGoBack, kvoCanGoForward, kvoLoading, kvoEstimatedProgress]
}

@objc class HandleJsWindowOpen : NSObject {
    static func open(url: String) {
        ensureMainThread {
            guard let wv = BraveApp.getCurrentWebView() else { return }
            let current = wv.URL
            print("window.open")
            if BraveApp.getPrefs()?.boolForKey("blockPopups") ?? true {
                guard let lastTappedTime = wv.lastTappedTime else { return }
                if fabs(lastTappedTime.timeIntervalSinceNow) > 0.75 { // outside of the 3/4 sec time window and we ignore it
                    print(lastTappedTime.timeIntervalSinceNow)
                    return
                }
            }
            wv.lastTappedTime = nil
            if let _url = NSURL(string: url, relativeToURL: current) {
                getApp().browserViewController.openURLInNewTab(_url)
            }
        }
    }
}

class WebViewToUAMapper {
    static private let idToWebview = NSMapTable(keyOptions: .StrongMemory, valueOptions: .WeakMemory)

    static func setId(uniqueId: Int, webView: BraveWebView) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        idToWebview.setObject(webView, forKey: uniqueId)
    }

    static func userAgentToWebview(ua: String?) -> BraveWebView? {
        // synchronize code from this point on.
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        guard let ua = ua else { return nil }
        guard let loc = ua.rangeOfString("_id/") else {
            // the first created webview doesn't have this id set (see webviewBuiltinUserAgent to explain)
            return idToWebview.objectForKey(1) as? BraveWebView
        }
        let keyString = ua.substringWithRange(loc.endIndex..<loc.endIndex.advancedBy(6))
        guard let key = Int(keyString) else { return nil }
        return idToWebview.objectForKey(key) as? BraveWebView
    }
}

struct BraveWebViewConstants {
    static let kNotificationWebViewLoadCompleteOrFailed = "kNotificationWebViewLoadCompleteOrFailed"
    static let kNotificationPageInteractive = "kNotificationPageInteractive"
    static let kContextMenuBlockNavigation = 8675309
}

class BraveWebView: UIWebView {
    let specialStopLoadUrl = "http://localhost.stop.load"
    weak var navigationDelegate: WKNavigationDelegate?
    weak var UIDelegate: WKUIDelegate?
    lazy var configuration: BraveWebViewConfiguration = { return BraveWebViewConfiguration(webView: self) }()
    lazy var backForwardList: WebViewBackForwardList = { return WebViewBackForwardList(webView: self) } ()
    var progress: WebViewProgress?
    var certificateInvalidConnection:NSURLConnection?
    var braveShieldState = BraveShieldState() {
        didSet {
            if let fpOn = braveShieldState.isOnFingerprintProtection(), browser = getApp().tabManager.tabForWebView(self) where fpOn {
                if browser.getHelper(FingerprintingProtection.self) == nil {
                    let fp = FingerprintingProtection(browser: browser)
                    browser.addHelper(fp)
                }
            } else {
                getApp().tabManager.tabForWebView(self)?.removeHelper(FingerprintingProtection.self)
            }

            delay(0.2) { // update the UI, wait a bit for loading to have started
                (getApp().browserViewController as! BraveBrowserViewController).updateBraveShieldButtonState(animated: false)
            }
        }
    }
    var blankTargetLinkDetectionOn = true
    var lastTappedTime: NSDate?
    var removeBvcObserversOnDeinit: ((UIWebView) -> Void)?
    var removeProgressObserversOnDeinit: ((UIWebView) -> Void)?

    var prevDocumentLocation = ""
    var estimatedProgress: Double = 0
    var title: String = "" {
        didSet {
            if let item = backForwardList.currentItem {
                item.title = title
            }
        }
    }

    private var _url: (url: NSURL?, isReliableSource: Bool, prevUrl: NSURL?) = (nil, false, nil)

    private var lastBroadcastedKvoUrl: String = ""
    func setUrl(url: NSURL?, reliableSource: Bool) {
        _url.prevUrl = _url.url
        _url.isReliableSource = reliableSource
        if URL?.absoluteString.endsWith("?") ?? false {
            if let noQuery = URL?.absoluteString.componentsSeparatedByString("?")[0] {
                _url.url = NSURL(string: noQuery)
            }
        } else {
            _url.url = url
        }

        if let url = URL?.absoluteString where url != lastBroadcastedKvoUrl {
            kvoBroadcast([KVOStrings.kvoURL])
            lastBroadcastedKvoUrl = url
        }
    }

    func isUrlSourceReliable() -> Bool {
        return _url.isReliableSource
    }

    var previousUrl: NSURL? { get { return _url.prevUrl } }

    var URL: NSURL? {
        get {
            return _url.url
        }
    }

    var uniqueId = -1

    var internalIsLoadingEndedFlag: Bool = false;
    var knownFrameContexts = Set<NSObject>()
    private static var containerWebViewForCallbacks = { return ContainerWebView() }()
    // From http://stackoverflow.com/questions/14268230/has-anybody-found-a-way-to-load-https-pages-with-an-invalid-server-certificate-u
    var loadingUnvalidatedHTTPSPage: Bool = false

    // This gets set as soon as it is available from the first UIWebVew created
    private static var webviewBuiltinUserAgent: String?

    // To mimic WKWebView we need this property. And, to easily overrride where Firefox code is setting it, we hack the setter,
    // so that a custom agent is set always to our kDesktopUserAgent.
    // A nil customUserAgent means to use the default which is correct.
    //TODO setting the desktop agent doesn't currently work, see note below)
    var customUserAgent:String? {
        willSet {
            if self.customUserAgent == newValue || newValue == nil {
                return
            }
            self.customUserAgent = newValue == nil ? nil : kDesktopUserAgent
            // The following doesn't work, we need to kill and restart the webview, and restore its history state
            // for this setting to take effect
            //      let defaults = NSUserDefaults(suiteName: AppInfo.sharedContainerIdentifier())!
            //      defaults.registerDefaults(["UserAgent": (self.customUserAgent ?? "")])
        }
    }

    // Needed to identify webview in url protocol
    func generateUniqueUserAgent() {
        // synchronize code from this point on.
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        struct StaticCounter {
            static var counter = 0
        }

        StaticCounter.counter += 1
        if let webviewBuiltinUserAgent = BraveWebView.webviewBuiltinUserAgent {
            let userAgent = webviewBuiltinUserAgent + String(format:" _id/%06d", StaticCounter.counter)
            let defaults = NSUserDefaults(suiteName: AppInfo.sharedContainerIdentifier())!
            defaults.registerDefaults(["UserAgent": userAgent ])
            self.uniqueId = StaticCounter.counter
            WebViewToUAMapper.setId(uniqueId, webView:self)
        } else {
            if StaticCounter.counter > 1 {
                // We shouldn't get here, we allow the first webview to have no user agent, and we special-case the look up. The first webview inits the UA from its built in defaults
                // If we get to more than one, just use a hard coded user agent, to avoid major bugs
                let device = UIDevice.currentDevice().userInterfaceIdiom == .Phone ? "iPhone" : "iPad"
                BraveWebView.webviewBuiltinUserAgent = "Mozilla/5.0 (\(device)) AppleWebKit/601.1.46 (KHTML, like Gecko) Mobile/13C75"
            }
            WebViewToUAMapper.idToWebview.setObject(self, forKey: 1) // the first webview, we don't have the user agent just yet
        }
    }

    var triggeredLocationCheckTimer = NSTimer()
    // On page load, the contentSize of the webview is updated (**). If the webview has not been notified of a page change (i.e. shouldStartLoadWithRequest was never called) then 'loading' will be false, and we should check the page location using JS.
    // (** Not always updated, particularly on back/forward. For instance load duckduckgo.com, then google.com, and go back. No content size change detected.)
    func contentSizeChangeDetected() {
        if triggeredLocationCheckTimer.valid {
            return
        }

        // Add a time delay so that multiple calls are aggregated
        triggeredLocationCheckTimer = NSTimer.scheduledTimerWithTimeInterval(0.15, target: self, selector: #selector(timeoutCheckLocation), userInfo: nil, repeats: false)
    }

    // Pushstate navigation may require this case (see brianbondy.com), as well as sites for which simple pushstate detection doesn't work:
    // youtube and yahoo news are examples of this (http://stackoverflow.com/questions/24297929/javascript-to-listen-for-url-changes-in-youtube-html5-player)
    @objc func timeoutCheckLocation() {
        assert(NSThread.isMainThread())

        func tryUpdateUrl() {
            guard let location = self.stringByEvaluatingJavaScriptFromString("window.location.href"), currentUrl = URL?.absoluteString else { return }
            if location == currentUrl || location.contains("about:") || location.contains("//localhost") || URL?.host != NSURL(string: location)?.host {
                return
            }

            if isUrlSourceReliable() && location == previousUrl?.absoluteString {
                return
            }

            print("Page change detected by content size change triggered timer: \(location)")

            NSNotificationCenter.defaultCenter().postNotificationName(kNotificationPageUnload, object: self)
            setUrl(NSURL(string: location), reliableSource: false)

            shieldStatUpdate(.reset)

            progress?.reset()
        }

        progress?.setProgress(0.3)
        kvoBroadcast([KVOStrings.kvoEstimatedProgress])

        tryUpdateUrl()

        if (!loading ||
            stringByEvaluatingJavaScriptFromString("document.readyState.toLowerCase()") == "complete") && !isUrlSourceReliable()
        {
            title = stringByEvaluatingJavaScriptFromString("document.title") ?? ""
            internalIsLoadingEndedFlag = false // need to set this to bypass loadingCompleted() precondition
            loadingCompleted()
            kvoBroadcast()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    static var allocCounter = 0

    private func commonInit() {
        BraveWebView.allocCounter += 1
        print("webview init  \(BraveWebView.allocCounter)")
        generateUniqueUserAgent()

        progress = WebViewProgress(parent: self)

        delegate = self
        scalesPageToFit = true

        scrollView.showsHorizontalScrollIndicator = false

        #if !TEST
            let rate = UIScrollViewDecelerationRateFast + (UIScrollViewDecelerationRateNormal - UIScrollViewDecelerationRateFast) * 0.5;
            scrollView.setValue(NSValue(CGSize: CGSizeMake(rate, rate)), forKey: "_decelerationFactor")
        #endif
    }

    var jsBlockedStatLastUrl: String? = nil
    func checkScriptBlockedAndBroadcastStats() {
        if braveShieldState.isOnScriptBlocking() ?? BraveApp.getPrefs()?.boolForKey(kPrefKeyNoScriptOn) ?? false {
            let jsBlocked = Int(stringByEvaluatingJavaScriptFromString("document.getElementsByTagName('script').length") ?? "0") ?? 0

            if request?.URL?.absoluteString == jsBlockedStatLastUrl && jsBlocked == 0 {
                return
            }
            jsBlockedStatLastUrl = request?.URL?.absoluteString

            shieldStatUpdate(.jsSetValue, jsBlocked)
        } else {
            shieldStatUpdate(.broadcastOnly)
        }
    }

    func internalProgressNotification(notification: NSNotification) {
        //print("\(notification.userInfo?["WebProgressEstimatedProgressKey"])")
        if (notification.userInfo?["WebProgressEstimatedProgressKey"] as? Double ?? 0 > 0.99) {
            delegate?.webViewDidFinishLoad?(self)
        }
    }

    override var loading: Bool {
        get {
            if internalIsLoadingEndedFlag {
                // we detected load complete internally –UIWebView sometimes stays in a loading state (i.e. bbc.com)
                return false
            }
            return super.loading
        }
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        commonInit()
    }

    deinit {
        BraveWebView.allocCounter -= 1
        if (BraveWebView.allocCounter == 0) {
            NSNotificationCenter.defaultCenter().postNotificationName(kNotificationAllWebViewsDeallocated, object: nil)
            print("NO LIVE WEB VIEWS")
        }

        NSNotificationCenter.defaultCenter().removeObserver(self)

        _ = Try(withTry: {
            self.removeBvcObserversOnDeinit?(self)
        }) { (exception) -> Void in
            print("Failed remove: \(exception)")
        }

        _ = Try(withTry: {
            self.removeProgressObserversOnDeinit?(self)
        }) { (exception) -> Void in
            print("Failed remove: \(exception)")
        }

        print("webview deinit \(title) ")
    }

    var blankTargetUrl: String?

    func urlBlankTargetTapped(url: String) {
        blankTargetUrl = url
    }

    let internalProgressStartedNotification = "WebProgressStartedNotification"
    let internalProgressChangedNotification = "WebProgressEstimateChangedNotification"
    let internalProgressFinishedNotification = "WebProgressFinishedNotification" // Not usable

    override func loadRequest(request: NSURLRequest) {
        guard let internalWebView = valueForKeyPath("documentView.webView") else { return }
        NSNotificationCenter.defaultCenter().removeObserver(self, name: internalProgressChangedNotification, object: internalWebView)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(BraveWebView.internalProgressNotification(_:)), name: internalProgressChangedNotification, object: internalWebView)

        if let url = request.URL, domain = url.normalizedHost() {
            braveShieldState = BraveShieldState.perNormalizedDomain[domain] ?? BraveShieldState()
        }
        super.loadRequest(request)
    }

    func loadingCompleted() {
        if internalIsLoadingEndedFlag {
            return
        }
        internalIsLoadingEndedFlag = true

        // Wait a tiny bit in hopes the page contents are updated. Load completed doesn't mean the UIWebView has done any rendering (or even has the JS engine for the page ready, see the delay() below)
        delay(0.1) {
            [weak self] in
            guard let me = self else { return }
            guard let docLoc = me.stringByEvaluatingJavaScriptFromString("document.location.href") else { return }

            if docLoc != me.prevDocumentLocation {
                me.title = me.stringByEvaluatingJavaScriptFromString("document.title") ?? NSURL(string: docLoc)?.baseDomain() ?? ""
                #if DEBUG
                print("Adding history, TITLE:\(me.title)")
                #endif
                if let nd = me.navigationDelegate {
                    BraveWebView.containerWebViewForCallbacks.legacyWebView = me
                    nd.webView?(BraveWebView.containerWebViewForCallbacks, didFinishNavigation: nullWKNavigation)
                }
            }
            me.prevDocumentLocation = docLoc

            me.configuration.userContentController.injectJsIntoPage()
            NSNotificationCenter.defaultCenter().postNotificationName(BraveWebViewConstants.kNotificationWebViewLoadCompleteOrFailed, object: me)
            LegacyUserContentController.injectJsIntoAllFrames(me, script: "document.body.style.webkitTouchCallout='none'")

            me.stringByEvaluatingJavaScriptFromString("console.log('get favicons'); __firefox__.favicons.getFavicons()")

            #if !TEST
                me.replaceAdImages(me)
            #endif

            me.checkScriptBlockedAndBroadcastStats()
        }
    }

    func kvoBroadcast(kvos: [KVOStrings]? = nil) {
        if let _kvos = kvos {
            for item in _kvos {
                willChangeValueForKey(item.rawValue)
                didChangeValueForKey(item.rawValue)
            }
        } else {
            // URL has its own broadcasting when set
            kvoBroadcast(KVOStrings.allValuesExceptURL)
        }
    }

    func canNavigateBackward() -> Bool {
        return self.canGoBack
    }

    func canNavigateForward() -> Bool {
        return self.canGoForward
    }

    func reloadFromOrigin() {
        self.reload()
    }

    override func reload() {
        shieldStatUpdate(.reset)
        progress?.setProgress(0.3)
        NSURLCache.sharedURLCache().removeAllCachedResponses()
        NSURLCache.sharedURLCache().diskCapacity = 0
        NSURLCache.sharedURLCache().memoryCapacity = 0

        if let url = URL, domain = url.normalizedHost() {
            braveShieldState = BraveShieldState.perNormalizedDomain[domain] ?? BraveShieldState()
            (getApp().browserViewController as! BraveBrowserViewController).updateBraveShieldButtonState(animated: false)
        }
        super.reload()
        
        BraveApp.setupCacheDefaults()
    }

    override func stopLoading() {
        super.stopLoading()
        self.progress?.reset()
    }

    private func convertStringToDictionary(text: String?) -> [String:AnyObject]? {
        if let data = text?.dataUsingEncoding(NSUTF8StringEncoding) where text?.characters.count > 0 {
            do {
                let json = try NSJSONSerialization.JSONObjectWithData(data, options: .MutableContainers) as? [String:AnyObject]
                return json
            } catch {
                print("Something went wrong")
            }
        }
        return nil
    }

    func evaluateJavaScript(javaScriptString: String, completionHandler: ((AnyObject?, NSError?) -> Void)?) {
        ensureMainThread() {
            let wrapped = "var result = \(javaScriptString); JSON.stringify(result)"
            let string = self.stringByEvaluatingJavaScriptFromString(wrapped)
            let dict = self.convertStringToDictionary(string)
            completionHandler?(dict, NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotOpenFile, userInfo: nil))
        }
    }

    func goToBackForwardListItem(item: LegacyBackForwardListItem) {
        if let index = backForwardList.backList.indexOf(item) {
            let backCount = backForwardList.backList.count - index
            for _ in 0..<backCount {
                goBack()
            }
        } else if let index = backForwardList.forwardList.indexOf(item) {
            for _ in 0..<(index + 1) {
                goForward()
            }
        }
    }

    override func goBack() {
        // stop scrolling so the web view will respond faster
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        NSNotificationCenter.defaultCenter().postNotificationName(kNotificationPageUnload, object: self)
        super.goBack()
    }

    override func goForward() {
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        NSNotificationCenter.defaultCenter().postNotificationName(kNotificationPageUnload, object: self)
        super.goForward()
    }

    class func isTopFrameRequest(request:NSURLRequest) -> Bool {
        return request.URL == request.mainDocumentURL
    }

    // Long press context menu text selection overriding
    override func canPerformAction(action: Selector, withSender sender: AnyObject?) -> Bool {
        return super.canPerformAction(action, withSender: sender)
    }

    func injectCSS(css: String) {
        var js = "var script = document.createElement('style');"
        js += "script.type = 'text/css';"
        js += "script.innerHTML = '\(css)';"
        js += "document.head.appendChild(script);"
        LegacyUserContentController.injectJsIntoAllFrames(self, script: js)
    }

    var safeBrowsingCheckIsEmptyPageTimer = NSTimer()

    func safeBrowsingCheckIsEmptyPageTimeout(timer: NSTimer) {
        let urlInfo = timer.userInfo as? NSURL
        safeBrowsingCheckIsEmptyPageTimer.invalidate()

        ensureMainThread {
            let contents = self.stringByEvaluatingJavaScriptFromString("document.body")
            if contents?.isEmpty ?? true {
                let path = NSBundle.mainBundle().pathForResource("SafeBrowsingError", ofType: "html")!
                let src = try! NSString(contentsOfFile: path, encoding: NSUTF8StringEncoding) as String
                self.loadHTMLString(src, baseURL: nil)
            }
            delay(0.2) {
                [weak self] in
                self?.setUrl(urlInfo, reliableSource: true)
            }
        }
    }

    func safeBrowsingCheckIsEmptyPage(url: NSURL?) {
        if safeBrowsingCheckIsEmptyPageTimer.valid {
            return
        }
        safeBrowsingCheckIsEmptyPageTimer = NSTimer.scheduledTimerWithTimeInterval(0.5, target: self, selector: #selector(safeBrowsingCheckIsEmptyPageTimeout), userInfo: url, repeats: false)
    }

    enum ShieldStatUpdate {
        case reset
        case broadcastOnly
        case httpseIncrement
        case abAndTpIncrement
        case jsSetValue
        case fpIncrement
    }

    var shieldStats = ShieldBlockedStats()

    func shieldStatUpdate(stat: ShieldStatUpdate, _ value: Int = 1) {

        switch stat {
        case .broadcastOnly:
            break
        case .reset:
            shieldStats = ShieldBlockedStats()
        case .httpseIncrement:
            shieldStats.httpse += value
        case .abAndTpIncrement:
            shieldStats.abAndTp += value
        case .jsSetValue:
            shieldStats.js = value
        case .fpIncrement:
            shieldStats.fp += value
        }

        delay(0.2) { [weak self] in
            if let me = self where BraveApp.getCurrentWebView() === me {
                (getApp().rootViewController.visibleViewController as? BraveTopViewController)?.rightSidePanel.setShieldBlockedStats(me.shieldStats)
            }
        }
    }
}

extension BraveWebView: UIWebViewDelegate {

    class LegacyNavigationAction : WKNavigationAction {
        var writableRequest: NSURLRequest
        var writableType: WKNavigationType

        init(type: WKNavigationType, request: NSURLRequest) {
            writableType = type
            writableRequest = request
            super.init()
        }

        override var request: NSURLRequest { get { return writableRequest} }
        override var navigationType: WKNavigationType { get { return writableType } }
        override var sourceFrame: WKFrameInfo {
            get { return WKFrameInfo() }
        }
    }

    func webView(webView: UIWebView,shouldStartLoadWithRequest request: NSURLRequest, navigationType: UIWebViewNavigationType ) -> Bool {
        guard let url = request.URL else { return false }

        if url.absoluteString == blankTargetUrl {
            blankTargetUrl = nil
            getApp().browserViewController.openURLInNewTab(url)
            return false
        }
        blankTargetUrl = nil

        if let contextMenu = window?.rootViewController?.presentedViewController
            where contextMenu.view.tag == BraveWebViewConstants.kContextMenuBlockNavigation {
            // When showing a context menu, the webview will often still navigate (ex. news.google.com)
            // We need to block navigation using this tag.
            return false
        }

        if BraveWebView.webviewBuiltinUserAgent == nil {
            BraveWebView.webviewBuiltinUserAgent = request.valueForHTTPHeaderField("User-Agent")
            assert(BraveWebView.webviewBuiltinUserAgent != nil)
        }

        if url.scheme == "mailto" {
            UIApplication.sharedApplication().openURL(url)
            return false
        }

        #if DEBUG
            var printedUrl = url.absoluteString
            let maxLen = 100
            if printedUrl.characters.count > maxLen {
                printedUrl =  printedUrl.substringToIndex(printedUrl.startIndex.advancedBy(maxLen)) + "..."
            }
            //print("webview load: " + printedUrl)
        #endif

        if AboutUtils.isAboutHomeURL(url) {
            setUrl(url, reliableSource: true)
            progress?.completeProgress()
            return true
        }

        if url.absoluteString.contains(specialStopLoadUrl) {
            progress?.completeProgress()
            return false
        }

        if loadingUnvalidatedHTTPSPage {
            certificateInvalidConnection = NSURLConnection(request: request, delegate: self)
            certificateInvalidConnection?.start()
            return false
        }

        if let progressCheck = progress?.shouldStartLoadWithRequest(request, navigationType: navigationType) where !progressCheck {
            return false
        }

        var result = true
        if let nd = navigationDelegate {
            let action:LegacyNavigationAction =
                LegacyNavigationAction(type: convertNavActionToWKType(navigationType), request: request)

            nd.webView?(nullWebView, decidePolicyForNavigationAction: action,
                        decisionHandler: { (policy:WKNavigationActionPolicy) -> Void in
                            result = policy == .Allow
            })
        }

        if url.scheme.startsWith("itms") || url.host == "itunes.apple.com" {
            progress?.completeProgress()
            return false
        }

        let locationChanged = BraveWebView.isTopFrameRequest(request) && url.absoluteString != URL?.absoluteString
        if locationChanged {
            blankTargetLinkDetectionOn = true
            // TODO Maybe separate page unload from link clicked.
            NSNotificationCenter.defaultCenter().postNotificationName(kNotificationPageUnload, object: self)
            setUrl(url, reliableSource: true)
            #if DEBUG
                print("Page changed by shouldStartLoad: \(URL?.absoluteString ?? "")")
            #endif

            if let url = request.URL, domain = url.normalizedHost() {
                braveShieldState = BraveShieldState.perNormalizedDomain[domain] ?? BraveShieldState()
            }

            shieldStatUpdate(.reset)
        }

        kvoBroadcast()

        return result
    }


    func webViewDidStartLoad(webView: UIWebView) {
        backForwardList.update()

        if let nd = navigationDelegate {
            // this triggers the network activity spinner
            nd.webView?(nullWebView, didStartProvisionalNavigation: nullWKNavigation)
        }
        progress?.webViewDidStartLoad()
        kvoBroadcast([KVOStrings.kvoLoading])

        #if !TEST
            HideEmptyImages.runJsInWebView(self)
        #endif

        configuration.userContentController.injectFingerprintProtection()
    }

    func webViewDidFinishLoad(webView: UIWebView) {
        assert(NSThread.isMainThread())

        // browserleaks canvas requires injection at this point
        configuration.userContentController.injectFingerprintProtection()

        guard let pageInfo = stringByEvaluatingJavaScriptFromString("document.readyState.toLowerCase() + '|' + document.title") else {
            return
        }
        let pageInfoArray = pageInfo.componentsSeparatedByString("|")

        let readyState = pageInfoArray.first // ;print("readyState:\(readyState)")
        title = pageInfoArray.last ?? ""
        progress?.webViewDidFinishLoad(documentReadyState: readyState)

        backForwardList.update()
        kvoBroadcast()
    }

    func webView(webView: UIWebView, didFailLoadWithError error: NSError?) {
        if (error?.code == NSURLErrorCancelled) {
            return
        }

        if (error?.domain == NSURLErrorDomain) {
            if (error?.code == NSURLErrorServerCertificateHasBadDate      ||
                error?.code == NSURLErrorServerCertificateUntrusted         ||
                error?.code == NSURLErrorServerCertificateHasUnknownRoot    ||
                error?.code == NSURLErrorServerCertificateNotYetValid)
            {
                let errorUrl = error?.userInfo["NSErrorFailingURLKey"] as? String ?? ""
                if errorUrl.characters.count < 1 {
                    #if DEBUG
                        // This doesn't seem to happen on the top level doc, and when a resource is being repeatedly loaded and fails, this would show up repeatedly and block using the page
                        BraveApp.showErrorAlert(title: "Certificate Error", error: "Unable to load site due to invalid certificate")
                    #endif
                    return
                }

                let alert = UIAlertController(title: "Certificate Error", message: "The identity of \(errorUrl) can't be verified", preferredStyle: UIAlertControllerStyle.Alert)
                alert.addAction(UIAlertAction(title: "Cancel", style: UIAlertActionStyle.Default) {
                    handler in
                    self.stopLoading()
                    webView.loadRequest(NSURLRequest(URL: NSURL(string: self.specialStopLoadUrl)!))

                    // The current displayed url is wrong, so easiest hack is:
                    if (self.canGoBack) { // I don't think the !canGoBack case needs handling
                        self.goBack()
                        self.goForward()
                    }
                    })
                alert.addAction(UIAlertAction(title: "Continue", style: UIAlertActionStyle.Default) {
                    handler in
                    self.loadingUnvalidatedHTTPSPage = true;
                    if let url = NSURL(string: errorUrl) {
                        self.loadRequest(NSURLRequest(URL: url))
                    }
                    })

                #if !TEST
                    window?.rootViewController?.presentViewController(alert, animated: true, completion: nil)
                #endif
                return
            }
        }

        NSNotificationCenter.defaultCenter()
            .postNotificationName(BraveWebViewConstants.kNotificationWebViewLoadCompleteOrFailed, object: self)
        if let nd = navigationDelegate {
            nd.webView?(nullWebView, didFailNavigation: nullWKNavigation,
                        withError: error ?? NSError.init(domain: "", code: 0, userInfo: nil))
        }

        if let error = error, urlString = error.userInfo["NSErrorFailingURLStringKey"] as? String
            where error.code == -1009 /*kCFURLErrorNotConnectedToInternet*/ {
            if let url = NSURL(string: urlString)  {
                let cache = NSURLCache.sharedURLCache().cachedResponseForRequest(NSURLRequest(URL: url))
                if let html = cache?.data.utf8EncodedString {
                    loadHTMLString(html, baseURL: url)
                }
            }
        }

        print("didFailLoadWithError: \(error)")
        progress?.didFailLoadWithError()
        kvoBroadcast()
    }
}

extension BraveWebView : NSURLConnectionDelegate, NSURLConnectionDataDelegate {
    func connection(connection: NSURLConnection, willSendRequestForAuthenticationChallenge challenge: NSURLAuthenticationChallenge) {
        guard let trust = challenge.protectionSpace.serverTrust else { return }
        let cred = NSURLCredential(forTrust: trust)
        challenge.sender?.useCredential(cred, forAuthenticationChallenge: challenge)
    }
    
    func connection(connection: NSURLConnection, didReceiveResponse response: NSURLResponse) {
        guard let url = URL else { return }
        loadingUnvalidatedHTTPSPage = false
        loadRequest(NSURLRequest(URL: url))
        certificateInvalidConnection?.cancel()
    }    
}
