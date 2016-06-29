/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Shared
private let log = Logger.browserLogger

private let KVOLoading = "loading"
private let KVOEstimatedProgress = "estimatedProgress"
private let KVOURL = "URL"
private let KVOCanGoBack = "canGoBack"
private let KVOCanGoForward = "canGoForward"
private let KVOContentSize = "contentSize"

protocol BrowserTabStateDelegate: class {
    func browserUrlChanged(browser: Browser)
    func browserProgressChanged(browser: Browser)
}

// We can't use a WeakList here because this is a protocol.
class WeakBrowserTabStateDelegate {
    weak var value : BrowserTabStateDelegate?

    init (value: BrowserTabStateDelegate) {
        self.value = value
    }

    func get() -> BrowserTabStateDelegate? {
        return value
    }
}

extension BrowserViewController: BrowserDelegate {

    override func observeValueForKeyPath(keyPath: String?, ofObject object: AnyObject?, change: [String: AnyObject]?, context: UnsafeMutablePointer<Void>) {
        ///let webView = object as! WKWebView
        if object !== tabManager.selectedTab?.webView {
            return
        }
        guard let path = keyPath else { assertionFailure("Unhandled KVO key: \(keyPath)"); return }
        switch path {
        case KVOEstimatedProgress:
            guard let progress = change?[NSKeyValueChangeNewKey] as? Float else { break }
            urlBar.updateProgressBar(progress)

            if let tab = tabManager.selectedTab {
                for delegate in delegates {
                    delegate.get()?.browserProgressChanged(tab)
                }
            }

        case KVOLoading:
            guard let loading = change?[NSKeyValueChangeNewKey] as? Bool else { break }
            toolbar?.updateReloadStatus(loading)
            urlBar.updateReloadStatus(loading)

        case KVOURL:
            if let tab = tabManager.selectedTab {
                if tab.webView?.URL == nil {
                    log.debug("URL is nil!")
                }

                if tab.webView === object && !tab.restoring {
                    updateUIForReaderHomeStateForTab(tab)
                }

                for delegate in delegates {
                    delegate.get()?.browserUrlChanged(tab)
                }
            }

        case KVOCanGoBack:
            guard let canGoBack = change?[NSKeyValueChangeNewKey] as? Bool else { break }
            navigationToolbar.updateBackStatus(canGoBack)
        case KVOCanGoForward:
            guard let canGoForward = change?[NSKeyValueChangeNewKey] as? Bool else { break }
            navigationToolbar.updateForwardStatus(canGoForward)
        default:
            assertionFailure("Unhandled KVO key: \(keyPath)")
        }
    }

    func browser(browser: Browser, didCreateWebView webView: BraveWebView) {
        // Observers that live as long as the tab.
        let observed = [KVOEstimatedProgress, KVOLoading, KVOCanGoBack, KVOCanGoForward, KVOURL]
        for key in observed {
            webView.addObserver(self, forKeyPath: key, options: .New, context: nil)
        }

        webView.scrollView.addObserver(self.scrollController, forKeyPath: KVOContentSize, options: .New, context: nil)

        webView.removeBvcObserversOnDeinit = {
            [unowned self, weak sc = self.scrollController] (wv) in
            for key in observed {
                wv.removeObserver(self, forKeyPath: key)
            }
            wv.scrollView.removeObserver(sc!, forKeyPath: KVOContentSize)
        }

        #if !BRAVE
            webView.UIDelegate = self /// these are for javascript alert panels
        #endif
        let readerMode = ReaderMode(browser: browser)
        readerMode.delegate = self
        browser.addHelper(readerMode)

        let favicons = FaviconManager(browser: browser, profile: profile)
        browser.addHelper(favicons)

        let logins = LoginsHelper(browser: browser, profile: profile)
        browser.addHelper(logins)

        #if !BRAVE
            let contextMenuHelper = ContextMenuHelper(browser: browser)
            contextMenuHelper.delegate = self
            browser.addHelper(contextMenuHelper, name: ContextMenuHelper.name())
        #endif

        let errorHelper = ErrorPageHelper()
        browser.addHelper(errorHelper)

        let windowCloseHelper = WindowCloseHelper(browser: browser)
        windowCloseHelper.delegate = self
        browser.addHelper(windowCloseHelper)

        let sessionRestoreHelper = SessionRestoreHelper(browser: browser)
        sessionRestoreHelper.delegate = self
        browser.addHelper(sessionRestoreHelper)

        let findInPageHelper = FindInPageHelper(browser: browser)
        findInPageHelper.delegate = self
        browser.addHelper(findInPageHelper)

        let printHelper = PrintHelper(browser: browser)
        browser.addHelper(printHelper)

        let openURL = {(url: NSURL) -> Void in
            self.switchToTabForURLOrOpen(url)
        }
        let spotlightHelper = SpotlightHelper(browser: browser, openURL: openURL)
        browser.addHelper(spotlightHelper)

        #if BRAVE
            let pageUnload = BravePageUnloadHelper(browser: browser)
            browser.addHelper(pageUnload)
        #endif
    }

