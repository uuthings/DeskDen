import AppKit
import ImageIO
import LauncherCore
import UniformTypeIdentifiers

/// Disposable presentation and image fixtures; no picker, network, account or Keychain access.
@MainActor enum UsagePresentationModelChecks {
    static func run() -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(label)")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deskden-usage-icons-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let modelDirectory = directory.appendingPathComponent("Display")
            let model = UsagePresentationModel(dataDirectory: modelDirectory)
            let key = UsagePresentationSourceID.ai(.codex)
            check(!model.isCollapsed(.ai) && model.appearance(for: key).visible, "new presentation preserves visible AI cards and expanded groups")

            let legacyDirectory = directory.appendingPathComponent("Legacy")
            try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
            let legacyURL = legacyDirectory.appendingPathComponent("display-preferences.json")
            let legacyData = Data("""
            { "schemaVersion": 1, "aiCollapsed": true,
              "cards": { "ai.codex": { "displayName": "Legacy research", "visible": false } } }
            """.utf8)
            try legacyData.write(to: legacyURL)
            let legacy = UsagePresentationModel(dataDirectory: legacyDirectory)
            let legacyAfterLoad = try Data(contentsOf: legacyURL)
            check(legacy.storageError == nil && legacy.preferences.schemaVersion == 1 && legacy.isCollapsed(.ai)
                  && legacy.appearance(for: key).displayName == "Legacy research" && !legacy.appearance(for: key).visible,
                  "legacy presentation restores names, visibility and stored collapse preferences")
            check(legacyAfterLoad == legacyData && !FileManager.default.fileExists(atPath: legacyURL.appendingPathExtension("previous").path),
                  "opening a legacy model does not rewrite the original or create a migration backup")
            let legacyRegistrationDate = Date(timeIntervalSince1970: 1_700_000_000)
            check(legacy.registerSources([key], now: legacyRegistrationDate), "explicit source registration can persist the legacy presentation in the current format")
            let registeredLegacy = UsagePresentationModel(dataDirectory: legacyDirectory)
            check(registeredLegacy.preferences.schemaVersion == 3 && registeredLegacy.appearance(for: key).addedAt == legacyRegistrationDate
                  && registeredLegacy.appearance(for: key).displayName == "Legacy research" && !registeredLegacy.appearance(for: key).visible
                  && registeredLegacy.isCollapsed(.ai), "explicit legacy registration preserves display and compatibility choices across restart")

