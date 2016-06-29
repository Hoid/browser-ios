/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import WebKit
import Storage
import Shared

private let log = Logger.browserLogger

protocol TabManagerDelegate: class {
    func tabManager(tabManager: TabManager, didSelectedTabChange selected: Browser?, previous: Browser?)
    func tabManager(tabManager: TabManager, didCreateWebView tab: Browser)
    func tabManager(tabManager: TabManager, didAddTab tab: Browser)
    func tabManager(tabManager: TabManager, didRemoveTab tab: Browser)
    func tabManagerDidRestoreTabs(tabManager: TabManager)
    func tabManagerDidAddTabs(tabManager: TabManager)
    func tabManagerDidEnterPrivateBrowsingMode(tabManager: TabManager) // has default impl
    func tabManagerDidExitPrivateBrowsingMode(tabManager: TabManager) // has default impl
}

extension TabManagerDelegate { // add default implementation for 'optional' funcs
    func tabManagerDidEnterPrivateBrowsingMode(tabManager: TabManager) {}
    func tabManagerDidExitPrivateBrowsingMode(tabManager: TabManager) {}
}

protocol TabManagerStateDelegate: class {
    func tabManagerWillStoreTabs(tabs: [Browser])
}

// We can't use a WeakList here because this is a protocol.
class WeakTabManagerDelegate {
    weak var value : TabManagerDelegate?

    init (value: TabManagerDelegate) {
        self.value = value
    }

    func get() -> TabManagerDelegate? {
        return value
    }
}

// TabManager must extend NSObjectProtocol in order to implement WKNavigationDelegate
class TabManager : NSObject {
    private var delegates = [WeakTabManagerDelegate]()
    weak var stateDelegate: TabManagerStateDelegate?

    func addDelegate(delegate: TabManagerDelegate) {
        assert(NSThread.isMainThread())
        delegates.append(WeakTabManagerDelegate(value: delegate))
    }

    func removeDelegate(delegate: TabManagerDelegate) {
        assert(NSThread.isMainThread())
        for i in 0 ..< delegates.count {
            let del = delegates[i]
            if delegate === del.get() {
                delegates.removeAtIndex(i)
                return
            }
        }
    }

    private(set) var tabs = [Browser]()
    private var _selectedIndex = -1
    private let defaultNewTabRequest: NSURLRequest
    private let navDelegate: TabManagerNavDelegate
    private(set) var isRestoring = false

    // A WKWebViewConfiguration used for normal tabs
    lazy private var configuration: WKWebViewConfiguration = {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = WKProcessPool()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = !(self.prefs.boolForKey("blockPopups") ?? true)
        return configuration
    }()

    // A WKWebViewConfiguration used for private mode tabs
    @available(iOS 9, *)
    lazy private var privateConfiguration: WKWebViewConfiguration = {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = WKProcessPool()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = !(self.prefs.boolForKey("blockPopups") ?? true)
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore()
        return configuration
    }()

    private let imageStore: DiskImageStore?

    private let prefs: Prefs
    var selectedIndex: Int { return _selectedIndex }

    var normalTabs: [Browser] {
        assert(NSThread.isMainThread())

        return tabs.filter { !$0.isPrivate }
    }

