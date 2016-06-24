/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Shared
private let log = Logger.browserLogger

/// List of schemes that are allowed to open a popup window
private let SchemesAllowedToOpenPopups = ["http", "https", "javascript", "data"]

extension BrowserViewController: WKUIDelegate {

    #if !BRAVE
    /// THIS IS FOR _blank TARGETS
    func webView(webView: WKWebView, createWebViewWithConfiguration configuration: WKWebViewConfiguration, forNavigationAction navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let currentTab = tabManager.selectedTab else { return nil }

        screenshotHelper.takeScreenshot(currentTab)

        // If the page uses window.open() or target="_blank", open the page in a new tab.
        // TODO: This doesn't work for window.open() without user action (bug 1124942).
        let newTab: Browser
        if #available(iOS 9, *) {
            newTab = tabManager.addTab(navigationAction.request, configuration: configuration, isPrivate: currentTab.isPrivate)
        } else {
            newTab = tabManager.addTab(navigationAction.request, configuration: configuration)
        }
        tabManager.selectTab(newTab)

        // If the page we just opened has a bad scheme, we return nil here so that JavaScript does not
        // get a reference to it which it can return from window.open() - this will end up as a
        // CFErrorHTTPBadURL being presented.
        guard let scheme = navigationAction.request.URL?.scheme.lowercaseString where SchemesAllowedToOpenPopups.contains(scheme) else {
            return nil
        }

        return newTab.webView
    }
    #endif
    #if !BRAVE
    private func canDisplayJSAlertForWebView(webView: WKWebView) -> Bool {
        // Only display a JS Alert if we are selected and there isn't anything being shown
        return (tabManager.selectedTab?.webView == webView ?? false) && (self.presentedViewController == nil)
    }

    func webView(webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: () -> Void) {
        var messageAlert = MessageAlert(message: message, frame: frame, completionHandler: completionHandler)
        if canDisplayJSAlertForWebView(webView) {
            presentViewController(messageAlert.alertController(), animated: true, completion: nil)
        } else if let promptingTab = tabManager[webView] {
            promptingTab.queueJavascriptAlertPrompt(messageAlert)
        } else {
            // This should never happen since an alert needs to come from a web view but just in case call the handler
            // since not calling it will result in a runtime exception.
            completionHandler()
        }
    }
    #endif
    #if !BRAVE
    func webView(webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: (Bool) -> Void) {
        var confirmAlert = ConfirmPanelAlert(message: message, frame: frame, completionHandler: completionHandler)
        if canDisplayJSAlertForWebView(webView) {
            presentViewController(confirmAlert.alertController(), animated: true, completion: nil)
        } else if let promptingTab = tabManager[webView] {
            promptingTab.queueJavascriptAlertPrompt(confirmAlert)
        } else {
            completionHandler(false)
        }
    }
    #endif
    #if !BRAVE
    func webView(webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: (String?) -> Void) {
        var textInputAlert = TextInputAlert(message: prompt, frame: frame, completionHandler: completionHandler, defaultText: defaultText)
        if canDisplayJSAlertForWebView(webView) {
            presentViewController(textInputAlert.alertController(), animated: true, completion: nil)
        } else if let promptingTab = tabManager[webView] {
            promptingTab.queueJavascriptAlertPrompt(textInputAlert)
        } else {
            completionHandler(nil)
        }
    }
    #endif

    /// Invoked when an error occurs while starting to load data for the main frame.
    func webView(webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: NSError) {
        // Ignore the "Frame load interrupted" error that is triggered when we cancel a request
        // to open an external application and hand it over to UIApplication.openURL(). The result
        // will be that we switch to the external app, for example the app store, while keeping the
        // original web page in the tab instead of replacing it with an error page.
        if error.domain == "WebKitErrorDomain" && error.code == 102 {
            return
        }

        if checkIfWebContentProcessHasCrashed(webView, error: error) {
            return
        }

        if error.code == Int(CFNetworkErrors.CFURLErrorCancelled.rawValue) {
            guard let container = webView as? ContainerWebView else { return }
            guard let legacyWebView = container.legacyWebView else { return }
            if let browser = tabManager.tabForWebView(legacyWebView) where browser === tabManager.selectedTab {
                urlBar.currentURL = browser.displayURL
            }
            return
        }

        if let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? NSURL {
            ErrorPageHelper().showPage(error, forUrl: url, inWebView: webView)

            // If the local web server isn't working for some reason (Firefox cellular data is
            // disabled in settings, for example), we'll fail to load the session restore URL.
            // We rely on loading that page to get the restore callback to reset the restoring
            // flag, so if we fail to load that page, reset it here.
            if AboutUtils.getAboutComponent(url) == "sessionrestore" {
                tabManager.tabs.filter { $0.webView == webView }.first?.restoring = false
            }
        }
    }

    private func checkIfWebContentProcessHasCrashed(webView: WKWebView, error: NSError) -> Bool {
        if error.code == WKErrorCode.WebContentProcessTerminated.rawValue && error.domain == "WebKitErrorDomain" {
            log.debug("WebContent process has crashed. Trying to reloadFromOrigin to restart it.")
            webView.reloadFromOrigin()
            return true
        }

        return false
    }

    func webView(webView: WKWebView, decidePolicyForNavigationResponse navigationResponse: WKNavigationResponse, decisionHandler: (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.canShowMIMEType {
            decisionHandler(WKNavigationResponsePolicy.Allow)
            return
        }

        let error = NSError(domain: ErrorPageHelper.MozDomain, code: Int(ErrorPageHelper.MozErrorDownloadsNotEnabled), userInfo: [NSLocalizedDescriptionKey: "Downloads aren't supported in Brave yet (but we're working on it)."])
        ErrorPageHelper().showPage(error, forUrl: navigationResponse.response.URL!, inWebView: webView)
        decisionHandler(WKNavigationResponsePolicy.Allow)
    }
}
