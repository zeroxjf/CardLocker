// MARK: - AppDelegate to handle Dock icon clicks
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Find the main "CardVault" window (or the first visible window) and bring it to front
        if let window = sender.windows.first(where: { $0.title == "CardVault" }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }
}
//
//  ConsolidatedCardVaultCode.swift
//  CardVault
//
//  Created by Johnny Franks on 5/25/25.
//

import SwiftUI
import LocalAuthentication
import AppKit
import Combine
import CloudKit
import Security // Added from KeychainService and Models

// MARK: - DisplayMode (from CardVaultApp copy.txt)
enum DisplayMode: String, CaseIterable {
    case menuBar = "Menu Bar Only"
    case appWindow = "App Window Only"
    case both = "Both"
}

// MARK: - CardMetadata (from Models copy.txt)
/// Lightweight metadata synced via CloudKit
struct CardMetadata: Identifiable, Hashable, Codable {
    var id: UUID
    var nickname: String
    var category: String
    var notes: String
    var lastModified: Date
    var deletedDate: Date?
    var originalCategory: String?
}

extension CardMetadata {
    func toCKRecord() -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString)
        let record = CKRecord(recordType: "Card", recordID: recordID)
        record["nickname"]     = nickname    as NSString
        record["category"]     = category    as NSString
        record["notes"]        = notes       as NSString
        record["lastModified"] = lastModified as NSDate
        if let deleted = deletedDate {
            record["deletedDate"] = deleted as NSDate
        }
        if let original = originalCategory {
            record["originalCategory"] = original as NSString
        }
        return record
    }
}

// MARK: - Card (from Models copy.txt)
struct Card: Identifiable, Hashable, Codable {
    /// Sensitive fields stored in Keychain
    var number: String?
    var expiry: String?
    var cvv: String?

    var metadata: CardMetadata

    // Convenience accessors
    var id: UUID { metadata.id }
    var nickname: String { metadata.nickname }
    var category: String { metadata.category }
    var notes: String { metadata.notes }
    var lastModified: Date { metadata.lastModified }
    var deletedDate: Date? { metadata.deletedDate }

    var last4: String? {
        guard let number = number else { return nil }
        return String(number.suffix(4))
    }

    init(metadata: CardMetadata, number: String? = nil, expiry: String? = nil, cvv: String? = nil) {
        self.metadata = metadata
        self.number = number
        self.expiry = expiry
        self.cvv = cvv
    }
}

// MARK: - KeychainService (from KeychainService copy.txt)
/// A simple wrapper around Keychain operations for CardVault.
enum KeychainService {
    private static let service = "CardVault"

    /// Save secure card fields (number, expiry, cvv) to Keychain.
    static func save(_ card: Card) {
        let fields = [
            ("number", card.number ?? ""),
            ("expiry", card.expiry ?? ""),
            ("cvv", card.cvv ?? "")
        ]

        for (key, value) in fields {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "\(card.id.uuidString)_\(key)"
            ]

            // Remove any existing item
            SecItemDelete(query as CFDictionary)

            // Insert the new value
            var attributes = query
            attributes[kSecValueData as String] = value.data(using: .utf8)
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    /// Load secure card fields from Keychain for a given Card.
    static func loadFields(for card: Card) -> Card {
        var updated = card

        func read(_ key: String) -> String? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "\(card.id.uuidString)_\(key)",
                kSecReturnData as String: true
            ]
            var result: AnyObject?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data {
                return String(data: data, encoding: .utf8)
            }
            return nil
        }

