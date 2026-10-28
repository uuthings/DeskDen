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
        checkClipboard(check)
        print("Vault editor checks: \(total-failures)/\(total) passed")
        exit(failures == 0 ? 0:1)
    }

    @MainActor private static func checkClipboard(_ check:(Bool,String)->Void) {
        let pasteboard=NSPasteboard.withUniqueName()
        defer {pasteboard.clearContents();pasteboard.releaseGlobally()}
        var scheduled:[@MainActor ()->Void]=[],delays:[TimeInterval]=[],cancellations=0
        let clipboard=VaultClipboard(pasteboard:pasteboard,schedule:{delay,action in
            delays.append(delay);scheduled.append(action)
            return {cancellations += 1}
        })
        let editor=VaultClipboardTextView(frame:NSRect(x:0,y:0,width:400,height:100))
        editor.clipboard=clipboard;editor.isRichText=true;editor.isEditable=true;editor.allowsUndo=false
        let privateText="Synthetic private text 🔐"
        editor.textStorage?.setAttributedString(NSAttributedString(string:privateText,attributes:[.font:NSFont.boldSystemFont(ofSize:18),.foregroundColor:NSColor.systemBlue]))
        editor.setSelectedRange(NSRange(location:0,length:(privateText as NSString).length))
        editor.copy(nil)
        check(pasteboard.string(forType:.string) == privateText,"production copy writes the complete Unicode selection to an isolated clipboard")
        check(pasteboard.types?.contains(VaultClipboard.concealedType) == true && pasteboard.types?.contains(VaultClipboard.transientType) == true,
              "private copies are marked confidential and transient before publication")
        let rich=pasteboard.data(forType:.rtf).flatMap{try? NSAttributedString(data:$0,options:[.documentType:NSAttributedString.DocumentType.rtf],documentAttributes:nil)}
        let font=rich?.attribute(.font,at:0,effectiveRange:nil) as? NSFont
        check(rich?.string == privateText && font?.pointSize == 18 && font.map{NSFontManager.shared.traits(of:$0).contains(.boldFontMask)} == true,
              "private copy preserves the native rich-text representation")
        check(delays == [180],"the clipboard cleanup deadline is three minutes")
        scheduled[0]()
        check(pasteboard.pasteboardItems?.isEmpty != false,"the cleanup deadline removes the clipboard data still owned by this copy")

        editor.copy(nil);let staleDeadline=scheduled.last!
        editor.setSelectedRange(NSRange(location:0,length:9));editor.copy(nil)
        let latestDeadline=scheduled.last!,latestCount=pasteboard.changeCount
        staleDeadline()
        check(pasteboard.changeCount == latestCount && pasteboard.string(forType:.string) == "Synthetic",
              "a cancelled earlier deadline cannot erase a newer private copy")
        latestDeadline()
        check(pasteboard.pasteboardItems?.isEmpty != false && cancellations>=3,"a repeated private copy cancels the old timer and gets its own deadline")

        editor.copy(nil);let replacedDeadline=scheduled.last!
        pasteboard.clearContents();pasteboard.setString("Synthetic later public copy",forType:.string)
        let replacementCount=pasteboard.changeCount
        replacedDeadline();clipboard.clearOwnedContents()
        check(pasteboard.changeCount == replacementCount && pasteboard.string(forType:.string) == "Synthetic later public copy",
              "deadline and lock cleanup both preserve a later copy from another source")

        editor.copy(nil);let lockDeadline=scheduled.last!
        clipboard.clearOwnedContents()
        check(pasteboard.pasteboardItems?.isEmpty != false,"locking immediately clears private clipboard content")
        pasteboard.setString("Synthetic copy after lock",forType:.string);let afterLockCount=pasteboard.changeCount
        lockDeadline()
        check(pasteboard.changeCount == afterLockCount && pasteboard.string(forType:.string) == "Synthetic copy after lock",
              "a deadline invalidated by locking cannot clear a subsequent copy")

        editor.string="Synthetic cut text";editor.setSelectedRange(NSRange(location:0,length:9));editor.cut(nil)
        check(editor.string == " cut text" && pasteboard.string(forType:.string) == "Synthetic",
              "production cut copies privately and deletes only the selected text")
        check(pasteboard.types?.contains(VaultClipboard.concealedType) == true,"cut uses the same confidential clipboard path")
        clipboard.clearOwnedContents()
        editor.setSelectedRange(NSRange(location:0,length:0));pasteboard.setString("Keep unrelated clipboard",forType:.string)
        let emptySelectionCount=pasteboard.changeCount;editor.copy(nil);editor.cut(nil)
        check(pasteboard.changeCount == emptySelectionCount && editor.string == " cut text","copy and cut with no selection leave text and unrelated clipboard data intact")

        let field=NSTextField(),secure=NSSecureTextField()
        let fieldEditor=VaultClipboard.privateFieldEditor(for:field) as? VaultClipboardTextView
        check(fieldEditor?.isFieldEditor == true && VaultClipboard.privateFieldEditor(for:secure) == nil && VaultClipboard.privateFieldEditor(for:NSView()) == nil,
              "private title and category fields use the protected field editor while secure fields retain their native editor")
        fieldEditor?.clipboard=clipboard;fieldEditor?.string="Synthetic category";fieldEditor?.setSelectedRange(NSRange(location:0,length:18));fieldEditor?.copy(nil)
        check(pasteboard.string(forType:.string) == "Synthetic category" && pasteboard.types?.contains(VaultClipboard.transientType) == true,
              "the shared native field editor protects title and category copying")
        VaultClipboard.shared.clearPrivateSession()
        check(fieldEditor?.string.isEmpty == true && fieldEditor?.undoManager?.canUndo != true,
              "locking clears cached private field-editor text even when it is not the active responder")
        fieldEditor?.clipboard = .shared;clipboard.clearOwnedContents()
        editor.string=""
    }
}
@MainActor private final class IsolatedEditor:NSTextView {
    // These commands execute synchronously without a native mouse event loop.
    // Explicit production command groups therefore define one undoable action.
    let history:UndoManager = {let manager=UndoManager();manager.groupsByEvent=false;return manager}()
    override var undoManager:UndoManager? {history}
}
