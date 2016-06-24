/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Shared

extension BrowserViewController {
    func reloadTab(){
        if homePanelController == nil {
            tabManager.selectedTab?.reload()
        }
    }

    func goBack(){
        if tabManager.selectedTab?.canGoBack == true && homePanelController == nil {
            tabManager.selectedTab?.goBack()
        }
    }
    func goForward(){
        if tabManager.selectedTab?.canGoForward == true && homePanelController == nil {
            tabManager.selectedTab?.goForward()
        }
    }

    func findOnPage(){
        if let tab = tabManager.selectedTab where homePanelController == nil {
            browser(tab, didSelectFindInPageForSelection: "")
        }
    }

    func selectLocationBar() {
        urlBar.browserLocationViewDidTapLocation(urlBar.locationView)
    }

    func newTab() {
        openBlankNewTabAndFocus(isPrivate: PrivateBrowsing.singleton.isOn)
        delay(0.2) {
            self.selectLocationBar()
        }
    }

    func newPrivateTab() {
        openBlankNewTabAndFocus(isPrivate: true)
        delay(0.2) {
            self.selectLocationBar()
        }
    }

    func closeTab() {
        guard let tab = tabManager.selectedTab else { return }
        let priv = tab.isPrivate
        nextOrPrevTabShortcut(isNext: false)
        tabManager.removeTab(tab, createTabIfNoneLeft: !priv)
        if priv && tabManager.privateTabs.count == 0 {
            urlBarDidPressTabs(urlBar)
        }
    }

    private func nextOrPrevTabShortcut(isNext isNext: Bool) {
        guard let tab = tabManager.selectedTab else { return }
        let step = isNext ? 1 : -1
        let tabList: [Browser] = tab.isPrivate ? tabManager.privateTabs : tabManager.tabs
        func wrappingMod(val:Int, mod:Int) -> Int {
            return ((val % mod) + mod) % mod
        }
        assert(wrappingMod(-1, mod: 10) == 9)
        let index = wrappingMod((tabList.indexOf(tab)! + step), mod: tabList.count)
        tabManager.selectTab(tabList[index])
    }

    func nextTab() {
        nextOrPrevTabShortcut(isNext: true)
    }

    func previousTab() {
        nextOrPrevTabShortcut(isNext: false)
    }

    override var keyCommands: [UIKeyCommand]? {
        if #available(iOS 9.0, *) {
            return [
                UIKeyCommand(input: "r", modifierFlags: .Command, action: #selector(BrowserViewController.reloadTab), discoverabilityTitle: Strings.ReloadPageTitle),
                UIKeyCommand(input: "[", modifierFlags: .Command, action: #selector(BrowserViewController.goBack), discoverabilityTitle: Strings.BackTitle),
                UIKeyCommand(input: "]", modifierFlags: .Command, action: #selector(BrowserViewController.goForward), discoverabilityTitle: Strings.ForwardTitle),

                UIKeyCommand(input: "f", modifierFlags: .Command, action: #selector(BrowserViewController.findOnPage), discoverabilityTitle: Strings.FindTitle),
                UIKeyCommand(input: "l", modifierFlags: .Command, action: #selector(BrowserViewController.selectLocationBar), discoverabilityTitle: Strings.SelectLocationBarTitle),
                UIKeyCommand(input: "t", modifierFlags: .Command, action: #selector(BrowserViewController.newTab), discoverabilityTitle: Strings.NewTabTitle),
                UIKeyCommand(input: "p", modifierFlags: [.Command, .Shift], action: #selector(BrowserViewController.newPrivateTab), discoverabilityTitle: Strings.NewPrivateTabTitle),
                UIKeyCommand(input: "w", modifierFlags: .Command, action: #selector(BrowserViewController.closeTab), discoverabilityTitle: Strings.CloseTabTitle),
                UIKeyCommand(input: "\t", modifierFlags: .Control, action: #selector(BrowserViewController.nextTab), discoverabilityTitle: Strings.ShowNextTabTitle),
                UIKeyCommand(input: "\t", modifierFlags: [.Control, .Shift], action: #selector(BrowserViewController.previousTab), discoverabilityTitle: Strings.ShowPreviousTabTitle),
            ]
        } else {
            // Fallback on earlier versions
            return [
                UIKeyCommand(input: "r", modifierFlags: .Command, action: #selector(BrowserViewController.reloadTab)),
                UIKeyCommand(input: "[", modifierFlags: .Command, action: #selector(BrowserViewController.goBack)),
                UIKeyCommand(input: "f", modifierFlags: .Command, action: #selector(BrowserViewController.findOnPage)),
                UIKeyCommand(input: "l", modifierFlags: .Command, action: #selector(BrowserViewController.selectLocationBar)),
                UIKeyCommand(input: "t", modifierFlags: .Command, action: #selector(BrowserViewController.newTab)),
                UIKeyCommand(input: "p", modifierFlags: [.Command, .Shift], action: #selector(BrowserViewController.newPrivateTab)),
                UIKeyCommand(input: "w", modifierFlags: .Command, action: #selector(BrowserViewController.closeTab)),
                UIKeyCommand(input: "\t", modifierFlags: .Control, action: #selector(BrowserViewController.nextTab)),
                UIKeyCommand(input: "\t", modifierFlags: [.Control, .Shift], action: #selector(BrowserViewController.previousTab))
            ]
        }
    }
}