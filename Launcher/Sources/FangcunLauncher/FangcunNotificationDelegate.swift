import Foundation
import LauncherCore
@preconcurrency import UserNotifications

extension Notification.Name {
    static let fangcunNotificationActivated=Notification.Name("local.fangcun.notification.activated")
    static let fangcunNotificationOpenBudget=Notification.Name("local.fangcun.notification.open-budget")
}

/// UNUserNotificationCenter keeps a weak delegate. A single shared instance
/// survives module lifetimes and is never replaced by AI or device services.
@MainActor final class FangcunNotificationDelegate:NSObject,UNUserNotificationCenterDelegate {
    static let shared=FangcunNotificationDelegate()
    private override init(){super.init()}
    func install(){UNUserNotificationCenter.current().delegate=self}
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification) async -> UNNotificationPresentationOptions {[.banner,.list,.sound]}
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,didReceive response:UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {return}
        // UN response/userInfo objects stay on the delegate's executor. Extract
        // the bounded String fields before crossing to MainActor.
        let userInfo=response.notification.request.content.userInfo
        var fields:[String:String]=[:]
        for key in ["fangcunRoute","provider","reminderID","detail"] {
            if let value=userInfo[key] as? String,value.count <= 2048 {fields[key]=value}
        }
        guard let target=FangcunNotificationTarget.decode(fields:fields,requestIdentifier:response.notification.request.identifier) else {return}
        await MainActor.run {NotificationCenter.default.post(name:.fangcunNotificationActivated,object:target)}
    }
}
