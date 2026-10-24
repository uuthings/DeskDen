import AppKit
import SwiftUI
import LauncherCore

/// A genuine key-binding list. It has its own vertical viewport and preserves
/// physical keyboard order; editing still exposes all 38 physical positions.
@MainActor final class LauncherBindingListView:NSScrollView {
    private(set) var rows:[LauncherBindingListRow]=[]
    init(owner:LauncherController,frame:NSRect) {
        super.init(frame:frame)
        drawsBackground=false;borderType = .noBorder;hasVerticalScroller=true;autohidesScrollers=true;scrollerStyle = .overlay
        autoresizingMask=[.width,.height]
        setAccessibilityIdentifier("fc.launcher.bindingList")
        let settings=owner.configuration.settings
        let light=settings.workbenchAppearance == .light || (settings.workbenchAppearance == .system && NSApp.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .aqua)
        let palette=ThemePalette(theme:settings.workbenchTheme,opacity:settings.glassOpacity,light:light)
        let keys=LauncherPresentationPolicy.visibleKeys(settings:settings,bindings:owner.bindings,editing:owner.isEditing)
        let document=FlippedView(frame:NSRect(x:0,y:0,width:frame.width,height:max(frame.height,CGFloat(keys.count)*52+8)))
        document.autoresizingMask=[.width];documentView=document
        for (index,key) in keys.enumerated() {
            let row=LauncherBindingListRow(key:key,binding:owner.bindings[key],editing:owner.isEditing,
                shortcut:owner.configuration.effectiveBindingHotKeys[key]?.title,palette:palette,
                frame:NSRect(x:8,y:4+CGFloat(index)*52,width:max(0,frame.width-16),height:48))
            row.autoresizingMask=[.width]
            row.activate={ [weak owner,weak row] in
                guard let owner,let row else {return}
                if let binding=owner.bindings[key],!owner.isEditing,!row.missing {owner.launch(binding.target)}
                else if owner.bindings[key] == nil {owner.showTypeMenu(key,anchor:row)}
                else {owner.openEditor(key,anchor:row)}
            }
            row.context={ [weak owner,weak row] in if let owner,let row {owner.showKeyMenu(key,anchor:row)} }
            row.remove={ [weak owner] in owner?.removeBinding(key) }
            row.swap={ [weak owner] source,destination in
                guard let owner,owner.isEditing else {return}
                owner.draft?.swap(source,destination);owner.render();owner.toast("位置已交换 · 完成后保存")
            }
            rows.append(row);document.addSubview(row)
        }
        if keys.isEmpty {
            let empty=NSTextField(labelWithString:"没有已绑定的按键，可从设置中的「管理绑定」添加。")
            empty.font = .systemFont(ofSize:12);empty.textColor=palette.nsMuted;empty.alignment = .center
            empty.frame=NSRect(x:20,y:30,width:max(0,frame.width-40),height:24);empty.autoresizingMask=[.width];document.addSubview(empty)
        }
    }
    required init?(coder:NSCoder){fatalError()}
}

