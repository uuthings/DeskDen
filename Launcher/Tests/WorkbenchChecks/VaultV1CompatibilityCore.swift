import Foundation
import CryptoKit
import CommonCrypto
import Security

public enum PrivateDocumentCategory:String,Codable,CaseIterable,Sendable {case unclassified,work,personal
    public var title:String {switch self {case .unclassified:"未分类";case .work:"工作";case .personal:"个人"}}
}
public struct PrivateDocument:Codable,Equatable,Identifiable,Sendable {
    public var id:UUID
    public var title:String
    public var body:String
    public var createdAt:Date
    public var updatedAt:Date
    public var category:PrivateDocumentCategory
    public init(id:UUID=UUID(),title:String="未命名文本",body:String="",category:PrivateDocumentCategory = .unclassified,now:Date=Date()) {
        self.id=id;self.title=title;self.body=body;self.category=category;createdAt=now;updatedAt=now
    }
    private enum CodingKeys:String,CodingKey {case id,title,body,createdAt,updatedAt,category}
    public init(from decoder:Decoder) throws {
        let fields=try decoder.container(keyedBy:CodingKeys.self)
        id=try fields.decode(UUID.self,forKey:.id);title=try fields.decode(String.self,forKey:.title);body=try fields.decode(String.self,forKey:.body)
        createdAt=try fields.decode(Date.self,forKey:.createdAt);updatedAt=try fields.decode(Date.self,forKey:.updatedAt)
        category=try fields.decodeIfPresent(PrivateDocumentCategory.self,forKey:.category) ?? .unclassified
    }
}
public struct VaultProtectionPreferences:Codable,Equatable,Sendable {
    public var schema=1
    public var idleMinutes:Int=5
    public init(idleMinutes:Int=5){self.idleMinutes=idleMinutes}
    public func validated() throws -> Self {guard schema == 1,[1,5,10].contains(idleMinutes) else {throw VaultFailure.invalidData};return self}
}
public struct VaultContents:Codable,Equatable,Sendable {
    public var version=1
    public var documents:[PrivateDocument]
    public init(documents:[PrivateDocument]=[]) { self.documents=documents }
    public func validate() throws {
        guard version==1,documents.count<=5000,Set(documents.map(\.id)).count==documents.count,
              documents.allSatisfy({$0.title.count<=100 && $0.body.count<=160_000 && $0.createdAt.timeIntervalSince1970.isFinite && $0.updatedAt.timeIntervalSince1970.isFinite}) else { throw VaultFailure.invalidData }
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
    public init(rounds:UInt32,salt:Data,sealed:Data) {format="deskden-encrypted-vault";version=1;self.rounds=rounds;self.salt=salt;self.sealed=sealed}
    public func validate() throws {
        guard format=="deskden-encrypted-vault",version==1,rounds==310_000,salt.count==16,sealed.count>=28,sealed.count<=16_777_216 else {throw VaultFailure.invalidData}
    }
}
public struct UnlockedVault:Sendable {
    public let key:SymmetricKey
    public let envelope:VaultEnvelope
    public let contents:VaultContents
}
public enum VaultCryptography {
    public static let rounds:UInt32=310_000
    private static let associatedData=Data("deskden-encrypted-vault:1:pbkdf2-sha256-310000".utf8)
    public static func create(contents:VaultContents,password:String) throws -> UnlockedVault {
        guard password.count>=8 else {throw VaultFailure.weakPassword}
        var salt=Data(count:16)
        let result=salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault,16,$0.baseAddress!) }
        guard result==errSecSuccess else {throw VaultFailure.randomFailure}
        let key=try derive(password:password,salt:salt)
        let envelope=try seal(contents:contents,key:key,salt:salt)
        return UnlockedVault(key:key,envelope:envelope,contents:contents)
    }
    public static func unlock(data:Data,password:String) throws -> UnlockedVault {
        let envelope=try decodeEnvelope(data)
        let key=try derive(password:password,salt:envelope.salt)
        do {
            let box=try AES.GCM.SealedBox(combined:envelope.sealed)
            let plaintext=try AES.GCM.open(box,using:key,authenticating:associatedData)
            let contents=try JSONDecoder().decode(VaultContents.self,from:plaintext);try contents.validate()
            return UnlockedVault(key:key,envelope:envelope,contents:contents)
        } catch {throw VaultFailure.incorrectPassword}
    }
    public static func seal(contents:VaultContents,key:SymmetricKey,salt:Data) throws -> VaultEnvelope {
        try contents.validate();guard salt.count==16 else {throw VaultFailure.invalidData}
        let data=try JSONEncoder().encode(contents);guard data.count<16_000_000 else {throw VaultFailure.tooLarge}
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
            let copy=url.deletingLastPathComponent().appendingPathComponent("vault-before-restore-\(UUID().uuidString).deskdenvault")
            try manager.copyItem(at:url,to:copy);try manager.setAttributes([.posixPermissions:0o600],ofItemAtPath:copy.path);preserved=copy
        }
        try write(envelope,preservePrevious:false);return preserved
    }
}