    var privateTabs: [Browser] {
        assert(NSThread.isMainThread())

        if #available(iOS 9, *) {
            return tabs.filter { $0.isPrivate }
        } else {
            return []
        }
    }

    init(defaultNewTabRequest: NSURLRequest, prefs: Prefs, imageStore: DiskImageStore?) {
        assert(NSThread.isMainThread())

        self.prefs = prefs
        self.defaultNewTabRequest = defaultNewTabRequest
        self.navDelegate = TabManagerNavDelegate()
        self.imageStore = imageStore
        super.init()

        addNavigationDelegate(self)

        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(TabManager.prefsDidChange), name: NSUserDefaultsDidChangeNotification, object: nil)
    }

    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(self)
    }

    func addNavigationDelegate(delegate: WKNavigationDelegate) {
        assert(NSThread.isMainThread())

        self.navDelegate.insert(delegate)
    }

    var tabCount: Int {
        assert(NSThread.isMainThread())
        return tabs.count
    }

    var selectedTab: Browser? {
        assert(NSThread.isMainThread())
        if !(0..<tabCount ~= _selectedIndex) {
            return nil
        }

        return tabs[_selectedIndex]
    }

    subscript(index: Int) -> Browser? {
        assert(NSThread.isMainThread())

        if index >= tabs.count {
            return nil
        }
        return tabs[index]
    }

    func tabForWebView(webView: UIWebView) -> Browser? {
        assert(NSThread.isMainThread())

        for tab in tabs {
            if tab.webView === webView {
                return tab
            }
        }

        return nil
    }

    func getTabFor(url: NSURL) -> Browser? {
        assert(NSThread.isMainThread())

        for tab in tabs {
            if (tab.webView?.URL == url) {
                return tab
            }
        }
        return nil
    }

    func selectTab(tab: Browser?) {
        assert(NSThread.isMainThread())
        ensureMainThread() {
            if let tab = tab where self.selectedTab === tab && tab.webView != nil {
                return
            }

            let previous = self.selectedTab

            if let tab = tab {
                self._selectedIndex = self.tabs.indexOf(tab) ?? -1
            } else {
                self._selectedIndex = -1
            }

            self.preserveTabs()

            assert(tab === self.selectedTab, "Expected tab is selected")
            self.selectedTab?.createWebview()

            for delegate in self.delegates {
                delegate.get()?.tabManager(self, didSelectedTabChange: tab, previous: previous)
            }

            self.limitInMemoryTabs()

            let bvc = getApp().browserViewController as! BraveBrowserViewController
            bvc.updateBraveShieldButtonState(animated: false)
        }
    }

    func expireSnackbars() {
        assert(NSThread.isMainThread())

        for tab in tabs {
            tab.expireSnackbars()
        }
    }

    @available(iOS 9, *)
    func addTab(request: NSURLRequest! = nil, configuration: WKWebViewConfiguration! = nil, isPrivate: Bool) -> Browser? {
        return self.addTab(request, configuration: configuration, flushToDisk: true, zombie: false, isPrivate: isPrivate)
    }

    @available(iOS 9, *)
    func addTabAndSelect(request: NSURLRequest! = nil, configuration: WKWebViewConfiguration! = nil, isPrivate: Bool) -> Browser? {
        guard let tab = addTab(request, configuration: configuration, isPrivate: isPrivate) else { return nil }
        selectTab(tab)
        return tab
    }

    func addTabAndSelect(request: NSURLRequest! = nil, configuration: WKWebViewConfiguration! = nil) -> Browser? {
        guard let tab = addTab(request, configuration: configuration) else { return nil }
        selectTab(tab)
        return tab
    }

    // This method is duplicated to hide the flushToDisk option from consumers.
    func addTab(request: NSURLRequest! = nil, configuration: WKWebViewConfiguration! = nil) -> Browser? {
        return self.addTab(request, configuration: configuration, flushToDisk: true, zombie: false)
    }

    func addTabsForURLs(urls: [NSURL], zombie: Bool) {
        assert(NSThread.isMainThread())

        if urls.isEmpty {
            return
        }

        var tab: Browser!
        for url in urls {
            tab = self.addTab(NSURLRequest(URL: url), flushToDisk: false, zombie: zombie)
        }

        // Flush.
        storeChanges()

        // Select the most recent.
        self.selectTab(tab)

        // Notify that we bulk-loaded so we can adjust counts.
        for delegate in delegates {
            delegate.get()?.tabManagerDidAddTabs(self)
        }
    }

    func memoryWarning() {
        ensureMainThread() {
            for browser in self.tabs {
                if browser.webView == nil {
                    continue
                }

                if self.selectedTab != browser {
                    browser.deleteWebView()
                }
            }
        }
    }

    func limitInMemoryTabs() {
        let maxInMemTabs = BraveUX.MaxTabsInMemory
        if tabs.count < maxInMemTabs {
            return
        }

        var webviews = 0
        for browser in tabs {
            if browser.webView != nil {
                webviews += 1
            }
        }
        if webviews < maxInMemTabs {
            return
        }

        print("webviews \(webviews)")

        var oldestTime: Timestamp = NSDate.now()
        var oldestBrowser: Browser? = nil
        for browser in tabs {
            if browser.webView == nil {
                continue
            }
            if let t = browser.lastExecutedTime where t < oldestTime {
                oldestTime = t
                oldestBrowser = browser
            }
        }
        if let browser = oldestBrowser {
            if selectedTab != browser {
                browser.deleteWebView()
            } else {
                print("limitInMemoryTabs: tab to delete is selected!")
            }
        }
    }

    @available(iOS 9, *)
    private func addTab(request: NSURLRequest? = nil, configuration: WKWebViewConfiguration? = nil, flushToDisk: Bool, zombie: Bool, isPrivate: Bool) -> Browser {
        assert(NSThread.isMainThread())

        let tab = Browser(configuration: isPrivate ? privateConfiguration : self.configuration, isPrivate: isPrivate)
        ensureMainThread() {
            self.configureTab(tab, request: request, flushToDisk: flushToDisk, zombie: zombie)
        }
        return tab
    }

    private func addTab(request: NSURLRequest? = nil, configuration: WKWebViewConfiguration? = nil, flushToDisk: Bool, zombie: Bool) -> Browser {
        assert(NSThread.isMainThread())

        let tab = Browser(configuration: configuration ?? self.configuration)
        ensureMainThread() {
            self.configureTab(tab, request: request, flushToDisk: flushToDisk, zombie: zombie)
        }
        return tab
    }

    func configureTab(tab: Browser, request: NSURLRequest?, flushToDisk: Bool, zombie: Bool) {
        assert(NSThread.isMainThread())
        limitInMemoryTabs()

        tabs.append(tab)

        for delegate in delegates {
            delegate.get()?.tabManager(self, didAddTab: tab)
        }

        tab.createWebview()

        for delegate in delegates {
            delegate.get()?.tabManager(self, didCreateWebView: tab)
        }

        tab.navigationDelegate = self.navDelegate
        tab.loadRequest(request ?? defaultNewTabRequest)

        if flushToDisk {
            storeChanges()
        }
    }

    // This method is duplicated to hide the flushToDisk option from consumers.
    func removeTab(tab: Browser, createTabIfNoneLeft: Bool) {
        self.removeTab(tab, flushToDisk: true, notify: true, createTabIfNoneLeft: createTabIfNoneLeft)
        hideNetworkActivitySpinner()
    }

    /// - Parameter notify: if set to true, will call the delegate after the tab
    ///   is removed.
    private func removeTab(tab: Browser, flushToDisk: Bool, notify: Bool, createTabIfNoneLeft: Bool) {
        assert(NSThread.isMainThread())
        if !NSThread.isMainThread() {
            return
        }

        let tabToKeepSelected = selectedTab != tab ? selectedTab : nil

        if selectedTab === tab {
            let tabList: [Browser] = PrivateBrowsing.singleton.isOn ? privateTabs : tabs
            let currIndex = tabList.indexOf(tab)
            if let currIndex = currIndex where tabList.count > 1 {
                let newIndex = currIndex > 0 ? currIndex - 1 : tabList.count - 1
                assert(newIndex < tabList.count)
                selectTab(tabList[newIndex])
            } else {
                selectTab(nil)
            }
        }

        let prevCount = tabCount
        for i in 0..<tabCount {
            if tabs[i] === tab {
                tabs.removeAtIndex(i)
                break
            }
        }
        assert(tabCount == prevCount - 1, "Tab removed")

        if let t = tabToKeepSelected {
            selectTab(t)
        }

        // There's still some time between this and the webView being destroyed.
        // We don't want to pick up any stray events.
        tab.webView?.navigationDelegate = nil
        if notify {
            for delegate in delegates {
                delegate.get()?.tabManager(self, didRemoveTab: tab)
            }
        }

        // Make sure we never reach 0 normal tabs
        if !tab.isPrivate && normalTabs.count == 0 && createTabIfNoneLeft {
            let tab = addTab()
            selectTab(tab)
        }

        if flushToDisk {
        	storeChanges()
        }
    }

    /// Removes all private tabs from the manager.
    /// - Parameter notify: if set to true, the delegate is called when a tab is
    ///   removed.
    func removeAllPrivateTabsAndNotify(notify: Bool) {
        for tab in tabs {
            tab.deleteWebView()
        }
        _selectedIndex = -1
        privateTabs.forEach{
            removeTab($0, flushToDisk: true, notify: notify, createTabIfNoneLeft: false)
        }
    }

    func removeAll() {
        let tabs = self.tabs

        for tab in tabs {
            self.removeTab(tab, flushToDisk: false, notify: true, createTabIfNoneLeft: false)
        }
        storeChanges()
    }

    func getIndex(tab: Browser) -> Int? {
       assert(NSThread.isMainThread())

        for i in 0..<tabCount {
            if tabs[i] === tab {
                return i
            }
        }

        assertionFailure("Tab not in tabs list")
        return nil
    }

    func getTabForURL(url: NSURL) -> Browser? {
        assert(NSThread.isMainThread())

        return tabs.filter { $0.webView?.URL == url } .first
    }

    func storeChanges() {
        stateDelegate?.tabManagerWillStoreTabs(normalTabs)

        // Also save (full) tab state to disk.
        preserveTabs()
    }

    func prefsDidChange() {
#if !BRAVE
        dispatch_async(dispatch_get_main_queue()) {
            let allowPopups = !(self.prefs.boolForKey("blockPopups") ?? true)
            // Each tab may have its own configuration, so we should tell each of them in turn.
            for tab in self.tabs {
                tab.webView?.configuration.preferences.javaScriptCanOpenWindowsAutomatically = allowPopups
            }
            // The default tab configurations also need to change.
            self.configuration.preferences.javaScriptCanOpenWindowsAutomatically = allowPopups
            if #available(iOS 9, *) {
                self.privateConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = allowPopups
            }
        }
