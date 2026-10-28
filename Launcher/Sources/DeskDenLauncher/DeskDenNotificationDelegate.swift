import Foundation
import LauncherCore
@preconcurrency import UserNotifications

extension Notification.Name {
    static let deskdenNotificationActivated=Notification.Name("local.deskden.notification.activated")
    static let deskdenNotificationOpenBudget=Notification.Name("local.deskden.notification.open-budget")
}

/// UNUserNotificationCenter keeps a weak delegate. A single shared instance
/// survives module lifetimes and is never replaced by AI or device services.
@MainActor final class DeskDenNotificationDelegate:NSObject,UNUserNotificationCenterDelegate {
    static let shared=DeskDenNotificationDelegate()
    private override init(){super.init()}
    func install(){UNUserNotificationCenter.current().delegate=self}
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification) async -> UNNotificationPresentationOptions {[.banner,.list,.sound]}
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,didReceive response:UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {return}
        // UN response/userInfo objects stay on the delegate's executor. Extract
        // the bounded String fields before crossing to MainActor.
        let userInfo=response.notification.request.content.userInfo
        var fields:[String:String]=[:]
        for key in ["deskdenRoute","provider","reminderID","detail"] {
            if let value=userInfo[key] as? String,value.count <= 2048 {fields[key]=value}
        }
        guard let target=DeskDenNotificationTarget.decode(fields:fields,requestIdentifier:response.notification.request.identifier) else {return}
        await MainActor.run {NotificationCenter.default.post(name:.deskdenNotificationActivated,object:target)}
    }
}