            let listDirectory = directory.appendingPathComponent("Classified list")
            let list = UsagePresentationModel(dataDirectory: listDirectory)
            let research = UsageCardCategory(title: "A Research"), network = UsageCardCategory(title: "Z Network")
            check(list.replaceCategories(list.preferences.categories + [research, network]), "custom categories save through the presentation model")
            let identity = UUID()
            let serviceKey = UsagePresentationSourceID.service(identity), apiKey = UsagePresentationSourceID.api(identity)
            let firstAdded = Date(timeIntervalSince1970: 1_700_000_000), laterAdded = firstAdded.addingTimeInterval(120)
            check(list.registerSources([serviceKey, key], now: firstAdded), "new list sources register their first observed creation time")
            let listURL = listDirectory.appendingPathComponent("display-preferences.json")
            let firstRegistration = try Data(contentsOf: listURL)
            let repeated = list.registerSources([key, serviceKey], now: laterAdded)
            let repeatedRegistration = try Data(contentsOf: listURL)
            check(repeated && firstRegistration == repeatedRegistration && list.preferences.sourceOrder == [serviceKey, key]
                  && list.appearance(for: key).addedAt == firstAdded && list.appearance(for: serviceKey).addedAt == firstAdded,
                  "registering known sources again preserves their creation dates, order and exact saved bytes")
            check(list.registerSources([key, apiKey, serviceKey], now: laterAdded)
                  && list.appearance(for: apiKey).addedAt == laterAdded && list.appearance(for: key).addedAt == firstAdded
                  && list.preferences.sourceOrder == [serviceKey, key, apiKey],
                  "registering a new API identity appends it without duplicating or redating existing sources")
            for (id, category) in [(key, research.id), (apiKey, research.id), (serviceKey, network.id)] {
                var display = list.appearance(for: id); display.categoryID = category
                check(list.saveAppearance(display, for: id), "a source category assignment saves without replacing its creation date")
            }
            let entries: [(id: String, name: String, category: String)] = [
                (key, "Zulu", research.id), (serviceKey, "Alpha", network.id), (apiKey, "Bravo", research.id)
            ]
            check(list.setOrdering(.added, ascending: true) && list.orderedSourceIDs(entries) == [serviceKey, key, apiKey],
                  "creation order uses first registration and stays deterministic for equal creation times")
            check(list.setOrdering(.added, ascending: false) && list.orderedSourceIDs(entries) == [apiKey, key, serviceKey],
                  "descending creation order reverses the chronological ranking")
            check(list.setOrdering(.name, ascending: true) && list.orderedSourceIDs(entries) == [serviceKey, apiKey, key],
                  "ascending name order sorts the combined AI, service and API list")
            check(list.setOrdering(.name, ascending: false) && list.orderedSourceIDs(entries) == [key, apiKey, serviceKey],
                  "descending name order applies across source kinds")
            let ties = entries.map { (id: $0.id, name: "Same name", category: $0.category) }
            let descendingTies = list.orderedSourceIDs(ties)
            let nameReload = UsagePresentationModel(dataDirectory: listDirectory)
            check(!nameReload.preferences.ascending && nameReload.preferences.sort == .name
                  && nameReload.orderedSourceIDs(Array(ties.reversed())) == descendingTies,
                  "equal names keep the same order after reload and input reordering")
            check(list.setOrdering(.name, ascending: true) && list.orderedSourceIDs(ties) == descendingTies,
                  "switching sort direction keeps equal-name ties stable")
            check(list.setOrdering(.category, ascending: true) && list.orderedSourceIDs(entries) == [apiKey, key, serviceKey],
                  "category ordering sorts by category and then by source name")
            check(list.setOrdering(.category, ascending: false) && list.orderedSourceIDs(entries) == [serviceKey, key, apiKey],
                  "descending category ordering also reverses names within a category")
            var reordered = list.preferences.categories.filter { $0.id != research.id && $0.id != network.id }
            reordered.insert(network, at: 0); reordered.insert(.init(id: research.id, title: "Renamed research"), at: 1)
            check(list.replaceCategories(reordered) && list.setOrdering(.category, ascending: true)
                  && list.orderedSourceIDs(entries) == [serviceKey, apiKey, key]
                  && list.categoryTitle(for: apiKey, defaultID: "api-balance") == "Renamed research",
                  "category order and renaming update the shared catalog without changing assignments")
            check(list.setOrdering(.category, ascending: true) && list.setCategoryFilter(research.id)
                  && list.orderedSourceIDs(entries) == [apiKey, key], "category filter selects assigned AI and API sources from one combined list")
            let filteredReload = UsagePresentationModel(dataDirectory: listDirectory)
            check(filteredReload.preferences.filterCategoryID == research.id && filteredReload.orderedSourceIDs(entries) == [apiKey, key]
                  && filteredReload.appearance(for: serviceKey).categoryID == network.id && filteredReload.appearance(for: apiKey).categoryID == research.id,
                  "reload preserves the custom filter and independent API and service assignments sharing a UUID")
            check(list.replaceCategories(list.preferences.categories.filter { $0.id != research.id })
                  && list.preferences.filterCategoryID == "uncategorized" && list.appearance(for: key).categoryID == "uncategorized"
                  && list.appearance(for: apiKey).categoryID == "uncategorized" && list.appearance(for: serviceKey).categoryID == network.id,
                  "deleting a category moves its assigned cards and active filter to uncategorized")
            let deletionReload = UsagePresentationModel(dataDirectory: listDirectory)
            check(deletionReload.preferences.filterCategoryID == "uncategorized" && deletionReload.orderedSourceIDs(entries).count == 2
                  && deletionReload.appearance(for: key).categoryID == "uncategorized"
                  && deletionReload.appearance(for: apiKey).addedAt == laterAdded
                  && deletionReload.preferences.categories.contains(network) && !deletionReload.preferences.categories.contains(research),
                  "category deletion, uncategorized migration and original creation dates persist after restart")
            let implicit = UsagePresentationModel(dataDirectory: directory.appendingPathComponent("Implicit categories"))
            check(implicit.registerSources([key, serviceKey], defaultCategoryIDs: [key: "ai-subscription", serviceKey: "vps-traffic"])
                  && implicit.appearance(for: key).categoryID == "ai-subscription"
                  && implicit.appearance(for: serviceKey).categoryID == "traffic-services",
                  "registration materializes legacy implicit categories using the shared catalog")
            check(implicit.replaceCategories(implicit.preferences.categories.filter { $0.id != "traffic-services" })
                  && implicit.categoryID(for: serviceKey, defaultID: "vps-traffic") == "uncategorized"
                  && implicit.appearance(for: serviceKey).categoryID == "uncategorized",
                  "deleting a default category cannot let implicit cards return through an old service default")
            let categoryEditor = UsageCategoryEditor(UsageCardCategory.defaults)
            categoryEditor.newCategoryName = "Work"; categoryEditor.addCategory()
            let workID = categoryEditor.categories.first { $0.title == "Work" }!.id
            categoryEditor.move(workID, by: -1)
            check(categoryEditor.hasChanges && categoryEditor.categories.last?.id == "uncategorized"
                  && categoryEditor.categories.firstIndex(where: { $0.id == workID }) == 2
                  && !categoryEditor.canMove("uncategorized", by: -1),
                  "category editing keeps uncategorized fixed while new categories can move")
            let beforeInvalidEdit = list.preferences, beforeInvalidBytes = try Data(contentsOf: listURL)
            let duplicateRejected = !list.replaceCategories(list.preferences.categories + [.init(id: network.id, title: "Duplicate identity")])
            let missingFilterRejected = !list.setCategoryFilter("missing-category")
            var invalidAssignment = list.appearance(for: key); invalidAssignment.categoryID = "missing-category"
            let missingAssignmentRejected = !list.saveAppearance(invalidAssignment, for: key)
            let afterInvalidBytes = try Data(contentsOf: listURL)
            check(duplicateRejected && missingFilterRejected && missingAssignmentRejected && list.preferences == beforeInvalidEdit && afterInvalidBytes == beforeInvalidBytes,
                  "invalid categories and references leave both active presentation and saved bytes unchanged")

