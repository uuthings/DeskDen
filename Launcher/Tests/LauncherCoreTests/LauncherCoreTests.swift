import XCTest
@testable import LauncherCore

final class LauncherCoreTests: XCTestCase {
    let safari = LaunchTarget(kind:.app,name:"Safari",location:"/Applications/Safari.app")
    let notes = LaunchTarget(kind:.app,name:"备忘录",location:"/System/Applications/Notes.app",keywords:"Notes")
    func testPhysicalKeyboardIsCompleteAndUnique() {
        XCTAssertEqual(KeyboardLayout.keys.count,38)
        XCTAssertEqual(Set(KeyboardLayout.keyCodes.values),Set(KeyboardLayout.keys))
        XCTAssertNil(KeyboardLayout.keyCodes[49]); XCTAssertNil(KeyboardLayout.keyCodes[36])
    }
    func testDisplayModesFitTwelveKeysWithoutClipping() {
        for mode in DisplayMode.allCases {
            XCTAssertLessThanOrEqual(12*mode.keySize+11*7,mode.width-40)
            XCTAssertLessThan(mode.iconSize,mode.keySize)
        }
        XCTAssertEqual(Set(DisplayMode.allCases.map(\.height)),[560])
        XCTAssertEqual(Set(DisplayMode.allCases.map(\.width)),[1080])
    }
    func testApprovedVisibleIconDimensions() {
        XCTAssertEqual(DisplayMode.name.width,1080)
        XCTAssertEqual(DisplayMode.name.keySize,80)
        XCTAssertEqual(DisplayMode.name.iconSize,54,accuracy:0.01)
        XCTAssertEqual(DisplayMode.name.rowHeight+DisplayMode.name.rowGap,92)
        XCTAssertEqual(DisplayMode.icon.iconSize,57,accuracy:0.01)
        XCTAssertEqual(DisplayMode.key.iconSize,50,accuracy:0.01)
        XCTAssertEqual(DisplayMode.full.iconSize,45,accuracy:0.01)
        XCTAssertEqual(DisplayMode.full.height,560,accuracy:0.5)
        XCTAssertEqual(DisplayMode.name.height,560,accuracy:0.5)
        XCTAssertEqual(DisplayMode.icon.height,560,accuracy:0.5)
    }
    func testMovingDuplicateApplicationIsOneUndoStep() {
        let original = ["S":KeyBinding(target:safari),"N":KeyBinding(target:notes)]
        var draft = BindingEditor(original)
        draft.set(KeyBinding(target:safari),at:"N",movingFrom:"1",alsoRemoving:"S")
        XCTAssertNil(draft.bindings["S"])
        XCTAssertEqual(draft.bindings["N"]?.target,safari)
        draft.undo(); XCTAssertEqual(draft.bindings,original)
    }
    func testChineseNameFullPinyinAndInitials() {
        let entries = [SearchEntry(target:notes),SearchEntry(target:safari)]
        for query in ["备忘", "beiwanglu", "bwl", "Notes", "ＢＷＬ"] {
            XCTAssertEqual(SearchEngine.search(entries,query:query).map(\.id),[notes.id],query)
        }
    }
    func testSearchRanksExactBeforeSubstring() {
        let items = [LaunchTarget(kind:.app,name:"Safari Technology Preview",location:"/a.app"),safari].map { SearchEntry(target:$0) }
        XCTAssertEqual(SearchEngine.search(items,query:"safari").first?.id,safari.id)
    }
    func testSearchUsesBindingAliasAndDeduplicates() {
        let entries = SearchEngine.entries(applications:[notes,notes],bindings:["N":KeyBinding(target:notes,alias:"我的日记")],includeBindings:true)
        XCTAssertEqual(entries.count,1)
        XCTAssertEqual(SearchEngine.search(entries,query:"wdrj").first?.target,notes)
        XCTAssertEqual(SearchEngine.search(entries,query:"notes").first?.target,notes)
    }
    func testSearchPreservesChineseAliasOriginalNameAndEnglishMetadataInParallel() {
        let application = LaunchTarget(kind:.app,name:"活动监视器",location:"/System/Applications/Activity Monitor.app",keywords:"Activity Monitor\nActivityMonitor")
        var olderBindingTarget = application; olderBindingTarget.keywords = ""
        let entries = SearchEngine.entries(applications:[application],bindings:["A":KeyBinding(target:olderBindingTarget,alias:"电脑状态")],includeBindings:true)
        XCTAssertEqual(entries.count,1)
        XCTAssertEqual(entries.first?.title,"电脑状态")
        for query in ["电脑", "diannaozhuangtai", "dnzt", "活动", "huodongjianshiqi", "hdjsq", "activity monitor", "ActivityMonitor", "am", "actvtymntr"] {
            XCTAssertEqual(SearchEngine.search(entries,query:query).map(\.id),[application.id],query)
        }
    }
    func testEnglishWordsCamelCaseAndAbbreviationsAreSearchable() {
        let code = LaunchTarget(kind:.app,name:"Visual Studio Code",location:"/Applications/Visual Studio Code.app",keywords:"Code\nVSCode")
        let entry = SearchEntry(target:code)
        for query in ["Visual Studio Code", "visualstudiocode", "VSCode", "vsc", "vc", "visual code", "vstd", "vscode"] {
            XCTAssertNotNil(entry.score(query),query)
        }
        let monitor = SearchEntry(target:LaunchTarget(kind:.app,name:"ActivityMonitor",location:"/Applications/Monitor.app"))
        XCTAssertNotNil(monitor.score("am"))
        XCTAssertNotNil(monitor.score("monitor"))
        XCTAssertNotNil(monitor.score("actvtymntr"))
    }
    func testEnglishSubsequenceAllowsSkippedLettersButNotArbitraryDistantOrSingleLetters() {
        let entry = SearchEntry(target:safari)
        for query in ["safri", "sfri", "sfr", "sri"] { XCTAssertNotNil(entry.score(query),query) }
        XCTAssertNil(entry.score("f"),"A single interior letter must not become a fuzzy match")
        XCTAssertNil(entry.score("z"))
        let longName = SearchEntry(target:LaunchTarget(kind:.app,name:"A Very Long Unrelated Application Ending Z",location:"/Applications/Example.app"))
        XCTAssertNil(longName.score("az"),"Two letters at opposite ends of a long name must not match")
    }
    func testExactAndPrefixEnglishResultsRankAboveFuzzyMatches() {
        let exact = LaunchTarget(kind:.app,name:"SFR",location:"/Applications/Exact.app")
        let prefix = LaunchTarget(kind:.app,name:"SFR Tools",location:"/Applications/Prefix.app")
        let fuzzy = safari
        let entries = [SearchEntry(target:fuzzy),SearchEntry(target:prefix),SearchEntry(target:exact)]
        XCTAssertEqual(SearchEngine.search(entries,query:"sfr").map(\.id),[exact.id,prefix.id,fuzzy.id])
    }
    func testSearchDoesNotUsePrivateDirectoryOrWebAddressesAsNames() {
        let app = SearchEntry(target:LaunchTarget(kind:.app,name:"Editor",location:"/Users/test/SecretProject/Applications/Editor.app",keywords:"https://secret.example/private\n/private/hidden"))
        for query in ["secretproject", "secret", "hidden", "srtpjt", "https", "private"] { XCTAssertNil(app.score(query),query) }
        let web = SearchEntry(target:LaunchTarget(kind:.web,name:"文档",location:"https://private.example/SecretDashboard?token=hidden"))
        for query in ["secretdashboard", "private", "hidden", "scrtdshbrd"] { XCTAssertNil(web.score(query),query) }
        XCTAssertNotNil(web.score("wendang"))
    }
    func testAllAppsExcludesBoundFilesUntilQuery() {
        let file = LaunchTarget(kind:.file,name:"笔记",location:"/tmp/笔记.txt")
        let bindings = ["N":KeyBinding(target:file)]
        XCTAssertEqual(SearchEngine.entries(applications:[safari],bindings:bindings,includeBindings:false).count,1)
        XCTAssertEqual(SearchEngine.entries(applications:[safari],bindings:bindings,includeBindings:true).count,2)
    }
    func testDistinctApplicationLocationsRemainDistinguishable() {
        let alternate = LaunchTarget(kind:.app,name:"Safari",location:"/Users/test/Applications/Safari.app")
        XCTAssertEqual(SearchEngine.entries(applications:[safari,alternate],bindings:[:],includeBindings:false).count,2)
    }
    func testEmptyAndUnmatchedSearch() {
        let entries = [SearchEntry(target:notes)]
        XCTAssertEqual(SearchEngine.search(entries,query:"  ").count,1)
        XCTAssertTrue(SearchEngine.search(entries,query:"no-such-target").isEmpty)
    }
    func testPagingClampsAfterResultsShrink() {
        var selection = SearchSelection(); selection.page = 9; selection.selected = 23
        selection.clamp(total:25,pageSize:24)
        XCTAssertEqual(selection.page,1); XCTAssertEqual(selection.selected,0)
        XCTAssertEqual(selection.range(total:25,pageSize:24),24..<25)
        selection.clamp(total:0,pageSize:24)
        XCTAssertEqual(selection.page,0); XCTAssertEqual(selection.range(total:0,pageSize:24),0..<0)
    }
    func testNavigationNeverSelectsOutsideVisiblePage() {
        var value = SearchSelection(); value.move(-8,visibleCount:5); XCTAssertEqual(value.selected,0)
        value.move(8,visibleCount:5); XCTAssertEqual(value.selected,4)
        value.move(1,visibleCount:0); XCTAssertEqual(value.selected,0)
        XCTAssertEqual(value.pageCount(total:24,pageSize:24),1)
        XCTAssertEqual(value.pageCount(total:25,pageSize:24),2)
    }
    func testHorizontalArrowsKeepEachRowWhenCrossingPages() {
        for row in 0..<3 {
            var value = SearchSelection(); value.selected = row*7+6
            value.moveHorizontally(1,total:63,pageSize:21,columns:7)
            XCTAssertEqual(value.page,1); XCTAssertEqual(value.selected,row*7)
            value.moveHorizontally(-1,total:63,pageSize:21,columns:7)
            XCTAssertEqual(value.page,0); XCTAssertEqual(value.selected,row*7+6)
        }
    }
    func testHorizontalArrowsStayAtMissingRowsAndOuterEdges() {
        for row in 1..<3 {
            var value = SearchSelection(); value.selected = row*7+6
            value.moveHorizontally(1,total:22,pageSize:21,columns:7)
            XCTAssertEqual(value.page,0); XCTAssertEqual(value.selected,row*7+6)
        }
        var first = SearchSelection(); first.selected = 7
        first.moveHorizontally(-1,total:42,pageSize:21,columns:7)
        XCTAssertEqual(first.page,0); XCTAssertEqual(first.selected,7)
        var last = SearchSelection(); last.page = 1; last.selected = 20
        last.moveHorizontally(1,total:42,pageSize:21,columns:7)
        XCTAssertEqual(last.page,1); XCTAssertEqual(last.selected,20)
    }
    func testHorizontalArrowsNavigatePartialLastRowWithoutChangingRows() {
        var value = SearchSelection(); value.selected = 13
        value.moveHorizontally(1,total:30,pageSize:21,columns:7)
        XCTAssertEqual(value.page,1); XCTAssertEqual(value.selected,7)
        value.moveHorizontally(1,total:30,pageSize:21,columns:7)
        XCTAssertEqual(value.selected,8)
        value.moveHorizontally(1,total:30,pageSize:21,columns:7)
        XCTAssertEqual(value.page,1); XCTAssertEqual(value.selected,8)
        value.moveHorizontally(-1,total:30,pageSize:21,columns:7)
        XCTAssertEqual(value.selected,7)
        value.moveHorizontally(-1,total:30,pageSize:21,columns:7)
        XCTAssertEqual(value.page,0); XCTAssertEqual(value.selected,13)
    }
    func testHorizontalNavigationAlwaysSelectsAnExistingItemAndIsReversible() {
        for total in 1...65 {
            for absoluteIndex in 0..<total {
                for direction in [-1,1] {
                    var value = SearchSelection(); value.page = absoluteIndex/21; value.selected = absoluteIndex%21
                    let initialPage = value.page, initialOffset = value.selected
                    value.moveHorizontally(direction,total:total,pageSize:21,columns:7)
                    XCTAssertTrue((0..<total).contains(value.page*21+value.selected))
                    XCTAssertEqual(value.selected/7,initialOffset/7)
                    if value.page != initialPage || value.selected != initialOffset {
                        value.moveHorizontally(-direction,total:total,pageSize:21,columns:7)
                        XCTAssertEqual(value.page,initialPage); XCTAssertEqual(value.selected,initialOffset)
                    }
                }
            }
        }
    }
    func testHorizontalNavigationHandlesEmptyAndShrunkenResults() {
        var value = SearchSelection(); value.page = 9; value.selected = 20
        value.moveHorizontally(1,total:0,pageSize:21,columns:7)
        XCTAssertEqual(value.page,0); XCTAssertEqual(value.selected,0)
        value.page = 3; value.selected = 20
        value.moveHorizontally(1,total:22,pageSize:21,columns:7)
        XCTAssertEqual(value.page,1); XCTAssertEqual(value.selected,0)
    }
    func testDraftCancelLeavesOriginalUntouched() {
        let original = ["S":KeyBinding(target:safari)]
        var draft = BindingEditor(original); draft.remove("S"); draft.set(KeyBinding(target:notes),at:"N")
        XCTAssertEqual(original["S"]?.target,safari); XCTAssertNil(original["N"])
    }
    func testSwapWithEmptyAndUndo() {
        let original = ["S":KeyBinding(target:safari)]
        var draft = BindingEditor(original); draft.swap("S","N")
        XCTAssertNil(draft.bindings["S"]); XCTAssertEqual(draft.bindings["N"]?.target,safari)
        draft.undo(); XCTAssertEqual(draft.bindings,original)
    }
    func testMoveReplaceAndUndoAreOneOperation() {
        let original = ["S":KeyBinding(target:safari),"N":KeyBinding(target:notes)]
        var draft = BindingEditor(original); draft.set(KeyBinding(target:safari,alias:"浏览器"),at:"N",movingFrom:"S")
        XCTAssertNil(draft.bindings["S"]); XCTAssertEqual(draft.bindings["N"]?.title,"浏览器")
        draft.undo(); XCTAssertEqual(draft.bindings,original); XCTAssertTrue(draft.history.isEmpty)
    }
    func testInvalidKeyCannotModifyDraft() {
        var draft = BindingEditor(["S":KeyBinding(target:safari)])
        draft.set(KeyBinding(target:notes),at:"Space"); draft.swap("S","Space")
        XCTAssertEqual(draft.bindings.count,1); XCTAssertTrue(draft.history.isEmpty)
    }
    func testWebValidationRejectsExecutableSchemesAndCredentials() {
        for location in ["javascript:alert(1)","file:///etc/passwd","https://","example.com","https://name:secret@example.com"] {
            XCTAssertThrowsError(try LaunchTarget(kind:.web,name:"Website",location:location).validate(),location)
        }
        XCTAssertNoThrow(try LaunchTarget(kind:.web,name:"Website",location:"https://example.com/path?q=中文").validate())
    }
    func testWebTemplateReusesVariablesInFirstAppearanceOrder() throws {
        let template = try WebURLTemplate("https://example.com/{ID}?name={名字}&again={ID}#part={名字}")
        XCTAssertEqual(template.variables,["ID","名字"])
        let url = try template.resolvedURL(values:["ID":"one/two", "名字":"张 三&admin=true#尾"])
        XCTAssertEqual(url.host,"example.com")
        XCTAssertTrue(url.absoluteString.contains("/one%2Ftwo?"))
        let components = try XCTUnwrap(URLComponents(url:url,resolvingAgainstBaseURL:false))
        XCTAssertEqual(components.queryItems?.map(\.name),["name","again"])
        XCTAssertEqual(components.queryItems?.first?.value,"张 三&admin=true#尾")
        XCTAssertEqual(components.queryItems?.last?.value,"one/two")
        XCTAssertEqual(components.fragment,"part=张 三&admin=true#尾")
    }
    func testWebTemplateEncodingCannotInjectQueryOrChangeOrigin() throws {
        let template = try WebURLTemplate("https://example.com/search?q={q}")
        let value = "&next=https://other.example/?x=1#frag %2F +"
        let url = try template.resolvedURL(values:["q":value])
        let components = try XCTUnwrap(URLComponents(url:url,resolvingAgainstBaseURL:false))
        XCTAssertEqual(components.queryItems?.count,1)
        XCTAssertEqual(components.queryItems?.first?.value,value)
        XCTAssertNil(components.fragment)
        XCTAssertEqual(url.host,"example.com")
    }
    func testWebTemplateRejectsUnbalancedVariablesAndVariableAuthority() {
        for text in ["https://{domain}/a", "{scheme}://example.com", "https://example.com:{port}/", "https://example.com/{", "https://example.com/a}", "https://example.com/{}", "https://example.com/{ q}", "https://example.com/{{q}}", "https://example.com/a\nb"] {
            XCTAssertThrowsError(try WebURLTemplate(text),text)
        }
        XCTAssertNoThrow(try WebURLTemplate("https://example.com/%7BID%7D"))
        XCTAssertNoThrow(try LaunchTarget(kind:.web,name:"查询",location:"https://example.com/?q={名字}").validate())
    }
    func testWebTemplateMissingValuesDoNotBecomeLiteralBraces() throws {
        let template = try WebURLTemplate("https://example.com/?q={名字}")
        XCTAssertThrowsError(try template.resolvedURL())
        XCTAssertEqual(try template.resolvedURL(values:["名字":""]).absoluteString,"https://example.com/?q=")
        XCTAssertThrowsError(try template.resolvedURL(values:["名字":String(repeating:"a",count:4097)]))
    }
    func testIconOriginDoesNotSendSavedQueryOrVariables() throws {
        let template = try WebURLTemplate("https://example.com:8443/private/{名字}?token=saved#fragment")
        XCTAssertEqual(template.originURL.absoluteString,"https://example.com:8443/")
        XCTAssertEqual(try WebURLTemplate(" https://example.com/page ").resolvedURL().absoluteString,"https://example.com/page")
    }
    func testOptionalIconMigratesAndDoesNotChangeTargetIdentity() throws {
        var original = LaunchTarget(kind:.web,name:"文档",location:"https://example.com")
        let legacyData = try JSONEncoder().encode(original)
        XCTAssertFalse(String(decoding:legacyData,as:UTF8.self).contains("iconData"))
        XCTAssertNil(try JSONDecoder().decode(LaunchTarget.self,from:legacyData).iconData)
        XCTAssertNil(try JSONDecoder().decode(LaunchTarget.self,from:legacyData).iconIsCustom)
        let identity = original.id
        original.iconData = Data([1,2,3])
        original.iconIsCustom = true
        XCTAssertEqual(original.id,identity)
        XCTAssertEqual(try JSONDecoder().decode(LaunchTarget.self,from:JSONEncoder().encode(original)),original)
        original.iconData = Data(repeating:0,count:131_073)
        XCTAssertThrowsError(try original.validate())
    }
    func testApplicationGridUsesThreeRowsOfSeven() {
        XCTAssertEqual(ResultLayout.grid.pageSize,21)
        var selection = SearchSelection(); selection.page = 1
        XCTAssertEqual(selection.range(total:23,pageSize:ResultLayout.grid.pageSize),21..<23)
    }
    func testSortingKeepsStarsFirstAndCustomOrderStable() {
        let a = LaunchTarget(kind:.app,name:"A",location:"/a.app")
        let b = LaunchTarget(kind:.app,name:"B",location:"/b.app")
        let c = LaunchTarget(kind:.app,name:"C",location:"/c.app")
        XCTAssertEqual(ApplicationSorter.sorted([b,c,a],mode:.nameDescending,starred:[a.id]).map(\.id),[a.id,c.id,b.id])
        XCTAssertEqual(ApplicationSorter.sorted([b,c,a],mode:.custom,order:[c.id,c.id,a.id]).map(\.id),[c.id,a.id,b.id])
    }
    func testDateSortsUseRequestedFieldAndKeepUnknownDatesLast() {
        let a = LaunchTarget(kind:.app,name:"A",location:"/a.app"), b = LaunchTarget(kind:.app,name:"B",location:"/b.app"), c = LaunchTarget(kind:.app,name:"C",location:"/c.app")
        let earlier = Date(timeIntervalSince1970:100), later = Date(timeIntervalSince1970:200)
        let metadata = [a.id:ApplicationMetadata(addedAt:earlier,installedAt:later,lastUsedAt:earlier), b.id:ApplicationMetadata(addedAt:later,installedAt:earlier,lastUsedAt:later)]
        XCTAssertEqual(ApplicationSorter.sorted([c,b,a],mode:.addedNewest,metadata:metadata).map(\.id),[b.id,a.id,c.id])
        XCTAssertEqual(ApplicationSorter.sorted([c,b,a],mode:.installedNewest,metadata:metadata).map(\.id),[a.id,b.id,c.id])
        XCTAssertEqual(ApplicationSorter.sorted([c,b,a],mode:.usedOldest,metadata:metadata).map(\.id),[a.id,b.id,c.id])
    }
    func testSearchCanPreserveUserSortWithoutOverridingMatchQuality() {
        let a = LaunchTarget(kind:.app,name:"A Tool",location:"/a.app"), b = LaunchTarget(kind:.app,name:"B Tool",location:"/b.app"), exact = LaunchTarget(kind:.app,name:"Tool",location:"/tool.app")
        XCTAssertEqual(SearchEngine.search([b,a,exact].map { SearchEntry(target:$0) },query:"tool",preservingInputOrder:true).map(\.id),[exact.id,b.id,a.id])
    }
    func testLegacyConfigurationKeepsExistingDisplayAndDefaultsNewFields() throws {
        let data = Data(#"{"schemaVersion":1,"settings":{"display":"icon","hotKey":"optionSpace","hideOnLaunch":false,"resultLayout":"list","reduceMotion":true},"bindings":{},"addedApplications":[]}"#.utf8)
        let value = try JSONDecoder().decode(LauncherConfiguration.self,from:data)
        XCTAssertEqual(value.settings.display,.icon); XCTAssertEqual(value.settings.hotKey,.optionSpace)
        XCTAssertFalse(value.settings.hideOnLaunch); XCTAssertTrue(value.settings.reduceMotion)
        XCTAssertFalse(value.settings.lightAppearance); XCTAssertEqual(value.settings.appSort,.nameAscending)
        XCTAssertTrue(value.applicationOrder.isEmpty); XCTAssertTrue(value.scanDirectories.isEmpty)
        XCTAssertTrue(value.hiddenApplications.isEmpty); XCTAssertTrue(value.starredApplications.isEmpty)
        XCTAssertTrue(value.applicationMetadata.isEmpty)
        XCTAssertTrue(value.bindingHotKeys.isEmpty)
        XCTAssertNil(value.settings.directLaunchPrefix); XCTAssertNil(value.settings.applicationViewHotKey)
        XCTAssertEqual(LauncherConfiguration().settings.display,.name)
    }
    func testBindingShortcutsRequireModifierAndPhysicalKey() {
        XCTAssertThrowsError(try BindingHotKey(keyCode:13).validate())
        XCTAssertThrowsError(try BindingHotKey(keyCode:13,shift:true).validate())
        XCTAssertThrowsError(try BindingHotKey(keyCode:57,control:true).validate())
        XCTAssertNoThrow(try BindingHotKey(keyCode:13,control:true).validate())
        XCTAssertEqual(BindingHotKey(keyCode:13,control:true).title,"⌃W")
        XCTAssertEqual(BindingHotKey(keyCode:49,option:true,command:true).title,"⌥⌘空格")
    }
    func testDuplicateGlobalBindingShortcutCannotBeSaved() {
        var config = LauncherConfiguration()
        let shortcut = BindingHotKey(keyCode:13,control:true)
        config.bindingHotKeys = ["W":shortcut,"E":shortcut]
        XCTAssertThrowsError(try config.validate())
        config.bindingHotKeys.removeValue(forKey:"E")
        XCTAssertNoThrow(try config.validate())
    }
    func testUnifiedPrefixCoversOnlyBoundPhysicalKeys() throws {
        var config = LauncherConfiguration()
        config.settings.directLaunchPrefix = KeyShortcutPrefix(control:true)
        for key in KeyboardLayout.keys { config.bindings[key] = KeyBinding(target:safari) }
        try config.validate()
        XCTAssertEqual(Set(config.effectiveBindingHotKeys.keys),Set(KeyboardLayout.keys))
        XCTAssertEqual(Set(config.effectiveBindingHotKeys.values).count,38)
        for (code,key) in KeyboardLayout.keyCodes {
            XCTAssertEqual(config.effectiveBindingHotKeys[key],BindingHotKey(keyCode:code,control:true))
        }
        config.bindings.removeValue(forKey:"S")
        XCTAssertNil(config.effectiveBindingHotKeys["S"])
    }
    func testExplicitShortcutOverridesPrefixAndSurvivesDisablingIt() throws {
        var config = LauncherConfiguration()
        config.bindings = ["S":KeyBinding(target:safari),"N":KeyBinding(target:notes)]
        config.settings.directLaunchPrefix = KeyShortcutPrefix(control:true)
        let explicit = BindingHotKey(keyCode:105,option:true,command:true)
        config.bindingHotKeys["S"] = explicit
        try config.validate()
        XCTAssertEqual(config.effectiveBindingHotKeys["S"],explicit)
        XCTAssertEqual(config.effectiveBindingHotKeys["N"],KeyShortcutPrefix(control:true).shortcut(for:"N"))
        config.settings.directLaunchPrefix = nil
        XCTAssertEqual(config.effectiveBindingHotKeys,["S":explicit])
    }
    func testPrefixRejectsCrossKeyCollisionRatherThanDroppingABinding() {
        var config = LauncherConfiguration()
        let prefix = KeyShortcutPrefix(control:true)
        config.settings.directLaunchPrefix = prefix
        config.bindings = ["S":KeyBinding(target:safari),"N":KeyBinding(target:notes)]
        config.bindingHotKeys["S"] = prefix.shortcut(for:"N")
        XCTAssertThrowsError(try config.validate())
    }
    func testPrefixCannotReserveUnmodifiedOrShiftOnlyTyping() {
        XCTAssertThrowsError(try KeyShortcutPrefix().validate())
        XCTAssertThrowsError(try KeyShortcutPrefix(shift:true).validate())
        XCTAssertNoThrow(try KeyShortcutPrefix(control:true,shift:true).validate())
        XCTAssertNil(KeyShortcutPrefix(control:true).shortcut(for:"Esc"))
        XCTAssertEqual(KeyShortcutPrefix(control:true,option:true,shift:true,command:true).title,"⌃⌥⇧⌘")
    }
    func testApplicationViewShortcutMustBeDistinctFromLauncherAndTargets() {
        var config = LauncherConfiguration()
        config.settings.applicationViewHotKey = config.settings.effectiveLauncherHotKey
        XCTAssertThrowsError(try config.validate())
        config.bindings["S"] = KeyBinding(target:safari)
        let prefix = KeyShortcutPrefix(control:true)
        config.settings.directLaunchPrefix = prefix
        config.settings.applicationViewHotKey = prefix.shortcut(for:"S")
        XCTAssertThrowsError(try config.validate())
        config.settings.applicationViewHotKey = BindingHotKey(keyCode:103,option:true,command:true)
        XCTAssertNoThrow(try config.validate())
    }
    func testNewGlobalShortcutSettingsRoundTripWithoutChangingLegacyDefaults() throws {
        var config = LauncherConfiguration()
        config.bindings["S"] = KeyBinding(target:safari)
        config.settings.directLaunchPrefix = KeyShortcutPrefix(control:true,option:true)
        config.settings.applicationViewHotKey = BindingHotKey(keyCode:103,control:true,command:true)
        let restored = try JSONDecoder().decode(LauncherConfiguration.self,from:JSONEncoder().encode(config))
        XCTAssertEqual(restored,config)
        XCTAssertEqual(restored.settings.hotKey,.controlOptionSpace)
        XCTAssertEqual(restored.effectiveBindingHotKeys,config.effectiveBindingHotKeys)
        try restored.validate()
    }
    func testPanelPreferencesMigrateAndRoundTrip() throws {
        let old = Data(#"{"display":"name","hotKey":"controlOptionSpace"}"#.utf8)
        let migrated = try JSONDecoder().decode(LauncherSettings.self,from:old)
        XCTAssertEqual(migrated.defaultSearchInputMode,.quick)
        XCTAssertTrue(migrated.actionsEnabled); XCTAssertTrue(migrated.applicationsEnabled)
        XCTAssertTrue(migrated.scrollSwitchesViews)
        var configured = migrated
        configured.defaultSearchInputMode = .text; configured.actionsEnabled = false; configured.scrollSwitchesViews = false
        XCTAssertEqual(try JSONDecoder().decode(LauncherSettings.self,from:JSONEncoder().encode(configured)),configured)
    }
    func testAtLeastOnePanelMustRemainEnabled() throws {
        var config = LauncherConfiguration()
        config.settings.actionsEnabled = false
        XCTAssertNoThrow(try config.validate())
        config.settings.applicationsEnabled = false
        XCTAssertThrowsError(try config.validate())
        config.settings.actionsEnabled = true
        XCTAssertNoThrow(try config.validate())
    }
    func testHorizontalNavigationCrossesOnlyLeadingApplicationBoundary() {
        let settings = LauncherSettings()
        XCTAssertEqual(HorizontalNavigation.destination(applications:false,page:0,direction:1,settings:settings),.applications)
        XCTAssertEqual(HorizontalNavigation.destination(applications:false,page:0,direction:-1,settings:settings),.none)
        XCTAssertEqual(HorizontalNavigation.destination(applications:true,page:0,direction:-1,settings:settings),.actions)
        XCTAssertEqual(HorizontalNavigation.destination(applications:true,page:1,direction:-1,settings:settings),.page(-1))
        XCTAssertEqual(HorizontalNavigation.destination(applications:true,page:0,direction:1,settings:settings),.page(1))
    }
    func testDisabledCrossViewScrollRetainsApplicationPaging() {
        var settings = LauncherSettings(); settings.scrollSwitchesViews = false
        XCTAssertEqual(HorizontalNavigation.destination(applications:false,page:0,direction:1,settings:settings),.none)
        XCTAssertEqual(HorizontalNavigation.destination(applications:true,page:0,direction:-1,settings:settings),.page(-1))
        settings.scrollSwitchesViews = true; settings.actionsEnabled = false
        XCTAssertEqual(HorizontalNavigation.destination(applications:true,page:0,direction:-1,settings:settings),.page(-1))
        settings.actionsEnabled = true; settings.applicationsEnabled = false
        XCTAssertEqual(HorizontalNavigation.destination(applications:false,page:0,direction:1,settings:settings),.none)
        settings.applicationsEnabled = true; settings.resultLayout = .list
        XCTAssertEqual(HorizontalNavigation.destination(applications:true,page:0,direction:-1,settings:settings),.none)
        XCTAssertEqual(HorizontalNavigation.destination(applications:false,page:0,direction:1,settings:settings),.none)
    }
    func testScriptPathIsAFileNotACommandString() {
        XCTAssertThrowsError(try LaunchTarget(kind:.shell,name:"Script",location:"echo hello").validate())
        XCTAssertThrowsError(try LaunchTarget(kind:.shell,name:"Script",location:"/tmp/script.txt").validate())
        XCTAssertNoThrow(try LaunchTarget(kind:.shell,name:"Script",location:"/tmp/a 'quoted' $(untouched).sh").validate())
    }
    func testConfigurationRejectsFutureSchema() {
        var value = LauncherConfiguration(); value.schemaVersion = 2
        XCTAssertThrowsError(try value.validate())
    }
    func testConfigurationRejectsUnknownKeysAndLongAlias() {
        var value = LauncherConfiguration(); value.bindings["ESC"] = KeyBinding(target:safari)
        XCTAssertThrowsError(try value.validate())
        value.bindings = ["S":KeyBinding(target:safari,alias:String(repeating:"字",count:65))]
        XCTAssertThrowsError(try value.validate())
    }
}

final class ConfigurationStoreTests: XCTestCase {
    var directory:URL!
    var store:ConfigurationStore!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-store-tests-\(UUID().uuidString)",isDirectory:true)
        store = ConfigurationStore(url:directory.appendingPathComponent("configuration.json"))
    }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath:directory.path) { try FileManager.default.removeItem(at:directory) } }
    func testFirstRunDoesNotCreateDataUntilSave() throws { XCTAssertNil(try store.load()); XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path)) }
    func testRoundTripSettingsBindingsAndBookmarks() throws {
        var value = LauncherConfiguration(); value.settings.display = .icon; value.settings.hideOnLaunch = false
        value.bindings["1"] = KeyBinding(target:LaunchTarget(kind:.file,name:"中文.txt",location:"/tmp/中文.txt",bookmark:Data([1,2,3])),alias:"资料")
        try store.save(value); XCTAssertEqual(try store.load(),value)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:store.url.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
    }
    func testRoundTripApplicationManagementAndCustomIcons() throws {
        var value = LauncherConfiguration()
        value.settings.appSort = .custom; value.settings.lightAppearance = true
        value.scanDirectories = ["/tmp/Applications"]
        value.applicationOrder = ["app:/tmp/A.app","app:/tmp/B.app"]
        value.hiddenApplications = ["app:/tmp/B.app"]; value.starredApplications = ["app:/tmp/A.app"]
        value.applicationMetadata = ["app:/tmp/A.app":ApplicationMetadata(addedAt:Date(timeIntervalSince1970:123),lastUsedAt:Date(timeIntervalSince1970:456))]
        value.bindings["W"] = KeyBinding(target:LaunchTarget(kind:.web,name:"网页",location:"https://example.com/?id={ID}",iconData:Data([1,2,3]),iconIsCustom:true))
        value.bindingHotKeys["W"] = BindingHotKey(keyCode:13,control:true)
        try store.save(value)
        XCTAssertEqual(try store.load(),value)
    }
    func testPreviousSnapshotAndExplicitRecoveryPreserveCorruptData() throws {
        let first = LauncherConfiguration(); try store.save(first)
        var second = first; second.settings.display = .name; try store.save(second)
        let damaged = Data("not json".utf8); try damaged.write(to:store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try store.recoverPrevious(),first)
        XCTAssertEqual(try store.load(),first)
        let copies = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter { $0.lastPathComponent.contains("preserved-") }
        XCTAssertEqual(copies.count,1); XCTAssertEqual(try Data(contentsOf:copies[0]),damaged)
    }
    func testSaveNeverOverwritesCorruptConfiguration() throws {
        try store.save(LauncherConfiguration()); let damaged = Data("broken".utf8); try damaged.write(to:store.url)
        XCTAssertThrowsError(try store.save(LauncherConfiguration()))
        XCTAssertEqual(try Data(contentsOf:store.url),damaged)
    }
    func testValidationFailureLeavesLastGoodFileIntact() throws {
        let first = LauncherConfiguration(); try store.save(first); let data = try Data(contentsOf:store.url)
        var invalid = first; invalid.schemaVersion = 900
        XCTAssertThrowsError(try store.save(invalid)); XCTAssertEqual(try Data(contentsOf:store.url),data)
    }
    func testDisablingBothPanelsCannotReplaceSavedPreferences() throws {
        var value = LauncherConfiguration(); value.settings.defaultSearchInputMode = .text
        try store.save(value)
        let previous = try Data(contentsOf:store.url)
        value.settings.actionsEnabled = false; value.settings.applicationsEnabled = false
        XCTAssertThrowsError(try store.save(value))
        XCTAssertEqual(try Data(contentsOf:store.url),previous)
        XCTAssertEqual(try store.load()?.settings.defaultSearchInputMode,.text)
    }
    func testConflictingUnifiedShortcutCannotReplaceLastSavedConfiguration() throws {
        var first = LauncherConfiguration()
        let target = LaunchTarget(kind:.web,name:"Fixture",location:"https://example.com/")
        first.bindings = ["S":KeyBinding(target:target),"N":KeyBinding(target:target)]
        first.settings.directLaunchPrefix = KeyShortcutPrefix(control:true)
        first.settings.applicationViewHotKey = BindingHotKey(keyCode:105,option:true,command:true)
        try store.save(first)
        XCTAssertEqual(try store.load(),first)
        let original = try Data(contentsOf:store.url)
        var conflicting = first
        conflicting.bindingHotKeys["S"] = first.settings.directLaunchPrefix?.shortcut(for:"N")
        XCTAssertThrowsError(try store.save(conflicting))
        XCTAssertEqual(try Data(contentsOf:store.url),original)
        XCTAssertEqual(try store.load(),first)
    }
    func testOversizedEncodedConfigurationCannotReplaceReadableData() throws {
        let first = LauncherConfiguration(); try store.save(first)
        let original = try Data(contentsOf:store.url)
        var oversized = first
        oversized.addedApplications = [LaunchTarget(kind:.app,name:"Large",location:"/tmp/Large.app",keywords:String(repeating:"x",count:8_388_608))]
        XCTAssertThrowsError(try store.save(oversized))
        XCTAssertEqual(try Data(contentsOf:store.url),original)
        XCTAssertEqual(try store.load(),first)
    }
    func testUnreadableDestinationReportsFailure() throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try Data("obstacle".utf8).write(to:store.url)
        let inaccessible = ConfigurationStore(url:store.url.appendingPathComponent("config.json"))
        XCTAssertThrowsError(try inaccessible.save(LauncherConfiguration()))
    }
    func testBadBackupCannotReplaceCurrentData() throws {
        try store.save(LauncherConfiguration()); let original = try Data(contentsOf:store.url)
        try Data("invalid backup".utf8).write(to:store.backupURL)
        XCTAssertThrowsError(try store.recoverPrevious()); XCTAssertEqual(try Data(contentsOf:store.url),original)
    }
}
