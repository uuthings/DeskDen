import AppKit
import CryptoKit
import Foundation
import LauncherCore
import VaultV1Compatibility

/// Exercises the DeskDen schema-v1 derivative identified by the check script,
/// not the earlier brand's release bytes. The codec is a separate module;
/// all data, passwords and biometric storage here are synthetic.
@main struct VaultFormatCompatibilityChecks {
    @MainActor static func main() async {
        _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("deskden-vault-format-checks-\(UUID().uuidString)")
        defer{try? FileManager.default.removeItem(at:directory)}
        var checks=0,failures=0
        func check(_ condition:Bool,_ message:String){checks += 1;if !condition {failures += 1};print("\(condition ? "PASS":"FAIL") \(message)")}
        func rejects(_ action:()throws->Void)->Bool {do{try action();return false}catch{return true}}
        do {
            let password="synthetic-format-compatibility-password"
            let oldContents=VaultV1Compatibility.VaultContents(documents:[VaultV1Compatibility.PrivateDocument(title:"Legacy synthetic title",body:"Legacy synthetic body 🔐",category:.work)])
            let old=try VaultV1Compatibility.VaultCryptography.create(contents:oldContents,password:password)
            let oldBytes=try VaultV1Compatibility.VaultCryptography.encoded(old.envelope)
            let oldStore=VaultV1Compatibility.VaultFileStore(url:directory.appendingPathComponent("current/private.deskdenvault"))
            try oldStore.write(old.envelope)
            let preferencesURL=directory.appendingPathComponent("current/protection.json")
            let oldPreferences=try JSONEncoder().encode(VaultV1Compatibility.VaultProtectionPreferences(idleMinutes:1))
            try oldPreferences.write(to:preferencesURL)
            let biometric=FormatSyntheticBiometrics()
            let model=VaultModel(dataDirectory:directory.appendingPathComponent("current"),protectedDataAvailable:{true},biometrics:biometric)
            check(model.idleMinutes == 1 && !model.biometricEnabled,"new reader accepts schema1 fixture preferences")
            check(try Data(contentsOf:preferencesURL) == oldPreferences,"loading schema1 preferences does not migrate or rewrite the file")
            check(await model.unlock(password:password),"new reader unlocks DeskDen schema-v1 fixture ciphertext")
            check(model.selectedDocument?.body == "Legacy synthetic body 🔐" && model.selectedDocument?.category == .work,"legacy body and category survive read-only adoption")
            model.lock(reason:"read-only compatibility check")
            check(try Data(contentsOf:oldStore.url) == oldBytes,"unlocking and locking version1 without edits preserves every encrypted byte")
            check(try VaultV1Compatibility.VaultCryptography.unlock(data:Data(contentsOf:oldStore.url),password:password).contents == oldContents,"retained old decoder still opens the untouched version1 file")
            let legacyDecoded=try LauncherCore.VaultCryptography.unlock(data:oldBytes,password:password)
            check(legacyDecoded.contents.version == 1,"new decoder records the source version until a real write")
            let upgraded=try LauncherCore.VaultCryptography.seal(contents:legacyDecoded.contents,key:legacyDecoded.key,salt:legacyDecoded.envelope.salt)
            let upgradedBytes=try LauncherCore.VaultCryptography.encoded(upgraded)
            check(try LauncherCore.VaultCryptography.unlock(data:upgradedBytes,password:password).contents.version == 3,"even an ordinary successful seal of old content writes payload version3")
            check(rejects{_ = try VaultV1Compatibility.VaultCryptography.unlock(data:upgradedBytes,password:password)},"schema-v1 decoder rejects migrated version3 before any ordinary edit can strip new fields")
            check(await model.unlock(password:password),"legacy file can be reopened for an explicit edit")
            let blockedPrevious=oldStore.url.appendingPathExtension("previous")
            try FileManager.default.createDirectory(at:blockedPrevious,withIntermediateDirectories:true)
            model.updateBody("Synthetic pending migration")
            check(!model.flush() && model.hasPendingSave,"failed migration keeps only the encrypted pending revision for retry")
            check(try Data(contentsOf:oldStore.url) == oldBytes,"failed migration never changes the existing version1 ciphertext")
            check(try VaultV1Compatibility.VaultCryptography.unlock(data:Data(contentsOf:oldStore.url),password:password).contents == oldContents,"schema-v1 decoder still opens the preserved file after failed migration")
            try FileManager.default.removeItem(at:blockedPrevious)
            let body="Formatted synthetic body 🔐"
            model.updateRichBody(body,formatting:[LauncherCore.VaultTextStyleRun(location:0,length:(body as NSString).length,family:.serif,size:18,bold:true)])
            check(model.flush(),"the first successful rich edit explicitly commits the format migration")
            let firstMigrationPrevious=try Data(contentsOf:oldStore.url.appendingPathExtension("previous"))
            let firstMigrationContents=try LauncherCore.VaultCryptography.unlock(data:firstMigrationPrevious,password:password).contents
            check(firstMigrationPrevious == oldBytes && firstMigrationContents.version == 1,"first successful migration retains every byte of the prior encrypted version1 revision")
            check(model.addCategory("Synthetic archive"),"new category is accepted after the explicit format migration")
            let category=model.categories.last!;model.moveSelected(to:category.id)
            // The previous file is a rotating revision, not an immutable v1
            // archive. Navigation may flush accepted edits before the move.
            let precedingRevision=try Data(contentsOf:oldStore.url)
            check(model.flush(),"the category move commits the latest rich document ciphertext")
            let newBytes=try Data(contentsOf:oldStore.url)
            check(try Data(contentsOf:oldStore.url.appendingPathExtension("previous")) == precedingRevision,"later writes preserve every byte of their immediately preceding encrypted revision")
            let current=try LauncherCore.VaultCryptography.unlock(data:newBytes,password:password)
            check(current.contents.version == 3 && current.contents.documents.first?.formatting?.first?.bold == true && current.contents.documents.first?.effectiveCategoryID == category.id,"version3 preserves rich formatting and custom category references")
            check(rejects{_ = try VaultV1Compatibility.VaultCryptography.unlock(data:newBytes,password:password)},"schema-v1 password unlock rejects the new rich payload")
            check(try Data(contentsOf:oldStore.url) == newBytes,"old decoder rejection leaves new encrypted data unchanged")
            model.changeIdleMinutes(10)
            let schema2=try Data(contentsOf:preferencesURL)
            let parsed=try JSONDecoder().decode(LauncherCore.VaultProtectionPreferences.self,from:schema2).validated()
            check(parsed.schema == 2 && parsed.idleMinutes == 10,"explicit idle change writes schema2 preferences")
            check(rejects{_ = try JSONDecoder().decode(VaultV1Compatibility.VaultProtectionPreferences.self,from:schema2).validated()},"schema-v1 preference guard rejects schema2 instead of overwriting the new biometric flag")
            await model.refreshBiometrics()
            check(await model.enableBiometrics(),"synthetic opt-in persists the schema2 biometric flag")
            model.changeIdleMinutes(5)
            let optedIn=try Data(contentsOf:preferencesURL)
            let optedInPreferences=try JSONDecoder().decode(LauncherCore.VaultProtectionPreferences.self,from:optedIn).validated()
            check(optedInPreferences.schema == 2 && optedInPreferences.biometricEnabled,"idle changes preserve enabled biometrics in schema2")
            let reloaded=VaultModel(dataDirectory:directory.appendingPathComponent("current"),protectedDataAvailable:{true},biometrics:biometric)
            check(reloaded.biometricEnabled && reloaded.idleMinutes == 5,"new model retains schema2 protection settings across recreation")
            check(try Data(contentsOf:preferencesURL) == optedIn,"loading schema2 protection settings is also read-only")
            check(rejects{_ = try JSONDecoder().decode(VaultV1Compatibility.VaultProtectionPreferences.self,from:optedIn).validated()},"retained old parser cannot accept enabled schema2 preferences")
            let oldParsed=try JSONDecoder().decode(LauncherCore.VaultProtectionPreferences.self,from:oldPreferences).validated()
            let rewritten=try JSONEncoder().encode(oldParsed)
            check(try JSONDecoder().decode(LauncherCore.VaultProtectionPreferences.self,from:rewritten).schema == 2,"encoding legacy preferences always emits the new schema")
            let optInDirectory=directory.appendingPathComponent("legacy-opt-in")
            let optInStore=VaultV1Compatibility.VaultFileStore(url:optInDirectory.appendingPathComponent("private.deskdenvault"))
            try optInStore.write(old.envelope)
            try oldPreferences.write(to:optInDirectory.appendingPathComponent("protection.json"))
            let optInBiometrics=FormatSyntheticBiometrics()
            let optInModel=VaultModel(dataDirectory:optInDirectory,protectedDataAvailable:{true},biometrics:optInBiometrics)
            _=await optInModel.unlock(password:password);await optInModel.refreshBiometrics()
            let optInBlocked=optInStore.url.appendingPathExtension("previous")
            try FileManager.default.createDirectory(at:optInBlocked,withIntermediateDirectories:true)
            check(!(await optInModel.enableBiometrics()) && optInBiometrics.enrollments == 0,"failed opt-in format migration never reaches biometric authentication or key enrollment")
            check(try Data(contentsOf:optInStore.url) == oldBytes && Data(contentsOf:optInDirectory.appendingPathComponent("protection.json")) == oldPreferences,"failed opt-in migration preserves both legacy ciphertext and legacy preferences")
            try FileManager.default.removeItem(at:optInBlocked)
            check(await optInModel.enableBiometrics(),"explicit opt-in can migrate a read-only legacy vault once storage succeeds")
            let optedInPayload=try Data(contentsOf:optInStore.url)
            check(try LauncherCore.VaultCryptography.unlock(data:optedInPayload,password:password).contents.version == 3 && rejects{_ = try VaultV1Compatibility.VaultCryptography.unlock(data:optedInPayload,password:password)},"biometric opt-in also fences the old payload writer before storing the protected key")
            optInModel.lock(reason:"finished opt-in migration checks")
            // Reconstruct the preceding v2 wire payload: its envelope/KDF are
            // unchanged, while new style fields did not yet exist in the JSON.
            var v2Object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(current.contents)) as! [String:Any]
            v2Object["version"]=2
            var v2Documents=v2Object["documents"] as! [[String:Any]]
            for index in v2Documents.indices {
                if var runs=v2Documents[index]["formatting"] as? [[String:Any]] {
                    for run in runs.indices {for key in ["strikethrough","textColor","highlightColor"] {runs[run].removeValue(forKey:key)}}
                    v2Documents[index]["formatting"]=runs
                }
            }
            v2Object["documents"]=v2Documents
            let v2Plain=try JSONSerialization.data(withJSONObject:v2Object)
            let v2Box=try AES.GCM.seal(v2Plain,using:current.key,authenticating:Data("deskden-encrypted-vault:1:pbkdf2-sha256-310000".utf8))
            let v2Envelope=LauncherCore.VaultEnvelope(rounds:LauncherCore.VaultCryptography.rounds,salt:current.envelope.salt,sealed:v2Box.combined!)
            let v2Store=LauncherCore.VaultFileStore(url:directory.appendingPathComponent("legacy-v2/private.deskdenvault"))
            try v2Store.write(v2Envelope);let v2Bytes=try v2Store.read()
            let v2Model=VaultModel(dataDirectory:v2Store.url.deletingLastPathComponent(),protectedDataAvailable:{true},biometrics:FormatSyntheticBiometrics())
            check(await v2Model.unlock(password:password),"version2 encrypted documents still unlock with their original password")
            check(v2Model.documents.first?.formatting?.first?.textColor == .automatic && v2Model.documents.first?.formatting?.first?.highlightColor == LauncherCore.VaultHighlightColor.none,
                  "version2 styles acquire safe color defaults without dropping their existing font traits")
            v2Model.lock(reason:"read-only v2 compatibility check")
            check(try v2Store.read() == v2Bytes,"read-only version2 unlock and lock preserve every original encrypted byte")
            _=await v2Model.unlock(password:password)
            let styledBody="Version3 color and strike 🔐"
            let styledRun=LauncherCore.VaultTextStyleRun(location:0,length:styledBody.utf16.count,family:.georgia,size:26,bold:true,
                strikethrough:true,textColor:.blue,highlightColor:.yellow)
            v2Model.updateRichBody(styledBody,formatting:[styledRun])
            check(v2Model.flush(),"explicit color editing of a version2 document commits its version3 migration")
            let styledResult=try LauncherCore.VaultCryptography.unlock(data:v2Store.read(),password:password)
            check(styledResult.contents.version == 3 && styledResult.contents.documents.first?.formatting == [styledRun],
                  "version3 reload preserves expanded font, 26 pt, strike and both semantic colors")
            check(try Data(contentsOf:v2Store.url.appendingPathExtension("previous")) == v2Bytes,
                  "version2 migration retains its exact prior encrypted revision")
            let styledPlain=try AES.GCM.open(AES.GCM.SealedBox(combined:styledResult.envelope.sealed),using:styledResult.key,
                authenticating:Data("deskden-encrypted-vault:1:pbkdf2-sha256-310000".utf8))
            check(rejects{_ = try JSONDecoder().decode(FrozenV2PayloadVersionGate.self,from:styledPlain)},
                  "the preceding version2 reader rejects the new payload before it could strip color fields")
            let v3BackupURL=directory.appendingPathComponent("version3-export.deskdenvault")
            check(v2Model.exportBackup(to:v3BackupURL),"version3 backup exports through the real model transaction")
            let v3Backup=try Data(contentsOf:v3BackupURL)
            let restoredV3=try LauncherCore.VaultCryptography.unlock(data:v3Backup,password:password)
            check(restoredV3.contents.documents.first?.formatting == [styledRun],"encrypted exported bytes keep version3 semantic text styles")
            let restoredModel=VaultModel(dataDirectory:directory.appendingPathComponent("restored-v3"),protectedDataAvailable:{true},biometrics:FormatSyntheticBiometrics())
            let loadedV3=restoredModel.loadRestoreSource(v3BackupURL)
            let verifiedV3=await restoredModel.verifyRestore(password:password)
            check(loadedV3 && verifiedV3,"version3 encrypted import validates the actual backup before replacement")
            let confirmedV3=restoredModel.confirmRestore()
            let unlockedV3=await restoredModel.unlock(password:password)
            check(confirmedV3 && unlockedV3 && restoredModel.documents.first?.formatting == [styledRun],
                  "confirmed model restore and password unlock preserve colors, strike and expanded fonts")
            check(try Data(contentsOf:v3BackupURL) == v3Backup,"restoring version3 never rewrites the exported backup")
            restoredModel.lock(reason:"finished v3 restore checks")
            v2Model.lock(reason:"finished v2 migration checks")
            var futureContents=current.contents;futureContents.version=4
            check(rejects{_ = try JSONEncoder().encode(futureContents)} && rejects{_ = try LauncherCore.VaultCryptography.seal(contents:futureContents,key:current.key,salt:current.envelope.salt)},"unknown future payload cannot be encoded or silently downgraded by the current writer")
            var futureObject=try JSONSerialization.jsonObject(with:JSONEncoder().encode(current.contents)) as! [String:Any]
            futureObject["version"]=4
            let futurePlaintext=try JSONSerialization.data(withJSONObject:futureObject)
            let futureBox=try AES.GCM.seal(futurePlaintext,using:current.key,authenticating:Data("deskden-encrypted-vault:1:pbkdf2-sha256-310000".utf8))
            let futureEnvelope=LauncherCore.VaultEnvelope(rounds:LauncherCore.VaultCryptography.rounds,salt:current.envelope.salt,sealed:futureBox.combined!)
            let futureStore=LauncherCore.VaultFileStore(url:directory.appendingPathComponent("future/private.deskdenvault"))
            try futureStore.write(futureEnvelope);let futureBytes=try futureStore.read()
            let futureModel=VaultModel(dataDirectory:directory.appendingPathComponent("future"),protectedDataAvailable:{true},biometrics:FormatSyntheticBiometrics())
            check(!(await futureModel.unlock(password:password)) && futureModel.documents.isEmpty,"unsupported future payload never exposes or adopts a partially decoded document")
            futureModel.newDocument();futureModel.updateBody("Synthetic attempted edit");_ = futureModel.flush()
            check(try futureStore.read() == futureBytes,"unsupported future payload remains byte-identical after attempted edits")
            let futurePreferences=Data("{\"schema\":3,\"idleMinutes\":1,\"biometricEnabled\":true}".utf8)
            try futurePreferences.write(to:directory.appendingPathComponent("future/protection.json"))
            let futureProtection=VaultModel(dataDirectory:directory.appendingPathComponent("future"),protectedDataAvailable:{true},biometrics:FormatSyntheticBiometrics())
            futureProtection.changeIdleMinutes(10)
            let futurePreferencesAfter=try Data(contentsOf:directory.appendingPathComponent("future/protection.json"))
            check(!futureProtection.canChangeProtectionPreferences && futurePreferencesAfter == futurePreferences,"unknown future preferences are protected against overwrite")
            var invalidPreferences=LauncherCore.VaultProtectionPreferences();invalidPreferences.schema=3
            check(rejects{_ = try JSONEncoder().encode(invalidPreferences)},"current preference encoder rejects unsupported future schema")
            model.lock(reason:"finished compatibility checks");reloaded.lock(reason:"finished compatibility checks")
        }catch{check(false,"unexpected synthetic compatibility failure: \(error.localizedDescription)")}
        print("Vault format compatibility checks: \(checks-failures)/\(checks) passed")
        exit(failures == 0 ? 0:1)
    }
}
@MainActor private final class FormatSyntheticBiometrics:VaultBiometricStore {
    var available=true
    var secret:Data?
    var salt:Data?
    var enrollments=0
    func containsKey() async -> Bool {secret != nil}
    func enroll(key:Data,salt:Data) async throws {secret=key;self.salt=salt;enrollments += 1}
    func readKey(salt:Data) async throws -> Data {guard self.salt == salt,let secret else {throw LauncherCore.VaultFailure.incorrectPassword};return secret}
    func remove() async throws {secret=nil;salt=nil}
    func removeSynchronously() throws {secret=nil;salt=nil}
    func cancel() {}
}

/// Exact pre-v3 payload version guard, retained to verify that old writers fail
/// before adopting a payload whose additional semantic styles they cannot keep.
private struct FrozenV2PayloadVersionGate:Decodable {
    let version:Int
    enum CodingKeys:String,CodingKey {case version}
    init(from decoder:Decoder) throws {
        let fields=try decoder.container(keyedBy:CodingKeys.self)
        version=try fields.decode(Int.self,forKey:.version)
        guard version == 1 || version == 2 else {throw LauncherCore.VaultFailure.invalidData}
    }
}