#endif
    }

    func resetProcessPool() {
        assert(NSThread.isMainThread())

        configuration.processPool = WKProcessPool()
    }
}

extension TabManager {

    class SavedTab: NSObject, NSCoding {
        let isSelected: Bool
        let title: String?
        let isPrivate: Bool
        var sessionData: SessionData?
        var screenshotUUID: NSUUID?

        var jsonDictionary: [String: AnyObject] {
            let title: String = self.title ?? "null"
            let uuid: String = String(self.screenshotUUID ?? "null")

            var json: [String: AnyObject] = [
                "title": title,
                "isPrivate": String(self.isPrivate),
                "isSelected": String(self.isSelected),
                "screenshotUUID": uuid
            ]

            if let sessionDataInfo = self.sessionData?.jsonDictionary {
                json["sessionData"] = sessionDataInfo
            }

            return json
        }

        init?(browser: Browser, isSelected: Bool) {
            assert(NSThread.isMainThread())

            self.screenshotUUID = browser.screenshotUUID
            self.isSelected = isSelected
            self.title = browser.displayTitle
            self.isPrivate = browser.isPrivate
            super.init()

            if browser.sessionData == nil {
                let currentItem: LegacyBackForwardListItem! = browser.webView?.backForwardList.currentItem

                // Freshly created web views won't have any history entries at all.
                // If we have no history, abort.
                if currentItem == nil {
                    return nil
                }

                let backList = browser.webView?.backForwardList.backList ?? []
                let forwardList = browser.webView?.backForwardList.forwardList ?? []
                let urls = (backList + [currentItem] + forwardList).map { $0.URL }
                let currentPage = -forwardList.count
                self.sessionData = SessionData(currentPage: currentPage, currentTitle: browser.title, urls: urls, lastUsedTime: browser.lastExecutedTime ?? NSDate.now())
            } else {
                self.sessionData = browser.sessionData
            }
        }

