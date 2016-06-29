/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Shared
import Storage

private let log = Logger.browserLogger

extension BrowserViewController: URLBarDelegate {
    private func showSearchController() {
        if searchController != nil {
            return
        }

        let isPrivate = tabManager.selectedTab?.isPrivate ?? false
        searchController = SearchViewController(isPrivate: isPrivate)
        searchController!.searchEngines = profile.searchEngines
        searchController!.searchDelegate = self
        searchController!.profile = self.profile

        searchLoader.addListener(searchController!)

        addChildViewController(searchController!)
        view.addSubview(searchController!.view)
        searchController!.view.snp_makeConstraints { make in
            make.top.equalTo(self.header.snp_bottom)
            make.left.right.bottom.equalTo(self.view)
            return
        }

        homePanelController?.view?.hidden = true

        searchController!.didMoveToParentViewController(self)
    }

    private func hideSearchController() {
        if let searchController = searchController {
            searchController.willMoveToParentViewController(nil)
            searchController.view.removeFromSuperview()
            searchController.removeFromParentViewController()
            self.searchController = nil
            homePanelController?.view?.hidden = false
        }
    }

    func urlBarDidPressReload(urlBar: URLBarView) {
        tabManager.selectedTab?.reload()
    }

    func urlBarDidPressStop(urlBar: URLBarView) {
        tabManager.selectedTab?.stop()
    }

    func urlBarDidPressTabs(urlBar: URLBarView) {
        self.webViewContainerToolbar.hidden = true
        updateFindInPageVisibility(visible: false)

        let tabTrayController = TabTrayController(tabManager: tabManager, profile: profile, tabTrayDelegate: self)

        if let tab = tabManager.selectedTab {
            screenshotHelper.takeScreenshot(tab)
        }

        //self.navigationController?.pushViewController(tabTrayController, animated: true)
        #if BRAVE
            tabTrayController.modalPresentationStyle = .OverCurrentContext
            tabTrayController.modalTransitionStyle = .CrossDissolve
            self.navigationController?.presentViewController(tabTrayController, animated: true, completion: nil)
            UIView.animateWithDuration(0.2, animations: {
                let braveTopVC = getApp().rootViewController.topViewController as? BraveTopViewController
                braveTopVC?.view.backgroundColor = UIColor.blackColor()
                self.view.alpha = CGFloat(BraveUX.BrowserViewAlphaWhenShowingTabTray)
            })
        #endif
        self.tabTrayController = tabTrayController
    }

    func urlBarDidPressReaderMode(urlBar: URLBarView) {
        if let tab = tabManager.selectedTab {
            if let readerMode = tab.getHelper(ReaderMode.self) {
                switch readerMode.state {
                case .Available:
                    enableReaderMode()
                case .Active:
                    disableReaderMode()
                case .Unavailable:
                    break
                }
            }
        }
    }

    func urlBarDidLongPressReaderMode(urlBar: URLBarView) -> Bool {
        guard let tab = tabManager.selectedTab,
            url = tab.displayURL,
            result = profile.readingList?.createRecordWithURL(url.absoluteString, title: tab.title ?? "", addedBy: UIDevice.currentDevice().name)
            else {
                UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, NSLocalizedString("Could not add page to Reading list", comment: "Accessibility message e.g. spoken by VoiceOver after adding current webpage to the Reading List failed."))
                return false
        }

