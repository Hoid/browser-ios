/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */
import UIKit
import SnapKit

let kPrefKeyTabsBarOn = "kPrefKeyTabsBarOn"
let kPrefKeyTabsBarOnDefaultValue = UIDevice.currentDevice().userInterfaceIdiom == .Pad

let minTabWidth = CGFloat(180)
let tabHeight = CGFloat(24)

class TabsBarViewController: UIViewController {
    var scrollView: UIScrollView!

    var tabs = [TabWidget]()

    var leftOverflowIndicator : CAGradientLayer = CAGradientLayer()
    var rightOverflowIndicator : CAGradientLayer = CAGradientLayer()

    init() {
        super.init(nibName: nil, bundle: nil)

        self.view = UIView(frame: CGRectZero)
        scrollView = UIScrollView(frame: CGRectZero)
        scrollView.bounces = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delegate = self
        view.addSubview(scrollView)

        scrollView.snp_makeConstraints { (make) in
            make.edges.equalTo(scrollView.superview!)
        }

        getApp().tabManager.addDelegate(self)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLayoutSubviews() {
        updateContentSize(tabs.count)
    }

    func tabOverflowWidth(tabCount: Int) -> CGFloat {
        let overflow = CGFloat(tabCount) * minTabWidth - view.frame.width
        return overflow > 0 ? overflow : 0
    }

    func updateContentSize(tabCount: Int) {
        struct staticWidth { static var val = CGFloat(0) }
        if staticWidth.val != view.bounds.width {
            let w = calcTabWidth(tabs.count)
            tabs.forEach {
                $0.widthConstraint?.updateOffset(w)
            }
            overflowIndicators()
        }
        staticWidth.val = view.bounds.width
        scrollView.contentSize = CGSizeMake(view.bounds.width + tabOverflowWidth(tabCount), view.bounds.height)
    }

    func overflowIndicators() {
        if tabOverflowWidth(tabs.count) < 1 {
            leftOverflowIndicator.opacity = 0
            rightOverflowIndicator.opacity = 0
            return
        }

        let offset = Float(scrollView.contentOffset.x)
        let startFade = Float(30)
        if offset < startFade {
            leftOverflowIndicator.opacity = offset / startFade
        } else {
            leftOverflowIndicator.opacity = 1

        }

        // all the way scrolled right
        let offsetFromRight = scrollView.contentSize.width - CGFloat(offset) - scrollView.frame.width
        if offsetFromRight < CGFloat(startFade) {
            rightOverflowIndicator.opacity = Float(offsetFromRight) / startFade
        } else {
            rightOverflowIndicator.opacity = 1
        }
    }

    override func viewDidAppear(animated: Bool) {
        addLeftRightScrollHint(isRightSide: false, maskLayer: leftOverflowIndicator)
        addLeftRightScrollHint(isRightSide: true, maskLayer: rightOverflowIndicator)

        if tabs.count < 1 {
            return
        }

        let w = calcTabWidth(tabs.count)
        tabs.forEach {
            $0.widthConstraint?.updateOffset(w)
        }
        updateContentSize(tabs.count)
        overflowIndicators()
    }

    func addTab(browser browser: Browser) -> TabWidget {
        let t = TabWidget(browser: browser)
        t.delegate = self

        scrollView.addSubview(t)
        t.alpha = 0

        let w = calcTabWidth(tabs.count + 1)

        UIView.setAnimationsEnabled(true)
        UIView.animateWithDuration(0.2, animations: {
            self.tabs.forEach {
                $0.widthConstraint?.updateOffset(w)
            }
            self.scrollView.layoutIfNeeded()
            }, completion: { _ in
                UIView.animateWithDuration(0.2) {
                    t.alpha = 1
                }
            }
        )

        t.snp_makeConstraints {
            make in
            make.top.equalTo(t.superview!)
            t.widthConstraint = make.width.equalTo(w).constraint
            make.height.equalTo(tabHeight)

            if let prev = tabs.last {
                make.left.equalTo(prev.snp_right)
            } else {
                make.left.equalTo(t.superview!)
            }

            tabs.append(t)
        }

        updateContentSize(tabs.count)
        overflowIndicators()

        return t
    }

    func calcTabWidth(tabCount: Int) -> CGFloat {
        if tabCount < 1 {
            return view.frame.width
        }
        var w = view.frame.width / (CGFloat(tabCount))
        if w < minTabWidth {
            w = minTabWidth
        }
        return w
    }

    func removeTab(tab: TabWidget) {
        let w = calcTabWidth(tabs.count - 1)
        var index = 0

        UIView.animateWithDuration(0.2, animations: {
            tab.alpha = 0
            for (i, item) in self.tabs.enumerate() {
                if item === tab {
                    index = i
                    item.widthConstraint?.updateOffset(0)
                } else {
                    item.widthConstraint?.updateOffset(w)
                }
            }
            self.scrollView.layoutIfNeeded()
            self.updateContentSize(self.tabs.count - 1)
        }) { _ in
            func at(i: Int) -> TabWidget? {
                return 0 ..< self.tabs.count ~= i ? self.tabs[i] : nil
            }

            let prev = at(index - 1)
            let next = at(index + 1)
            next?.snp_makeConstraints(closure: { (make) in
                if let prev = prev {
                    make.left.equalTo(prev.snp_right)
                } else {
                    make.left.equalTo(self.view)
                }
            })

            tab.removeFromSuperview()
            self.tabs.removeAtIndex(index)
            self.overflowIndicators()
        }
    }

    func addLeftRightScrollHint(isRightSide isRightSide: Bool, maskLayer: CAGradientLayer) {
        maskLayer.removeFromSuperlayer()
        let colors = [UIColor(white: 80/255, alpha: 0).CGColor, UIColor(white:66/255, alpha: 1.0).CGColor]
        let locations = [0.9, 1.0]
        maskLayer.startPoint = CGPoint(x: isRightSide ? 0 : 1.0, y: 0.5)
        maskLayer.endPoint = CGPoint(x: isRightSide ? 1.0 : 0, y: 0.5)
        maskLayer.opacity = 0
        maskLayer.colors = colors;
        maskLayer.locations = locations;
        maskLayer.bounds = CGRectMake(0, 0, scrollView.frame.width, tabHeight)
        maskLayer.anchorPoint = CGPointZero;
        // you must add the mask to the root view, not the scrollView, otherwise the masks will move as the user scrolls!
        view.layer.addSublayer(maskLayer)
    }
}

extension TabsBarViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(scrollView: UIScrollView) {
        overflowIndicators()
    }
}

