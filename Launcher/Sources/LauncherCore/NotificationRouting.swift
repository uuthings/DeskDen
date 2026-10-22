import Foundation

/// Only these app-owned destinations can be selected by a notification. The
/// payload never carries a URL, executable action or a request to complete data.
public enum FangcunNotificationTarget:Equatable,Sendable {
    case reminder(String?)
    case ai(AIProvider?)
    case networkBudget
    case thermal
    case device

    public static func decode(fields:[String:String],requestIdentifier:String = "")->Self? {
        guard requestIdentifier.count <= 2048 else {return nil}
        if let route=fields["fangcunRoute"] {
            switch route {
            case "calendar":return .reminder(validIdentifier(fields["reminderID"]))
            case "ai":return .ai(fields["provider"].flatMap(AIProvider.init(rawValue:)))
            case "network":return fields["detail"] == "budget" ? .networkBudget:nil
            case "device":return fields["detail"] == "thermal" ? .thermal:.device
            default:return nil
            }
        }
        if fields["reminderID"] != nil {return .reminder(validIdentifier(fields["reminderID"]))}
        if requestIdentifier.hasPrefix(ReminderNotificationPlan.prefix) {
            return .reminder(validIdentifier(String(requestIdentifier.dropFirst(ReminderNotificationPlan.prefix.count))))
        }
        // Historical device alerts had no detail metadata. Open their module
        // rather than guessing whether they referred to temperature or traffic.
        if requestIdentifier.hasPrefix("fangcun-device-") {return .device}
        return nil
    }
    private static func validIdentifier(_ value:String?)->String? {
        guard let value,!value.isEmpty,value.count <= 1024,
              value.unicodeScalars.allSatisfy({!CharacterSet.controlCharacters.contains($0)}) else {return nil}
        return value
    }
}

/// Background operation needs the same service owner regardless of which
/// interface, if any, is shown at launch.
public enum FangcunStartupPresentation:Equatable,Sendable {
    case background,launcher,workbench
    public init(arguments:[String]) {
        if arguments.contains("--background") {self = .background}
        else if arguments.contains("--launcher") || arguments.contains("--material-preview") {self = .launcher}
        else {self = .workbench}
    }
}