    func browser(browser: Browser, willDeleteWebView webView: BraveWebView) {
        browser.cancelQueuedAlerts()

        #if !BRAVE // todo create a fake proxy for this. it is unused completely ATM
            webView.UIDelegate = nil
        #endif
        webView.scrollView.delegate = nil
        webView.removeFromSuperview()
    }

    private func findSnackbar(barToFind: SnackBar) -> Int? {
        let bars = snackBars.subviews
        for (index, bar) in bars.enumerate() {
            if bar === barToFind {
                return index
            }
        }
        return nil
    }

    func updateSnackBarConstraints() {
        snackBars.snp_remakeConstraints { make in
            make.bottom.equalTo(findInPageContainer.snp_top)

            let bars = self.snackBars.subviews
            if bars.count > 0 {
                let view = bars[bars.count-1]
                make.top.equalTo(view.snp_top)
            } else {
                make.height.equalTo(0)
            }

            if traitCollection.horizontalSizeClass != .Regular {
                make.leading.trailing.equalTo(self.footer)
                self.snackBars.layer.borderWidth = 0
            } else {
                make.centerX.equalTo(self.footer)
                make.width.equalTo(SnackBarUX.MaxWidth)
                self.snackBars.layer.borderColor = UIConstants.BorderColor.CGColor
                self.snackBars.layer.borderWidth = 1
            }
        }
    }

    // This removes the bar from its superview and updates constraints appropriately
    private func finishRemovingBar(bar: SnackBar) {
        // If there was a bar above this one, we need to remake its constraints.
        if let index = findSnackbar(bar) {
            // If the bar being removed isn't on the top of the list
            let bars = snackBars.subviews
            if index < bars.count-1 {
                // Move the bar above this one
                let nextbar = bars[index+1] as! SnackBar
                nextbar.snp_updateConstraints { make in
                    // If this wasn't the bottom bar, attach to the bar below it
                    if index > 0 {
                        let bar = bars[index-1] as! SnackBar
                        nextbar.bottom = make.bottom.equalTo(bar.snp_top).constraint
                    } else {
                        // Otherwise, we attach it to the bottom of the snackbars
                        nextbar.bottom = make.bottom.equalTo(self.snackBars.snp_bottom).constraint
                    }
                }
            }
        }

        // Really remove the bar
        bar.removeFromSuperview()
    }

    private func finishAddingBar(bar: SnackBar) {
        snackBars.addSubview(bar)
        bar.snp_remakeConstraints { make in
            // If there are already bars showing, add this on top of them
            let bars = self.snackBars.subviews

            // Add the bar on top of the stack
            // We're the new top bar in the stack, so make sure we ignore ourself
            if bars.count > 1 {
                let view = bars[bars.count - 2]
                bar.bottom = make.bottom.equalTo(view.snp_top).offset(0).constraint
            } else {
                bar.bottom = make.bottom.equalTo(self.snackBars.snp_bottom).offset(0).constraint
            }
            make.leading.trailing.equalTo(self.snackBars)
        }
    }

    func showBar(bar: SnackBar, animated: Bool) {
        finishAddingBar(bar)
        updateSnackBarConstraints()

        bar.hide()
        view.layoutIfNeeded()
        UIView.animateWithDuration(animated ? 0.25 : 0, animations: { () -> Void in
            bar.show()
            self.view.layoutIfNeeded()
        })
    }

    func removeBar(bar: SnackBar, animated: Bool) {
        if let _ = findSnackbar(bar) {
            UIView.animateWithDuration(animated ? 0.25 : 0, animations: { () -> Void in
                bar.hide()
                self.view.layoutIfNeeded()
            }) { success in
                // Really remove the bar
                self.finishRemovingBar(bar)
                self.updateSnackBarConstraints()
            }
        }
    }

    func removeAllBars() {
        let bars = snackBars.subviews
        for bar in bars {
            if let bar = bar as? SnackBar {
                bar.removeFromSuperview()
            }
        }
        self.updateSnackBarConstraints()
    }

    func browser(browser: Browser, didAddSnackbar bar: SnackBar) {
        if tabManager.selectedTab !== browser {
            return
        }
        showBar(bar, animated: true)
    }

    func browser(browser: Browser, didRemoveSnackbar bar: SnackBar) {
        removeBar(bar, animated: true)
    }
    
    func browser(browser: Browser, didSelectFindInPageForSelection selection: String) {
        updateFindInPageVisibility(visible: true)
        findInPageBar?.text = selection
    }
}
