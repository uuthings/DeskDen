import Foundation

public enum WorkbenchRoute:String,Codable,CaseIterable,Sendable {
    case overview,device,health,calendar,ai,network,vault,cards,settings
    public var title:String {
        switch self { case .overview:"首页";case .device:"设备状态";case .health:"体检中心";case .calendar:"日历与提醒";case .ai:"AI 用量";case .network:"网络监控";case .vault:"私密空间";case .cards:"桌面组件";case .settings:"设置" }
    }
    public var symbol:String {
        switch self { case .overview:"rectangle.split.2x2";case .device:"waveform.path.ecg";case .health:"heart.text.square";case .calendar:"calendar";case .ai:"chart.bar.xaxis";case .network:"arrow.up.arrow.down";case .vault:"lock";case .cards:"square.grid.2x2";case .settings:"slider.horizontal.3" }
    }
}
public enum DesktopCardKind:String,Codable,CaseIterable,Sendable {
    case ai,today,device
    public var title:String { switch self { case .ai:"AI 用量";case .today:"今日安排";case .device:"这台 Mac" } }
    public var symbol:String { switch self { case .ai:"chart.bar.xaxis";case .today:"calendar";case .device:"waveform.path.ecg" } }
}
public struct DesktopCardPreference:Codable,Equatable,Identifiable,Sendable {
    public var id:DesktopCardKind
    public var visible=false
    public var floating=false
    public var small=false
    public var locked=false
    public var clickThrough=false
    public var source="both"
    public var x:Double?
    public var y:Double?
    public init(id:DesktopCardKind) { self.id=id }
}
public struct WorkbenchPreferences:Codable,Equatable,Sendable {
    public var schemaVersion=1
    public var sampleInterval:Double=2
    public var menuBarVisible=true
    public var cards=DesktopCardKind.allCases.map { DesktopCardPreference(id:$0) }
    public init() {}
    public func validate() throws {
        guard schemaVersion==1, [1.0,2,5].contains(sampleInterval), cards.count==3,
              Set(cards.map(\.id)).count==3,
              cards.allSatisfy({ ["both","codex","claude"].contains($0.source) && ($0.x?.isFinite ?? true) && ($0.y?.isFinite ?? true) }) else {
            throw LauncherError.storage("工作台设置格式无效，原文件已保留。")
        }
    }
}
public struct WorkbenchPreferenceStore:Sendable {
    public let url:URL
    public init(url:URL) { self.url=url }
    public func load() throws -> WorkbenchPreferences {
        guard FileManager.default.fileExists(atPath:url.path) else { return WorkbenchPreferences() }
        let data=try Data(contentsOf:url);guard data.count<1_048_576 else { throw LauncherError.storage("工作台设置过大。") }
        let value=try JSONDecoder().decode(WorkbenchPreferences.self,from:data);try value.validate();return value
    }
    public func save(_ value:WorkbenchPreferences) throws {
        try value.validate();let manager=FileManager.default
        try manager.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        if manager.fileExists(atPath:url.path) {
            _=try load();try Data(contentsOf:url).write(to:url.appendingPathExtension("previous"),options:.atomic)
            try manager.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.appendingPathExtension("previous").path)
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(value).write(to:url,options:.atomic)
        try manager.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
}
