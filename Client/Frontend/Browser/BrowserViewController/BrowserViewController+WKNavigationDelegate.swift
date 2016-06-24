/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Shared
private let log = Logger.browserLogger

extension BrowserViewController: WKNavigationDelegate {
    func webView(webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        #if !BRAVE
            if tabManager.selectedTab?.webView !== webView {
                return
            }
        #else
            // remove the open in overlay view if it is present
            removeOpenInView()
        #endif
        updateFindInPageVisibility(visible: false)

        // If we are going to navigate to a new page, hide the reader mode button. Unless we
        // are going to a about:reader page. Then we keep it on screen: it will change status
        // (orange color) as soon as the page has loaded.
        if let url = webView.URL {
            if !ReaderModeUtils.isReaderModeURL(url) {
                urlBar.updateReaderModeState(ReaderModeState.Unavailable)
                hideReaderModeBar(animated: false)
            }

        }
    }

    // Recognize an Apple Maps URL. This will trigger the native app. But only if a search query is present. Otherwise
    // it could just be a visit to a regular page on maps.apple.com.
    private func isAppleMapsURL(url: NSURL) -> Bool {
        if url.scheme == "http" || url.scheme == "https" {
            if url.host == "maps.apple.com" && url.query != nil {
                return true
            }
        }
        return false
    }

    // Recognize a iTunes Store URL. These all trigger the native apps. Note that appstore.com and phobos.apple.com
    // used to be in this list. I have removed them because they now redirect to itunes.apple.com. If we special case
    // them then iOS will actually first open Safari, which then redirects to the app store. This works but it will
    // leave a 'Back to Safari' button in the status bar, which we do not want.
    private func isStoreURL(url: NSURL) -> Bool {
        if url.scheme == "http" || url.scheme == "https" {
            if url.host == "itunes.apple.com" {
                return true
            }
        }
        return false
    }

    // This is the place where we decide what to do with a new navigation action. There are a number of special schemes
    // and http(s) urls that need to be handled in a different way. All the logic for that is inside this delegate
    // method.