        updated.number = read("number")
        updated.expiry = read("expiry")
        updated.cvv = read("cvv")
        return updated
    }

    /// Delete all secure fields for a card from Keychain.
    static func deleteFields(for card: Card) {
        let keys = ["number", "expiry", "cvv"]
        for key in keys {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "\(card.id.uuidString)_\(key)"
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}

// MARK: - CardStore (from Models copy.txt)
final class CardStore: ObservableObject {
    /// Returns whether iCloud sync is enabled by user preference.
    private var isICloudEnabled: Bool {
        UserDefaults.standard.bool(forKey: "useICloud")
    }
    @Published var cards: [Card] = []

    private let storageKey = "storedCards"

    // MARK: - CloudKit Operations

    private let cloudContainer = CKContainer.default().privateCloudDatabase

    private func modifyRecord(_ record: CKRecord, delete: Bool = false, attempt: Int = 0) {
        guard isICloudEnabled else { return }
        let op: CKDatabaseOperation
        if delete {
            op = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: [record.recordID])
        } else {
            let modifyOp = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            modifyOp.savePolicy = .changedKeys
            op = modifyOp
        }
        (op as? CKModifyRecordsOperation)?.modifyRecordsCompletionBlock = { saved, deleted, error in
            if let ckError = error as? CKError,
               [.serviceUnavailable, .zoneBusy, .serverRecordChanged].contains(ckError.code),
               let retry = ckError.userInfo[CKErrorRetryAfterKey] as? TimeInterval,
               attempt < 3 {
                DispatchQueue.global().asyncAfter(deadline: .now() + retry) {
                    self.modifyRecord(record, delete: delete, attempt: attempt + 1)
                }
                return
            } else if let error = error {
                print("☁️ Cloud operation error:", error)
            }
        }
        cloudContainer.add(op)
    }

    private let appGroupID = "group.com.JFTech.CardVault"
    private var storeURL: URL {
        if let container = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent("storedCards.json")
        } else {
            // Fallback to Documents folder if App Group not available
            print("⚠️ App Group container missing; using Documents folder")
            let docs = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
            ).first!
            return docs.appendingPathComponent("storedCards.json")
        }
    }

    /// Keys available for sorting the card list
    enum SortKey: String, CaseIterable {
        case nickname = "Title"
        case number = "Card Number"
        case expiry = "Expiry"
        case category = "Category"
    }

    /// Returns cards filtered by category, search text, and sorted by the given key and order.
    func filteredCards(categorySelection: String,
                       searchText: String,
                       sortKey: SortKey,
                       sortAscending: Bool) -> [Card] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        // Base filter by category and search
        let base: [Card] = {
            switch categorySelection {
            case "Deleted":
                return cards.filter {
                    $0.category == "Deleted" &&
                    ($0.deletedDate ?? .distantPast) > cutoff &&
                    (searchText.isEmpty ||
                        $0.nickname.localizedCaseInsensitiveContains(searchText) ||
                        ($0.number ?? "").localizedCaseInsensitiveContains(searchText))
                }
            case "All":
                return cards.filter {
                    $0.category != "Deleted" &&
                    (searchText.isEmpty ||
                        $0.nickname.localizedCaseInsensitiveContains(searchText) ||
                        ($0.number ?? "").localizedCaseInsensitiveContains(searchText))
                }
            default:
                return cards.filter {
                    $0.category == categorySelection &&
                    (searchText.isEmpty ||
                        $0.nickname.localizedCaseInsensitiveContains(searchText) ||
                        ($0.number ?? "").localizedCaseInsensitiveContains(searchText))
                }
            }
        }()
        // Sort either numerically (for card numbers) or lexically
        let sorted: [Card]
        if sortKey == .number {
            sorted = base.sorted {
                let lhs = Int(($0.number ?? "").filter { char in char.isNumber }) ?? 0
                let rhs = Int(($1.number ?? "").filter { char in char.isNumber }) ?? 0
                return sortAscending ? lhs < rhs : lhs > rhs
            }
        } else if sortKey == .expiry {
            sorted = base.sorted {
                let lhs = $0.expiry ?? ""
                let rhs = $1.expiry ?? ""
                return sortAscending ? lhs < rhs : lhs > rhs
            }
        } else {
            sorted = base.sorted {
                let lhsValue: String
                let rhsValue: String
                switch sortKey {
                case .nickname: lhsValue = $0.nickname; rhsValue = $1.nickname
                case .category: lhsValue = $0.category; rhsValue = $1.category
                default:        lhsValue = "";          rhsValue = ""
                }
                return sortAscending ? lhsValue < rhsValue : lhsValue > rhsValue
            }
        }
        return sorted
    }

    init() {
        loadCards()
        if isICloudEnabled {
            subscribeToChanges(attempt: 0)
        }
        // No more unlock state in CardStore; rely on AutoLockManager.shared
    }

    func addCard(_ card: Card) {
        cards.append(card)
        saveCards()
        guard isICloudEnabled else { return }
        let record = CKRecord(recordType: "Card", recordID: CKRecord.ID(recordName: card.metadata.id.uuidString))
        // Removed setting record["id"] as per instructions
        record["nickname"] = card.metadata.nickname as NSString
        // Do not store sensitive fields in CloudKit
        // record["number"] = card.number as NSString?
        // record["expiry"] = card.expiry as NSString?
        // record["cvv"] = card.cvv as NSString?
        record["category"] = card.metadata.category as NSString
        record["deletedDate"] = card.metadata.deletedDate as NSDate?
        record["notes"] = card.metadata.notes as NSString
        record["lastModified"] = card.metadata.lastModified as NSDate
        modifyRecord(record)
    }


    /// Soft-delete a card (moves to "Deleted" and sets deletedDate)
    func softDeleteCard(_ card: Card) {
        var deleted = card
        // Always store originalCategory locally
        deleted.metadata.originalCategory = deleted.metadata.category
        deleted.metadata.category = "Deleted"
        deleted.metadata.deletedDate = Date()
        updateCard(deleted)  // Always update local store and save

        if isICloudEnabled {
            // Sync with iCloud if enabled (updateCard will sync, so no-op needed here)
            // If you want to ensure iCloud is updated immediately, you could call updateCard(deleted) again, but that's redundant.
            // Optionally, could use a dedicated method, but updateCard handles iCloud sync.
        }
    }
    /// Recover a soft-deleted card, restoring its original category.
    func recoverCard(_ card: Card) {
        var recovered = card
        // Restore category to originalCategory if present, else fallback to "Credit"
        recovered.metadata.category = recovered.metadata.originalCategory ?? "Credit"
        recovered.metadata.originalCategory = nil
        recovered.metadata.deletedDate = nil
        updateCard(recovered) // Always update local store and save

        if isICloudEnabled {
            recoverCardInCloud(recovered)
        }
    }

    /// Permanently delete a card after 30 days
    func purgeCard(_ card: Card) {
        if let index = cards.firstIndex(where: { $0.metadata.id == card.metadata.id }) {
            cards.remove(at: index)
            saveCards()
            guard isICloudEnabled else { return }
            let recordID = CKRecord.ID(recordName: card.metadata.id.uuidString)
            let deleteRecord = CKRecord(recordType: "Card", recordID: recordID)
            modifyRecord(deleteRecord, delete: true)
        }
    }

    func updateCard(_ card: Card) {
        // Update the lastModified timestamp
        var updated = card
        updated.metadata.lastModified = Date()
        if let index = cards.firstIndex(where: { $0.metadata.id == updated.metadata.id }) {
            cards[index] = updated
            saveCards()
            // Always update local store and saveCards. Conditionally sync to iCloud.
            guard isICloudEnabled else { return }
            let recordID = CKRecord.ID(recordName: updated.metadata.id.uuidString)
            cloudContainer.fetch(withRecordID: recordID) { record, error in
                if let record = record, error == nil {
                    // Removed setting record["id"] as per instructions
                    record["nickname"] = updated.metadata.nickname as NSString
                    // Do not store sensitive fields in CloudKit
                    // record["number"] = updated.number as NSString?
                    // record["expiry"] = updated.expiry as NSString?
                    // record["cvv"] = updated.cvv as NSString?
                    record["category"] = updated.metadata.category as NSString
                    record["deletedDate"] = updated.metadata.deletedDate as NSDate?
                    record["notes"] = updated.metadata.notes as NSString
                    record["lastModified"] = updated.metadata.lastModified as NSDate
                    // Also sync originalCategory if present (for recovery support)
                    if let originalCategory = updated.metadata.originalCategory {
                        record["originalCategory"] = originalCategory as NSString
                    } else {
                        record["originalCategory"] = nil
                    }
                    self.modifyRecord(record)
                } else {
                    // If record doesn't exist, create a new one
                    let newRecord = CKRecord(recordType: "Card", recordID: recordID)
                    // Removed setting newRecord["id"] as per instructions
                    newRecord["nickname"] = updated.metadata.nickname as NSString
                    // Do not store sensitive fields in CloudKit
                    // newRecord["number"] = updated.number as NSString?
                    // newRecord["expiry"] = updated.expiry as NSString?
                    // newRecord["cvv"] = updated.cvv as NSString?
                    newRecord["category"] = updated.metadata.category as NSString
                    newRecord["deletedDate"] = updated.metadata.deletedDate as NSDate?
                    newRecord["notes"] = updated.metadata.notes as NSString
                    newRecord["lastModified"] = updated.metadata.lastModified as NSDate
                    if let originalCategory = updated.metadata.originalCategory {
                        newRecord["originalCategory"] = originalCategory as NSString
                    }
                    self.modifyRecord(newRecord)
                }
            }
        }
    }
    
    func deleteCardFromKeychain(_ card: Card) {
        let service = "CardVault"
        let keys = ["number", "expiry", "cvv"]
        for key in keys {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "\(card.id.uuidString)_\(key)"
            ]
            SecItemDelete(query as CFDictionary)
        }
    }


    /// Updates the card metadata and secure fields (Keychain)
    func securelyUpdateCard(_ card: Card) {
        KeychainService.save(card)
        guard isICloudEnabled else { return }
        updateCard(card)
    }

    private func loadCards() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([Card].self, from: data) else {
            cards = []
            return
        }
        cards = decoded
        removeOldDeletedCards()
    }

    func saveCards() {
        removeOldDeletedCards()
        if let encoded = try? JSONEncoder().encode(cards) {
            try? encoded.write(to: storeURL, options: [.atomic])
        }
    }

    func subscribeToChanges(attempt: Int = 0) {
        guard isICloudEnabled else { return }
        let subscription = CKQuerySubscription(
            recordType: "Card",
            predicate: NSPredicate(value: true),
            subscriptionID: "card-changes",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        
        cloudContainer.save(subscription) { _, error in
            if let error = error as? CKError,
               attempt < 3,
               let retry = error.userInfo[CKErrorRetryAfterKey] as? TimeInterval {
                print("Cloud subscription failed, retrying in \(retry)s: \(error)")
                DispatchQueue.global().asyncAfter(deadline: .now() + retry) {
                    self.subscribeToChanges(attempt: attempt + 1)
                }
            } else if let error = error {
                print("Cloud subscription error: \(error)")
            }
        }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCloudKitNotification),
            name: .CKAccountChanged,
            object: nil
        )
    }
    
    
    @objc private func handleCloudKitNotification() {
        if isICloudEnabled {
            fetchFromCloud()
        }
    }

    func fetchFromCloud() {
        guard isICloudEnabled else { return }
        let query = CKQuery(recordType: "Card", predicate: NSPredicate(value: true))
        cloudContainer.perform(query, inZoneWith: nil) { records, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("Failed to fetch cards from CloudKit: \(error)")
                } else if let records = records {
                    let fetchedCards = records.compactMap { record -> Card? in
                        let idString = record.recordID.recordName
                        guard let id = UUID(uuidString: idString),
                              let nickname = record["nickname"] as? String,
                              let category = record["category"] as? String,
                              let notes = record["notes"] as? String,
                              let lastModified = record["lastModified"] as? Date
                        else {
                            return nil
                        }
                        let deletedDate = record["deletedDate"] as? Date
                        let originalCategory = record["originalCategory"] as? String
                        let metadata = CardMetadata(
                            id: id,
                            nickname: nickname,
                            category: category,
                            notes: notes,
                            lastModified: lastModified,
                            deletedDate: deletedDate,
                            originalCategory: originalCategory
                        )
                        return KeychainService.loadFields(for: Card(metadata: metadata))
                    }
                    self.cards = fetchedCards
                    self.saveCards()
                }
            }
        }
    }
    // The legacy fetchFromCloud() using fetch(withQuery:) has been removed.

    /// Recovers a soft-deleted card in CloudKit and restores its original category.
    func recoverCardInCloud(_ card: Card, attempt: Int = 0) {
        guard isICloudEnabled else { return }
        let privateDB = cloudContainer
        let recordID = CKRecord.ID(recordName: card.metadata.id.uuidString)

        privateDB.fetch(withRecordID: recordID) { record, error in
            guard let record = record, error == nil else {
                if let ckError = error as? CKError {
                    DispatchQueue.main.async {
                        print("Sync error captured: \(ckError.localizedDescription)")
                    }
                }
                print("Cloud recover fetch error:", error ?? "Unknown error")
                return
            }

            // Restore category before saving record
            let restoredCategory = record["originalCategory"] as? String ?? "Credit"
            record["category"] = restoredCategory as NSString
            record["originalCategory"] = nil
            record["deletedDate"] = nil
            record["lastModified"] = Date() as NSDate

            let modifyOp = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            modifyOp.savePolicy = .changedKeys
            modifyOp.modifyRecordsCompletionBlock = { _, _, opError in
                if let ckError = opError as? CKError,
                   ckError.code == .serverRecordChanged,
                   let retryAfter = ckError.userInfo[CKErrorRetryAfterKey] as? TimeInterval,
                   attempt < 3 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + retryAfter) {
                        self.recoverCardInCloud(card, attempt: attempt + 1)
                    }
                } else if let opError = opError {
                    if let ckError = opError as? CKError {
                        DispatchQueue.main.async {
                            print("Sync error captured: \(ckError.localizedDescription)")
                        }
                    }
                    print("Cloud recover error:", opError)
                } else {
                    print("Record \(card.id) recovered in iCloud")

                    // Update local card to reflect restored category
                    var updatedCard = card
                    updatedCard.metadata.category = restoredCategory
                    updatedCard.metadata.originalCategory = nil
                    updatedCard.metadata.deletedDate = nil
                    self.updateCard(updatedCard)
                }
            }
            privateDB.add(modifyOp)
        }
    }

    private func removeOldDeletedCards() {
        cards.removeAll { card in
            if card.category == "Deleted", let date = card.deletedDate,
               date <= Date().addingTimeInterval(-30*24*60*60) {
                purgeCard(card)
                return true
            }
            return false
        }
    }



    deinit {
        NotificationCenter.default.removeObserver(self)
        print("🗑️ [CardStore] deinitialized and removed observers")
    }
}

// MARK: - AutoLockMode (from Models copy.txt)
/// Modes in which auto-lock can operate
public enum AutoLockMode: String, CaseIterable {
    case menuBarOnly = "Menu Bar Only"   // Only lock when the menu bar UI is active
    case appOnly     = "App Only"        // Only lock when any app window is active
    case both        = "Both"            // Lock in both scenarios
}

// MARK: - AutoLockManager (from Models copy.txt)
/// Manages auto-lock logic across different app modes
public class AutoLockManager: ObservableObject {
    /// Shared application‐lifetime auto‐lock manager
    public static let shared: AutoLockManager = {
        let minutes = UserDefaults.standard.integer(forKey: "autoLockInterval")
        let interval = TimeInterval(minutes) * 60
        let modeRaw = UserDefaults.standard.string(forKey: "autoLockMode")
            ?? AutoLockMode.both.rawValue
        let mode = AutoLockMode(rawValue: modeRaw) ?? .both
        let manager = AutoLockManager(interval: interval, mode: mode)
        if UserDefaults.standard.bool(forKey: "lockOnBoot"), mode != .menuBarOnly {
            manager.performLockCheck()
        }
        return manager
    }()
    /// Indicates whether the app is currently locked
    @Published public private(set) var isLocked: Bool = false

    private var lockTimer: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitors: [Any] = []

    /// Time interval (in seconds) after which the app should auto-lock
    private var interval: TimeInterval
    /// Current auto-lock mode
    private var mode: AutoLockMode

