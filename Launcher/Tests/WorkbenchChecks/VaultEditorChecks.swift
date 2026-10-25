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
        editor.setSelectedRange(NSRange(location:0,length:9));controller.refresh()
        controller.setSize(22);check(controller.size == 22,"22 pt is a real native font size")
        controller.setSize(26);check(controller.size == 26,"26 pt is a real native font size")
        controller.toggleStrikethrough();controller.setTextColor(.blue);controller.setHighlightColor(.yellow)
        let decorated=VaultEditorFormatting.runs(editor.attributedString()).first
        check(decorated?.strikethrough == true && decorated?.textColor == .blue && decorated?.highlightColor == .yellow,
              "strike, text color and highlight compose as semantic selected-text formatting")
        check((editor.attributedString().attribute(.strikethroughStyle,at:0,effectiveRange:nil) as? Int) == NSUnderlineStyle.single.rawValue &&
              editor.attributedString().attribute(.foregroundColor,at:0,effectiveRange:nil) as? NSColor == VaultEditorFormatting.color(.blue,automatic:.textColor) &&
              editor.attributedString().attribute(.backgroundColor,at:0,effectiveRange:nil) as? NSColor == VaultEditorFormatting.highlight(.yellow),
              "semantic colors and strike paint actual native attributes")
        controller.setTextColor(.purple);editor.undoManager?.undo()
        check(VaultEditorFormatting.runs(editor.attributedString()).first?.textColor == .blue,"color changes participate in native undo")
        editor.undoManager?.redo()
        check(VaultEditorFormatting.runs(editor.attributedString()).first?.textColor == .purple,"color changes participate in native redo")
        VaultEditorFormatting.updateAutomaticColor(in:editor,color:.white)
        check(editor.attributedString().attribute(.foregroundColor,at:0,effectiveRange:nil) as? NSColor == VaultEditorFormatting.color(.purple,automatic:.white),
              "theme changes preserve explicitly colored text")
        check(VaultEditorFormatting.availableFamilies.count >= 6 && Set(VaultEditorFormatting.availableFamilies).count == VaultEditorFormatting.availableFamilies.count,
              "font choices contain several distinct actually installed families")
        let preserved=VaultEditorFormatting.runs(editor.attributedString())
        let restored=NSMutableAttributedString(string:editor.string)
        for style in preserved {restored.addAttributes(VaultEditorFormatting.attributes(for:style,automatic:.white),range:NSRange(location:style.location,length:style.length))}
        check(VaultEditorFormatting.runs(restored) == preserved,"persisted color and font runs reload without changing semantic ranges")
        editor.setSelectedRange(NSRange(location:0,length:9));controller.refresh();controller.clearFormatting()
        let cleared=VaultEditorFormatting.runs(editor.attributedString()).first
        check(cleared?.family == .system && cleared?.size == 14 && cleared?.bold == false && cleared?.italic == false && cleared?.underline == false && cleared?.strikethrough == false && cleared?.textColor == .automatic && cleared?.highlightColor == VaultHighlightColor.none,"clear formatting restores the shared body style")
        editor.setSelectedRange(NSRange(location:3,length:0));controller.refresh();controller.toggle(.boldFontMask);controller.setSize(18)
        let typingFont=editor.typingAttributes[.font] as? NSFont
        check(controller.bold && typingFont?.pointSize == 18 && NSFontManager.shared.traits(of:typingFont!).contains(.boldFontMask),"empty selection applies formatting to the next typed characters")
        controller.setTextColor(.red);controller.setHighlightColor(.blue);controller.toggleStrikethrough()
        check(controller.textColor == .red && controller.highlightColor == .blue && controller.strikethrough &&
              editor.typingAttributes[VaultEditorFormatting.textColorKey] as? String == VaultTextColor.red.rawValue,
              "insertion-point colors and strike apply to future typing without altering existing text")
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
@MainActor private final class IsolatedEditor:NSTextView {
    // These commands execute synchronously without a native mouse event loop.
    // Explicit production command groups therefore define one undoable action.
    let history:UndoManager = {let manager=UndoManager();manager.groupsByEvent=false;return manager}()
    override var undoManager:UndoManager? {history}
}