        required init?(coder: NSCoder) {
            self.sessionData = coder.decodeObjectForKey("sessionData") as? SessionData
            self.screenshotUUID = coder.decodeObjectForKey("screenshotUUID") as? NSUUID
            self.isSelected = coder.decodeBoolForKey("isSelected")
            self.title = coder.decodeObjectForKey("title") as? String
            self.isPrivate = coder.decodeBoolForKey("isPrivate")
        }

        func encodeWithCoder(coder: NSCoder) {
#if BRAVE
            if (isPrivate) { // seems more private to not write private tab info to disk
                return
            }
#endif
            coder.encodeObject(sessionData, forKey: "sessionData")
            coder.encodeObject(screenshotUUID, forKey: "screenshotUUID")
            coder.encodeBool(isSelected, forKey: "isSelected")
            coder.encodeObject(title, forKey: "title")
#if !BRAVE
            coder.encodeBool(isPrivate, forKey: "isPrivate")
#endif
        }
    }

    static private func tabsStateArchivePath() -> String {
        let documentsPath = NSSearchPathForDirectoriesInDomains(.DocumentDirectory, .UserDomainMask, true)[0]
        return NSURL(fileURLWithPath: documentsPath).URLByAppendingPathComponent("tabsState.archive").path!
    }

    static func tabArchiveData() -> NSData? {
        let tabStateArchivePath = tabsStateArchivePath()
        if NSFileManager.defaultManager().fileExistsAtPath(tabStateArchivePath) {
            return NSData(contentsOfFile: tabStateArchivePath)
        } else {
            return nil
        }
    }