    // MARK: - Prompt-on-return flag
    private var hasPromptedOnReturn = false

    /// Initializes the manager with a given interval and mode
    /// - Parameters:
    ///   - interval: Seconds before auto-lock fires
    ///   - mode: One of `AutoLockMode` values
    private init(interval: TimeInterval, mode: AutoLockMode) {
        self.interval = interval
        self.mode = mode
        subscribeToAppNotifications()
        resetTimer()
        // Monitor basic UI events to reset timer on interaction
        let masks: [NSEvent.EventTypeMask] = [.keyDown, .leftMouseDown, .scrollWheel]
        for mask in masks {
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
                self?.userDidInteract()
                return event
            }) {
                eventMonitors.append(monitor)
            }
        }
    }

    /// Resets and restarts the auto-lock timer
    public func resetTimer() {
        // Skip scheduling for “Never” or zero interval (<= 0)
        guard interval > 0 else {
            lockTimer?.cancel()
            print("🔒 [AutoLockManager] resetTimer skipped (interval <= 0)")
            return
        }
        print("🔒 [AutoLockManager] resetTimer called - interval: \(interval) mode: \(mode.rawValue)")
        lockTimer?.cancel()
        lockTimer = Timer
            .publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                switch self.mode {
                case .both:
                    self.performLockCheck()
                case .appOnly:
                    // Only lock if the app is frontmost
                    if NSApp.isActive {
                        self.performLockCheck()
                    }
                case .menuBarOnly:
                    // Always lock in menu-bar mode on timer
                    self.performLockCheck()
                }
            }
    }

    /// Cancels the auto-lock timer
    public func cancelTimer() {
        lockTimer?.cancel()
    }

    /// Call this from user interaction events to prevent premature locking
    public func userDidInteract() {
        guard mode != .appOnly else { return }
        print("🔒 [AutoLockManager] userDidInteract - resetting timer (mode: \(mode.rawValue))")
        resetTimer()
    }

    public func performLockCheck() {
        guard !isLocked else { return }
        print("🔒 [AutoLockManager] performLockCheck triggered - locking now")
        isLocked = true
        hasPromptedOnReturn = false
        cancelTimer()
    }

    private func subscribeToAppNotifications() {
        // App became active (focused)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self = self else { return }
                print("🔒 [AutoLockManager] App did become active - mode: \(self.mode.rawValue)")
                if self.isLocked {
                    // Prompt once on return
                    if !self.hasPromptedOnReturn {
                        self.hasPromptedOnReturn = true
                        self.authenticate { success in
                            if success {
                                self.unlock()
                            }
                        }
                    }
                } else if self.mode != .menuBarOnly {
                    self.resetTimer()
                }
            }
            .store(in: &cancellables)

        // Immediately lock on deactivation when interval <= 0 (Immediate setting)
        NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.interval <= 0 {
                    self.performLockCheck()
                }
            }
            .store(in: &cancellables)
    }

    /// Unlocks the app and restarts the auto-lock timer
    public func unlock() {
        print("🔓 [AutoLockManager] unlock called - unlocking now")
        self.isLocked = false
        resetTimer()
    }

    /// Prompts the user with the system authentication dialog
    public func authenticate(completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var authError: NSError?
        let reason = "Unlock CardVault"
        // Use device owner authentication (passcode or biometrics)
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                DispatchQueue.main.async {
                    completion(success)
                }
            }
        } else {
            // Cannot evaluate policy (Touch ID or passcode not available)
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Authentication Unavailable"
                alert.informativeText = "Please enable Touch ID or device passcode for CardVault in System Settings to unlock the app."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                completion(false)
            }
        }
    }

    /// Updates the auto-lock interval and mode at runtime
    public func updateSettings(interval: TimeInterval, mode: AutoLockMode) {
        self.interval = interval
        self.mode = mode
        resetTimer()
    }
    deinit {
        // Remove interaction event monitors
        eventMonitors.forEach { NSEvent.removeMonitor($0) }
        eventMonitors.removeAll()
        lockTimer?.cancel()
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        print("🔒 [AutoLockManager] deinitialized and cancelled subscriptions")
    }
}

// MARK: - ContentView (from ContentView copy.txt)
struct ContentView: View {
    @EnvironmentObject var autoLockManager: AutoLockManager
    
    private func authenticateUser() {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Authenticate to unlock") { success, authError in
                DispatchQueue.main.async {
                    if success {
                        autoLockManager.unlock()
                    }
                }
            }
        }
    }
    
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Hello, world!")
        }
        .padding()
        .onAppear {
            autoLockManager.resetTimer()
        }
        .onTapGesture {
            autoLockManager.userDidInteract()
        }
        .onReceive(autoLockManager.$isLocked) { locked in
            if locked {
                authenticateUser()
            }
        }
    }
}

// MARK: - SettingsView (from SettingsView copy.txt)
struct SettingsView: View {
    @AppStorage("useICloud") private var useICloud: Bool = false
    @AppStorage("showInDock") private var showInDock: Bool = true
    @EnvironmentObject var statusBarController: StatusBarController
    @EnvironmentObject var store: CardStore
    @AppStorage("autoLockInterval") private var autoLockInterval: Int = 5
    @AppStorage("lockOnBoot") private var lockOnBoot: Bool = true
    @EnvironmentObject var autoLockManager: AutoLockManager

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            GroupBox(label: Text("Appearance").font(.headline)) {
                Toggle("Show in Dock", isOn: $showInDock)
                    .padding(.top, 4)
            }

            GroupBox(label: Text("Cloud Sync").font(.headline)) {
                Toggle("Enable iCloud Sync", isOn: $useICloud)
            }


            // Placeholder for future settings section
            GroupBox(label: Text("Preferences").font(.headline)) {
                Text("More settings coming soon...")
                    .foregroundColor(.secondary)
            }

            Divider()
            Button("Reset to Defaults") {
                useICloud = false
                showInDock = true
                autoLockInterval = 5
                lockOnBoot = true
                autoLockManager.updateSettings(
                    interval: TimeInterval(autoLockInterval) * 60,
                    mode: .both
                )
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 420)
    }
}


// MARK: - CloudKit Helper Functions (from CardViews copy.txt)
private func recoverCardInCloud(_ card: Card, store: CardStore, attempt: Int = 0) {
    guard UserDefaults.standard.bool(forKey: "useICloud") else { return }
    let privateDB = CKContainer.default().privateCloudDatabase
    let recordID = CKRecord.ID(recordName: card.id.uuidString)
    privateDB.fetch(withRecordID: recordID) { record, error in
        guard let record = record, error == nil else {
            if let ckError = error as? CKError {
                DispatchQueue.main.async {
                    // Assuming you have access to cloudError from CardListView;
                    // replace with a call to a passed-in error handler, or log for now.
                    print("Sync error captured: \(ckError.localizedDescription)")
                }
            }
            print("Cloud recover fetch error:", error ?? "Unknown error")
            return
        }
        // Undo soft-delete fields
        let restoredCategory = card.metadata.originalCategory ?? "Credit"
        record["category"] = restoredCategory as NSString
        record["deletedDate"] = nil as NSDate?
        record["lastModified"] = Date() as NSDate

        let modifyOp = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        modifyOp.savePolicy = .changedKeys
        modifyOp.modifyRecordsCompletionBlock = { _, _, opError in
            if let ckError = opError as? CKError,
               ckError.code == .serverRecordChanged,
               let retryAfter = ckError.userInfo[CKErrorRetryAfterKey] as? TimeInterval,
               attempt < 3 {
                DispatchQueue.global().asyncAfter(deadline: .now() + retryAfter) {
                    recoverCardInCloud(card, store: store, attempt: attempt + 1)
                }
            } else if let opError = opError {
                if let ckError = opError as? CKError {
                    DispatchQueue.main.async {
                        // Assuming you have access to cloudError from CardListView;
                        // replace with a call to a passed-in error handler, or log for now.
                        print("Sync error captured: \(ckError.localizedDescription)")
                    }
                }
                print("Cloud recover error:", opError)
            } else {
                print("Record \(card.id) recovered in iCloud")
                // Update CloudKit record to restore category, and clear originalCategory
                let restoredCategory = record["originalCategory"] as? String ?? "Credit"
                record["category"] = restoredCategory as NSString
                record["originalCategory"] = nil

                // Update local card to reflect restored category
                var updatedCard = card
                updatedCard.metadata.category = restoredCategory
                updatedCard.metadata.originalCategory = nil
                updatedCard.metadata.deletedDate = nil
                store.updateCard(updatedCard)
            }
        }
        privateDB.add(modifyOp)
    }
}

private func modifyCardInCloud(_ card: Card, attempt: Int = 0) {
    guard UserDefaults.standard.bool(forKey: "useICloud") else { return }
    let privateDB = CKContainer.default().privateCloudDatabase
    let recordID = CKRecord.ID(recordName: card.metadata.id.uuidString)
    privateDB.fetch(withRecordID: recordID) { record, error in
        guard let record = record, error == nil else {
            if let ckError = error as? CKError {
                DispatchQueue.main.async {
                    print("Sync error captured: \(ckError.localizedDescription)")
                }
            }
            print("Cloud modify fetch error:", error ?? "Unknown error")
            return
        }
        // Update fields (only metadata, not sensitive info)
        record["nickname"] = card.metadata.nickname as NSString
        record["category"] = card.metadata.category as NSString
        record["notes"] = card.metadata.notes as NSString
        record["lastModified"] = Date() as NSDate

        // Save originalCategory if present, else clear it
        if let originalCategory = card.metadata.originalCategory {
            record["originalCategory"] = originalCategory as NSString
        } else {
            record["originalCategory"] = nil
        }

        let modifyOp = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        modifyOp.savePolicy = .changedKeys
        modifyOp.modifyRecordsCompletionBlock = { _, _, opError in
            if let ckError = opError as? CKError,
               ckError.code == .serverRecordChanged,
               let retryAfter = ckError.userInfo[CKErrorRetryAfterKey] as? TimeInterval,
               attempt < 3 {
                DispatchQueue.global().asyncAfter(deadline: .now() + retryAfter) {
                    modifyCardInCloud(card, attempt: attempt + 1)
                }
            } else if let opError = opError {
                if let ckError = opError as? CKError {
                    DispatchQueue.main.async {
                        print("Sync error captured: \(ckError.localizedDescription)")
                    }
                }
                print("Cloud modify error:", opError)
            } else {
                print("Record \(card.metadata.id) updated in iCloud")
            }
        }
        privateDB.add(modifyOp)
    }
}