            let source = directory.appendingPathComponent("fixture.png")
            guard let context = CGContext(data: nil, width: 1024, height: 512, bitsPerComponent: 8, bytesPerRow: 4096,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = context.makeImage() else { throw UsagePresentationError.image }
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { throw UsagePresentationError.image }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "fixture artist"]] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw UsagePresentationError.image }
            try (png as Data).write(to: source)
            let icon = try model.importImage(from: source)
            let normalized = model.image(for: icon)
            check(normalized?.size.width == 256 && normalized?.size.height == 128, "custom icon is copied and downsampled while preserving its aspect ratio")
            check(model.saveAppearance(.init(displayName: "  Research  ", icon: icon, visible: false), for: key)
                  && model.setCollapsed(true, group: .service), "display edits save independently from source collection")
            try FileManager.default.removeItem(at: source)
            let restored = UsagePresentationModel(dataDirectory: modelDirectory)
            check(restored.appearance(for: key).displayName == "Research" && !restored.appearance(for: key).visible
                  && restored.isCollapsed(.service) && restored.image(for: icon) != nil, "restart restores appearance and managed icon after original image is removed")
            if case .image(let name) = icon {
                let saved = modelDirectory.appendingPathComponent("Icons").appendingPathComponent(name)
                let data = try Data(contentsOf: saved)
                let decoded = CGImageSourceCreateWithData(data as CFData, nil)!
                let properties = CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any]
                let metadata = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
                check(metadata?[kCGImagePropertyTIFFArtist] == nil && data.count <= UsagePresentationModel.maximumStoredImageBytes, "normalized icon does not retain original image metadata")
            }
            let oversized = directory.appendingPathComponent("oversized.png")
            try Data(count: UsagePresentationModel.maximumImportBytes + 1).write(to: oversized)
            check((try? model.importImage(from: oversized)) == nil, "oversized input is rejected before image decoding")
            let malformed = directory.appendingPathComponent("malformed.png")
            try Data("not an image".utf8).write(to: malformed)
            let symlink = directory.appendingPathComponent("linked.png")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: malformed)
            check((try? model.importImage(from: malformed)) == nil && (try? model.importImage(from: symlink)) == nil, "malformed and linked inputs cannot become managed images")
            let configuration = modelDirectory.appendingPathComponent("display-preferences.json")
            let damaged = Data("{invalid".utf8); try damaged.write(to: configuration)
            let protected = UsagePresentationModel(dataDirectory: modelDirectory)
            let rejected = !protected.setCollapsed(true, group: .ai)
            let after = try Data(contentsOf: configuration)
            check(protected.storageError != nil && rejected && after == damaged, "damaged presentation original blocks writes and stays intact")
            let refusedNewSettings = !protected.setOrdering(.name, ascending: false) && !protected.setCategoryFilter(nil)
                && !protected.replaceCategories(protected.preferences.categories) && !protected.registerSources([key])
            let afterNewSettings = try Data(contentsOf: configuration)
            check(refusedNewSettings && afterNewSettings == damaged,
                  "damaged presentation protection also blocks category, filter, sort and registration writes")
        } catch { check(false, "presentation fixture failed: \(error.localizedDescription)") }
        print("Usage presentation checks: \(count) checks, \(failures) failures")
        return (count, failures)
    }
}
