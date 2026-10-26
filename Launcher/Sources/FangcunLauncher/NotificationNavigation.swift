import AppKit
import LauncherCore
@preconcurrency import UserNotifications

/// The latest notification waits for an existing draft or permission sheet.
/// Retrying never dismisses an editor or runs the notification's business action.
@MainActor final class WorkbenchNotificationRouter {
    private weak var owner:LauncherController?
    private let center:NotificationCenter
    private let isApplicationActive:()->Bool
    private var observer:NSObjectProtocol?
    private var pending:FangcunNotificationTarget?
    private var retry:Task<Void,Never>?
    init(owner:LauncherController,center:NotificationCenter = .default,isApplicationActive:@escaping ()->Bool = {NSApp.isActive}) {
        self.owner=owner;self.center=center;self.isApplicationActive=isApplicationActive
        observer=center.addObserver(forName:.fangcunNotificationActivated,object:nil,queue:.main){[weak self] note in
            guard let target=note.object as? FangcunNotificationTarget else {return}
            MainActor.assumeIsolated {self?.receive(target)}
        }
    }
    func receive(_ target:FangcunNotificationTarget) {
        guard let owner,!owner.isPreparingToQuit else {return}
        pending=target
        if owner.openNotificationTarget(target,revealBlocked:true) {pending=nil;retry?.cancel();retry=nil;return}
        guard retry == nil else {return}
        retry=Task{[weak self] in
            while !Task.isCancelled {
                do {try await Task.sleep(for:.milliseconds(250))}catch{return}
                guard let self,let owner=self.owner else {return}
                guard !owner.isPreparingToQuit else {self.pending=nil;self.retry=nil;return}
                guard let pending=self.pending else {self.retry=nil;return}
                if self.isApplicationActive(),owner.openNotificationTarget(pending,revealBlocked:false) {self.pending=nil;self.retry=nil;return}
            }
        }
    }
    func stop(){retry?.cancel();retry=nil;pending=nil;if let observer {center.removeObserver(observer);self.observer=nil}}
}

/// A view may not yet be mounted when the route changes. Keep this harmless
/// presentation request until the matching network view consumes it.
@MainActor enum NotificationDetailRequests {
    private static weak var budgetModel:DeviceStatusModel?
    static func requestBudget(for model:DeviceStatusModel){budgetModel=model;NotificationCenter.default.post(name:.fangcunNotificationOpenBudget,object:model)}
    static func consumeBudget(for model:DeviceStatusModel)->Bool {guard budgetModel === model else {return false};budgetModel=nil;return true}
}

@MainActor extension LauncherController {
    /// Creation starts services but never presents or orders the window forward.
    @discardableResult func prepareWorkbenchServices(makeController:((LauncherController)->WorkbenchWindowController)?=nil)->WorkbenchWindowController? {
        guard !isPreparingToQuit else {return nil}
        if let workbenchController {return workbenchController}
        let controller=makeController?(self) ?? WorkbenchWindowController(owner:self)
        workbenchController=controller
        return controller
    }
    func performStartupPresentation(_ presentation:FangcunStartupPresentation,makeController:((LauncherController)->WorkbenchWindowController)?=nil) {
        guard prepareWorkbenchServices(makeController:makeController) != nil else {return}
        switch presentation {case .background:break;case .launcher:show();case .workbench:showWorkbench()}
    }
    @discardableResult func openNotificationTarget(_ target:FangcunNotificationTarget,revealBlocked:Bool=true)->Bool {
        guard !isPreparingToQuit else {return true}
        guard let workbench=prepareWorkbenchServices() else {return true}
        let model=workbench.model
        model.modals.prune()
        let blocked=pickerActive || editorPanel != nil || overlay != nil || hasUnsavedLauncherChanges
            || model.modals.isPresented || workbench.presentationWindow?.attachedSheet != nil
            || model.confirmingQuit || model.calendar.editor != nil || model.ai.dialog != nil
            || model.ai.hasUnsavedPriceChanges
            || model.usagePresentation.editor != nil
        if blocked {
            if revealBlocked {
                if editorPanel != nil || overlay != nil || hasUnsavedLauncherChanges || pickerActive {show()}
                else {workbench.present()}
                model.toast="请先完成当前编辑；之后会打开通知对应内容。"
            }
            return false
        }
        switch target {
        case .ai(let provider):
            showWorkbench(route:.ai)
            guard model.route == .ai else {return false}
            model.usagePresentation.selectedSourceID=nil
            if let provider {model.ai.show(.provider(provider))}
            else {model.ai.showOverview();model.toast="通知中的 AI 账户已不可用，已打开 AI 用量。"}
        case .networkBudget:
            showWorkbench(route:.network)
            guard model.route == .network else {return false}
            model.toast="已打开网络监控，可从流量预算查看当前额度与提醒。"
            NotificationDetailRequests.requestBudget(for:model.device)
        case .thermal:
            showWorkbench(route:.device)
            guard model.route == .device else {return false}
            model.deviceDetail = .thermal
        case .device:
            showWorkbench(route:.device)
            guard model.route == .device else {return false}
            model.deviceDetail=nil;model.toast="已打开设备状态；这条历史提醒没有保存具体读数位置。"
        case .reminder(let identifier):
            showWorkbench(route:.calendar)
            guard model.route == .calendar else {return false}
            model.calendar.showSources=false
            if let identifier,let item=model.calendar.localReminders.first(where:{$0.id == identifier}) {
                if let date=ReminderQueries.displayDate(for:.reminder(item),calendar:model.calendar.displayCalendar){model.calendar.selectDay(date)}
                model.calendar.openReminder(item)
            } else {model.toast=model.calendar.storageError == nil ? "这条本机提醒已删除或不可用，已打开日历与提醒。":"提醒数据暂不可用，原文件已保留；已打开日历与提醒。"}
        }
        return true
    }
}