@MainActor final class LauncherBindingListRow:ClickableButton {
    let key:String
    let binding:KeyBinding?
    let editing:Bool
    let missing:Bool
    private let shortcut:String?
    private let palette:ThemePalette
    var activate:(()->Void)?
    var context:(()->Void)?
    var remove:(()->Void)?
    var swap:((String,String)->Void)?
    private var hovered=false
    private var dropHighlight=false
    private var initialPoint:NSPoint?
    private var dragged=false
    private var tracking:NSTrackingArea?
    override var isFlipped:Bool {true}
    init(key:String,binding:KeyBinding?,editing:Bool,shortcut:String?,palette:ThemePalette,frame:NSRect) {
        self.key=key;self.binding=binding;self.editing=editing;self.shortcut=shortcut;self.palette=palette
        missing=binding.map{$0.target.kind.isFileSystem && TargetResolver.url(for:$0.target) == nil} ?? false
        super.init(frame:frame)
        isBordered=false;title="";focusRingType = .none;target=self;action=#selector(invoke)
        setAccessibilityLabel("\(key) · \(binding?.title ?? "未绑定")\(missing ? "，目标失效":"")")
        setAccessibilityIdentifier("fc.launcher.bindingList.\(key)")
        toolTip=binding.map{"\(key) · \($0.title)\n\($0.target.location)"} ?? "绑定到 \(key)"
    }
    required init?(coder:NSCoder){fatalError()}
    @objc private func invoke(){activate?()}
    override func updateTrackingAreas(){if let tracking {removeTrackingArea(tracking)};tracking=NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self);addTrackingArea(tracking!);super.updateTrackingAreas()}
    override func mouseEntered(with event:NSEvent){hovered=true;needsDisplay=true}
    override func mouseExited(with event:NSEvent){hovered=false;needsDisplay=true}
    override func rightMouseDown(with event:NSEvent){context?()}
    override func mouseDown(with event:NSEvent){if event.modifierFlags.contains(.control){context?();return};window?.makeFirstResponder(self);initialPoint=event.locationInWindow;dragged=false;isHighlighted=true;needsDisplay=true}
    override func mouseDragged(with event:NSEvent){
        guard editing,let initialPoint else {return}
        if hypot(event.locationInWindow.x-initialPoint.x,event.locationInWindow.y-initialPoint.y)>6 {dragged=true}
        guard dragged else {return}
        for case let row as LauncherBindingListRow in superview?.subviews ?? [] {row.dropHighlight=row.bounds.contains(row.convert(event.locationInWindow,from:nil));row.needsDisplay=true}
    }
    override func mouseUp(with event:NSEvent){
        defer{initialPoint=nil;isHighlighted=false;needsDisplay=true}
        if dragged {
            for case let row as LauncherBindingListRow in superview?.subviews ?? [] {let drop=row.dropHighlight;row.dropHighlight=false;row.needsDisplay=true;if drop {swap?(key,row.key)}}
        } else if bounds.contains(convert(event.locationInWindow,from:nil)) {
            if editing,binding != nil,convert(event.locationInWindow,from:nil).x > bounds.width-40 {remove?()}
            else {activate?()}
        }
    }
    override func keyDown(with event:NSEvent){if event.keyCode == 36 || event.keyCode == 76 {activate?()} else {super.keyDown(with:event)}}
    override func draw(_ dirtyRect:NSRect){
        let plate=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:8,yRadius:8)
        NSColor(palette.control).setFill();plate.fill();NSColor(palette.controlBorder).setStroke();plate.lineWidth=1;plate.stroke()
        if hovered || dropHighlight || isHighlighted || window?.firstResponder === self {NSColor(palette.soft).setFill();plate.fill();if dropHighlight || window?.firstResponder === self {palette.nsAccent.setStroke();plate.stroke()}}
        let keyRect=NSRect(x:12,y:12,width:30,height:24)
        drawText(key,in:keyRect,size:13,color:palette.nsAccent,alignment:.center,weight:.medium)
        if let binding {drawTarget(binding.target,in:NSRect(x:55,y:10,width:28,height:28),normalized:true,opacity:missing ? 0.45:1)}
        else {drawSymbol("plus",in:NSRect(x:61,y:16,width:16,height:16),color:palette.nsMuted)}
        drawText(binding?.title ?? "未绑定",in:NSRect(x:96,y:6,width:max(0,bounds.width-270),height:20),size:12,color:palette.nsText,weight:.medium)
        drawText(missing ? "目标已移动或不可访问":binding?.target.kind.title ?? "点击选择绑定目标",in:NSRect(x:96,y:27,width:max(0,bounds.width-270),height:15),size:11,color:palette.nsMuted)
        if editing,binding != nil {drawSymbol("minus.circle",in:NSRect(x:bounds.width-30,y:16,width:16,height:16),color:NSColor(palette.critical))}
        else if let shortcut {drawText(shortcut,in:NSRect(x:bounds.width-172,y:15,width:156,height:20),size:11,color:palette.nsSecondary,alignment:.right)}
        else if missing {drawSymbol("exclamationmark.triangle",in:NSRect(x:bounds.width-30,y:16,width:16,height:16),color:NSColor(palette.warning))}
    }
}
