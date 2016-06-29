/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */

let TabsBarHeight = CGFloat(26)
var showTabsBar = true

// To hide the curve effect
class HideCurveView : CurveView {
    override func drawRect(rect: CGRect) {}
}

extension UILabel {
    func boldRange(range: Range<String.Index>) {
        if let text = self.attributedText {
            let attr = NSMutableAttributedString(attributedString: text)
            let start = text.string.startIndex.distanceTo(range.startIndex)
            let length = range.startIndex.distanceTo(range.endIndex)
            attr.addAttributes([NSFontAttributeName: UIFont.boldSystemFontOfSize(self.font.pointSize)], range: NSMakeRange(start, length))
            self.attributedText = attr
        }
    }

    func boldSubstring(substr: String) {
        let range = self.text?.rangeOfString(substr)
        if let r = range {
            boldRange(r)
        }
    }
}

class ButtonWithUnderlayView : UIButton {
    lazy var starView: UIImageView = {
        let v = UIImageView()
        v.contentMode = .Center
        self.addSubview(v)
        v.userInteractionEnabled = false

        v.snp_makeConstraints {
            make in
            make.center.equalTo(self.snp_center)
        }
        return v
    }()

    lazy var underlay: UIView = {
        let v = UIView()
        if UIDevice.currentDevice().userInterfaceIdiom == .Pad {
            v.backgroundColor = BraveUX.ProgressBarColor
            v.layer.cornerRadius = 4
            v.layer.borderWidth = 1
            v.layer.borderColor = UIColor.clearColor().CGColor
            v.layer.masksToBounds = true
        }
        v.userInteractionEnabled = false
        v.hidden = true

        return v
    }()

    func hideUnderlay(hide: Bool) {
        underlay.hidden = hide
        starView.hidden = !hide
    }

    func setStarImageBookmarked(on: Bool) {
        if on {
            starView.image = UIImage(named: "listpanel_bookmarked_star")!.imageWithRenderingMode(.AlwaysOriginal)
        } else {
            starView.image = UIImage(named: "listpanel_notbookmarked_star")!.imageWithRenderingMode(.AlwaysTemplate)
        }
    }
}

class BraveURLBarView : URLBarView {

    static var CurrentHeight = UIConstants.ToolbarHeight

    private static weak var currentInstance: BraveURLBarView?
    lazy var leftSidePanelButton: ButtonWithUnderlayView = { return ButtonWithUnderlayView() }()
    lazy var braveButton = { return UIButton() }()

    let tabsBarController = TabsBarViewController()

