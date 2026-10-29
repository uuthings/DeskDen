import AppKit
import SwiftUI
import LauncherCore

struct CalendarReminderEditor:View {
    @ObservedObject var model:CalendarModel
    let initial:CalendarReminderDraft
    @State private var draft:CalendarReminderDraft
    @State private var confirmDelete=false
    @State private var confirmDiscard=false
    @State private var showCountingRule=false
    @State private var notesHeight:CGFloat=48
    @FocusState private var titleFocused:Bool
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.workbenchModals) private var modals
    init(model:CalendarModel,initial:CalendarReminderDraft){self.model=model;self.initial=initial;_draft=State(initialValue:initial)}
    private var writable:Bool {draft.creating || draft.item.isWritable}
    private var destinationError:String? {
        guard draft.creating,draft.item.origin == .system else {return nil}
        guard model.systemRemindersAvailable else {return "系统提醒事项连接或权限已关闭。请重新接入，或明确选择仅保存在本机。"}
        guard !model.writableCalendars.isEmpty else {return "系统没有可写入的提醒列表。请在提醒事项中创建列表，或明确选择仅保存在本机。"}
        return model.reminderDestinationAvailable(for:draft) ? nil:"原提醒列表已不可用，请重新选择一个系统列表。"
    }
    private var destinationOptions:[(value:String,title:String)] {
        (model.systemRemindersAvailable ? model.writableCalendars.map{(value:"system:"+$0.id,title:"提醒事项 · "+$0.title)}:[])
            + [(value:"local",title:"仅保存在方寸本机")]
    }
    private var destination:Binding<String> {
        Binding(get:{draft.item.origin == .local ? "local":"system:"+(draft.item.calendarID ?? "")},set:{value in
            if value == "local" {draft.item.origin = .local;draft.item.calendarID=nil;draft.item.calendarName=nil}
            else if let calendar=model.writableCalendars.first(where:{"system:"+$0.id == value}) {
                draft.item.origin = .system;draft.item.calendarID=calendar.id;draft.item.calendarName=calendar.title
            }
        })
    }
    private var anchorLabel:String {
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"zh_CN")
        formatter.calendar=draft.calendar;formatter.timeZone=draft.calendar.timeZone;formatter.dateFormat="M月d日"
        return formatter.string(from:draft.deadlineAnchor)
    }
    private var deadlineError:String? {
        do {_ = try draft.resolvedDeadline();return nil} catch {return error.localizedDescription}
    }
    private var deadlineSummary:String {
        guard draft.deadlineMode != .none else {return "长期待办，没有任何期限限制"}
        guard let date=try? draft.resolvedDeadline() else {return "请调整期限设置"}
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"zh_CN")
        formatter.calendar=draft.calendar;formatter.timeZone=draft.calendar.timeZone
        formatter.dateFormat="M月d日 EEEE"
        var summary=formatter.string(from:date)+" 截止"
        if draft.deadlineMode == .days {
            summary += " · "+draft.countingRule.daysBasis.title
            if draft.countingRule.skipHolidays {summary += "，跳过节假日"}
            if draft.countingRule.includeMakeupWorkdays {summary += "，计入调休上班日"}
        }
        return summary
    }
    var body:some View {
        CalendarDialog(title:initial.creating ? "新建待办":"编辑待办",dismiss:cancel,width:640) {
            TextField("要完成什么？",text:$draft.item.title)
                .textFieldStyle(.plain).font(.system(size:12)).padding(.horizontal,10).frame(height:32)
                .background(palette.control,in:RoundedRectangle(cornerRadius:8))
                .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(palette.controlBorder,lineWidth:1))
                .focused($titleFocused).disabled(!writable)
                .accessibilityLabel("待办标题").accessibilityIdentifier("fc.calendar.editor.title")
            deadlineSection
            destinationSection
            HStack(alignment:.top,spacing:12) {
                Text("备注").font(.system(size:12)).frame(width:48,alignment:.leading).padding(.top,8)
                CalendarNotesEditor(text:$draft.item.notes,height:$notesHeight).frame(height:notesHeight)
                    .background(palette.control,in:RoundedRectangle(cornerRadius:8))
                    .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(palette.controlBorder,lineWidth:1))
                    .clipShape(RoundedRectangle(cornerRadius:8)).disabled(!writable)
            }
            notificationSection
            if !writable {Text("这个系统提醒列表为只读。").font(.system(size:11)).foregroundStyle(palette.warning)}
            if let error=model.errorMessage {Text(error).font(.system(size:11)).foregroundStyle(palette.critical).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("fc.calendar.editor.inline-error")}
        } actions:{
            if !initial.creating && writable {Button("删除"){confirmDelete=true}.buttonStyle(WBButtonStyle(destructive:true))}
            Spacer()
            Button("取消",action:cancel).buttonStyle(WBButtonStyle()).keyboardShortcut(.cancelAction)
            Button(initial.creating ? "创建待办":"保存修改"){
                guard WBEditableComboSurface.commitActive(in:modals?.hostWindow) else {model.errorMessage="请检查日期与时间中的输入。";return}
                modals?.hostWindow?.makeFirstResponder(nil)
                Task {_=await model.saveDraft(draft)}
            }.buttonStyle(WBButtonStyle(primary:true)).keyboardShortcut(.return,modifiers:.command)
                .disabled(!writable || model.isWorking || destinationError != nil || deadlineError != nil)
                .accessibilityIdentifier("fc.calendar.editor.save")
        }.onAppear{titleFocused=true;model.errorMessage=nil}.onChange(of:model.editorCloseRequest){_,_ in cancel()}
            .onChange(of:model.writableCalendars){_,calendars in
                if draft.creating,draft.item.origin == .system,draft.item.calendarID == nil,let calendar=calendars.first {
                    draft.item.calendarID=calendar.id;draft.item.calendarName=calendar.title
                }
            }
            .workbenchModal(isPresented:$showCountingRule,width:480) {
                CalendarCountingRuleEditor(initial:draft.countingRule,dismiss:{showCountingRule=false}) {rule in
                    draft.countingRule=rule;showCountingRule=false
                }
            }
            .workbenchModal(isPresented:$confirmDiscard){CalendarDiscardDialog {confirmDiscard=false} discard:{confirmDiscard=false;model.cancelEditor()}}
            .workbenchModal(isPresented:$confirmDelete){CalendarDeleteDialog(model:model,item:initial.item,dismiss:{confirmDelete=false})}
    }
    private var deadlineSection:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:12) {
                CalendarDeadlineModes(selection:$draft.deadlineMode).frame(width:240)
                    .accessibilityElement(children:.contain)
                    .accessibilityIdentifier("fc.calendar.editor.deadline-mode")
                Group {
                    switch draft.deadlineMode {
                    case .none:Spacer(minLength:0)
                    case .date:
                        WBDateInput("截止日期",selection:$draft.date,components:.date,calendar:draft.calendar)
                            .frame(maxWidth:.infinity).frame(height:32)
                            .accessibilityIdentifier("fc.calendar.editor.deadline-date")
                    case .days:
                        HStack(spacing:8) {
                            TextField("10",text:$draft.deadlineDaysText)
                                .textFieldStyle(.plain).font(.system(size:12).monospacedDigit()).multilineTextAlignment(.center)
                                .padding(.horizontal,8).frame(width:64,height:32)
                                .background(palette.control,in:RoundedRectangle(cornerRadius:8))
                                .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(palette.controlBorder,lineWidth:1))
                                .accessibilityLabel("指定天数").accessibilityIdentifier("fc.calendar.editor.deadline-days")
                            Text("天内").font(.system(size:12)).fixedSize()
                            Button {modals?.hostWindow?.makeFirstResponder(nil);showCountingRule=true} label:{Image(systemName:"gearshape")}
                                .buttonStyle(WBIconButtonStyle(size:32)).accessibilityLabel("计日设置")
                                .accessibilityIdentifier("fc.calendar.editor.counting-settings")
                            Spacer(minLength:0)
                        }
                    }
                }
            }.disabled(!writable)
            Text(deadlineSummary).font(.system(size:11))
                .foregroundStyle(draft.deadlineMode == .none ? palette.muted:palette.accent)
                .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("fc.calendar.editor.deadline-summary")
            if let deadlineError {
                Text(deadlineError).font(.system(size:11)).foregroundStyle(palette.critical).fixedSize(horizontal:false,vertical:true)
                    .accessibilityIdentifier("fc.calendar.editor.deadline-error")
            }
            if draft.hasDate {
                HStack(spacing:12) {
                    Toggle("指定时间",isOn:$draft.hasTime).toggleStyle(.checkbox).clickableCursor().font(.system(size:12))
                    if draft.hasTime {
                        WBDateInput("截止时间",selection:$draft.time,components:.time,calendar:draft.calendar).frame(width:156,height:32)
                    } else {
                        Text("可留空，只设截止日期").font(.system(size:11)).foregroundStyle(palette.muted)
                    }
                    Spacer(minLength:0)
                }.disabled(!writable)
            }
        }.environment(\.calendar,draft.calendar).environment(\.timeZone,draft.calendar.timeZone)
    }
    private var destinationSection:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:12) {
                Text("保存到").font(.system(size:12)).fixedSize().frame(width:48,alignment:.leading)
                if draft.creating {
                    WBSelect("选择提醒列表",selection:destination,options:destinationOptions).accessibilityIdentifier("fc.calendar.editor.destination")
                } else {
                    Text(draft.item.sourceTitle).font(.system(size:12)).foregroundStyle(palette.secondary)
                        .padding(.horizontal,10).frame(maxWidth:.infinity,minHeight:32,alignment:.leading)
                        .background(palette.soft,in:RoundedRectangle(cornerRadius:8))
                }
            }
            if draft.creating && !model.systemRemindersAvailable {
                HStack(spacing:10) {
                    Text("接入后可直接保存到系统提醒事项。").font(.system(size:11)).foregroundStyle(palette.muted)
                    Spacer(minLength:0)
                    Button("接入提醒事项") {Task {
                        await model.connect(reminders:true)
                        if model.systemRemindersAvailable {
                            let calendar=model.writableCalendars.first
                            draft.item.origin = .system;draft.item.calendarID=calendar?.id;draft.item.calendarName=calendar?.title
                        }
                    }}.buttonStyle(WBButtonStyle(compact:true)).disabled(model.isWorking)
                        .accessibilityIdentifier("fc.calendar.editor.connect-reminders")
                }
            }
            if let destinationError {
                Text(destinationError).font(.system(size:11)).foregroundStyle(palette.warning).fixedSize(horizontal:false,vertical:true)
                    .accessibilityIdentifier("fc.calendar.editor.destination-error")
            }
        }
    }
    private var notificationSection:some View {
        VStack(alignment:.leading,spacing:6) {
            if draft.item.origin == .local {
                Toggle("到时提醒我",isOn:$draft.item.notificationsEnabled).toggleStyle(.checkbox).clickableCursor().font(.system(size:12)).disabled(!writable)
                Text("设置日期和时间后发送本机通知。"+(model.preferences.notificationsEnabled && model.notificationAccess == .granted ? "":"本机通知尚未开启，可在来源中管理。"))
                    .font(.system(size:11)).foregroundStyle(palette.muted).fixedSize(horizontal:false,vertical:true)
            } else {
                Text("通知由系统提醒事项管理，方寸不重复发送。").font(.system(size:11)).foregroundStyle(palette.muted)
            }
            if draft.deadlineMode == .days {
                Text("从 "+anchorLabel+" 起算，不计当天；保存后截止日期保持不变。").font(.system(size:11)).foregroundStyle(palette.muted)
            }
        }
    }
    private func cancel(){guard !model.isWorking else{return};modals?.hostWindow?.makeFirstResponder(nil);if draft != initial {confirmDiscard=true}else{model.cancelEditor()}}
}