private func deleteCardFromCloud(_ cardID: UUID, permanent: Bool, attempt: Int = 0) {
    guard UserDefaults.standard.bool(forKey: "useICloud") else { return }
    let privateDB = CKContainer.default().privateCloudDatabase
    let recordID = CKRecord.ID(recordName: cardID.uuidString)

    if permanent {
        // Permanently delete the record
        privateDB.delete(withRecordID: recordID) { _, error in
            if let ckError = error as? CKError {
                if ckError.code == .serverRecordChanged,
                   let retryAfter = ckError.userInfo[CKErrorRetryAfterKey] as? TimeInterval,
                   attempt < 3 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + retryAfter) {
                        deleteCardFromCloud(cardID, permanent: true, attempt: attempt + 1)
                    }
                    return
                }
                DispatchQueue.main.async {
                    // Assuming you have access to cloudError from CardListView;
                    // replace with a call to a passed-in error handler, or log for now.
                    print("Sync error captured: \(ckError.localizedDescription)")
                }
                print("Cloud delete error:", ckError)
            } else if let error = error {
                print("Cloud delete error:", error)
            } else {
                print("Record \(cardID) permanently deleted from iCloud")
            }
        }
    } else {
        // Soft-delete: update field via modify operation
        privateDB.fetch(withRecordID: recordID) { record, error in
            guard let record = record, error == nil else {
                if let ckError = error as? CKError {
                    DispatchQueue.main.async {
                        // Assuming you have access to cloudError from CardListView;
                        // replace with a call to a passed-in error handler, or log for now.
                        print("Sync error captured: \(ckError.localizedDescription)")
                    }
                }
                print("Cloud soft-delete fetch error:", error ?? "Unknown error")
                return
            }
            // Save original category before marking as Deleted
            record["originalCategory"] = record["category"]
            record["category"] = "Deleted" as NSString
            record["deletedDate"] = Date() as NSDate
            record["lastModified"] = Date() as NSDate

            let modifyOp = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            modifyOp.savePolicy = .changedKeys
            modifyOp.modifyRecordsCompletionBlock = { saved, deleted, opError in
                if let ckError = opError as? CKError {
                    if (ckError.code == .serverRecordChanged),
                       let retryAfter = ckError.userInfo[CKErrorRetryAfterKey] as? TimeInterval,
                       attempt < 3 {
                        DispatchQueue.global().asyncAfter(deadline: .now() + retryAfter) {
                            deleteCardFromCloud(cardID, permanent: false, attempt: attempt + 1)
                        }
                        return
                    }
                    DispatchQueue.main.async {
                        // Assuming you have access to cloudError from CardListView;
                        // replace with a call to a passed-in error handler, or log for now.
                        print("Sync error captured: \(ckError.localizedDescription)")
                    }
                    print("Cloud soft-delete error:", ckError)
                } else if let error = opError {
                    print("Cloud soft-delete error:", error)
                } else {
                    print("Record \(cardID) soft-deleted in iCloud")
                }
            }
            privateDB.add(modifyOp)
        }
    }
}

// MARK: - CardListView (from CardViews copy.txt)
struct CardListView: View {
    // Remove title; use categorySelection instead
    @EnvironmentObject var store: CardStore
    @Binding var selectedCard: Card?
    @Binding var categorySelection: String

    @State private var searchText: String = ""
    @State private var showingAddCard = false
    @State private var sortKey: CardStore.SortKey = .nickname
    @State private var sortAscending: Bool = true
    @State private var isInfoHidden: Bool = true
    @State private var showingDeleteConfirmation = false
    @State private var showingPermanentDeleteConfirmation = false
    @State private var cloudError: CKError?

    @AppStorage("autoLockInterval") private var autoLockInterval: Int = 5
    @AppStorage("autoLockMode") private var autoLockModeValue: AutoLockMode = .both // Renamed to avoid conflict
    @EnvironmentObject var autoLockManager: AutoLockManager

    @State private var isEditingMode = false
    @State private var selectedCards: Set<UUID> = []



    private let categoryColors: [String: Color] = [
        "All": .green,
        "Credit": .blue,
        "Debit": .red,
        "Rewards": .cyan,
        "Business": .orange,
        "Deleted": .gray
    ]

    var filteredCards: [Card] {
        store.filteredCards(
            categorySelection: categorySelection,
            searchText: searchText,
            sortKey: sortKey,
            sortAscending: sortAscending
        )
    }

    // Header, search, sort, and add button
    private var listHeader: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(categorySelection)
                        .font(.largeTitle.weight(.bold))
                    Text("\(filteredCards.count) Items")
                        .foregroundColor(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    // Sort menu and add button, edit button
                    Menu {
                        Picker("Sort by", selection: $sortKey) {
                            ForEach(CardStore.SortKey.allCases, id: \.self) { key in
                                Text(key.rawValue).tag(key)
                            }
                        }
                        Divider()
                        Picker("Order", selection: $sortAscending) {
                            Text("Ascending").tag(true)
                            Text("Descending").tag(false)
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                            .labelStyle(.iconOnly)
                            .imageScale(.medium)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15)))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    // Add Card button
                    Button {
                        showingAddCard = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15)))
                    }
                    .buttonStyle(PlainButtonStyle())
                    // Edit/Done button
                    Button(action: {
                        isEditingMode.toggle()
                        if !isEditingMode {
                            selectedCards.removeAll()
                        }
                    }) {
                        Text(isEditingMode ? "Done" : "Edit")
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            Divider().padding(.top, 2)
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gray.opacity(0.3)))
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
        .padding(.horizontal, 14)
        .background(Color(NSColor.windowBackgroundColor).ignoresSafeArea())
    }

    // Scrollable card list
    private var listContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredCards) { card in
                    let isSelected = selectedCard?.id == card.id
                    let isMarkedForDeletion = selectedCards.contains(card.id)
                    HStack {
                        if isEditingMode {
                            Button(action: {
                                if selectedCards.contains(card.id) {
                                    selectedCards.remove(card.id)
                                } else {
                                    selectedCards.insert(card.id)
                                }
                            }) {
                                Image(systemName: isMarkedForDeletion ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(isMarkedForDeletion ? .accentColor : .gray)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        CardListRow(card: card, isSelected: isSelected, categoryColors: categoryColors)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .onTapGesture {
                                if isEditingMode {
                                    if selectedCards.contains(card.id) {
                                        selectedCards.remove(card.id)
                                    } else {
                                        selectedCards.insert(card.id)
                                    }
                                } else {
                                    selectedCard = card
                                }
                            }
                            .contextMenu {
                                if !isEditingMode {
                                    Button("Open in New Window") { print("Open in New Window tapped for card \(card.nickname)") }
                                    Divider()
                                    Button("Copy Card Number") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(card.number ?? "", forType: .string)
                                    }
                                    Button("Copy Expiry") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(card.expiry ?? "", forType: .string)
                                    }
                                    Button("Copy CVV") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(card.cvv ?? "", forType: .string)
                                    }
                                    Divider()
                                    Button("Edit") {
                                        selectedCard = card // This will show CardDetailView which has edit functionality
                                    }
                                    Button("Delete…", role: .destructive) {
                                        showingDeleteConfirmation = true
                                        selectedCard = card
                                    }
                                }
                            }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            // Delete selected button
            if isEditingMode && !selectedCards.isEmpty {
                Button(action: {
                    print("Bulk delete tapped – selected IDs:", selectedCards)
                    withAnimation {
                        for cardID in selectedCards {
                            if let cardToDelete = store.cards.first(where: { $0.id == cardID }) {
                                if categorySelection == "Deleted" {
                                    print("Permanently deleting card:", cardID)
                                    store.purgeCard(cardToDelete)
                                    store.deleteCardFromKeychain(cardToDelete)
                                    // Force the view to refresh
                                    store.objectWillChange.send()
                                    deleteCardFromCloud(cardToDelete.id, permanent: true)
                                } else {
                                    print("Soft deleting card:", cardID)
                                    store.softDeleteCard(cardToDelete)
                                    store.objectWillChange.send()
                                }
                            }
                        }
                    }
                    selectedCards.removeAll()
                    isEditingMode = false
                }) {
                    Text(categorySelection == "Deleted"
                        ? "Permanently Delete Selected (\(selectedCards.count))"
                        : "Delete Selected (\(selectedCards.count))")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.vertical, 10)
                        .padding(.horizontal, 24)
                        .background(
                            Capsule()
                                .stroke(Color.red, lineWidth: 1.5)
                        )
                        .foregroundColor(.red)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.top, 14)
            }
        }
        .background(Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedCard = nil
        }
        .focusable(true)
        .focusEffectDisabled()
        .onDeleteCommand {
            if let card = selectedCard {
                if categorySelection == "Deleted" {
                    showingPermanentDeleteConfirmation = true
                } else {
                    showingDeleteConfirmation = true
                }
            }
        }
    }

    // Extracted middle pane into its own view for compiler performance
    private var listPane: some View {
        VStack(spacing: 8) {
            listHeader
            listContent
        }
        .background(Color(NSColor.windowBackgroundColor).ignoresSafeArea())
        .frame(minWidth: 260, idealWidth: 260)
        .sheet(isPresented: $showingAddCard) {
            PopoverAddCardForm(
                isPresented: $showingAddCard
            )
            .environmentObject(store)
        }
    }


    // Extracted detail pane into its own view for compiler performance
    private var detailPane: some View {
        Group {
            if let card = selectedCard {
                CardDetailView(
                    card: card,
                    isInfoHidden: $isInfoHidden,
                    categoryColors: categoryColors,
                    selectedCard: $selectedCard
                )
            } else {
                VStack(alignment: .center) {
                    Spacer()
                    VStack {
                        Image(systemName: "creditcard.fill")
                            .font(.system(size: 68))
                            .foregroundColor(.secondary)
                            .padding(.bottom, 18)
                        Text("No Card Selected")
                            .font(.title2.bold())
                            .foregroundColor(.secondary)
                            .padding(.bottom, 4)
                        Text("Cards are saved securely here. Select a card on the left to view details.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                            .font(.body)
                            .frame(maxWidth: 380)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor).ignoresSafeArea())
            }
        }
        .frame(minWidth: 430, idealWidth: 430, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor).ignoresSafeArea())
    }

    // Factor out sync error alert binding
    private var syncErrorBinding: Binding<Bool> {
        Binding(
            get: { cloudError != nil },
            set: { if !$0 { cloudError = nil } }
        )
    }

    var body: some View {
        if autoLockManager.isLocked {
            EmptyView()
        } else {
            ZStack {
                Color(NSColor.windowBackgroundColor).ignoresSafeArea()

                HSplitView {
                    SidebarView(selection: $categorySelection)
                        .frame(minWidth: 290, idealWidth: 290, maxWidth: 290)

                    listPane

                    detailPane
                }
                .onTapGesture {
                    autoLockManager.userDidInteract()
                }
            }
            .onAppear {
                print("CardListView appeared. Loaded \(store.cards.count) cards")
                store.fetchFromCloud()
                autoLockManager.resetTimer()
                // Close duplicate main windows on launch
                let mains = NSApp.windows.filter { $0.title == "CardVault" }
                if mains.count > 1 {
                    for window in mains.dropFirst() {
                        window.close()
                    }
                }
            }
            .onChange(of: categorySelection) { _ in
                selectedCard = nil
            }
            .focusable(true)  // re-enable keyboard focus for delete
            .onDeleteCommand {
                if let card = selectedCard {
                    if categorySelection == "Deleted" {
                        showingPermanentDeleteConfirmation = true
                    } else {
                        showingDeleteConfirmation = true
                    }
                }
            }
            .alert("Sync Error", isPresented: syncErrorBinding) {
                Button("OK", role: .cancel) { cloudError = nil }
            } message: {
                Text(cloudError?.localizedDescription ?? "An iCloud sync error occurred.")
            }
            // === Begin: Delete confirmation alerts for CardListView ===
            .alert("Are you sure you want to delete this card?", isPresented: $showingDeleteConfirmation) {
                Button("Delete Card", role: .destructive) {
                    if let card = selectedCard {
                        if card.category == "Deleted" {
                            // Permanently delete from both local store and iCloud
                            store.purgeCard(card)
                            store.deleteCardFromKeychain(card)
                            deleteCardFromCloud(card.id, permanent: true)
                        } else {
                            store.softDeleteCard(card)
                        }
                        DispatchQueue.main.async {
                            selectedCard = nil
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This card will be moved to Recently Deleted. After 30 days, it will be permanently deleted.")
            }
            .alert("Permanently Delete Card?", isPresented: $showingPermanentDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    if let card = selectedCard {
                        DispatchQueue.main.async {
                            store.purgeCard(card)
                            store.deleteCardFromKeychain(card)
                            deleteCardFromCloud(card.id, permanent: true)
                            selectedCard = nil
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This card will be permanently removed and cannot be recovered.")
            }
            // === End: Delete confirmation alerts for CardListView ===
            .environment(\.font, .system(.body, weight: .semibold))
            .background(Color(NSColor.windowBackgroundColor).ignoresSafeArea())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // (Auto-lock logic removed)
        }
    }
}

// MARK: - PopoverCardRow (from CardViews copy.txt)
fileprivate struct PopoverCardRow: View {
    let card: Card
    @Binding var selectedCard: Card?
    let categoryColors: [String: Color]

    var isExpanded: Bool {
        selectedCard?.id == card.id
    }

    var body: some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { isExpanded },
                set: { newValue in
                    selectedCard = newValue ? card : nil
                }
            ),
            content: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Number: \(card.number ?? "")")
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Text("Expiry: \(card.expiry ?? "")")
                    Text("CVV: \(card.cvv ?? "")")
                }
                .font(.caption)
                .padding(.horizontal)
                .padding(.bottom, 6)
            },
            label: {
                HStack {
                    Text(card.nickname)
                        .font(.body)
                    Spacer()
                    Text("•••• \((card.number ?? "").suffix(4))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isExpanded ? Color.accentColor.opacity(0.2) : Color.clear)
                )
            }
        )
        .animation(.default, value: selectedCard)
    }
}

