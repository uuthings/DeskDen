import Foundation
import CryptoKit
import CommonCrypto
import Security

public enum PrivateDocumentCategory:String,Codable,CaseIterable,Sendable {case unclassified,work,personal
    public var title:String {switch self {case .unclassified:"未分类";case .work:"工作";case .personal:"个人"}}
}
/// Formatting is semantic data, never RTF/HTML or executable attachments.
public enum VaultFontFamily:String,Codable,CaseIterable,Sendable,Hashable {
    case system,serif,monospaced,pingFang,kaiti,heiti,helvetica,georgia,menlo
}
public enum VaultTextColor:String,Codable,CaseIterable,Sendable,Hashable {
    case automatic,red,orange,green,blue,purple,gray
}
public enum VaultHighlightColor:String,Codable,CaseIterable,Sendable,Hashable {
    case none,yellow,green,blue,pink,purple
}
public struct VaultTextStyleRun:Codable,Equatable,Sendable {
    public var location:Int
    public var length:Int
    public var family:VaultFontFamily
    public var size:Double
    public var bold:Bool
    public var italic:Bool
    public var underline:Bool
    public var strikethrough:Bool
    public var textColor:VaultTextColor
    public var highlightColor:VaultHighlightColor
    public init(location:Int,length:Int,family:VaultFontFamily = .system,size:Double=14,bold:Bool=false,italic:Bool=false,underline:Bool=false,
                strikethrough:Bool=false,textColor:VaultTextColor = .automatic,highlightColor:VaultHighlightColor = .none) {
        self.location=location;self.length=length;self.family=family;self.size=size;self.bold=bold;self.italic=italic;self.underline=underline
        self.strikethrough=strikethrough;self.textColor=textColor;self.highlightColor=highlightColor
    }
    private enum CodingKeys:String,CodingKey {case location,length,family,size,bold,italic,underline,strikethrough,textColor,highlightColor}
    public init(from decoder:Decoder) throws {
        let fields=try decoder.container(keyedBy:CodingKeys.self)
        location=try fields.decode(Int.self,forKey:.location);length=try fields.decode(Int.self,forKey:.length)
        family=try fields.decode(VaultFontFamily.self,forKey:.family);size=try fields.decode(Double.self,forKey:.size)
        bold=try fields.decode(Bool.self,forKey:.bold);italic=try fields.decode(Bool.self,forKey:.italic);underline=try fields.decode(Bool.self,forKey:.underline)
        strikethrough=try fields.decodeIfPresent(Bool.self,forKey:.strikethrough) ?? false
        textColor=try fields.decodeIfPresent(VaultTextColor.self,forKey:.textColor) ?? .automatic
        highlightColor=try fields.decodeIfPresent(VaultHighlightColor.self,forKey:.highlightColor) ?? .none
    }
}
public struct VaultCategory:Codable,Equatable,Identifiable,Sendable {
    public var id:String
    public var name:String
    public init(id:String=UUID().uuidString,name:String) {self.id=id;self.name=name}
    public static let defaults=[VaultCategory(id:"work",name:"工作"),VaultCategory(id:"personal",name:"个人")]
}
public struct PrivateDocument:Codable,Equatable,Identifiable,Sendable {
    public var id:UUID
    public var title:String
    public var body:String
    public var createdAt:Date
    public var updatedAt:Date
    public var category:PrivateDocumentCategory
    public var categoryID:String?
    public var formatting:[VaultTextStyleRun]?
    public var effectiveCategoryID:String {categoryID ?? category.rawValue}
    public init(id:UUID=UUID(),title:String="未命名文本",body:String="",category:PrivateDocumentCategory = .unclassified,now:Date=Date()) {
        self.id=id;self.title=title;self.body=body;self.category=category;categoryID=nil;formatting=nil;createdAt=now;updatedAt=now
    }
    private enum CodingKeys:String,CodingKey {case id,title,body,createdAt,updatedAt,category,categoryID,formatting}
    public init(from decoder:Decoder) throws {
        let fields=try decoder.container(keyedBy:CodingKeys.self)
        id=try fields.decode(UUID.self,forKey:.id);title=try fields.decode(String.self,forKey:.title);body=try fields.decode(String.self,forKey:.body)
        createdAt=try fields.decode(Date.self,forKey:.createdAt);updatedAt=try fields.decode(Date.self,forKey:.updatedAt)
        category=try fields.decodeIfPresent(PrivateDocumentCategory.self,forKey:.category) ?? .unclassified
        categoryID=try fields.decodeIfPresent(String.self,forKey:.categoryID)
        formatting=try fields.decodeIfPresent([VaultTextStyleRun].self,forKey:.formatting)
    }
}
/// Schema 2 fences released readers from silently dropping the biometric opt-in.
/// Reading schema 1 remains side-effect free; every subsequent write emits 2.
public struct VaultProtectionPreferences:Codable,Equatable,Sendable {
    public var schema=2
    public var idleMinutes:Int=5
    public var biometricEnabled:Bool=false
    public init(idleMinutes:Int=5,biometricEnabled:Bool=false){self.idleMinutes=idleMinutes;self.biometricEnabled=biometricEnabled}
    private enum CodingKeys:String,CodingKey {case schema,idleMinutes,biometricEnabled}
    public init(from decoder:Decoder) throws {
        let fields=try decoder.container(keyedBy:CodingKeys.self);schema=try fields.decode(Int.self,forKey:.schema)
        guard schema == 1 || schema == 2 else {throw VaultFailure.invalidData}
        idleMinutes=try fields.decode(Int.self,forKey:.idleMinutes)
        biometricEnabled=schema == 1 ? try fields.decodeIfPresent(Bool.self,forKey:.biometricEnabled) ?? false:try fields.decode(Bool.self,forKey:.biometricEnabled)
    }
    public func encode(to encoder:Encoder) throws {
        _=try validated();var fields=encoder.container(keyedBy:CodingKeys.self)
        try fields.encode(2,forKey:.schema);try fields.encode(idleMinutes,forKey:.idleMinutes);try fields.encode(biometricEnabled,forKey:.biometricEnabled)
    }
    public func validated() throws -> Self {guard schema == 1 || schema == 2,[1,5,10].contains(idleMinutes) else {throw VaultFailure.invalidData};return self}

}
/// Payload 3 protects color, strike and expanded font metadata from v2 writers.
/// Readers accept v1/v2 without rewriting. An actual save emits v3 so older
/// readers reject it before editing away new style fields. Envelope/KDF stay put.
public struct VaultContents:Codable,Equatable,Sendable {
    public var version=3
    public var documents:[PrivateDocument]
    public var categories:[VaultCategory]
    public init(documents:[PrivateDocument]=[],categories:[VaultCategory]=VaultCategory.defaults) {self.documents=documents;self.categories=categories}
    private enum CodingKeys:String,CodingKey {case version,documents,categories}
    public init(from decoder:Decoder) throws {
        let fields=try decoder.container(keyedBy:CodingKeys.self)
        version=try fields.decode(Int.self,forKey:.version)
        guard (1...3).contains(version) else {throw VaultFailure.invalidData}
        documents=try fields.decode([PrivateDocument].self,forKey:.documents)
        categories=version == 1 ? try fields.decodeIfPresent([VaultCategory].self,forKey:.categories) ?? VaultCategory.defaults:try fields.decode([VaultCategory].self,forKey:.categories)
    }
    public func encode(to encoder:Encoder) throws {
        try validate();var fields=encoder.container(keyedBy:CodingKeys.self)
        try fields.encode(3,forKey:.version);try fields.encode(documents,forKey:.documents);try fields.encode(categories,forKey:.categories)
    }
    public func upgradedForWriting() throws -> Self {try validate();var latest=self;latest.version=3;return latest}
    public func validate() throws {
        let ids=Set(categories.map(\.id))
        guard (1...3).contains(version),documents.count<=5000,Set(documents.map(\.id)).count==documents.count,
              categories.count<=100,ids.count==categories.count,!ids.contains("unclassified"),
              categories.allSatisfy({!$0.id.isEmpty && $0.id.count<=80 && !$0.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.name.count<=30}),
              Set(categories.map{$0.name.folding(options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive],locale:.current)}).count==categories.count,
              documents.allSatisfy({document in
                  guard document.title.count<=100,document.body.count<=160_000,
                        document.createdAt.timeIntervalSince1970.isFinite,document.updatedAt.timeIntervalSince1970.isFinite,
                        document.effectiveCategoryID == "unclassified" || ids.contains(document.effectiveCategoryID) else {return false}
                  guard let runs=document.formatting else {return true}
                  guard runs.count<=20_000 else {return false}
                  var previousEnd=0
                  for run in runs {
                      guard run.location>=previousEnd,run.length>0,run.location<=document.body.utf16.count,
                            run.length<=document.body.utf16.count-run.location,run.size.isFinite,(10...28).contains(run.size),
                            Range(NSRange(location:run.location,length:run.length),in:document.body) != nil else {return false}
                      previousEnd=run.location+run.length
                  }
                  return true
              }) else {throw VaultFailure.invalidData}
    }
}
public enum VaultFailure:LocalizedError,Equatable {
    case weakPassword,passwordTooLong,invalidData,incorrectPassword,randomFailure,notConfigured,tooLarge
    public var errorDescription:String? {
        switch self {
        case .weakPassword:"密码至少需要 8 个字符。"
        case .passwordTooLong:"密码不能超过 4096 个 UTF-8 字节。"
        case .invalidData:"私密资料或备份格式无效，当前资料未被替换。"
        case .incorrectPassword:"密码不正确，或加密文件已损坏。"
        case .randomFailure:"无法生成安全随机数，请重试。"
        case .notConfigured:"尚未建立私密资料库。"
        case .tooLarge:"私密资料超过支持的大小。"
        }
    }
}
public struct VaultEnvelope:Codable,Sendable {
    public let format:String
    public let version:Int
    public let rounds:UInt32
    public let salt:Data
    public let sealed:Data
    public init(rounds:UInt32,salt:Data,sealed:Data) {format="fangcun-encrypted-vault";version=1;self.rounds=rounds;self.salt=salt;self.sealed=sealed}
    public func validate() throws {
        guard format=="fangcun-encrypted-vault",version==1,rounds==310_000,salt.count==16,sealed.count>=28,sealed.count<=16_777_216 else {throw VaultFailure.invalidData}
    }
}
public struct UnlockedVault:Sendable {
    public let key:SymmetricKey
    public let envelope:VaultEnvelope
    public let contents:VaultContents
}
public enum VaultCryptography {
    public static let rounds:UInt32=310_000
    private static let associatedData=Data("fangcun-encrypted-vault:1:pbkdf2-sha256-310000".utf8)
    public static func create(contents:VaultContents,password:String) throws -> UnlockedVault {
        guard password.count>=8 else {throw VaultFailure.weakPassword}
        var salt=Data(count:16)
        let result=salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault,16,$0.baseAddress!) }
        guard result==errSecSuccess else {throw VaultFailure.randomFailure}
        let key=try derive(password:password,salt:salt),latest=try contents.upgradedForWriting()
        let envelope=try seal(contents:latest,key:key,salt:salt)
        return UnlockedVault(key:key,envelope:envelope,contents:latest)
    }
    public static func unlock(data:Data,password:String) throws -> UnlockedVault {
        let envelope=try decodeEnvelope(data)
        let key=try derive(password:password,salt:envelope.salt)
        return try unlock(data:data,key:key)
    }
    /// The key is supplied only by the already-unlocked session or authenticated Keychain retrieval.
    public static func unlock(data:Data,key:SymmetricKey) throws -> UnlockedVault {
        let envelope=try decodeEnvelope(data)
        guard key.bitCount == 256 else {throw VaultFailure.invalidData}
        do {
            let box=try AES.GCM.SealedBox(combined:envelope.sealed)
            let plaintext=try AES.GCM.open(box,using:key,authenticating:associatedData)
            let contents=try JSONDecoder().decode(VaultContents.self,from:plaintext);try contents.validate()
            return UnlockedVault(key:key,envelope:envelope,contents:contents)
        } catch {throw VaultFailure.incorrectPassword}
    }
    public static func seal(contents:VaultContents,key:SymmetricKey,salt:Data) throws -> VaultEnvelope {
        let latest=try contents.upgradedForWriting();guard salt.count==16 else {throw VaultFailure.invalidData}
        let data=try JSONEncoder().encode(latest);guard data.count<16_000_000 else {throw VaultFailure.tooLarge}
        let box=try AES.GCM.seal(data,using:key,authenticating:associatedData)
        guard let combined=box.combined else {throw VaultFailure.invalidData}
        return VaultEnvelope(rounds:rounds,salt:salt,sealed:combined)
    }
    public static func encoded(_ envelope:VaultEnvelope) throws -> Data {
        try envelope.validate();let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];return try encoder.encode(envelope)
    }
    public static func decodeEnvelope(_ data:Data) throws -> VaultEnvelope {
        guard data.count<=24_000_000 else {throw VaultFailure.tooLarge}
        do {let e=try JSONDecoder().decode(VaultEnvelope.self,from:data);try e.validate();return e}
        catch {throw VaultFailure.invalidData}
    }
    private static func derive(password:String,salt:Data) throws -> SymmetricKey {
        guard !password.isEmpty else {throw VaultFailure.incorrectPassword}
        guard password.utf8.count<=4096 else {throw VaultFailure.passwordTooLong}
        var passwordBytes=Array(password.utf8),derived=Data(count:32)
        defer { _=passwordBytes.withUnsafeMutableBytes { $0.initializeMemory(as:UInt8.self,repeating:0) } }
        let result=derived.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes in
                passwordBytes.withUnsafeBytes { input in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),input.baseAddress!.assumingMemoryBound(to:CChar.self),input.count,saltBytes.baseAddress!.assumingMemoryBound(to:UInt8.self),salt.count,CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),rounds,output.baseAddress!.assumingMemoryBound(to:UInt8.self),32)
                }
            }
        }
        guard result==kCCSuccess else {throw VaultFailure.invalidData}
        let key=SymmetricKey(data:derived);derived.resetBytes(in:0..<derived.count);return key
    }
}
public struct VaultFileStore:Sendable {
    public let url:URL
    public init(url:URL) {self.url=url}
    public func read() throws -> Data {
        guard FileManager.default.fileExists(atPath:url.path) else {throw VaultFailure.notConfigured}
        let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        guard (attributes[.size] as? NSNumber)?.uint64Value ?? UInt64.max <= 24_000_000 else {throw VaultFailure.tooLarge}
        let data=try Data(contentsOf:url);_=try VaultCryptography.decodeEnvelope(data);return data
    }
    public func write(_ envelope:VaultEnvelope,preservePrevious:Bool=true) throws {
        let data=try VaultCryptography.encoded(envelope),manager=FileManager.default
        try manager.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        if preservePrevious,manager.fileExists(atPath:url.path) {
            let old=try read();let previous=url.appendingPathExtension("previous")
            try old.write(to:previous,options:.atomic);try manager.setAttributes([.posixPermissions:0o600],ofItemAtPath:previous.path)
        }
        try data.write(to:url,options:[.atomic,.completeFileProtectionUnlessOpen]);try manager.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    /// Preserve the displaced encrypted database before an explicitly confirmed restore.
    public func restore(_ envelope:VaultEnvelope) throws -> URL? {
        let manager=FileManager.default
        var preserved:URL?
        if manager.fileExists(atPath:url.path) {
            let copy=url.deletingLastPathComponent().appendingPathComponent("vault-before-restore-\(UUID().uuidString).fangcunvault")
            try manager.copyItem(at:url,to:copy);try manager.setAttributes([.posixPermissions:0o600],ofItemAtPath:copy.path);preserved=copy
        }
        try write(envelope,preservePrevious:false);return preserved
    }
}