    static func tabsToRestore() -> [SavedTab]? {
        if let tabData = tabArchiveData() {
            let unarchiver = NSKeyedUnarchiver(forReadingWithData: tabData)
            return unarchiver.decodeObjectForKey("tabs") as? [SavedTab]
        } else {
            return nil
        }
    }

    private func preserveTabsInternal() {
        assert(NSThread.isMainThread())

        guard !isRestoring else { return }

        let path = TabManager.tabsStateArchivePath()
        var savedTabs = [SavedTab]()
        var savedUUIDs = Set<String>()
        for (tabIndex, tab) in tabs.enumerate() {
            if tab.isPrivate {
                continue
            }
            if let savedTab = SavedTab(browser: tab, isSelected: tabIndex == selectedIndex) {
                savedTabs.append(savedTab)

                if let screenshot = tab.screenshot,
                   let screenshotUUID = tab.screenshotUUID
                {
                    savedUUIDs.insert(screenshotUUID.UUIDString)
                    imageStore?.put(screenshotUUID.UUIDString, image: screenshot)
                }
            }
        }

        // Clean up any screenshots that are no longer associated with a tab.
        imageStore?.clearExcluding(savedUUIDs)

        let tabStateData = NSMutableData()
        let archiver = NSKeyedArchiver(forWritingWithMutableData: tabStateData)
        archiver.encodeObject(savedTabs, forKey: "tabs")
        archiver.finishEncoding()
        tabStateData.writeToFile(path, atomically: true)
    }

    func preserveTabs() {
        // This is wrapped in an Objective-C @try/@catch handler because NSKeyedArchiver may throw exceptions which Swift cannot handle
        _ = Try(withTry: { () -> Void in
            self.preserveTabsInternal()
            }) { (exception) -> Void in
            print("Failed to preserve tabs: \(exception)")
        }
    }