// MARK: - MenuBarPopoverView (from CardViews copy.txt)
/// A compact card list with detail expansion for the status-item popover
public struct MenuBarPopoverView: View {
    @EnvironmentObject var store: CardStore
    @EnvironmentObject var autoLockManager: AutoLockManager
    @Environment(\.openSettings) private var openSettings
    @State private var reloadID = UUID()
    @State private var selectedCard: Card? = nil
    @State private var categorySelection: String = "All"
    @State private var sortKey: CardStore.SortKey = .nickname
    @State private var sortAscending: Bool = true
    @State private var searchText: String = ""
    @State private var showingAddCard = false
    @State private var isEditing = false
    @State private var selectedCards: Set<UUID> = []
    @State private var showingDeleteConfirmation = false
    @State private var cardToDelete: Card? = nil
    @State private var isInfoHidden: Bool = true
    @State private var showingScanner: Bool = false
    @State private var pendingScannedCardData: (number: String, expiry: String, cvv: String)? = nil
    @State private var hoveredCard: Card.ID? = nil

    private let categoryColors: [String: Color] = [
        "All": .green,
        "Credit": .blue,
        "Debit": .red,
        "Rewards": .cyan,
        "Business": .orange,
        "Deleted": .gray
    ]

    private var filteredCards: [Card] {
        store.filteredCards(
            categorySelection: categorySelection,
            searchText: searchText,
            sortKey: sortKey,
            sortAscending: sortAscending
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: {
                    // Bring the app to the front and open settings directly without auth
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }) {
                    Label("Settings", systemImage: "gearshape")
                }
                .labelStyle(IconOnlyLabelStyle())
                .buttonStyle(PlainButtonStyle())
                .padding([.top, .trailing], 8)
            }

            if showingAddCard {
                PopoverAddCardForm(
                    isPresented: $showingAddCard,
                    prefillNumber: pendingScannedCardData?.number,
                    prefillExpiry: pendingScannedCardData?.expiry,
                    prefillCVV: pendingScannedCardData?.cvv
                )
                .environmentObject(store)
            } else {
                VStack(spacing: 14) {
                    HStack {
                        Text("\(filteredCards.count) Items")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                        Spacer()
                        Menu {
                            Picker("Category", selection: $categorySelection) {
                                Text("All").tag("All")
                                Text("Credit").tag("Credit")
                                Text("Debit").tag("Debit")
                                Text("Rewards").tag("Rewards")
                                Text("Business").tag("Business")
                                Text("Deleted").tag("Deleted")
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(categorySelection)
                                    .font(.title2.weight(.semibold))
                                Image(systemName: "chevron.down")
                                    .font(.caption)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 10)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15)))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                    }
                    .padding(.bottom, 4)

                    HStack(spacing: 8) {
                        Menu {
                            Picker("Sort by", selection: $sortKey) {
                                ForEach(CardStore.SortKey.allCases, id: \.self) { key in
                                    Text(key.rawValue).tag(key)
                                }
                            }
                            Divider()
                            Picker("Order", selection: $sortAscending) {
                                Text("Ascending").tag(true)
                                Text("Descending").tag(false)
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                                .imageScale(.medium)
                                .frame(width: 28, height: 28)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15)))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)

                        Button(action: {
                            showingAddCard = true
                        }) {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(PlainButtonStyle())

                        Button(action: { isEditing.toggle() }) {
                            Text(isEditing ? "Done" : "Edit")
                                .font(.body.weight(.semibold))
                        }
                        .buttonStyle(PlainButtonStyle())

                        Button(action: { isInfoHidden.toggle() }) {
                            Image(systemName: isInfoHidden ? "eye.slash" : "eye")
                        }
                        .buttonStyle(PlainButtonStyle())
                        .accessibilityLabel(isInfoHidden ? "Show details" : "Hide details")
                    }

                    Divider().padding(.top, 2)
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gray.opacity(0.3)))
                }
                .padding(.top, 6)
                .padding(.bottom, 4)
                .padding(.horizontal, 14)
                .background(Color(NSColor.windowBackgroundColor))
                .onTapGesture {
                    autoLockManager.userDidInteract()
                }

                Divider()

                if isEditing && !selectedCards.isEmpty {
                    Button(action: {
                        for cardID in selectedCards {
                            guard let cardToDelete = store.cards.first(where: { $0.id == cardID }) else { continue }
                            if categorySelection == "Deleted" {
                                print("Permanently deleting card \(cardID)")
                                store.purgeCard(cardToDelete)
                                store.deleteCardFromKeychain(cardToDelete)
                                deleteCardFromCloud(cardToDelete.id, permanent: true)
                            } else {
                                print("Soft deleting card \(cardID)")
                                store.softDeleteCard(cardToDelete)
                            }
                        }
                        selectedCards.removeAll()
                        isEditing = false
                    }) {
                        Text(categorySelection == "Deleted"
                            ? "Permanently Delete Selected (\(selectedCards.count))"
                            : "Delete Selected (\(selectedCards.count))")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.vertical, 10)
                            .padding(.horizontal, 24)
                            .background(
                                Capsule()
                                    .stroke(Color.red, lineWidth: 1.5)
                            )
                            .foregroundColor(.red)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.top, 14)
                }

                ScrollView {
                    MenuBarPopoverList(
                        filteredCards: filteredCards,
                        selectedCard: $selectedCard,
                        hoveredCard: .init(
                            get: { hoveredCard },
                            set: { hoveredCard = $0 }
                        ),
                        isEditing: isEditing,
                        cardToDelete: $cardToDelete,
                        showingDeleteConfirmation: $showingDeleteConfirmation,
                        isInfoHidden: isInfoHidden,
                        categoryColors: categoryColors,
                        selectedCards: $selectedCards,
                        isEditingMode: isEditing
                    )
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                }
                .frame(minWidth: 260, idealWidth: 260, minHeight: 300, maxHeight: 600)
            }
        }
        .background(Color(NSColor.windowBackgroundColor).ignoresSafeArea())
        .cornerRadius(8)
        .onTapGesture {
            autoLockManager.userDidInteract()
        }
        .onChange(of: showingAddCard) { presented in
            if !presented {
                reloadID = UUID()
            }
        }
        .id(reloadID)
        .alert("Delete Card?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let card = cardToDelete {
                    if card.category == "Deleted" {
                        store.purgeCard(card)
                        store.deleteCardFromKeychain(card)
                        store.objectWillChange.send()
                        deleteCardFromCloud(card.id, permanent: true)
                    } else {
                        var deletedCard = card
                        deletedCard.metadata.category = "Deleted"
                        deletedCard.metadata.deletedDate = Date()
                        store.updateCard(deletedCard)
                        store.objectWillChange.send()
                        deleteCardFromCloud(deletedCard.id, permanent: false)
                    }
                }
                cardToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                cardToDelete = nil
            }
        } message: {
            Text("This card will be moved to Recently Deleted. After 30 days, it will be permanently deleted.")
        }
        .environment(\.font, .system(.body, weight: .semibold))
        .sheet(isPresented: $showingAddCard, onDismiss: {
            pendingScannedCardData = nil
        }) {
            PopoverAddCardForm(
                isPresented: $showingAddCard,
                prefillNumber: pendingScannedCardData?.number,
                prefillExpiry: pendingScannedCardData?.expiry,
                prefillCVV: pendingScannedCardData?.cvv
            )
            .environmentObject(store)
        }
        .onAppear {
            autoLockManager.resetTimer()
        }
    }
}

