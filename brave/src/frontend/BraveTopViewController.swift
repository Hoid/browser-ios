/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Shared
import Storage
import SnapKit

let kNotificationLeftSlideOutClicked = "kNotificationLeftSlideOutClicked"
let kNotificationBraveButtonClicked = "kNotificationBraveButtonClicked"


class BraveTopViewController : UIViewController {
    var browserViewController:BraveBrowserViewController
    var mainSidePanel:MainSidePanelViewController
    var rightSidePanel:BraveRightSidePanelViewController
    var clickDetectionView = UIButton()
    var leftConstraint: Constraint? = nil
    var rightConstraint: Constraint? = nil
    var leftSidePanelButtonAndUnderlay: ButtonWithUnderlayView?
    init(browserViewController:BraveBrowserViewController) {
        self.browserViewController = browserViewController
        mainSidePanel = MainSidePanelViewController()
        rightSidePanel = BraveRightSidePanelViewController()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError()
    }

    private func addVC(vc: UIViewController) {
        addChildViewController(vc)
        view.addSubview(vc.view)
        vc.didMoveToParentViewController(self)
    }

    override func viewDidLoad() {
        view.accessibilityLabel = "HighestView"
        view.backgroundColor = BraveUX.TopLevelBackgroundColor

        browserViewController.view.accessibilityLabel = "BrowserViewController"

        addVC(browserViewController)
        addVC(mainSidePanel)
        addVC(rightSidePanel)


        mainSidePanel.view.snp_makeConstraints {
            make in
            make.bottom.left.top.equalTo(view)
            make.width.equalTo(0)
        }

        rightSidePanel.view.snp_makeConstraints {
            make in
            make.bottom.right.top.equalTo(view)
            make.width.equalTo(0)
        }

        clickDetectionView.backgroundColor = UIColor(white: 80/255, alpha: 0.3)

        setupBrowserConstraints(useTopLayoutGuide: true)

        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(onClickLeftSlideOut), name: kNotificationLeftSlideOutClicked, object: nil)

        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(onClickBraveButton), name: kNotificationBraveButtonClicked, object: nil)

        clickDetectionView.addTarget(self, action: #selector(BraveTopViewController.dismissAllSidePanels(_:)), forControlEvents: UIControlEvents.TouchUpInside)

        mainSidePanel.browserViewController = browserViewController
    }

    @objc func dismissAllSidePanels(button: UIButton) {
        if leftPanelShowing() {
            togglePanel(mainSidePanel)
            leftSidePanelButtonAndUnderlay?.selected = false
            leftSidePanelButtonAndUnderlay?.underlay.hidden = true
        }

        if rightPanelShowing() {
            togglePanel(rightSidePanel)
        }
    }

    private func setupBrowserConstraints(useTopLayoutGuide useTopLayoutGuide: Bool) {
        browserViewController.view.snp_remakeConstraints {
            make in
            make.bottom.equalTo(view)
            if useTopLayoutGuide {
                make.top.equalTo(snp_topLayoutGuideTop)
            } else {
                make.top.equalTo(view).inset(20)
            }

            if UIDevice.currentDevice().userInterfaceIdiom == .Phone {
                rightConstraint = make.right.equalTo(view).constraint
                leftConstraint = make.left.equalTo(view).constraint
            } else {
                make.right.left.equalTo(view)
            }
        }

        if UIDevice.currentDevice().userInterfaceIdiom != .Phone {
            browserViewController.header.snp_makeConstraints { make in
                leftConstraint = make.left.equalTo(view).constraint
                rightConstraint = make.right.equalTo(view).constraint
            }
        }
    }

    override func preferredStatusBarStyle() -> UIStatusBarStyle {
        return UIStatusBarStyle.LightContent
    }

    func leftPanelShowing() -> Bool {
        return mainSidePanel.view.frame.width == CGFloat(BraveUX.WidthOfSlideOut)
    }

    func rightPanelShowing() -> Bool {
        return rightSidePanel.view.frame.width == CGFloat(BraveUX.WidthOfSlideOut)
    }

    override func prefersStatusBarHidden() -> Bool {
        if UIDevice.currentDevice().userInterfaceIdiom != .Phone {
            return super.prefersStatusBarHidden()
        }

        if BraveApp.isIPhoneLandscape() {
            return true
        }

        return leftPanelShowing() || rightPanelShowing()
    }

    func onClickLeftSlideOut(notification: NSNotification) {
        leftSidePanelButtonAndUnderlay = notification.object as? ButtonWithUnderlayView
        if !rightSidePanel.view.hidden {
            togglePanel(rightSidePanel)
        }
        togglePanel(mainSidePanel)
    }

    func onClickBraveButton(notification: NSNotification) {
        if !mainSidePanel.view.hidden {
            togglePanel(mainSidePanel)
        }

        if self.browserViewController.tabManager.selectedTab?.displayURL?.absoluteString.isEmpty ?? true {
            return
        }

        browserViewController.tabManager.selectedTab?.webView?.checkScriptBlockedAndBroadcastStats()
        togglePanel(rightSidePanel)
    }

    func togglePanel(panel: SidePanelBaseViewController) {
        let willShow = panel.view.hidden
        if panel === mainSidePanel {
            leftSidePanelButtonAndUnderlay?.selected = willShow
            leftSidePanelButtonAndUnderlay?.hideUnderlay(!willShow)
        } else if !willShow && !panel.canShow {
            return
        }

        if clickDetectionView.superview != nil {
            clickDetectionView.userInteractionEnabled = false
            UIView.animateWithDuration(0.2, animations: {
                self.clickDetectionView.alpha = 0
                }, completion: { _ in
                    self.clickDetectionView.removeFromSuperview()
            } )
        }

        if willShow {
            clickDetectionView.alpha = 0
            clickDetectionView.userInteractionEnabled = true

            view.addSubview(clickDetectionView)
            clickDetectionView.snp_remakeConstraints {
                make in
                make.top.bottom.equalTo(browserViewController.view)
                make.right.equalTo(rightSidePanel.view.snp_left)
                make.left.equalTo(mainSidePanel.view.snp_right)
            }
            clickDetectionView.layoutIfNeeded()

            UIView.animateWithDuration(0.25) {
                self.clickDetectionView.alpha = 1
            }
        }
        panel.setHomePanelDelegate(self)
        panel.showPanel(willShow, parentSideConstraints: [leftConstraint, rightConstraint])
    }

    func updateBookmarkStatus(isBookmarked: Bool) {
        mainSidePanel.updateBookmarkStatus(isBookmarked)
    }
}

extension BraveTopViewController : HomePanelDelegate {
    func homePanelDidRequestToSignIn(homePanel: HomePanel) {}
    func homePanelDidRequestToCreateAccount(homePanel: HomePanel) {}
    func homePanel(homePanel: HomePanel, didSelectURL url: NSURL, visitType: VisitType) {
        print("selected \(url)")
        browserViewController.urlBar.leaveOverlayMode()
        browserViewController.tabManager.selectedTab?.loadRequest(NSURLRequest(URL: url))
        togglePanel(mainSidePanel)
    }
}