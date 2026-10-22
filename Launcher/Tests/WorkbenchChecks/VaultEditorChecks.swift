import AppKit
import CryptoKit
import LauncherCore

/// Synthetic native text only. No window, user files, authentication, or Keychain.
@main struct VaultEditorChecks {
    @MainActor static func main() {
        _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        var total=0,failures=0
        func check(_ condition:Bool,_ message:String){total += 1;if !condition {failures += 1};print("\(condition ? "PASS":"FAIL") \(message)")}
        let editor=IsolatedEditor(frame:NSRect(x:0,y:0,width:500,height:300))
        editor.isRichText=true;editor.allowsUndo=true
        let paragraph=VaultEditorFormatting.paragraph()
        editor.defaultParagraphStyle=paragraph
        editor.textStorage?.setAttributedString(NSAttributedString(string:"Synthetic text\n中文 🔐",attributes:[.font:VaultEditorFormatting.font(family:.system,size:14),.paragraphStyle:paragraph,VaultEditorFormatting.familyKey:VaultFontFamily.system.rawValue]))
        editor.typingAttributes=[.font:VaultEditorFormatting.font(family:.system,size:14),.paragraphStyle:paragraph,VaultEditorFormatting.familyKey:VaultFontFamily.system.rawValue]
        let controller=VaultEditorFormatting();controller.attach(editor)
        check(paragraph.minimumLineHeight == 0 && paragraph.maximumLineHeight == 0,"body and insertion point use natural font metrics")
        editor.setSelectedRange(NSRange(location:0,length:9));controller.refresh();controller.toggle(.boldFontMask)
        check(controller.bold && VaultEditorFormatting.runs(editor.attributedString()).first?.bold == true,"bold changes the native selected text")
        controller.toggle(.italicFontMask);controller.toggleUnderline();controller.setFamily(.serif);controller.setSize(20)
        let run=VaultEditorFormatting.runs(editor.attributedString()).first
        check(run?.family == .serif && run?.size == 20 && run?.bold == true && run?.italic == true && run?.underline == true,"font, size, and decorations compose without losing traits")
        check(editor.selectedRange() == NSRange(location:0,length:9),"toolbar commands preserve the selected range")
        editor.undoManager?.undo()
        check(VaultEditorFormatting.runs(editor.attributedString()).first?.size == 14,"native undo restores previous formatting")
        editor.undoManager?.redo()
        check(VaultEditorFormatting.runs(editor.attributedString()).first?.size == 20,"native redo restores the formatting command")
        editor.setSelectedRange(NSRange(location:0,length:9));controller.refresh();controller.clearFormatting()
        let cleared=VaultEditorFormatting.runs(editor.attributedString()).first
        check(cleared?.family == .system && cleared?.size == 14 && cleared?.bold == false && cleared?.italic == false && cleared?.underline == false,"clear formatting restores the shared body style")
        editor.setSelectedRange(NSRange(location:3,length:0));controller.refresh();controller.toggle(.boldFontMask);controller.setSize(18)
        let typingFont=editor.typingAttributes[.font] as? NSFont
        check(controller.bold && typingFont?.pointSize == 18 && NSFontManager.shared.traits(of:typingFont!).contains(.boldFontMask),"empty selection applies formatting to the next typed characters")
        check(editor.string == "Synthetic text\n中文 🔐","format commands never modify the underlying Unicode body")
        do {
            var document=PrivateDocument(title:"Synthetic editor",body:editor.string)
            document.formatting=VaultEditorFormatting.runs(editor.attributedString())
            let contents=VaultContents(documents:[document]);try contents.validate()
            let encrypted=try VaultCryptography.create(contents:contents,password:"synthetic-editor-password")
            let unlocked=try VaultCryptography.unlock(data:VaultCryptography.encoded(encrypted.envelope),password:"synthetic-editor-password")
            check(unlocked.contents == contents,"native semantic runs survive encrypted persistence")
        }catch{check(false,"native rich text validates and encrypts: \(error.localizedDescription)")}
        editor.string="";editor.undoManager?.removeAllActions();controller.detach()
        check(editor.string.isEmpty && editor.undoManager?.canUndo == false && controller.editor == nil,"native plaintext, format undo, and editor reference can be cleared on lock")
        print("Vault editor checks: \(total-failures)/\(total) passed")
        exit(failures == 0 ? 0:1)
    }
}
@MainActor private final class IsolatedEditor:NSTextView {let history=UndoManager();override var undoManager:UndoManager? {history}}