// MARK: - PopoverAddCardForm (from CardViews copy.txt)
struct PopoverAddCardForm: View {
    @EnvironmentObject var store: CardStore
    @Binding var isPresented: Bool
    @State private var nickname: String
    @State private var number: String
    @State private var expiry: String
    @State private var cvv: String
    @State private var category: String

    // Optional prefill parameters (used by this view's own scanner or if explicitly passed)
    var prefillNumber: String?
    var prefillExpiry: String?
    var prefillCVV: String?

    init(isPresented: Binding<Bool>,
         prefillNumber: String? = nil,
         prefillExpiry: String? = nil,
         prefillCVV: String? = nil) {
        self._isPresented = isPresented
        self.prefillNumber = prefillNumber
        self.prefillExpiry = prefillExpiry
        self.prefillCVV = prefillCVV
        
        _nickname = State(initialValue: "")
        _number = State(initialValue: prefillNumber ?? "")
        _expiry = State(initialValue: prefillExpiry ?? "")
        _cvv = State(initialValue: prefillCVV ?? "")
        _category = State(initialValue: "Credit")
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("New Card")
                .font(.title2).bold()
            // Category row
            HStack {
                Text("Category")
                    .frame(width: 90, alignment: .leading)
                Picker("", selection: $category) {
                    Text("Credit").tag("Credit")
                    Text("Debit").tag("Debit")
                    Text("Rewards").tag("Rewards")
                    Text("Business").tag("Business")
                }
                .pickerStyle(SegmentedPickerStyle())
            }
            // Nickname row
            HStack {
                Text("Nickname")
                    .frame(width: 90, alignment: .leading)
                TextField("Enter nickname", text: $nickname)
#if os(macOS)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
#else
                    .textFieldStyle(DefaultTextFieldStyle())
#endif
            }
            // Number row
            HStack {
                Text("Number")
                    .frame(width: 90, alignment: .leading)
                TextField("Enter card number", text: $number)
#if os(macOS)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
#else
                    .textFieldStyle(DefaultTextFieldStyle())
#endif
                    .onChange(of: number) { newValue in
                        let digits = newValue.filter { $0.isNumber }
                        let limited = String(digits.prefix(19))
                        var formatted = ""
                        for (index, char) in limited.enumerated() {
                            if index != 0 && index % 4 == 0 {
                                formatted.append("-")
                            }
                            formatted.append(char)
                        }
                        number = formatted
                    }
            }
            // Expiry and CVV row
            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text("Expiry")
                    TextField("MM/YY", text: $expiry)
#if os(macOS)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
#else
                        .textFieldStyle(DefaultTextFieldStyle())
#endif
                        .frame(width: 80)
                        .onChange(of: expiry) { newValue in
                            let digits = newValue.filter { $0.isNumber }
                            let month = String(digits.prefix(2))
                            let year = String(digits.dropFirst(2).prefix(2))
                            if digits.count > 2 {
                                expiry = "\(month)/\(year)"
                            } else {
                                expiry = month
                            }
                        }
                }
                VStack(alignment: .leading) {
                    Text("CVV")
                    TextField("CVV", text: $cvv)
#if os(macOS)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
#else
                        .textFieldStyle(DefaultTextFieldStyle())
#endif
                        .frame(width: 80)
                }
            }
            // Buttons
            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                Button("Save") {
                    let metadata = CardMetadata(
                        id: UUID(),
                        nickname: nickname,
                        category: category,
                        notes: "", // Assuming notes are not part of this quick form
                        lastModified: Date(),
                        deletedDate: nil
                    )
                    let newCard = Card(metadata: metadata, number: number, expiry: expiry, cvv: cvv)
                    store.addCard(newCard)
                    KeychainService.save(newCard)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 420, minHeight: 300, idealHeight: 300)
        .onAppear {
             print("PopoverAddCardForm appeared. Initial state - Number: \(number), Expiry: \(expiry), CVV: \(cvv)")
             // If prefill values were passed and state is empty, apply them.
             // This handles cases where the view might be reused or parameters change.
             if number.isEmpty, let pfNumber = prefillNumber { number = pfNumber }
             if expiry.isEmpty, let pfExpiry = prefillExpiry { expiry = pfExpiry }
             if cvv.isEmpty, let pfCVV = prefillCVV { cvv = pfCVV }
        }
        .environmentObject(store)
    }
}

// MARK: - InfoRow (from CardViews copy.txt)
private struct InfoRow<Content: View>: View {
    let label: String
    let value: Content
    let rawValue: Content // This should represent the unmasked value
    let isHidden: Bool
    let showCopy: Bool
    let rawString: String // The actual string to be copied
    @State private var isHovered = false
    @State private var didCopy = false

    // Initializer for displaying simple text values (non-edit mode)
    init(label: String, value: String, rawValue: String, isHidden: Bool, showCopy: Bool) where Content == Text {
        self.label = label
        self.value = Text(value) // This is the potentially masked display value
        self.rawValue = Text(rawValue) // This is the unmasked value for display when hovered/not hidden
        self.isHidden = isHidden
        self.showCopy = showCopy
        self.rawString = rawValue // Ensure rawString gets the unmasked value for copying
    }

    // Initializer for edit mode, allowing custom Content (e.g., TextField)
    init(label: String, rawString: String, isHidden: Bool, showCopy: Bool, @ViewBuilder value: () -> Content, @ViewBuilder rawValue: () -> Content) {
        self.label = label
        self.rawString = rawString // Ensure rawString is set for copying
        self.isHidden = isHidden
        self.showCopy = showCopy
        self.value = value()
        self.rawValue = rawValue()
    }


    var body: some View {
        HStack {
            Text(label)
                .font(.body)
                .foregroundColor(.primary)
            Spacer()
            HStack(spacing: 6) {
                Group {
                    if isHidden && !isHovered {
                        Text(hiddenDotString)
                    } else {
                        // When not hidden or hovered, show the 'rawValue' (unmasked)
                        rawValue
                    }
                }
                if showCopy {
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(rawString, forType: .string) // Use rawString for copying
                        withAnimation {
                            didCopy = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            withAnimation {
                                didCopy = false
                            }
                        }
                    }) {
                        Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                            .scaleEffect(didCopy ? 1.2 : 1.0)
                            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: didCopy)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .foregroundColor(didCopy ? .green : .accentColor)
                    .help("Copy")
                    .accessibilityLabel("Copy \(label)")
                }
            }
            .onHover { hovering in
                isHovered = hovering
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isHovered ? Color.gray.opacity(0.3) : Color.clear, lineWidth: 1)
            )
            .background(isHovered ? Color.gray.opacity(0.1) : Color.clear)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if showCopy { // Only copy on tap if showCopy is true
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rawString, forType: .string) // Use rawString for copying
                withAnimation {
                    didCopy = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    withAnimation {
                        didCopy = false
                    }
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .shadow(color: Color.black.opacity(0.03), radius: 1, x: 0, y: 1)
    }

    private var hiddenDotString: String {
        String(repeating: "•", count: max(4, rawString.count))
    }
}

// MARK: - SidebarItem (from CardViews copy.txt)
struct SidebarItem: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let color: Color
    let badgeCount: Int?
}

// MARK: - SidebarView (from CardViews copy.txt)
struct SidebarView: View {
    @Binding var selection: String  // or an enum for different sections
    @EnvironmentObject var store: CardStore

    // adaptive columns for flexible grid layout
    let columns = [GridItem(.adaptive(minimum: 120), spacing: 10)]

