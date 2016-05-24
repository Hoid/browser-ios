/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit
import Shared
import Deferred

private let SectionToggles = 0
private let SectionButton = 1
private let NumberOfSections = 2
private let SectionHeaderFooterIdentifier = "SectionHeaderFooterIdentifier"
private let TogglesPrefKey = "clearprivatedata.toggles"

private let log = Logger.browserLogger

private let HistoryClearableIndex = 0

class ClearPrivateDataTableViewController: UITableViewController {
    private var clearButton: UITableViewCell?

    var profile: Profile!

    private typealias DefaultCheckedState = Bool

    private lazy var clearables: [(clearable: Clearable, checked: DefaultCheckedState)] = {
        return [
            (HistoryClearable(profile: self.profile), true),
            (CacheClearable(), true),
            (CookiesClearable(), true),
            (PasswordsClearable(profile: self.profile), true),
            ]
    }()

    private lazy var toggles: [Bool] = {
        if let savedToggles = self.profile.prefs.arrayForKey(TogglesPrefKey) as? [Bool] {
            return savedToggles
        }

        return self.clearables.map { $0.checked }
    }()

    private var clearButtonEnabled = true {
        didSet {
            clearButton?.textLabel?.textColor = clearButtonEnabled ? UIConstants.DestructiveRed : UIColor.lightGrayColor()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = Strings.SettingsClearPrivateDataTitle

        tableView.registerClass(SettingsTableSectionHeaderFooterView.self, forHeaderFooterViewReuseIdentifier: SectionHeaderFooterIdentifier)

        tableView.separatorColor = UIConstants.TableViewSeparatorColor
        tableView.backgroundColor = UIConstants.TableViewHeaderBackgroundColor
        let footer = SettingsTableSectionHeaderFooterView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: UIConstants.TableViewHeaderFooterHeight))
        footer.showBottomBorder = false
        tableView.tableFooterView = footer
    }

    override func tableView(tableView: UITableView, cellForRowAtIndexPath indexPath: NSIndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: UITableViewCellStyle.Default, reuseIdentifier: nil)

        if indexPath.section == SectionToggles {
            cell.textLabel?.text = clearables[indexPath.item].clearable.label
            let control = UISwitch()
            control.onTintColor = UIConstants.ControlTintColor
            control.addTarget(self, action: #selector(ClearPrivateDataTableViewController.switchValueChanged(_:)), forControlEvents: UIControlEvents.ValueChanged)
            control.on = toggles[indexPath.item]
            cell.accessoryView = control
            cell.selectionStyle = .None
            control.tag = indexPath.item
        } else {
            assert(indexPath.section == SectionButton)
            cell.textLabel?.text = Strings.SettingsClearPrivateDataClearButton
            cell.textLabel?.textAlignment = NSTextAlignment.Center
            cell.textLabel?.textColor = UIConstants.DestructiveRed
            cell.accessibilityTraits = UIAccessibilityTraitButton
            cell.accessibilityIdentifier = "ClearPrivateData"
            clearButton = cell
        }

        return cell
    }

    override func numberOfSectionsInTableView(tableView: UITableView) -> Int {
        return NumberOfSections
    }

    override func tableView(tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == SectionToggles {
            return clearables.count
        }

        assert(section == SectionButton)
        return 1
    }

    override func tableView(tableView: UITableView, shouldHighlightRowAtIndexPath indexPath: NSIndexPath) -> Bool {
        guard indexPath.section == SectionButton else { return false }

        // Highlight the button only if it's enabled.
        return clearButtonEnabled
    }

    override func tableView(tableView: UITableView, didSelectRowAtIndexPath indexPath: NSIndexPath) {
        guard indexPath.section == SectionButton else { return }

        func clearPrivateData(secondAttempt secondAttempt: Bool = false) -> Deferred<()> {
            let deferred = Deferred<()>()

            let toggles = self.toggles
            self.clearables
                .enumerate()
                .flatMap { (i, pair) in
                    guard toggles[i] else {
                        return nil
                    }

                    log.debug("Clearing \(pair.clearable).")
                    let res = Success()
                    succeed().upon() { _ in // move off main thread
                        pair.clearable.clear().upon() { result in
                            res.fill(result)
                        }
                    }
                    return res
                }
                .allSucceed()
                .upon { result in
                    if !result.isSuccess && !secondAttempt {
                        print("Private data NOT cleared successfully")
                        delay(0.1) {
                            // For some reason, a second attempt seems to always succeed
                            clearPrivateData(secondAttempt: true)
                        }
                        return
                    }

                    if !result.isSuccess {
                        print("Private data NOT cleared after 2 attempts")
                    }

                    self.profile.prefs.setObject(self.toggles, forKey: TogglesPrefKey)

                    dispatch_async(dispatch_get_main_queue()) {
                        // Disable the Clear Private Data button after it's clicked.
                        self.clearButtonEnabled = false
                        self.tableView.deselectRowAtIndexPath(indexPath, animated: true)
                        deferred.fill()
                    }
            }
            return deferred
        }

        getApp().tabManager.removeAll()

        if PrivateBrowsing.singleton.isOn {
            PrivateBrowsing.singleton.exit().upon {
                clearPrivateData().upon {
                    delay(0.5) {
                        PrivateBrowsing.singleton.enter()
                        if #available(iOS 9, *) {
                            getApp().tabManager.selectTab (getApp().tabManager.addTab(nil, isPrivate: true))
                        }
                    }
                }
            }
        } else {
            delay(0.1) { // ensure GC has run
                clearPrivateData().uponQueue(dispatch_get_main_queue()) {
                    // TODO: add API to avoid add/remove
                    getApp().tabManager.removeTab(getApp().tabManager.addTab()!, createTabIfNoneLeft: true)
                }
            }
        }

        #if !BRAVE
            // We have been asked to clear history and we have an account.
            // (Whether or not it's in a good state is irrelevant.)
            if self.toggles[HistoryClearableIndex] && profile.hasAccount() {
                profile.syncManager.hasSyncedHistory().uponQueue(dispatch_get_main_queue()) { yes in
                    // Err on the side of warning, but this shouldn't fail.
                    let alert: UIAlertController
                    if yes.successValue ?? true {
                        // Our local database contains some history items that have been synced.
                        // Warn the user before clearing.
                        alert = UIAlertController.clearSyncedHistoryAlert(clearPrivateData)
                    } else {
                        alert = UIAlertController.clearPrivateDataAlert(clearPrivateData)
                    }
                    self.presentViewController(alert, animated: true, completion: nil)
                    return
                }
            } else {
                let alert = UIAlertController.clearPrivateDataAlert(clearPrivateData)
                self.presentViewController(alert, animated: true, completion: nil)
            }
        #endif
        tableView.deselectRowAtIndexPath(indexPath, animated: false)
    }

    override func tableView(tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        return tableView.dequeueReusableHeaderFooterViewWithIdentifier(SectionHeaderFooterIdentifier) as! SettingsTableSectionHeaderFooterView
    }

    override func tableView(tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return UIConstants.TableViewHeaderFooterHeight
    }

    @objc func switchValueChanged(toggle: UISwitch) {
        toggles[toggle.tag] = toggle.on

        // Dim the clear button if no clearables are selected.
        clearButtonEnabled = toggles.contains(true)
    }
}