    override func commonInit() {
        BraveURLBarView.currentInstance = self
        locationContainer.layer.cornerRadius = CGFloat(BraveUX.TextFieldCornerRadius)
        curveShape = HideCurveView()

        addSubview(leftSidePanelButton.underlay)
        addSubview(leftSidePanelButton)
        addSubview(braveButton)
        super.commonInit()

        leftSidePanelButton.addTarget(self, action: #selector(onClickLeftSlideOut), forControlEvents: UIControlEvents.TouchUpInside)
        leftSidePanelButton.setImage(UIImage(named: "listpanel")?.imageWithRenderingMode(.AlwaysTemplate), forState: .Normal)
        leftSidePanelButton.setImage(UIImage(named: "listpanel_down")?.imageWithRenderingMode(.AlwaysTemplate), forState: .Selected)
        leftSidePanelButton.accessibilityLabel = NSLocalizedString("Bookmarks and History Panel", comment: "Button to show the bookmarks and history panel")
        leftSidePanelButton.tintColor = BraveUX.ActionButtonTintColor
        leftSidePanelButton.setStarImageBookmarked(false)

        braveButton.addTarget(self, action: #selector(onClickBraveButton) , forControlEvents: UIControlEvents.TouchUpInside)
        braveButton.setImage(UIImage(named: "bravePanelButton"), forState: .Normal)
        braveButton.setImage(UIImage(named: "bravePanelButtonOff"), forState: .Selected)
        braveButton.accessibilityLabel = NSLocalizedString("Brave Panel", comment: "Button to show the brave panel")
        braveButton.tintColor = BraveUX.ActionButtonTintColor

        //ToolbarTextField.appearance().clearButtonTintColor = nil

        var theme = Theme()
        theme.URLFontColor = BraveUX.LocationBarTextColor_URLBaseComponent
        theme.hostFontColor = BraveUX.LocationBarTextColor_URLHostComponent
        theme.backgroundColor = BraveUX.LocationBarBackgroundColor
        BrowserLocationViewUX.Themes[Theme.NormalMode] = theme

        theme = Theme()
        theme.URLFontColor = BraveUX.LocationBarTextColor_URLBaseComponent
        theme.hostFontColor = BraveUX.LocationBarTextColor_URLHostComponent
        theme.backgroundColor = BraveUX.LocationBarBackgroundColor_PrivateMode
        BrowserLocationViewUX.Themes[Theme.PrivateMode] = theme

        theme = Theme()
        theme.backgroundColor = BraveUX.LocationBarEditModeBackgroundColor
        theme.textColor = BraveUX.LocationBarEditModeTextColor
        ToolbarTextField.Themes[Theme.NormalMode] = theme

        theme = Theme()
        theme.backgroundColor = BraveUX.LocationBarEditModeBackgroundColor_Private
        theme.textColor = BraveUX.LocationBarEditModeTextColor_Private
        theme.buttonTintColor = UIColor.whiteColor()    
        ToolbarTextField.Themes[Theme.PrivateMode] = theme

        theme = Theme()
        theme.borderColor = BraveUX.TextFieldBorderColor_NoFocus
        theme.activeBorderColor = BraveUX.TextFieldBorderColor_HasFocus
        theme.tintColor = URLBarViewUX.ProgressTintColor
        theme.textColor = BraveUX.LocationBarTextColor
        theme.buttonTintColor = BraveUX.ActionButtonTintColor
        URLBarViewUX.Themes[Theme.NormalMode] = theme

        stopReloadButton.imageEdgeInsets = UIEdgeInsetsMake(0, 6, 0, 0)

        if (showTabsBar) {
            addSubview(tabsBarController.view)
            getApp().browserViewController.addChildViewController(tabsBarController)
            tabsBarController.didMoveToParentViewController(getApp().browserViewController)
            BraveURLBarView.CurrentHeight = TabsBarHeight + UIConstants.ToolbarHeight
        }
    }

    override func applyTheme(themeName: String) {
        super.applyTheme(themeName)
//        if themeName == Theme.NormalMode {
//            backgroundColor = BraveUX.LocationBarBackgroundColor
//        }
//        if themeName == Theme.PrivateMode {
//            backgroundColor = BraveUX.LocationBarBackgroundColor_PrivateMode
//        }
    }

    override func updateAlphaForSubviews(alpha: CGFloat) {
        super.updateAlphaForSubviews(alpha)
        self.superview?.alpha = alpha
    }

    @objc func onClickLeftSlideOut() {
        leftSidePanelButton.selected = !leftSidePanelButton.selected
        NSNotificationCenter.defaultCenter().postNotificationName(kNotificationLeftSlideOutClicked, object: leftSidePanelButton)
    }

    @objc func onClickBraveButton() {
        NSNotificationCenter.defaultCenter().postNotificationName(kNotificationBraveButtonClicked, object: braveButton)
    }

    override func updateTabCount(count: Int, animated: Bool = true) {
        super.updateTabCount(count, animated: toolbarIsShowing)
        BraveBrowserBottomToolbar.updateTabCountDuplicatedButton(count, animated: animated)
    }

    class func tabButtonPressed() {
        guard let instance = BraveURLBarView.currentInstance else { return }
        instance.delegate?.urlBarDidPressTabs(instance)
    }

    override var accessibilityElements: [AnyObject]? {
        get {
            if inOverlayMode {
                guard let locationTextField = locationTextField else { return nil }
                return [leftSidePanelButton, locationTextField, cancelButton]
            } else {
                if toolbarIsShowing {
                    return [backButton, forwardButton, leftSidePanelButton, locationView, braveButton, shareButton, tabsButton]
                } else {
                    return [leftSidePanelButton, locationView, braveButton]
                }
            }
        }
        set {
            super.accessibilityElements = newValue
        }
    }

    override func updateViewsForOverlayModeAndToolbarChanges() {
        super.updateViewsForOverlayModeAndToolbarChanges()

        if !self.toolbarIsShowing {
            self.tabsButton.hidden = true
        } else {
            self.tabsButton.hidden = false
        }

        bookmarkButton.hidden = true
    }

    override func prepareOverlayAnimation() {
        super.prepareOverlayAnimation()
        bookmarkButton.hidden = true
        braveButton.hidden = true
    }

    override func transitionToOverlay(didCancel: Bool = false) {
        super.transitionToOverlay(didCancel)
        bookmarkButton.hidden = true
        locationView.alpha = 0.0

        locationView.superview?.backgroundColor = locationTextField?.backgroundColor
    }

    override func leaveOverlayMode(didCancel cancel: Bool) {
        if !inOverlayMode {
            return
        }

        super.leaveOverlayMode(didCancel: cancel)
        locationView.alpha = 1.0

        // The orange brave button sliding in looks odd, lets fade it in in-place
        braveButton.alpha = 0
        braveButton.hidden = false
        UIView.animateWithDuration(0.3, animations: { self.braveButton.alpha = 1.0 })
    }

    override func updateConstraints() {
        super.updateConstraints()

        if showTabsBar {
            bringSubviewToFront(tabsBarController.view)
            tabsBarController.view.snp_makeConstraints { (make) in
                make.bottom.left.right.equalTo(self)
                make.height.equalTo(TabsBarHeight)
            }
        }

        leftSidePanelButton.underlay.snp_makeConstraints {
            make in
            make.left.right.equalTo(leftSidePanelButton).inset(4)
            make.top.bottom.equalTo(leftSidePanelButton).inset(7)
        }

        curveShape.hidden = true
        bookmarkButton.hidden = true
        bookmarkButton.snp_removeConstraints()
        curveShape.snp_removeConstraints()

        func pinLeftPanelButtonToLeft() {
            leftSidePanelButton.snp_remakeConstraints { make in
                make.left.equalTo(self)
                make.centerY.equalTo(self.locationContainer)
                make.size.equalTo(UIConstants.ToolbarHeight)
            }
        }

        if inOverlayMode {
            // In overlay mode, we always show the location view full width
            self.locationContainer.snp_remakeConstraints { make in
                make.left.equalTo(self.leftSidePanelButton.snp_right)//.offset(URLBarViewUX.LocationLeftPadding)
                make.right.equalTo(self.cancelButton.snp_left)
                make.height.equalTo(URLBarViewUX.LocationHeight)
                make.top.equalTo(self).inset(8)
            }
            pinLeftPanelButtonToLeft()
        } else {
            self.locationContainer.snp_remakeConstraints { make in
                if self.toolbarIsShowing {
                    // Firefox is not referring to the bottom toolbar, it is asking is this class showing more tool buttons
                    make.leading.equalTo(self.leftSidePanelButton.snp_trailing)
                    make.trailing.equalTo(self).inset(UIConstants.ToolbarHeight * 3)
                } else {
                    make.left.right.equalTo(self).inset(UIConstants.ToolbarHeight)
                }

                make.height.equalTo(URLBarViewUX.LocationHeight)
                make.top.equalTo(self).inset(8)
            }

            if self.toolbarIsShowing {
                leftSidePanelButton.snp_remakeConstraints { make in
                    make.left.equalTo(self.forwardButton.snp_right)
                    make.centerY.equalTo(self.locationContainer)
                    make.size.equalTo(UIConstants.ToolbarHeight)
                }
            } else {
                pinLeftPanelButtonToLeft()
            }

            braveButton.snp_remakeConstraints { make in
                make.left.equalTo(self.locationContainer.snp_right)
                make.centerY.equalTo(self.locationContainer)
                make.size.equalTo(UIConstants.ToolbarHeight)
            }
        }

        bringSubviewToFront(stopReloadButton)
    }

    override func setupConstraints() {


        backButton.snp_makeConstraints { make in
            make.centerY.equalTo(self.locationContainer)
            make.left.equalTo(self)
            make.size.equalTo(UIConstants.ToolbarHeight)
        }

        forwardButton.snp_makeConstraints { make in
            make.left.equalTo(self.backButton.snp_right)
            make.centerY.equalTo(self.locationContainer)
            make.size.equalTo(backButton)
        }

        leftSidePanelButton.snp_makeConstraints { make in
            make.left.equalTo(self.forwardButton.snp_right)
            make.centerY.equalTo(self.locationContainer)
            make.size.equalTo(UIConstants.ToolbarHeight)
        }

        locationView.snp_makeConstraints { make in
            make.edges.equalTo(self.locationContainer)
        }

        cancelButton.snp_makeConstraints { make in
            make.centerY.equalTo(self.locationContainer)
            make.trailing.equalTo(self)
        }

        shareButton.snp_remakeConstraints { make in
            make.right.equalTo(self.tabsButton.snp_left).offset(0)
            make.centerY.equalTo(self.locationContainer)
            make.width.equalTo(UIConstants.ToolbarHeight)
        }

        tabsButton.snp_makeConstraints { make in
            make.centerY.equalTo(self.locationContainer)
            make.trailing.equalTo(self)
            make.size.equalTo(UIConstants.ToolbarHeight)
        }


        stopReloadButton.snp_makeConstraints { make in
            make.right.equalTo(self.locationView.snp_right)
            make.centerY.equalTo(self.locationContainer)
            make.size.equalTo(UIConstants.ToolbarHeight)
        }

        bringSubviewToFront(stopReloadButton)
    }

    var progressIsCompleting = false
    override func updateProgressBar(progress: Float, dueToTabChange: Bool = false) {
        func setWidth(width: CGFloat) {
            var frame = locationView.braveProgressView.frame
            frame.size.width = width
            locationView.braveProgressView.frame = frame
        }

        if dueToTabChange && (progress == 1.0 || progress == 0.0) {
            setWidth(0)
            return
        }

        let minProgress = locationView.frame.width / 3.0

        if progress == 1.0 {
            if progressIsCompleting {
                return
            }
            progressIsCompleting = true
            
            UIView.animateWithDuration(0.5, animations: {
                setWidth(self.locationView.frame.width)
                }, completion: { _ in
                    UIView.animateWithDuration(0.5, animations: {
                        self.locationView.braveProgressView.alpha = 0.0
                        }, completion: { _ in
                            self.progressIsCompleting = false
                            setWidth(0)
                    })
            })
        } else {
            self.locationView.braveProgressView.alpha = 1.0
            progressIsCompleting = false
            let w = minProgress + CGFloat(progress) * (self.locationView.frame.width - minProgress)
            
            if w > locationView.braveProgressView.frame.size.width {
                UIView.animateWithDuration(0.5, animations: {
                    setWidth(w)
                    }, completion: { _ in
                        
                })
            }
        }
    }

    override func updateBookmarkStatus(isBookmarked: Bool) {
        if let braveTopVC = getApp().rootViewController.topViewController as? BraveTopViewController {
            braveTopVC.updateBookmarkStatus(isBookmarked)
        }

        leftSidePanelButton.setStarImageBookmarked(isBookmarked)
    }

    func setBraveButtonState(shieldsUp shieldsUp: Bool, animated: Bool) {
        let selected = !shieldsUp
        if braveButton.selected == selected {
            return
        }
        
        braveButton.selected = selected

        if !animated {
            return
        }

        let v = InsetLabel(frame: CGRectMake(0, 0, locationContainer.frame.width, locationContainer.frame.height))
        v.rightInset = CGFloat(40)
        v.text = braveButton.selected ? BraveUX.TitleForBraveProtectionOff : BraveUX.TitleForBraveProtectionOn
        if var range = v.text!.rangeOfString(" ", options:NSStringCompareOptions.BackwardsSearch) {
            range.endIndex = v.text!.characters.endIndex
            v.boldRange(range)
        }
        v.backgroundColor = braveButton.selected ? UIColor(white: 0.6, alpha: 1.0) : BraveUX.BraveButtonMessageInUrlBarColor
        v.textAlignment = .Right
        locationContainer.addSubview(v)
        v.alpha = 0.0
        self.stopReloadButton.alpha = 0
        UIView.animateWithDuration(0.25, animations: { v.alpha = 1.0 }, completion: {
            finished in
            UIView.animateWithDuration(BraveUX.BraveButtonMessageInUrlBarFadeTime, delay: BraveUX.BraveButtonMessageInUrlBarShowTime, options: [], animations: {
                v.alpha = 0
                self.stopReloadButton.alpha = 1.0
                }, completion: {
                    finished in
                    v.removeFromSuperview()
                    self.stopReloadButton.alpha = 1.0
            })
        })
    }
}