    private var items: [SidebarItem] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        return [
            SidebarItem(title: "All", icon: "banknote.fill", color: .green,
                badgeCount: store.cards.filter { $0.category != "Deleted" }.count),
            SidebarItem(title: "Credit", icon: "creditcard.fill", color: .blue,
                badgeCount: store.cards.filter { $0.category == "Credit" }.count),
            SidebarItem(title: "Debit", icon: "banknote.fill", color: .red,
                badgeCount: store.cards.filter { $0.category == "Debit" }.count),
            SidebarItem(title: "Rewards", icon: "star.fill", color: .cyan,
                badgeCount: store.cards.filter { $0.category == "Rewards" }.count),
            SidebarItem(title: "Business", icon: "briefcase.fill", color: .orange,
                badgeCount: store.cards.filter { $0.category == "Business" }.count),
            SidebarItem(title: "Deleted", icon: "trash.fill", color: .gray,
                badgeCount: store.cards.filter {
                    $0.category == "Deleted" && ($0.deletedDate ?? .distantPast) > cutoff
                }.count)
        ]
    }

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).ignoresSafeArea()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(items) { item in
                        Button(action: { selection = item.title }) {
                            SidebarCategoryTile(item: item, isSelected: selection == item.title)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.top, 12)
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.visible)
        }
        .frame(minWidth: 290, idealWidth: 295, maxWidth: 305)
        .background(Color(NSColor.windowBackgroundColor).ignoresSafeArea())
    }
}

// MARK: - SidebarCategoryTile (from CardViews copy.txt)
private struct SidebarCategoryTile: View {
    let item: SidebarItem
    let isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color(NSColor.controlBackgroundColor))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    ZStack {
                        Circle()
                            .fill(isSelected ? Color.white : Color.gray.opacity(0.2))
                            .frame(width: 28, height: 28)
                        Image(systemName: item.icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(isSelected ? .accentColor : item.color)
                    }
                    Spacer()
                }
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isSelected ? .white : .primary)
                    .padding(.top, 6)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
        }
        .frame(width: 135, height: 70)
        .overlay(badgeOverlay)
    }

    private var badgeOverlay: some View {
        // Always show the badge, even if badgeCount is nil or 0
        Text("\(item.badgeCount ?? 0)")
            .font(.system(size: 15, weight: .regular))
            .foregroundColor(isSelected ? .white : .secondary)
            .padding(.top, 7)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, alignment: .topTrailing)
    }
}