private struct CalendarDeadlineModes:View {
    @Binding var selection:ReminderDeadlineMode
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        HStack(spacing:2) {
            ForEach(ReminderDeadlineMode.allCases) {mode in
                Button {selection=mode} label:{
                    Text(mode.title).font(.system(size:12)).foregroundStyle(selection == mode ? palette.text:palette.secondary)
                        .frame(maxWidth:.infinity).frame(height:28)
                }.buttonStyle(WBSelectableButtonStyle(selected:selection == mode,cornerRadius:6,showsBorder:false))
                    .accessibilityAddTraits(selection == mode ? .isSelected:[])
                    .accessibilityIdentifier("fc.calendar.editor.mode."+mode.rawValue)
            }
        }.padding(2).frame(height:32).background(palette.soft,in:RoundedRectangle(cornerRadius:8))
    }
}

private struct CalendarCountingRuleEditor:View {
    let initial:ReminderCountingRule
    let dismiss:()->Void
    let apply:(ReminderCountingRule)->Void
    @State private var rule:ReminderCountingRule
    @Environment(\.workbenchPalette) private var palette
    init(initial:ReminderCountingRule,dismiss:@escaping()->Void,apply:@escaping(ReminderCountingRule)->Void) {
        self.initial=initial;self.dismiss=dismiss;self.apply=apply;_rule=State(initialValue:initial)
    }
    var body:some View {
        CalendarDialog(title:"计日设置",dismiss:dismiss,width:480) {
            VStack(alignment:.leading,spacing:12) {
                Text("哪些日子计入天数？").font(.system(size:12))
                HStack(spacing:8) {
                    ForEach(ReminderDayBasis.allCases,id:\.self) {basis in
                        Button {
                            rule.daysBasis=basis
                            if basis == .everyday {rule.includeMakeupWorkdays=false}
                        } label:{
                            Text(basis.title).font(.system(size:12)).frame(maxWidth:.infinity).frame(height:32)
                        }.buttonStyle(WBSelectableButtonStyle(selected:rule.daysBasis == basis))
                            .background(palette.soft,in:RoundedRectangle(cornerRadius:8))
                            .accessibilityAddTraits(rule.daysBasis == basis ? .isSelected:[])
                            .accessibilityIdentifier("fc.calendar.counting.basis."+basis.rawValue)
                    }
                }
                Toggle("跳过节假日",isOn:$rule.skipHolidays).toggleStyle(.checkbox).clickableCursor().font(.system(size:12))
                    .accessibilityIdentifier("fc.calendar.counting.skip-holidays")
                Toggle("计入调休上班日",isOn:$rule.includeMakeupWorkdays).toggleStyle(.checkbox).clickableCursor().font(.system(size:12))
                    .disabled(rule.daysBasis == .everyday)
                    .accessibilityIdentifier("fc.calendar.counting.include-makeup")
                Text("节假日与调休使用中国大陆官方安排。未收录的年份会提示你调整设置，不会自动按普通工作日计算。")
                    .font(.system(size:11)).foregroundStyle(palette.muted).fixedSize(horizontal:false,vertical:true)
            }
        } actions:{
            Spacer();Button("取消",action:dismiss).buttonStyle(WBButtonStyle()).keyboardShortcut(.cancelAction)
            Button("应用"){apply(rule)}.buttonStyle(WBButtonStyle(primary:true)).keyboardShortcut(.return,modifiers:.command)
                .accessibilityIdentifier("fc.calendar.counting.apply")
        }
    }
}