    private func restoreTabsInternal() {
        log.debug("Restoring tabs.")
        guard let savedTabs = TabManager.tabsToRestore() else {
            log.debug("Nothing to restore.")
            return
        }

        var tabToSelect: Browser?
        for (_, savedTab) in savedTabs.enumerate() {
            if savedTab.isPrivate {
                continue
            }

            let tab = self.addTab(flushToDisk: false, zombie: true)
            tab.lastExecutedTime = savedTab.sessionData?.lastUsedTime

            // Set the UUID for the tab, asynchronously fetch the UIImage, then store
            // the screenshot in the tab as long as long as a newer one hasn't been taken.
            if let screenshotUUID = savedTab.screenshotUUID,
               let imageStore = self.imageStore {
                tab.screenshotUUID = screenshotUUID
                imageStore.get(screenshotUUID.UUIDString) >>== { screenshot in
                    if tab.screenshotUUID == screenshotUUID {
                        tab.setScreenshot(screenshot, revUUID: false)
                    }
                }
            }

            if savedTab.isSelected {
                tabToSelect = tab
            }

            tab.sessionData = savedTab.sessionData
            tab.lastTitle = savedTab.title

            if let w = tab.webView {
                tab.restore(w)
            }
        }

        if tabToSelect == nil {
            tabToSelect = tabs.first
        }

        log.debug("Done adding tabs.")

        // Only tell our delegates that we restored tabs if we actually restored a tab(s)
        if savedTabs.count > 0 {
            log.debug("Notifying delegates.")
            for delegate in delegates {
                delegate.get()?.tabManagerDidRestoreTabs(self)
            }
        }

        if let tab = tabToSelect {
            log.debug("Selecting a tab.")
            selectTab(tab)
        }

        log.debug("Done.")
    }

    func restoreTabs() {
        isRestoring = true

        if tabCount == 0 && !AppConstants.IsRunningTest && !DebugSettingsBundleOptions.skipSessionRestore {
            // This is wrapped in an Objective-C @try/@catch handler because NSKeyedUnarchiver may throw exceptions which Swift cannot handle
            let _ = Try(
                withTry: { () -> Void in
                    self.restoreTabsInternal()
                },
                catch: { exception in
                    print("Failed to restore tabs: \(exception)")
                }
            )
        }

        if tabCount == 0 {
            let tab = addTab()
            selectTab(tab)
        }

        isRestoring = false
    }

    // Only call from PB class
    func enterPrivateBrowsingMode(_: PrivateBrowsing) {
        tabs.forEach{ $0.deleteWebView() }
        delegates.forEach {
            $0.get()?.tabManagerDidEnterPrivateBrowsingMode(self)
        }
    }

    func exitPrivateBrowsingMode(_: PrivateBrowsing) {
        delegates.forEach {
            $0.get()?.tabManagerDidExitPrivateBrowsingMode(self)
        }

        if getApp().tabManager.tabs.count < 1 {
            getApp().tabManager.addTab()
        }
        getApp().tabManager.selectTab(getApp().tabManager.tabs.first)
    }
}

extension TabManager : WKNavigationDelegate {
    func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        UIApplication.sharedApplication().networkActivityIndicatorVisible = true

#if BRAVE
        var hider: (Void -> Void)!
        hider = {
            delay(1) {
                self.hideNetworkActivitySpinner()
                if UIApplication.sharedApplication().networkActivityIndicatorVisible {
                    hider()
                }
            }
        }
        hider()
#endif
    }

    func webView(webView: WKWebView, didFinishNavigation _: WKNavigation!) {
        hideNetworkActivitySpinner()

        guard let container = webView as? ContainerWebView else { return }
        guard let legacyWebView = container.legacyWebView else { return }

        // only store changes if this is not an error page
        // as we current handle tab restore as error page redirects then this ensures that we don't
        // call storeChanges unnecessarily on startup
        if let url = legacyWebView.URL {
            if !ErrorPageHelper.isErrorPageURL(url) {
                storeChanges()
            }
        }
    }

    func webView(_: WKWebView, didFailNavigation _: WKNavigation!, withError _: NSError) {
        hideNetworkActivitySpinner()
    }

    func hideNetworkActivitySpinner() {
        for tab in tabs {
            if let tabWebView = tab.webView {
                // If we find one tab loading, we don't hide the spinner
                if tabWebView.loading {
                    return
                }
            }
        }
        UIApplication.sharedApplication().networkActivityIndicatorVisible = false
    }

    /// Called when the WKWebView's content process has gone away. If this happens for the currently selected tab
    /// then we immediately reload it.

    func webViewWebContentProcessDidTerminate(webView: WKWebView) {
        if let browser = selectedTab where browser.webView == webView {
            webView.reload()
        }
    }
}