    func webView(webView: WKWebView, decidePolicyForNavigationAction navigationAction: WKNavigationAction, decisionHandler: (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.URL else {
            decisionHandler(WKNavigationActionPolicy.Cancel)
            return
        }

        // Fixes 1261457 - Rich text editor fails because requests to about:blank are blocked
        if url.scheme == "about" && url.resourceSpecifier == "blank" {
            decisionHandler(WKNavigationActionPolicy.Allow)
            return
        }

        // First special case are some schemes that are about Calling. We prompt the user to confirm this action. This
        // gives us the exact same behaviour as Safari. The only thing we do not do is nicely format the phone number,
        // instead we present it as it was put in the URL.

        if url.scheme == "tel" || url.scheme == "facetime" || url.scheme == "facetime-audio" {
            if let phoneNumber = url.resourceSpecifier.stringByRemovingPercentEncoding {
                let alert = UIAlertController(title: phoneNumber, message: nil, preferredStyle: UIAlertControllerStyle.Alert)
                alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment:"Alert Cancel Button"), style: UIAlertActionStyle.Cancel, handler: nil))
                alert.addAction(UIAlertAction(title: NSLocalizedString("Call", comment:"Alert Call Button"), style: UIAlertActionStyle.Default, handler: { (action: UIAlertAction!) in
                    UIApplication.sharedApplication().openURL(url)
                }))
                presentViewController(alert, animated: true, completion: nil)
            }
            decisionHandler(WKNavigationActionPolicy.Cancel)
            return
        }

        // Second special case are a set of URLs that look like regular http links, but should be handed over to iOS
        // instead of being loaded in the webview. Note that there is no point in calling canOpenURL() here, because
        // iOS will always say yes. TODO Is this the same as isWhitelisted?

        if isAppleMapsURL(url) {
            UIApplication.sharedApplication().openURL(url)
            decisionHandler(WKNavigationActionPolicy.Cancel)
            return
        }


        if let tab = tabManager.selectedTab where isStoreURL(url) {
            let tag = 8675309
            let hasOneAlready = tab.bars.contains({ $0.tag == tag })
            if hasOneAlready ?? true {
                return
            }

            let siteName = tab.displayURL?.hostWithGenericSubdomainPrefixRemoved() ?? "this site"
            let snackBar = TimerSnackBar(attrText: NSAttributedString(string: NSLocalizedString("  Allow \(siteName) to open iTunes?", comment: "Ask user if site can open iTunes store URL")),
                                         img: nil,
                                         buttons: [
                                            SnackButton(title: "Open", accessibilityIdentifier: "", callback: { bar in
                                                self.tabManager.selectedTab?.removeSnackbar(bar)
                                                UIApplication.sharedApplication().openURL(url)
                                            }),
                                            SnackButton(title: "Not now", accessibilityIdentifier: "", callback: { bar in
                                                self.tabManager.selectedTab?.removeSnackbar(bar)
                                            })
                ])
            snackBar.tag = tag
            tabManager.selectedTab?.addSnackbar(snackBar)
            return
        }


        // This is the normal case, opening a http or https url, which we handle by loading them in this WKWebView. We
        // always allow this.
        if url.scheme == "http" || url.scheme == "https" {
            #if !BRAVE
                if navigationAction.navigationType == .LinkActivated {
                    resetSpoofedUserAgentIfRequired(webView, newURL: url)
                } else if navigationAction.navigationType == .BackForward {
                    restoreSpoofedUserAgentIfRequired(webView, newRequest: navigationAction.request)
                }
            #endif
            decisionHandler(WKNavigationActionPolicy.Allow)
            return
        }

        // Default to calling openURL(). What this does depends on the iOS version. On iOS 8, it will just work without
        // prompting. On iOS9, depending on the scheme, iOS will prompt: "Firefox" wants to open "Twitter". It will ask
        // every time. There is no way around this prompt. (TODO Confirm this is true by adding them to the Info.plist)

        UIApplication.sharedApplication().openURL(url)
        decisionHandler(WKNavigationActionPolicy.Cancel)
    }

    //    func webView(webView: WKWebView, didReceiveAuthenticationChallenge challenge: NSURLAuthenticationChallenge, completionHandler: (NSURLSessionAuthChallengeDisposition, NSURLCredential?) -> Void) {
    //
    //        // If this is a certificate challenge, see if the certificate has previously been
    //        // accepted by the user.
    //        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
    //           let trust = challenge.protectionSpace.serverTrust,
    //           let cert = SecTrustGetCertificateAtIndex(trust, 0) where profile.certStore.containsCertificate(cert) {
    //            completionHandler(NSURLSessionAuthChallengeDisposition.UseCredential, NSURLCredential(forTrust: trust))
    //            return
    //        }
    //
    //        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic ||
    //              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPDigest ||
    //              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodNTLM,
    //              let tab = tabManager.tabForWebView(webView) else {
    //            completionHandler(NSURLSessionAuthChallengeDisposition.PerformDefaultHandling, nil)
    //            return
    //        }
    //
    //        // The challenge may come from a background tab, so ensure it's the one visible.
    //        tabManager.selectTab(tab)
    //
    //        let loginsHelper = tab.getHelper(name: LoginsHelper.name()) as? LoginsHelper
    //        Authenticator.handleAuthRequest(self, challenge: challenge, loginsHelper: loginsHelper).uponQueue(dispatch_get_main_queue()) { res in
    //            if let credentials = res.successValue {
    //                completionHandler(.UseCredential, credentials.credentials)
    //            } else {
    //                completionHandler(NSURLSessionAuthChallengeDisposition.RejectProtectionSpace, nil)
    //            }
    //        }
    //    }

    func webView(_webView: WKWebView, didFinishNavigation navigation: WKNavigation!) {
        guard let container = _webView as? ContainerWebView else { return }
        guard let webView = container.legacyWebView else { return }
        guard let tab = tabManager.tabForWebView(webView) else { return }

        tabManager.expireSnackbars()

        tab.lastExecutedTime = NSDate.now()

        if let url = webView.URL where !ErrorPageHelper.isErrorPageURL(url) && !AboutUtils.isAboutHomeURL(url) {
            if navigation == nil {
                log.warning("Implicitly unwrapped optional navigation was nil.")
            }

            updateProfileForLocationChange(tab, navigation: navigation)

            // Fire the readability check. This is here and not in the pageShow event handler in ReaderMode.js anymore
            // because that event wil not always fire due to unreliable page caching. This will either let us know that
            // the currently loaded page can be turned into reading mode or if the page already is in reading mode. We
            // ignore the result because we are being called back asynchronous when the readermode status changes.
            #if !BRAVE
                webView.evaluateJavaScript("_firefox_ReaderMode.checkReadability()", completionHandler: nil)
            #endif
        }

        if tab === tabManager.selectedTab {
            UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil)
            // must be followed by LayoutChanged, as ScreenChanged will make VoiceOver
            // cursor land on the correct initial element, but if not followed by LayoutChanged,
            // VoiceOver will sometimes be stuck on the element, not allowing user to move
            // forward/backward. Strange, but LayoutChanged fixes that.
            UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil)
        }

        #if BRAVE
            screenshotHelper.takeDelayedScreenshot(tab)
        #endif
        addOpenInViewIfNeccessary(webView.URL)

        // Remember whether or not a desktop site was requested
        if #available(iOS 9.0, *) {
            tab.desktopSite = webView.customUserAgent?.isEmpty == false
        }
    }

    func addOpenInViewIfNeccessary(url: NSURL?) {
        guard let url = url, let openInHelper = OpenInHelperFactory.helperForURL(url) else { return }
        let view = openInHelper.openInView
        webViewContainerToolbar.addSubview(view)
        webViewContainerToolbar.snp_updateConstraints { make in
            make.height.equalTo(OpenInViewUX.ViewHeight)
        }
        view.snp_makeConstraints { make in
            make.edges.equalTo(webViewContainerToolbar)
        }

        self.openInHelper = openInHelper
    }

    func removeOpenInView() {
        guard let _ = self.openInHelper else { return }
        webViewContainerToolbar.subviews.forEach { $0.removeFromSuperview() }

        webViewContainerToolbar.snp_updateConstraints { make in
            make.height.equalTo(0)
        }

        self.openInHelper = nil
    }

    private func updateProfileForLocationChange(tab: Browser, navigation: WKNavigation?) {
        var info = [String : AnyObject]()
        info["url"] = tab.displayURL
        info["title"] = tab.title
        if let visitType = self.getVisitTypeForTab(tab, navigation: navigation)?.rawValue {
            info["visitType"] = visitType
        }
        info["isPrivate"] = tab.isPrivate
        if !(tab.title?.isEmpty ?? true) {
            (profile as? BrowserProfile)?.onLocationChange(info)
        }
    }
}