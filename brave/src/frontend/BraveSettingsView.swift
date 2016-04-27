/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#if !NO_FABRIC
    import Crashlytics
#endif
import Shared
import OnePasswordExtension

class BraveSettingsView : AppSettingsTableViewController {

    static var cachedIs3rdPartyPasswordManagerInstalled = false

    var debugToggleItemToTriggerCrashCount = 0

    override func tableView(tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        if section != 2 {
            return nil
        }

        let footerView = InsetLabel(frame: CGRectMake(0, 0, tableView.frame.size.width, 40))
        footerView.leftInset = CGFloat(20)
        footerView.rightInset = CGFloat(10)
        footerView.numberOfLines = 0
        footerView.font = UIFont.boldSystemFontOfSize(13)

        if BraveSettingsView.isAllBraveShieldPrefsOff {
            footerView.text = "The Brave Shield button is disabled when all settings are off."
            return footerView
        } else if BraveApp.isBraveButtonBypassingFilters {
            footerView.text = "Brave Shields are currently down. These settings only take effect when shields are up."
            return footerView
        }

        return nil
    }

    override func tableView(tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        if section != 2 || !(BraveApp.isBraveButtonBypassingFilters || BraveSettingsView.isAllBraveShieldPrefsOff) {
            return 0
        }
        return 40.0
    }

    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(self)
    }

    let SEL_prefsChanged = "prefsChanged:"
    static var isAllBraveShieldPrefsOff = false
    @objc func prefsChanged(notification: NSNotification) {
        BraveSettingsView.isAllBraveShieldPrefsOff = BraveApp.isAllBraveShieldPrefsOff()
        delay(0.1) {
            self.tableView.reloadData()
        }
    }

    override func generateSettings() -> [SettingSection] {
        BraveSettingsView.isAllBraveShieldPrefsOff = BraveApp.isAllBraveShieldPrefsOff()

        NSNotificationCenter.defaultCenter().removeObserver(self)
        NSNotificationCenter.defaultCenter().addObserver(self, selector:NSSelectorFromString(SEL_prefsChanged), name: NSUserDefaultsDidChangeNotification, object: nil)

        let prefs = profile.prefs
        var generalSettings = [
            SearchSetting(settings: self),
            BoolSetting(prefs: prefs, prefKey: BraveUX.PrefKeyIsToolbarHidingEnabled , defaultValue: true, titleText: "Hide toolbar when scrolling", statusText: nil, settingDidChange:  { value in
                BraveScrollController.hideShowToolbarEnabled = value

                // Hidden way to trigger a crash for testing
                if (self.debugToggleItemToTriggerCrashCount > 4) {
                    UIAlertView(title: "Trigger a crash for testing", message: "Force a crash?", delegate: self, cancelButtonTitle: "Cancel", otherButtonTitles: "OK").show()
                    self.debugToggleItemToTriggerCrashCount = 0
                } else {
                    self.debugToggleItemToTriggerCrashCount += 1
                }
            }),
            BoolSetting(prefs: prefs, prefKey: "saveLogins", defaultValue: true,
                titleText: NSLocalizedString("Save Logins", comment: "Setting to enable the built-in password manager"))


            //            BoolSetting(prefs: prefs, prefKey: "blockPopups", defaultValue: true,
            //                titleText: NSLocalizedString("Block Pop-up Windows", comment: "Block pop-up windows setting")),
        ]

        #if !DISABLE_THIRD_PARTY_PASSWORD_SNACKBAR
            if BraveSettingsView.cachedIs3rdPartyPasswordManagerInstalled {
                generalSettings.append(ThirdPartyPasswordManagerSetting(profile: self.profile))
            }

            BraveApp.is3rdPartyPasswordManagerInstalled(refreshLookup: true).upon {
                result in
                if result == BraveSettingsView.cachedIs3rdPartyPasswordManagerInstalled {
                    return
                }
                BraveSettingsView.cachedIs3rdPartyPasswordManagerInstalled = result

                // TODO: if PW manager is removed, settings must be opening a 2nd time for setting to disappear.
                if result {
                    ensureMainThread {
                        generalSettings.append(ThirdPartyPasswordManagerSetting(profile: self.profile))
                        self.settings[0] = SettingSection(title: NSAttributedString(string: NSLocalizedString("General", comment: "General settings section title")), children: generalSettings)
                        let range = NSMakeRange(0, 1)
                        let section = NSIndexSet(indexesInRange: range)
                        self.tableView.reloadSections(section, withRowAnimation: .Automatic)
                    }
                }
            }
        #endif


        settings += [
            SettingSection(title: NSAttributedString(string: NSLocalizedString("General", comment: "General settings section title")), children: generalSettings),
            SettingSection(title: NSAttributedString(string: NSLocalizedString("Privacy", comment: "Privacy settings section title")), children:
                [ClearPrivateDataSetting(settings: self), CookieSetting(profile: self.profile)]

            ),
            SettingSection(title: NSAttributedString(string: NSLocalizedString("Brave Shield Settings", comment: "Section title for adbblock, tracking protection, HTTPS-E, and cookies")), children:
                [BoolSetting(prefs: prefs, prefKey: AdBlocker.prefKeyAdBlockOn, defaultValue: true, titleText: "Block Ads"),
                    BoolSetting(prefs: prefs, prefKey: TrackingProtection.prefKeyTrackingProtectionOn, defaultValue: true, titleText: "Tracking Protection"),
                    BoolSetting(prefs: prefs, prefKey: HttpsEverywhere.prefKeyHttpsEverywhereOn, defaultValue: true, titleText: "HTTPS Everywhere"),
                    BoolSetting(prefs: prefs, prefKey: SafeBrowsing.prefKey, defaultValue: true, titleText: "Block Phishing and Malware")
                ])]

        //#if !DISABLE_INTRO_SCREEN
        settings += [
            SettingSection(title: NSAttributedString(string: NSLocalizedString("Support", comment: "Support section title")), children: [
                ShowIntroductionSetting(settings: self),
                BraveSupportLinkSetting(),
                BravePrivacyPolicySetting(), BraveTermsOfUseSetting(),
                ])]
        //#endif
        settings += [
            SettingSection(title: NSAttributedString(string: NSLocalizedString("About", comment: "About settings section title")), children: [
                VersionSetting(settings: self),
                ])
        ]
        return settings
    }
}

