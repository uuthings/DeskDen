import Foundation
import CryptoKit
import CommonCrypto
import Security
import Darwin

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
    case unchangedPassword,passwordChangePending,passwordChangeSourceChanged
    public var errorDescription:String? {
        switch self {
        case .weakPassword:"密码至少需要 8 个字符。"
        case .passwordTooLong:"密码不能超过 4096 个 UTF-8 字节。"
        case .invalidData:"私密资料或备份格式无效，当前资料未被替换。"
        case .incorrectPassword:"密码不正确，或加密文件已损坏。"
        case .randomFailure:"无法生成安全随机数，请重试。"
        case .notConfigured:"尚未建立私密资料库。"
        case .tooLarge:"私密资料超过支持的大小。"
        case .unchangedPassword:"新密码与当前密码相同，无需更改。"
        case .passwordChangePending:"密码更改尚未完成，请先恢复密码更改；恢复完成后使用新密码解锁。"
        case .passwordChangeSourceChanged:"密码更改期间资料文件发生变化，已停止替换；现有文件和恢复记录已保留。"
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
        guard ["deskden-encrypted-vault","fangcun-encrypted-vault"].contains(format),version==1,rounds==310_000,salt.count==16,sealed.count>=28,sealed.count<=16_777_216 else {throw VaultFailure.invalidData}
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
    /// The released envelope's identity is authenticated. Renaming the product
    /// must not change the associated data used to open its existing ciphertext.
    private static func associatedData(for envelope:VaultEnvelope)->Data {
        Data("\(envelope.format):1:pbkdf2-sha256-310000".utf8)
    }
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
            let plaintext=try AES.GCM.open(box,using:key,authenticating:associatedData(for:envelope))
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
    /// Historical payloads are preserved byte for byte, including their schema.
    /// Only an authentication failure means that a history uses another password;
    /// malformed envelopes and other failures abort the whole password change.
    fileprivate static func reencryptHistory(_ data:Data,password:String,key:SymmetricKey,salt:Data) throws -> VaultEnvelope? {
        let envelope=try decodeEnvelope(data)
        let oldKey=try derive(password:password,salt:envelope.salt)
        let box=try AES.GCM.SealedBox(combined:envelope.sealed)
        var plaintext:Data
        do {plaintext=try AES.GCM.open(box,using:oldKey,authenticating:associatedData(for:envelope))}
        catch CryptoKitError.authenticationFailure {return nil}
        defer {plaintext.resetBytes(in:0..<plaintext.count)}
        let replacement=try AES.GCM.seal(plaintext,using:key,authenticating:associatedData)
        guard let combined=replacement.combined else {throw VaultFailure.invalidData}
        return VaultEnvelope(rounds:rounds,salt:salt,sealed:combined)
    }
}

public struct VaultPasswordChangeResult:Equatable,Sendable {
    public let reencryptedBackupCount:Int
    /// These authenticated-envelope files did not open with the old password.
    /// They remain unchanged; changing one vault password must not delete them.
    public let retainedOtherPasswordBackups:[String]
}

/// A prepared change contains ciphertext and file digests, never a password,
/// plaintext, or encryption key. Preparation may safely run off the main actor;
/// callers must recheck their session before committing it.
public struct VaultPasswordChange:Codable,Sendable {
    fileprivate struct Target:Codable,Sendable {
        let name:String
        let originalDigest:Data
        let replacement:Data?
    }
    fileprivate let schema:Int
    fileprivate let vaultName:String
    fileprivate let targets:[Target]
    public var result:VaultPasswordChangeResult {
        .init(reencryptedBackupCount:targets.filter{$0.name != vaultName && $0.replacement != nil}.count,
              retainedOtherPasswordBackups:targets.filter{$0.replacement == nil}.map(\.name))
    }
}

public struct VaultFileStore:Sendable {
    public let url:URL
    public init(url:URL) {self.url=url}
    private var passwordChangeURL:URL {url.appendingPathExtension("password-change")}
    public var isPendingPasswordChange:Bool {FileManager.default.fileExists(atPath:passwordChangeURL.path)}
    private static let maximumPasswordChangeSize=256_000_000
    public func read() throws -> Data {
        guard !isPendingPasswordChange else {throw VaultFailure.passwordChangePending}
        guard FileManager.default.fileExists(atPath:url.path) else {throw VaultFailure.notConfigured}
        let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        guard (attributes[.size] as? NSNumber)?.uint64Value ?? UInt64.max <= 24_000_000 else {throw VaultFailure.tooLarge}
        let data=try Data(contentsOf:url);_=try VaultCryptography.decodeEnvelope(data);return data
    }
    public func write(_ envelope:VaultEnvelope,preservePrevious:Bool=true) throws {
        guard !isPendingPasswordChange else {throw VaultFailure.passwordChangePending}
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
        guard !isPendingPasswordChange else {throw VaultFailure.passwordChangePending}
        let manager=FileManager.default
        var preserved:URL?
        if manager.fileExists(atPath:url.path) {
            let copy=url.deletingLastPathComponent().appendingPathComponent("vault-before-restore-\(UUID().uuidString).deskdenvault")
            try manager.copyItem(at:url,to:copy);try manager.setAttributes([.posixPermissions:0o600],ofItemAtPath:copy.path);preserved=copy
        }
        try write(envelope,preservePrevious:false);return preserved
    }

    public func preparePasswordChange(currentPassword:String,newPassword:String) throws -> VaultPasswordChange {
        guard !isPendingPasswordChange else {throw VaultFailure.passwordChangePending}
        guard currentPassword != newPassword else {throw VaultFailure.unchangedPassword}
        let currentData=try read()
        let current=try VaultCryptography.unlock(data:currentData,password:currentPassword)
        let changed=try VaultCryptography.create(contents:current.contents,password:newPassword)
        let names=try managedNames()
        guard names.count<=1000 else {throw VaultFailure.tooLarge}
        var targets:[VaultPasswordChange.Target]=[]
        for name in names {
            let original=try readManagedFile(named:name)
            let replacement:Data?
            if name == url.lastPathComponent {
                guard original == currentData else {throw VaultFailure.passwordChangeSourceChanged}
                replacement=try VaultCryptography.encoded(changed.envelope)
            } else if let envelope=try VaultCryptography.reencryptHistory(original,password:currentPassword,key:changed.key,salt:changed.envelope.salt) {
                replacement=try VaultCryptography.encoded(envelope)
            } else {replacement=nil}
            targets.append(.init(name:name,originalDigest:Self.digest(original),replacement:replacement))
        }
        let change=VaultPasswordChange(schema:1,vaultName:url.lastPathComponent,targets:targets)
        try validate(change)
        guard !isPendingPasswordChange else {throw VaultFailure.passwordChangePending}
        return change
    }

    /// The journal stores only replacement ciphertext. Histories commit first,
    /// the primary vault last. A failure after journaling requires explicit
    /// forward recovery, never an ordinary autosave or an old-key rollback.
    @discardableResult public func commitPasswordChange(_ change:VaultPasswordChange) throws -> VaultPasswordChangeResult {
        guard !isPendingPasswordChange else {throw VaultFailure.passwordChangePending}
        try validate(change)
        try verifySources(change,allowReplaced:false)
        try removeAbandonedPasswordChangeWrites()
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let journal=try encoder.encode(change)
        guard journal.count<=Self.maximumPasswordChangeSize else {throw VaultFailure.tooLarge}
        try writePrivate(journal,to:passwordChangeURL,exclusive:true)
        return try finishPasswordChange(change)
    }

    /// Call before opening a vault after an interrupted change. No password is
    /// needed: the durable journal already contains only new-password ciphertext.
    /// Success means that all app-managed old-password histories were replaced
    /// and the journal was removed. The new password now opens the main vault.
    @discardableResult public func recoverPasswordChange() throws -> VaultPasswordChangeResult? {
        try removeAbandonedPasswordChangeWrites()
        guard isPendingPasswordChange else {return nil}
        let attributes=try FileManager.default.attributesOfItem(atPath:passwordChangeURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size=attributes[.size] as? NSNumber,size.uint64Value<=UInt64(Self.maximumPasswordChangeSize) else {throw VaultFailure.invalidData}
        let journal=try Data(contentsOf:passwordChangeURL)
        guard journal.count<=Self.maximumPasswordChangeSize else {throw VaultFailure.tooLarge}
        let change=try JSONDecoder().decode(VaultPasswordChange.self,from:journal)
        try validate(change)
        return try finishPasswordChange(change)
    }

    private func finishPasswordChange(_ change:VaultPasswordChange) throws -> VaultPasswordChangeResult {
        try verifySources(change,allowReplaced:true)
        // Always leave the main vault until every recoverable history is safe.
        let ordered=change.targets.filter{$0.name != change.vaultName}+change.targets.filter{$0.name == change.vaultName}
        for target in ordered {
            guard let replacement=target.replacement else {continue}
            let current=try readManagedFile(named:target.name)
            guard Self.digest(current) == target.originalDigest || current == replacement else {throw VaultFailure.passwordChangeSourceChanged}
            if current != replacement {try writePrivate(replacement,to:url.deletingLastPathComponent().appendingPathComponent(target.name))}
        }
        guard try managedNames() == change.targets.map(\.name).sorted() else {throw VaultFailure.passwordChangeSourceChanged}
        for target in change.targets {
            let current=try readManagedFile(named:target.name)
            guard target.replacement.map({$0 == current}) ?? (Self.digest(current) == target.originalDigest) else {throw VaultFailure.passwordChangeSourceChanged}
        }
        try FileManager.default.removeItem(at:passwordChangeURL)
        guard !isPendingPasswordChange else {throw VaultFailure.passwordChangePending}
        return change.result
    }

    private func validate(_ change:VaultPasswordChange) throws {
        let names=change.targets.map(\.name)
        guard change.schema == 1,change.vaultName == url.lastPathComponent,
              !change.targets.isEmpty,change.targets.count<=1000,Set(names).count == names.count,
              change.targets.contains(where:{$0.name == change.vaultName && $0.replacement != nil}),
              change.targets.allSatisfy({isManagedName($0.name) && $0.originalDigest.count == 32}) else {throw VaultFailure.invalidData}
        for target in change.targets {if let replacement=target.replacement {_=try VaultCryptography.decodeEnvelope(replacement)}}
    }
    private func verifySources(_ change:VaultPasswordChange,allowReplaced:Bool) throws {
        guard try managedNames() == change.targets.map(\.name).sorted() else {throw VaultFailure.passwordChangeSourceChanged}
        for target in change.targets {
            let original=try readManagedFile(named:target.name)
            guard Self.digest(original) == target.originalDigest || (allowReplaced && target.replacement == original) else {throw VaultFailure.passwordChangeSourceChanged}
        }
    }
    private func managedNames() throws -> [String] {
        let names=try FileManager.default.contentsOfDirectory(atPath:url.deletingLastPathComponent().path).filter(isManagedName).sorted()
        guard names.contains(url.lastPathComponent) else {throw VaultFailure.notConfigured}
        return names
    }
    private func isManagedName(_ name:String) -> Bool {
        if name == url.lastPathComponent || name == url.lastPathComponent+".previous" {return true}
        let prefix="vault-before-restore-",suffix=".deskdenvault"
        guard name.hasPrefix(prefix),name.hasSuffix(suffix),name.count>prefix.count+suffix.count else {return false}
        return UUID(uuidString:String(name.dropFirst(prefix.count).dropLast(suffix.count))) != nil
    }
    private func readManagedFile(named name:String) throws -> Data {
        guard isManagedName(name) else {throw VaultFailure.invalidData}
        let candidate=url.deletingLastPathComponent().appendingPathComponent(name)
        let attributes=try FileManager.default.attributesOfItem(atPath:candidate.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size=attributes[.size] as? NSNumber,size.uint64Value<=24_000_000 else {throw VaultFailure.invalidData}
        let data=try Data(contentsOf:candidate);_=try VaultCryptography.decodeEnvelope(data);return data
    }
    private func writePrivate(_ data:Data,to destination:URL,exclusive:Bool=false) throws {
        let manager=FileManager.default,parent=url.deletingLastPathComponent()
        let temporary=parent.appendingPathComponent(passwordChangeURL.lastPathComponent+"-staging-"+UUID().uuidString)
        guard manager.createFile(atPath:temporary.path,contents:nil,attributes:[.posixPermissions:0o600]) else {throw CocoaError(.fileWriteNoPermission)}
        defer {try? manager.removeItem(at:temporary)}
        let handle=try FileHandle(forWritingTo:temporary)
        do {try handle.write(contentsOf:data);try handle.synchronize();try handle.close()}
        catch {try? handle.close();throw error}
        // Publish the complete journal without replacing another pending change.
        // Its temporary hard link is removed by defer or the next recovery.
        let status=exclusive ? Darwin.link(temporary.path,destination.path):Darwin.rename(temporary.path,destination.path)
        guard status == 0 else {
            if exclusive,errno == EEXIST {throw VaultFailure.passwordChangePending}
            throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)
        }
    }
    /// An interrupted atomic write contains only newly encrypted bytes. Remove
    /// its precisely named temporary file before a later change can retire that
    /// password too; never accumulate forgotten ciphertext outside the journal.
    private func removeAbandonedPasswordChangeWrites() throws {
        let manager=FileManager.default,parent=url.deletingLastPathComponent()
        guard manager.fileExists(atPath:parent.path) else {return}
        let prefix=passwordChangeURL.lastPathComponent+"-staging-"
        for name in try manager.contentsOfDirectory(atPath:parent.path) where name.hasPrefix(prefix) && UUID(uuidString:String(name.dropFirst(prefix.count))) != nil {
            let abandoned=parent.appendingPathComponent(name)
            let attributes=try manager.attributesOfItem(atPath:abandoned.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {throw VaultFailure.invalidData}
            try manager.removeItem(at:abandoned)
        }
    }
    private static func digest(_ data:Data) -> Data {Data(SHA256.hash(data:data))}
}