        switch result {
        case .Success:
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, NSLocalizedString("Added page to Reading List", comment: "Accessibility message e.g. spoken by VoiceOver after the current page gets added to the Reading List using the Reader View button, e.g. by long-pressing it or by its accessibility custom action."))
        // TODO: https://bugzilla.mozilla.org/show_bug.cgi?id=1158503 provide some form of 'this has been added' visual feedback?
        case .Failure(let error):
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, NSLocalizedString("Could not add page to Reading List. Maybe it's already there?", comment: "Accessibility message e.g. spoken by VoiceOver after the user wanted to add current page to the Reading List and this was not done, likely because it already was in the Reading List, but perhaps also because of real failures."))
            log.error("readingList.createRecordWithURL(url: \"\(url.absoluteString)\", ...) failed with error: \(error)")
        }
        return true
    }

    func locationActionsForURLBar(urlBar: URLBarView) -> [AccessibleAction] {
        if UIPasteboard.generalPasteboard().string != nil {
            return [pasteGoAction, pasteAction, copyAddressAction]
        } else {
            return [copyAddressAction]
        }
    }

    func urlBarDisplayTextForURL(url: NSURL?) -> String? {
        // use the initial value for the URL so we can do proper pattern matching with search URLs
        var searchURL = self.tabManager.selectedTab?.currentInitialURL
        if searchURL == nil || ErrorPageHelper.isErrorPageURL(searchURL!) {
            searchURL = url
        }
        return profile.searchEngines.queryForSearchURL(searchURL) ?? url?.absoluteString
    }

    func urlBarDidLongPressLocation(urlBar: URLBarView) {
        let longPressAlertController = UIAlertController(title: nil, message: nil, preferredStyle: .ActionSheet)

        for action in locationActionsForURLBar(urlBar) {
            longPressAlertController.addAction(action.alertAction(style: .Default))
        }

        let cancelAction = UIAlertAction(title: NSLocalizedString("Cancel", comment: "Cancel alert view"), style: .Cancel, handler: { (alert: UIAlertAction) -> Void in
        })
        longPressAlertController.addAction(cancelAction)

        let setupPopover = { [unowned self] in
            if let popoverPresentationController = longPressAlertController.popoverPresentationController {
                popoverPresentationController.sourceView = urlBar
                popoverPresentationController.sourceRect = urlBar.frame
                popoverPresentationController.permittedArrowDirections = .Any
                popoverPresentationController.delegate = self
            }
        }

        setupPopover()

        if longPressAlertController.popoverPresentationController != nil {
            displayedPopoverController = longPressAlertController
            updateDisplayedPopoverProperties = setupPopover
        }

        self.presentViewController(longPressAlertController, animated: true, completion: nil)
    }

    func urlBarDidPressScrollToTop(urlBar: URLBarView) {
        if let selectedTab = tabManager.selectedTab {
            // Only scroll to top if we are not showing the home view controller
            if homePanelController == nil {
                selectedTab.webView?.scrollView.setContentOffset(CGPointZero, animated: true)
            }
        }
    }

    func urlBarLocationAccessibilityActions(urlBar: URLBarView) -> [UIAccessibilityCustomAction]? {
        return locationActionsForURLBar(urlBar).map { $0.accessibilityCustomAction }
    }

    func urlBar(urlBar: URLBarView, didEnterText text: String) {
        searchLoader.query = text

        if text.isEmpty {
            hideSearchController()
        } else {
            showSearchController()
            searchController!.searchQuery = text
        }
    }

    func urlBar(urlBar: URLBarView, didSubmitText text: String) {
        // If we can't make a valid URL, do a search query.
        // If we still don't have a valid URL, something is broken. Give up.
        guard let url = URIFixup.getURL(text) ??
            profile.searchEngines.defaultEngine.searchURLForQuery(text) else {
                log.error("Error handling URL entry: \"\(text)\".")
                return
        }

        finishEditingAndSubmit(url, visitType: VisitType.Typed)
    }

    func urlBarDidEnterOverlayMode(urlBar: URLBarView) {
        showHomePanelController(inline: false)
    }

    func urlBarDidLeaveOverlayMode(urlBar: URLBarView) {
        hideSearchController()
        updateInContentHomePanel(tabManager.selectedTab?.url)
    }
}

extension BrowserViewController: BrowserToolbarDelegate {
    func browserToolbarDidPressBack(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
        tabManager.selectedTab?.goBack()
    }

    func browserToolbarDidLongPressBack(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
        // See 1159373 - Disable long press back/forward for backforward list
        //        let controller = BackForwardListViewController()
        //        controller.listData = tabManager.selectedTab?.backList
        //        controller.tabManager = tabManager
        //        presentViewController(controller, animated: true, completion: nil)
    }

    func browserToolbarDidPressReload(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
        tabManager.selectedTab?.reload()
    }

    func browserToolbarDidLongPressReload(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
        guard #available(iOS 9.0, *) else {
            return
        }

        guard let tab = tabManager.selectedTab where tab.webView?.URL != nil && tab.getHelper(ReaderMode.self)?.state != .Active else {
            return
        }

        let toggleActionTitle: String
        if tab.desktopSite {
            toggleActionTitle = NSLocalizedString("Request Mobile Site", comment: "Action Sheet Button for Requesting the Mobile Site")
        } else {
            toggleActionTitle = NSLocalizedString("Request Desktop Site", comment: "Action Sheet Button for Requesting the Desktop Site")
        }

        let controller = UIAlertController(title: nil, message: nil, preferredStyle: .ActionSheet)
        controller.addAction(UIAlertAction(title: toggleActionTitle, style: .Default, handler: { _ in tab.toggleDesktopSite() }))
        controller.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment:"Action Sheet Cancel Button"), style: .Cancel, handler: nil))
        controller.popoverPresentationController?.sourceView = toolbar ?? urlBar
        controller.popoverPresentationController?.sourceRect = button.frame
        presentViewController(controller, animated: true, completion: nil)
    }

    func browserToolbarDidPressStop(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
        tabManager.selectedTab?.stop()
    }

    func browserToolbarDidPressForward(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
        tabManager.selectedTab?.goForward()
    }

    func browserToolbarDidLongPressForward(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
        // See 1159373 - Disable long press back/forward for backforward list
        //        let controller = BackForwardListViewController()
        //        controller.listData = tabManager.selectedTab?.forwardList
        //        controller.tabManager = tabManager
        //        presentViewController(controller, animated: true, completion: nil)
    }

    func browserToolbarDidPressBookmark(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
        guard let tab = tabManager.selectedTab,
            let url = tab.displayURL?.absoluteString else {
                log.error("Bookmark error: No tab is selected, or no URL in tab.")
                return
        }

        profile.bookmarks.modelFactory >>== {
            $0.isBookmarked(url) >>== { isBookmarked in
                if isBookmarked {
                    self.removeBookmark(url)
                } else {
                    self.addBookmark(url, title: tab.title)
                }
            }
        }
    }

    func browserToolbarDidLongPressBookmark(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
    }

    func browserToolbarDidPressShare(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
        if let tab = tabManager.selectedTab, url = tab.displayURL {
            let sourceView = self.navigationToolbar.shareButton
            presentActivityViewController(url, tab: tab, sourceView: sourceView.superview, sourceRect: sourceView.frame, arrowDirection: .Up)
        }
    }
}