extension BraveSettingsView : UIAlertViewDelegate {
    func alertView(alertView: UIAlertView, didDismissWithButtonIndex buttonIndex: Int) {
        if buttonIndex == alertView.cancelButtonIndex {
            return
        }
        #if !NO_FABRIC
            Crashlytics.sharedInstance().crash()
        #endif
    }
}

// Opens the search settings pane
class ThirdPartyPasswordManagerSetting: PicklistSettingMainItem<String> {

    static var currentSetting: (displayName: String, cellLabel: String, prefId: Int)?

    static let _prefName = kPrefName3rdPartyPasswordShortcutEnabled
    static let _options =  [
        Choice<String> { ThirdPartyPasswordManagers.UseBuiltInInstead },
        Choice<String> { ThirdPartyPasswordManagers.OnePassword },
        Choice<String> { ThirdPartyPasswordManagers.LastPass }
    ]

    static func setupOnAppStart() {
        let current = BraveApp.getPrefs()?.intForKey(_prefName) ?? 0
        switch Int(current) {
        case ThirdPartyPasswordManagers.OnePassword.prefId:
            currentSetting = ThirdPartyPasswordManagers.OnePassword
        case ThirdPartyPasswordManagers.LastPass.prefId:
            currentSetting = ThirdPartyPasswordManagers.LastPass
        default:
            currentSetting = ThirdPartyPasswordManagers.UseBuiltInInstead
        }
    }

    init(profile: Profile) {
        super.init(profile: profile, displayName: "", prefName: ThirdPartyPasswordManagerSetting._prefName, options: ThirdPartyPasswordManagerSetting._options)
    }

    override func picklistSetting(setting: PicklistSettingOptionsView, pickedOptionId: Int) {
        super.picklistSetting(setting, pickedOptionId: pickedOptionId)
        ThirdPartyPasswordManagerSetting.setupOnAppStart()
    }