extension TabsBarViewController: TabWidgetDelegate {
    func tabWidgetClose(tab: TabWidget) {
        if let b = tab.browser {
            getApp().tabManager.removeTab(b, createTabIfNoneLeft: true)
        }
    }

    func tabWidgetSelected(tab: TabWidget) {
        tabs.forEach {
            $0.deselect()
        }
        tab.setStyleToSelected()

        if getApp().tabManager.selectedTab !== tab.browser {
            getApp().tabManager.selectTab(tab.browser)
        }

        delay(0.1) { // allow time for any layout code to complete
            let left = CGRectMake(tab.frame.minX, 1, 1, 1)
            let right = CGRectMake(tab.frame.maxX - 1, 1, 1, 1)
            self.scrollView.scrollRectToVisible(left, animated: true)
            self.scrollView.scrollRectToVisible(right, animated: true)
        }
    }
}

extension TabsBarViewController: TabManagerDelegate {
    func tabManagerDidEnterPrivateBrowsingMode(tabManager: TabManager) {
        assert(NSThread.currentThread().isMainThread)
        tabs.forEach{ $0.removeFromSuperview() }
        tabs.removeAll()
    }

    func tabManagerDidExitPrivateBrowsingMode(tabManager: TabManager) {
        assert(NSThread.currentThread().isMainThread)
        tabs.forEach{ $0.removeFromSuperview() }
        tabs.removeAll()

        tabManager.tabs.forEach {
            let t = addTab(browser: $0)
            t.title.setTitle($0.lastTitle, forState: .Normal)
            if tabManager.selectedTab === $0 {
                tabWidgetSelected(t)
            }
        }
    }

    func tabManager(tabManager: TabManager, didSelectedTabChange selected: Browser?, previous: Browser?) {
        assert(NSThread.currentThread().isMainThread)
        tabs.forEach { tabWidget in
            if tabWidget.browser === selected {
                tabWidgetSelected(tabWidget)
            }
        }
    }

    func tabManager(tabManager: TabManager, didCreateWebView tab: Browser) {
        if tabs.find({ $0.browser === tab }) != nil {
            return
        }
        addTab(browser: tab)
    }

    func tabManager(tabManager: TabManager, didAddTab tab: Browser) {}

    func tabManager(tabManager: TabManager, didRemoveTab tab: Browser) {
        assert(NSThread.currentThread().isMainThread)
        tabs.forEach { tabWidget in
            if tabWidget.browser === tab {
                removeTab(tabWidget)
            }
        }
    }

    func tabManagerDidRestoreTabs(tabManager: TabManager) {
        delay(0.5) { [weak self] in
            self?.tabs.forEach {
                $0.updateTitle_throttled()
            }
        }
    }

    func tabManagerDidAddTabs(tabManager: TabManager) {}
}