// MARK: - CardListRow (from CardViews copy.txt)
private struct CardListRow: View {
    let card: Card
    let isSelected: Bool
    let categoryColors: [String: Color]
    @Environment(\.colorScheme) var colorScheme
    @State private var isHovered: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor
                      : isHovered ? Color.gray.opacity(0.10)
                      : Color(NSColor.controlBackgroundColor))
            HStack(spacing: 12) {
                ZStack {
                    Rectangle()
                        .fill(categoryColors[card.category, default: .accentColor].opacity(isSelected ? 0.3 : 0.17))
                        .frame(width: 38, height: 26)
                    Image(systemName: "creditcard.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 15)
                        .foregroundColor(isSelected ? .white : categoryColors[card.category, default: .accentColor])
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.nickname)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isSelected ? .white : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text((card.number ?? "").isEmpty ? card.nickname : "•••• \(card.number!.suffix(4))")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(isSelected ? Color.white.opacity(0.82) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
            }
            .padding(.leading, 10)
            .padding(.vertical, 7)
            .padding(.trailing, 8)
        }
        .frame(height: 50)
        .padding(.vertical, 2)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - CardDetailView (from CardViews copy.txt)
private struct CardDetailView: View {
    let card: Card
    @Binding var isInfoHidden: Bool
    let categoryColors: [String: Color]
    @EnvironmentObject var store: CardStore
    @Binding var selectedCard: Card?

    @State private var currentDate = Date()
    @State private var showingEdit = false
    @State private var editableCard: Card
    @State private var showingPermanentDeleteConfirmation = false

    init(card: Card, isInfoHidden: Binding<Bool>, categoryColors: [String: Color], selectedCard: Binding<Card?>) {
        self.card = card
        _editableCard = State(initialValue: card)
        self._isInfoHidden = isInfoHidden
        self.categoryColors = categoryColors
        self._selectedCard = selectedCard
    }

    // Extracted content inside ScrollView to a computed property for compiler performance
    private var detailContent: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 0) {
                CardTitleHeaderView()
                CardInfoFieldsView()
                DeletedCardRecoveryView()
                Spacer()
            }
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Refactored Subviews for Detail Content
    private func CardTitleHeaderView() -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "creditcard.fill")
                .resizable()
                .frame(width: 32, height: 22)
                .foregroundColor(.white)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(categoryColors[card.category, default: .accentColor])
                )
            VStack(alignment: .leading, spacing: 2) {
                ZStack {
                    if showingEdit {
                        TextField("Title", text: Binding(
                            get: { editableCard.metadata.nickname },
                            set: { editableCard.metadata.nickname = $0 }
                        ))
                        .font(.system(size: 17, weight: .bold))
                        .textFieldStyle(PlainTextFieldStyle())
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.5)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(card.nickname)
                            .font(.system(size: 17, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Last modified \(card.lastModified, style: .date)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: { isInfoHidden.toggle() }) {
                Image(systemName: isInfoHidden ? "eye.slash" : "eye")
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(PlainButtonStyle())
            Button(showingEdit ? "Save" : "Edit") {
                if showingEdit {
                    store.updateCard(editableCard)
                    KeychainService.save(editableCard)
                    modifyCardInCloud(editableCard)
                    selectedCard = editableCard
                } else {
                    editableCard = card // Refresh editableCard when entering edit mode
                }
                showingEdit.toggle()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private func CardInfoFieldsView() -> some View {
        VStack(spacing: 12) {
            ZStack {
                if showingEdit {
                    InfoRow(
                        label: "Card Number",
                        rawString: editableCard.number ?? "",
                        isHidden: false,
                        showCopy: false,
                        value: {
                            TextField("", text: Binding(
                                get: { editableCard.number ?? "" },
                                set: { editableCard.number = $0 }
                            ))
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(PlainTextFieldStyle())
                        },
                        rawValue: {
                            TextField("", text: Binding(
                                get: { editableCard.number ?? "" },
                                set: { editableCard.number = $0 }
                            ))
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(PlainTextFieldStyle())
                        }
                    )
                } else {
                    InfoRow(
                        label: "Card Number",
                        value: "•••• •••• •••• \((card.number ?? "").suffix(4))", // Display value (masked)
                        rawValue: card.number ?? "", // Raw value (unmasked)
                        isHidden: isInfoHidden,
                        showCopy: true
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 32)
            Divider()

            ZStack {
                if showingEdit {
                    InfoRow(
                        label: "Expiry",
                        rawString: editableCard.expiry ?? "",
                        isHidden: false,
                        showCopy: false,
                        value: {
                            TextField("", text: Binding(
                                get: { editableCard.expiry ?? "" },
                                set: { editableCard.expiry = $0 }
                            ))
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(PlainTextFieldStyle())
                        },
                        rawValue: {
                            TextField("", text: Binding(
                                get: { editableCard.expiry ?? "" },
                                set: { editableCard.expiry = $0 }
                            ))
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(PlainTextFieldStyle())
                        }
                    )
                } else {
                     InfoRow(
                        label: "Expiry",
                        value: card.expiry ?? "", // Display value
                        rawValue: card.expiry ?? "", // Raw value
                        isHidden: false, // Expiry is generally not hidden with dots
                        showCopy: true
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 32)
            Divider()

            ZStack {
                if showingEdit {
                    InfoRow(
                        label: "CVV",
                        rawString: editableCard.cvv ?? "",
                        isHidden: false,
                        showCopy: false,
                        value: {
                            TextField("", text: Binding(
                                get: { editableCard.cvv ?? "" },
                                set: { editableCard.cvv = $0 }
                            ))
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(PlainTextFieldStyle())
                        },
                        rawValue: {
                            TextField("", text: Binding(
                                get: { editableCard.cvv ?? "" },
                                set: { editableCard.cvv = $0 }
                            ))
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(PlainTextFieldStyle())
                        }
                    )
                } else {
                    InfoRow(
                        label: "CVV",
                        value: String(repeating: "•", count: (card.cvv ?? "").count), // Display value (masked)
                        rawValue: card.cvv ?? "", // Raw value (unmasked)
                        isHidden: isInfoHidden,
                        showCopy: true
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 32)
            Divider()

            Group {
                HStack {
                    Text("Category")
                    Spacer()
                    if showingEdit {
                        Picker("", selection: Binding(
                            get: { editableCard.metadata.category },
                            set: { editableCard.metadata.category = $0 }
                        )) {
                            ForEach(categoryColors.keys.sorted().filter { $0 != "All" && $0 != "Deleted" }, id: \.self) { category in
                                Text(category).tag(category)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                    } else {
                        Text(card.category)
                            .foregroundColor(.primary)
                    }
                }
            }
            .padding(.vertical, 10)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    @State private var recovered = false

    private func DeletedCardRecoveryView() -> some View {
        if card.category == "Deleted", let deletedDate = card.deletedDate {
            let daysPassed = Calendar.current.dateComponents([.day], from: deletedDate, to: Date()).day ?? 0
            let daysLeft = max(0, 30 - daysPassed)
            return AnyView(
                VStack(spacing: 8) {
                    if recovered {
                        Text("Card successfully recovered!")
                            .font(.footnote)
                            .foregroundColor(.green)
                            .transition(.opacity)
                    } else {
                        Text("This card will be permanently deleted in \(daysLeft) day\(daysLeft == 1 ? "" : "s") unless it is recovered.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Button("Delete", role: .destructive) {
                            showingPermanentDeleteConfirmation = true
                        }
                        .buttonStyle(.bordered)
                        Button("Recover") {
                            store.recoverCard(card)
                            recovered = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                withAnimation {
                                    recovered = false
                                }
                            }
                            selectedCard = nil // Optionally deselect after recovery
                        }
                        .buttonStyle(.bordered)
                        .disabled(recovered)
                    }
                }
                .frame(maxWidth: 400)
                .padding()
            )
        } else {
            return AnyView(EmptyView())
        }
    }

    var body: some View {
        detailContent
            .alert("Permanently Delete Card?", isPresented: $showingPermanentDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    deleteCardFromCloud(card.id, permanent: true)
                    store.purgeCard(card)
                    store.deleteCardFromKeychain(card)
                    selectedCard = nil
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This card will be permanently removed and cannot be recovered.")
            }
    }
}

// MARK: - EditCardView (from CardViews copy.txt)
struct EditCardView: View {
    @State var card: Card
    @EnvironmentObject var store: CardStore
    @Environment(\.presentationMode) var presentationMode

    var onSave: (Card) -> Void

    var body: some View {
        Form {
            Section(header: Text("Card Info")) {
                TextField("Nickname", text: $card.metadata.nickname)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                TextField("Number", text: Binding(
                    get: { card.number ?? "" },
                    set: { card.number = $0 }
                ))
                TextField("Expiry", text: Binding(
                    get: { card.expiry ?? "" },
                    set: { card.expiry = $0 }
                ))
                TextField("CVV", text: Binding(
                    get: { card.cvv ?? "" },
                    set: { card.cvv = $0 }
                ))
                Picker("Category", selection: $card.metadata.category) {
                    Text("Credit").tag("Credit")
                    Text("Debit").tag("Debit")
                    Text("Rewards").tag("Rewards")
                    Text("Business").tag("Business")
                    Text("Deleted").tag("Deleted")
                }
                TextField("Notes", text: $card.metadata.notes)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    presentationMode.wrappedValue.dismiss()
                }
                Button("Save") {
                    onSave(card)
                    presentationMode.wrappedValue.dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 380, height: 700) // Consider making this more dynamic if needed
    }
}

// MARK: - MenuBarPopoverList (from CardViews copy.txt)
private struct MenuBarPopoverList: View {
    let filteredCards: [Card]
    @Binding var selectedCard: Card?
    @Binding var hoveredCard: Card.ID?
    let isEditing: Bool
    @Binding var cardToDelete: Card?
    @Binding var showingDeleteConfirmation: Bool
    let isInfoHidden: Bool
    let categoryColors: [String: Color]
    @Binding var selectedCards: Set<UUID>
    let isEditingMode: Bool

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(filteredCards) { card in
                let isSelected = selectedCard?.id == card.id
                let isHovered = hoveredCard == card.id
                HStack {
                    if isEditingMode {
                        Button(action: {
                            if selectedCards.contains(card.id) {
                                selectedCards.remove(card.id)
                            } else {
                                selectedCards.insert(card.id)
                            }
                        }) {
                            Image(systemName: selectedCards.contains(card.id) ? "checkmark.circle.fill" : "circle")
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    VStack(spacing: 0) {
                        CardListRow(card: card, isSelected: isSelected, categoryColors: categoryColors)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            // Removed conditional background highlight for selection
                            .onTapGesture {
                                withAnimation {
                                    selectedCard = (selectedCard?.id == card.id) ? nil : card
                                }
                            }
                            .onHover { hovering in
                                hoveredCard = hovering ? card.id : nil
                            }
                        if isSelected {
                            withAnimation {
                                VStack(spacing: 2) {
                                    InfoRow(
                                        label: "#",
                                        value: card.number ?? "", // Display value
                                        rawValue: card.number ?? "", // Raw value
                                        isHidden: isInfoHidden,
                                        showCopy: true
                                    )
                                    InfoRow(
                                        label: "Exp.",
                                        value: card.expiry ?? "", // Display value
                                        rawValue: card.expiry ?? "", // Raw value
                                        isHidden: isInfoHidden, // Expiry usually not hidden with dots
                                        showCopy: true
                                    )
                                    InfoRow(
                                        label: "CVV",
                                        value: card.cvv ?? "", // Display value (will be masked by InfoRow if isInfoHidden)
                                        rawValue: card.cvv ?? "", // Raw value
                                        isHidden: isInfoHidden,
                                        showCopy: true
                                    )
                                }
                                .padding(.horizontal, 0)
                                .padding(.bottom, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.95))
                                )
                                .transition(.opacity.combined(with: .move(edge: .top)))
                                .shadow(color: Color.black.opacity(0.03), radius: 2, x: 0, y: 1)
                            }
                        }
                    }
                    Spacer()
                    if isEditing {
                        Button(role: .destructive) {
                            cardToDelete = card
                            showingDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .background(
                    Group {
                        // Remove blue accent color highlight on selection
                        if isHovered {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.10))
                        }
                    }
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .onHover { hovering in
                    hoveredCard = hovering ? card.id : nil
                }
                .animation(.default, value: selectedCard)
            }
        }
    }
}

// MARK: - CardVaultApp (from CardVaultApp copy.txt)
@main
struct CardVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  // Ensure default value for showInDock before AppStorage properties initialize
  static let registerDefaults: Void = {
      UserDefaults.standard.register(defaults: ["showInDock": true])
  }()
  @Environment(\.scenePhase) private var scenePhase
  @State private var lastBackgroundDate: Date?
  @State private var selectedSection: String = "All"
  @State private var selection: Card?
  @StateObject private var store = CardStore()
  @StateObject private var autoLockManager = AutoLockManager.shared
  private let statusBarController = StatusBarController.shared // Use shared instance
  @AppStorage("hasPromptedForICloud") private var hasPromptedForICloud = false
  // Removed autoLockInterval, autoLockMode, lockOnBoot, and AppDelegate
  @AppStorage("showInDock")    private var showInDock: Bool    = true

  init() {
      let show = UserDefaults.standard.bool(forKey: "showInDock")
      autoLockManager.isLocked
      DispatchQueue.main.async {
          NSApplication.shared.setActivationPolicy(show ? .regular : .accessory)
      }
  }
    
  var body: some Scene {
    WindowGroup("CardVault") {
      CardListView(
        selectedCard: $selection,
        categorySelection: $selectedSection
      )
      .onAppear {
        autoLockManager.resetTimer()
        statusBarController.show(store: store)
      }
      .onChange(of: scenePhase) { newPhase in
        if newPhase == .active {
          statusBarController.show(store: store)
        }
      }
      .environmentObject(store)
      .environmentObject(statusBarController)
      .environmentObject(autoLockManager)
    }

    // (Lock window scene removed)
    Settings {
      SettingsView()
        .environmentObject(store)
        .environmentObject(statusBarController)
        .environmentObject(autoLockManager)
    }
    .windowStyle(HiddenTitleBarWindowStyle())
    .commands {
      CommandGroup(replacing: .appSettings) {
        SettingsLink()
      }
    }
  }
}

extension CardStore {
  func authenticateWithFallback(setAuthInProgress: @escaping (Bool) -> Void, completion: ((Bool) -> Void)? = nil) {
    let context = LAContext()
    let reason = "Access your saved cards"

    DispatchQueue.main.async {
      setAuthInProgress(true)
      NSApp.activate(ignoringOtherApps: true)
    }

    context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
      DispatchQueue.main.async {
        setAuthInProgress(false)
        if success {
            AutoLockManager.shared.unlock()
        }
        if success {
          self.fetchFromCloud()
        }
        completion?(success)
        if let laError = error as? LAError {
          switch laError.code {
          case .userCancel, .systemCancel, .appCancel:
            print("Authentication was cancelled by the user or system.")
          default:
            break
          }
        }
      }
    }
  }
}

// MARK: - StatusBarController (from CardVaultApp copy.txt)
import Combine
final class StatusBarController: ObservableObject {
    static let shared = StatusBarController() // Make it a singleton

    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var currentStore: CardStore?
    private var lockCancellable: AnyCancellable?

    private init() { // Make init private for singleton
        popover.contentSize = NSSize(width: 300, height: 400)
        popover.behavior = .transient
        // Subscribe to auto-lock and close popover if locked
        lockCancellable = AutoLockManager.shared.$isLocked.sink { [weak self] locked in
            if locked {
                DispatchQueue.main.async {
                    self?.popover.performClose(nil)
                }
            }
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        // Enforce Dock policy from Settings
        let showInDock = UserDefaults.standard.bool(forKey: "showInDock")
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        let autoLockManager = AutoLockManager.shared
        guard let store = currentStore else { return }
        if autoLockManager.isLocked {
            // Prompt authentication inline
            let context = LAContext()
            let reason = "Unlock CardVault"
            if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) {
                context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                    DispatchQueue.main.async {
                        if success {
                            autoLockManager.unlock()
                            autoLockManager.resetTimer()
                            DispatchQueue.main.async {
                                guard let button = self.statusItem?.button else { return }
                                self.popover.contentViewController = NSHostingController(rootView:
                                    MenuBarPopoverView()
                                        .environmentObject(store)
                                        .environmentObject(self)
                                        .environmentObject(autoLockManager)
                                )
                                self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                            }
                        }
                    }
                }
            }
            return
        }
        // Refresh content with the last known store
        if let store = currentStore {
            popover.contentViewController = NSHostingController(rootView:
                MenuBarPopoverView()
                    .environmentObject(store)
                    .environmentObject(self)
                    .environmentObject(autoLockManager)
            )
        }
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            AutoLockManager.shared.resetTimer()
        }
    }

    func show(store: CardStore) {
        currentStore = store
        DispatchQueue.main.async {
            if self.statusItem == nil {
                self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                if let button = self.statusItem?.button {
                    let image = NSImage(systemSymbolName: "creditcard.fill", accessibilityDescription: "CardVault")
                    image?.isTemplate = true
                    image?.size = NSSize(width: 18, height: 18)
                    button.image = image
                    button.imagePosition = .imageOnly
                    button.action = #selector(self.togglePopover(_:))
                    button.target = self
                }
            }
            // Always recreate the popover content with the latest store
            self.popover.contentViewController = NSHostingController(rootView:
                MenuBarPopoverView()
                    .environmentObject(store)
                    .environmentObject(self)
                    .environmentObject(AutoLockManager.shared) // Pass AutoLockManager
            )
        }
    }

    func hide() {
        DispatchQueue.main.async {
            if let item = self.statusItem {
                NSStatusBar.system.removeStatusItem(item)
                self.statusItem = nil
                self.popover.performClose(nil)
            }
        }
    }
}