    override var title: NSAttributedString? {
        return NSAttributedString(string: NSLocalizedString("3rd-party password manager", comment: "Setting to enable the built-in password manager"), attributes: [NSForegroundColorAttributeName: UIConstants.TableViewRowTextColor, NSFontAttributeName: UIFont.systemFontOfSize(14)])
    }
}


// Opens the search settings pane
class CookieSetting: PicklistSettingMainItem<UInt> {
    static let _prefName = "braveAcceptCookiesPref"
    static let _options =  [
        Choice<UInt> { (displayName: "Block 3rd party cookies", object: UInt(NSHTTPCookieAcceptPolicy.OnlyFromMainDocumentDomain.rawValue), optionId: 0) },
        Choice<UInt> { (displayName: "Block all cookies", object: UInt(NSHTTPCookieAcceptPolicy.Never.rawValue), optionId: 1) },
        Choice<UInt> { (displayName: "Don't block cookies", object: UInt( NSHTTPCookieAcceptPolicy.Always.rawValue), optionId: 2) }
    ]

    static func setPolicyFromOptionId(optionId: Int) {
        for option in _options {
            if option.item().optionId == optionId {
                NSHTTPCookieStorage.sharedHTTPCookieStorage().cookieAcceptPolicy = NSHTTPCookieAcceptPolicy.init(rawValue: option.item().object)!
            }
        }
    }

    static func setupOnAppStart() {
        let current = BraveApp.getPrefs()?.intForKey(_prefName) ?? 0
        setPolicyFromOptionId(Int(current))
    }

    init(profile: Profile) {
        super.init(profile: profile, displayName: "Cookie Control", prefName: CookieSetting._prefName, options: CookieSetting._options)
    }

    override func picklistSetting(setting: PicklistSettingOptionsView, pickedOptionId: Int) {
        super.picklistSetting(setting, pickedOptionId: pickedOptionId)
        CookieSetting.setPolicyFromOptionId(pickedOptionId)
    }
}

// Clear all stored passwords. This will clear SQLite storage and the system shared credential storage.
class PasswordsClearable: Clearable {
    let profile: Profile
    init(profile: Profile) {
        self.profile = profile
    }

    var label: String {
        return NSLocalizedString("Saved Logins", tableName: "ClearPrivateData", comment: "Settings item for clearing passwords and login data")
    }

    func clear() -> Success {
        // Clear our storage
        return profile.logins.removeAll() >>== { res in
            let storage = NSURLCredentialStorage.sharedCredentialStorage()
            let credentials = storage.allCredentials
            for (space, credentials) in credentials {
                for (_, credential) in credentials {
                    storage.removeCredential(credential, forProtectionSpace: space)
                }
            }
            return succeed()
        }
    }
}

class BraveSupportLinkSetting: Setting{
    override var title: NSAttributedString? {
        return NSAttributedString(string: NSLocalizedString("Report a bug", comment: "Show mail composer to report a bug."), attributes: [NSForegroundColorAttributeName: UIConstants.TableViewRowTextColor])
    }


    override func onClick(navigationController: UINavigationController?) {
        UIApplication.sharedApplication().openURL(NSURL(string: "mailto:support+ios@brave.com")!)
    }
}

class BravePrivacyPolicySetting: Setting {
    override var title: NSAttributedString? {
        return NSAttributedString(string: NSLocalizedString("Privacy Policy", comment: "Show Brave Browser Privacy Policy page from the Privacy section in the settings."), attributes: [NSForegroundColorAttributeName: UIConstants.TableViewRowTextColor])
    }

    override var url: NSURL? {
        return NSURL(string: "https://www.brave.com/privacy_ios")
    }

    override func onClick(navigationController: UINavigationController?) {
        setUpAndPushSettingsContentViewController(navigationController)
    }
}

class BraveTermsOfUseSetting: Setting {
    override var title: NSAttributedString? {
        return NSAttributedString(string: NSLocalizedString("Terms of Use", comment: "Show Brave Browser TOS page from the Privacy section in the settings."), attributes: [NSForegroundColorAttributeName: UIConstants.TableViewRowTextColor])
    }

    override var url: NSURL? {
        return NSURL(string: "https://www.brave.com/terms_of_use")
    }

    override func onClick(navigationController: UINavigationController?) {
        setUpAndPushSettingsContentViewController(navigationController)
    }
}