/// Notes grow from two to six complete lines, then use the shared overlay-scroll behavior.
private struct CalendarNotesEditor:NSViewRepresentable {
    @Binding var text:String
    @Binding var height:CGFloat
    @Environment(\.isEnabled) private var enabled
    @Environment(\.workbenchPalette) private var palette
    func makeCoordinator()->Coordinator {Coordinator(text:$text,height:$height)}
    func makeNSView(context:Context)->CalendarNotesScrollView {
        let scroll=CalendarNotesScrollView()
        scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=false
        scroll.autohidesScrollers=true;scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder;scroll.drawsBackground=false
        scroll.setAccessibilityIdentifier("fc.calendar.editor.notes")
        let editor=NSTextView(frame:NSRect(x:0,y:0,width:480,height:48))
        editor.isRichText=false;editor.importsGraphics=false;editor.allowsUndo=true
        editor.font = .systemFont(ofSize:12);editor.drawsBackground=false
        let paragraph=NSMutableParagraphStyle();paragraph.minimumLineHeight=16;paragraph.maximumLineHeight=16
        editor.defaultParagraphStyle=paragraph
        editor.typingAttributes=[.font:NSFont.systemFont(ofSize:12),.paragraphStyle:paragraph]
        editor.textContainerInset=NSSize(width:10,height:8)
        editor.textContainer?.lineFragmentPadding=0;editor.textContainer?.widthTracksTextView=true
        editor.textContainer?.containerSize=NSSize(width:480,height:CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable=true;editor.isHorizontallyResizable=false
        editor.autoresizingMask=[.width];editor.minSize=NSSize(width:0,height:0)
        editor.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("备注");editor.setAccessibilityIdentifier("fc.calendar.editor.notes.text")
        editor.delegate=context.coordinator;scroll.documentView=editor
        scroll.didLayout={ [weak editor,weak coordinator=context.coordinator] in
            guard let editor else{return};coordinator?.measure(editor)
        }
        return scroll
    }
    func updateNSView(_ scroll:CalendarNotesScrollView,context:Context) {
        context.coordinator.text=$text;context.coordinator.height=$height
        guard let editor=scroll.documentView as? NSTextView else {return}
        if editor.string != text && !editor.hasMarkedText() {
            editor.string=text
            let paragraph=NSMutableParagraphStyle();paragraph.minimumLineHeight=16;paragraph.maximumLineHeight=16
            editor.textStorage?.addAttributes([.font:NSFont.systemFont(ofSize:12),.paragraphStyle:paragraph],range:NSRange(location:0,length:(text as NSString).length))
        }
        editor.isEditable=enabled;editor.isSelectable=true
        editor.textColor=palette.nsText.withAlphaComponent(enabled ? 1:0.45);editor.insertionPointColor=palette.nsText
        scroll.scrollerStyle = .overlay;scroll.autohidesScrollers=true
        scroll.scrollerKnobStyle=palette.light ? .dark:.light
        scroll.scrollerInsets=NSEdgeInsets(top:0,left:0,bottom:0,right:0)
        context.coordinator.measure(editor)
    }
    @MainActor final class Coordinator:NSObject,NSTextViewDelegate {
        var text:Binding<String>
        var height:Binding<CGFloat>
        private var pendingHeight:CGFloat?
        init(text:Binding<String>,height:Binding<CGFloat>){self.text=text;self.height=height}
        func textDidChange(_ notification:Notification) {
            guard let editor=notification.object as? NSTextView else{return}
            text.wrappedValue=editor.string;measure(editor)
        }
        func measure(_ editor:NSTextView) {
            guard let manager=editor.layoutManager,let container=editor.textContainer else{return}
            manager.ensureLayout(for:container)
            let used=manager.usedRect(for:container)
            let last=manager.extraLineFragmentTextContainer === container ? manager.extraLineFragmentRect.maxY:0
            let lineHeight:CGFloat=16
            let contentHeight=max(used.maxY,last,lineHeight)
            let next=min(112,max(48,ceil(contentHeight/lineHeight)*lineHeight+16))
            guard abs(height.wrappedValue-next)>0.5,pendingHeight != next else{return}
            pendingHeight=next
            DispatchQueue.main.async { [weak self] in
                guard let self,self.pendingHeight == next else{return}
                self.pendingHeight=nil;self.height.wrappedValue=next
            }
        }
    }
}
private final class CalendarNotesScrollView:NSScrollView {
    var didLayout:(()->Void)?
    override var scrollerStyle:NSScroller.Style {
        didSet {if scrollerStyle != .overlay {scrollerStyle = .overlay}}
    }
    override func layout() {super.layout();didLayout?()}
}