extension TabManager {
    class func tabRestorationDebugInfo() -> String {
        assert(NSThread.isMainThread())

        let tabs = TabManager.tabsToRestore()?.map { $0.jsonDictionary } ?? []
        do {
            let jsonData = try NSJSONSerialization.dataWithJSONObject(tabs, options: [.PrettyPrinted])
            return String(data: jsonData, encoding: NSUTF8StringEncoding) ?? ""
        } catch _ {
            return ""
        }
    }
}

// WKNavigationDelegates must implement NSObjectProtocol
class TabManagerNavDelegate : NSObject, WKNavigationDelegate {
    private var delegates = WeakList<WKNavigationDelegate>()

    func insert(delegate: WKNavigationDelegate) {
        delegates.insert(delegate)
    }

    func webView(webView: WKWebView, didCommitNavigation navigation: WKNavigation!) {
        for delegate in delegates {
            delegate.webView?(webView, didCommitNavigation: navigation)
        }
    }

    func webView(webView: WKWebView, didFailNavigation navigation: WKNavigation!, withError error: NSError) {
        for delegate in delegates {
            delegate.webView?(webView, didFailNavigation: navigation, withError: error)
        }
    }

    func webView(webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: NSError) {
            for delegate in delegates {
                delegate.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)
            }
    }

    func webView(webView: WKWebView, didFinishNavigation navigation: WKNavigation!) {
        for delegate in delegates {
            delegate.webView?(webView, didFinishNavigation: navigation)
        }
    }

    func webView(webView: WKWebView, didReceiveAuthenticationChallenge challenge: NSURLAuthenticationChallenge,
        completionHandler: (NSURLSessionAuthChallengeDisposition,
        NSURLCredential?) -> Void) {
            let authenticatingDelegates = delegates.filter {
                $0.respondsToSelector(#selector(WKNavigationDelegate.webView(_:didReceiveAuthenticationChallenge:completionHandler:)))
            }

            guard let firstAuthenticatingDelegate = authenticatingDelegates.first else {
                return completionHandler(NSURLSessionAuthChallengeDisposition.PerformDefaultHandling, nil)
            }

            firstAuthenticatingDelegate.webView?(webView, didReceiveAuthenticationChallenge: challenge) { (disposition, credential) in
                completionHandler(disposition, credential)
            }
    }

    func webView(webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        for delegate in delegates {
            delegate.webView?(webView, didReceiveServerRedirectForProvisionalNavigation: navigation)
        }
    }

    func webView(webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        for delegate in delegates {
            delegate.webView?(webView, didStartProvisionalNavigation: navigation)
        }
    }

    func webView(webView: WKWebView, decidePolicyForNavigationAction navigationAction: WKNavigationAction,
        decisionHandler: (WKNavigationActionPolicy) -> Void) {
            var res = WKNavigationActionPolicy.Allow
            for delegate in delegates {
                delegate.webView?(webView, decidePolicyForNavigationAction: navigationAction, decisionHandler: { policy in
                    if policy == .Cancel {
                        res = policy
                    }
                })
            }

            decisionHandler(res)
    }

    func webView(webView: WKWebView, decidePolicyForNavigationResponse navigationResponse: WKNavigationResponse,
        decisionHandler: (WKNavigationResponsePolicy) -> Void) {
            var res = WKNavigationResponsePolicy.Allow
            for delegate in delegates {
                delegate.webView?(webView, decidePolicyForNavigationResponse: navigationResponse, decisionHandler: { policy in
                    if policy == .Cancel {
                        res = policy
                    }
                })
            }

            decisionHandler(res)
    }
}
