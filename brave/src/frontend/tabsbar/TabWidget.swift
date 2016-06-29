/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */
import UIKit
import SnapKit

protocol TabWidgetDelegate: class {
    func tabWidgetClose(tab: TabWidget)
    func tabWidgetSelected(tab: TabWidget)
}

class TabWidget : UIView {
    let title = UIButton()
    let close = UIButton()
    weak var delegate: TabWidgetDelegate?
    private(set) weak var browser: Browser?
    var widthConstraint: Constraint? = nil

    init(browser: Browser) {
        super.init(frame: CGRectZero)

        self.browser = browser

        getApp().browserViewController.delegates.append(WeakBrowserTabStateDelegate(value: self))

        let bar = UIView()

        close.addTarget(self, action: #selector(clicked), forControlEvents: .TouchUpInside)
        title.addTarget(self, action: #selector(selected), forControlEvents: .TouchUpInside)
        title.setTitle(NSLocalizedString("New tab", comment: "Default title in tabs bar for a tab"), forState: .Normal)
        [close, title, bar].forEach { addSubview($0) }

        close.setImage(UIImage(named: "stop")!, forState: .Normal)
        close.snp_makeConstraints(closure: { (make) in
            make.top.bottom.left.equalTo(self)
            make.width.equalTo(24)
        })
        close.tintColor = UIColor.lightGrayColor()

        title.snp_makeConstraints { (make) in
            make.top.bottom.equalTo(self)
            make.left.equalTo(close.snp_right).offset(4)
            make.right.equalTo(self).inset(4)
        }

        bar.backgroundColor = UIColor.blackColor()
        bar.snp_makeConstraints { (make) in
            make.left.top.bottom.equalTo(self)
            make.width.equalTo(1)
        }

        deselect()
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        var delegates = getApp().browserViewController.delegates
        if let item = delegates.find({ $0.get() ===  self }) {
            if let index = delegates.indexOf({ $0 === item}) {
                delegates.removeAtIndex(index)
            }
        }
    }

    func clicked() {
        delegate?.tabWidgetClose(self)
    }

    func deselect() {
        backgroundColor = UIColor.init(white: 90/255, alpha: 1.0)
        title.titleLabel!.font = UIFont.systemFontOfSize(11)
        title.setTitleColor(UIColor.init(white: 248/255, alpha: 1.0), forState: .Normal)
    }

    func selected() {
        delegate?.tabWidgetSelected(self)
    }

    func setStyleToSelected() {
        title.titleLabel!.font = UIFont.systemFontOfSize(11, weight: UIFontWeightSemibold)
        title.setTitleColor(UIColor.init(white: 255/255, alpha: 1.0), forState: .Normal)
        backgroundColor = UIColor.init(white: 67/255, alpha: 1.0)
    }

    private var titleUpdateScheduled = false
    func updateTitle_throttled() {
        if titleUpdateScheduled {
            return
        }
        titleUpdateScheduled = true
        delay(0.2) { [weak self] in
            self?.titleUpdateScheduled = false
            if let t = self?.browser?.webView?.title where !t.isEmpty {
                self?.title.setTitle(t, forState: .Normal)
            }
        }
    }
}

extension TabWidget : BrowserTabStateDelegate {
    func browserUrlChanged(browser: Browser) {
        if browser !== self.browser {
            return
        }

        updateTitle_throttled()
    }

    func browserProgressChanged(browser: Browser) {
        if browser !== self.browser {
            return
        }
        updateTitle_throttled()
    }
}

