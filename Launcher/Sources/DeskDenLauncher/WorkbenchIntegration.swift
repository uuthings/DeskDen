import AppKit
import LauncherCore

extension LauncherController {
    func showWorkbench(route:WorkbenchRoute?=nil,settingsTab:WorkbenchSettingsTab?=nil) {
        guard !isPreparingToQuit else { return }
        guard !pickerActive else {return}
        if editorPanel != nil {requestCloseEditor();if editorPanel != nil {return}}
        closeOverlay(render:false);hide(restore:false)
        topEntryController?.dismissSummary(animated: false)
        if workbenchController == nil {workbenchController=WorkbenchWindowController(owner:self)}
        workbenchController?.present(route:route,settingsTab:settingsTab)
    }
    func showWorkbenchFromTopEntry(originFrame: NSRect? = nil) {
        guard !isPreparingToQuit else { return }
        guard !pickerActive, editorPanel == nil, overlay == nil, !isEditing else { return }
        // A complete workbench is always the same frame-autosaving window,
        // regardless of whether it came from Mini, the menu, Dock or a hotkey.
        // Only the small hover summary remains a temporary accessory surface.
        showWorkbench()
    }
    @objc func workbenchFromMenu() {showWorkbench()}
    @objc func allSettingsFromMenu() {showWorkbench(route:.settings,settingsTab:.general)}
    @discardableResult func setGlobalGlassOpacity(_ value:Double)->Bool {
        guard value.isFinite,(0.50...0.90).contains(value) else {return false}
        let valid=value
        guard valid != configuration.settings.glassOpacity else {return true}
        guard updateSettings({$0.glassOpacity=valid}) else {return false}
        Palette.glassOpacity=valid
        func refresh(_ view:NSView) {
            if let glass=view as? GlassBackgroundView {glass.refreshAppearance()}
            if view is GlassTint {view.needsDisplay=true}
            view.subviews.forEach(refresh)
        }
        for window in NSApp.windows {if let root=window.contentView {refresh(root)}}
        return true
    }
    func showOpacityMenu(anchor:NSView) {
        guard !isPreparingToQuit else { return }
        if editorPanel != nil {requestCloseEditor();if editorPanel != nil {return}}
        closeOverlay(render:false)
        let card=GlobalOpacityMenuView(owner:self)
        presentBindingCard(card,anchor:anchor,centered:false)
        editorPanel?.setAccessibilityLabel("界面不透明度")
        editorPanel?.makeFirstResponder(card.slider)
    }
    func applicationProtectedDataWillBecomeUnavailable(_ notification:Notification) {workbenchController?.model.vault.lock(reason:"系统受保护数据不可用");hide(restore:false)}
}

@MainActor final class GlobalOpacityMenuView:CardView {
    weak var owner:LauncherController?
    let valueLabel=NSTextField(labelWithString:"")
    let slider=NSSlider(value:0.7,minValue:0.5,maxValue:0.9,target:nil,action:nil)
    init(owner:LauncherController) {
        self.owner=owner;super.init(frame:NSRect(x:0,y:0,width:278,height:154))
        radius=20
        let title=owner.label("界面不透明度",x:18,y:16,width:186,height:20,size:13,in:self)
        title.font = .systemFont(ofSize:13,weight:.medium)
        valueLabel.frame=NSRect(x:210,y:16,width:50,height:20);valueLabel.font = .monospacedDigitSystemFont(ofSize:12,weight:.medium)
        valueLabel.textColor=Palette.secondary;valueLabel.alignment = .right;addSubview(valueLabel)
        slider.frame=NSRect(x:16,y:43,width:246,height:24);slider.doubleValue=owner.configuration.settings.glassOpacity
        slider.target=self;slider.action=#selector(changed);slider.isContinuous=true;slider.setAccessibilityLabel("界面不透明度");addSubview(slider)
        let caption=NSTextField(labelWithString:"工作台、启动器与所有浮层即时生效")
        caption.frame=NSRect(x:18,y:77,width:242,height:17);caption.font = .systemFont(ofSize:11);caption.textColor=Palette.muted;addSubview(caption)
        let separator=NSBox(frame:NSRect(x:18,y:104,width:242,height:1));separator.boxType = .separator;addSubview(separator)
        let settings=owner.button("外观与全局设置",symbol:"gearshape",rect:NSRect(x:10,y:112,width:258,height:32),in:self) { [weak owner] in
            owner?.showWorkbench(route:.settings,settingsTab:.general)
        }
        settings.fontSize=12
        updateLabel()
    }
    required init?(coder:NSCoder) {fatalError()}
    @objc private func changed() {
        let value=(slider.doubleValue*100).rounded()/100
        if owner?.setGlobalGlassOpacity(value) != true {slider.doubleValue=owner?.configuration.settings.glassOpacity ?? 0.7}
        updateLabel()
    }
    private func updateLabel(){valueLabel.stringValue="\(Int((slider.doubleValue*100).rounded()))%"}
}
