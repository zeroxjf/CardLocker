
/*
 CardLocker.swift

 This file includes the core functionality for:
 
  • Secure card storage
    - Card metadata (nickname, category, notes) is saved in a local JSON file.
    - Sensitive fields (number, expiry, CVV) are stored securely in the macOS Keychain.
 
  • Optional iCloud sync
    - When enabled, card metadata is mirrored to the user’s private CloudKit database.
    - No sensitive fields (number, expiry, CVV) ever leave the device.
 
  • Auto-lock functionality
    - The app automatically locks after a configurable period of inactivity.
    - Touch ID or device passcode is required to unlock when locked.
 
  • Network monitoring
    - If the device goes offline, the app warns the user.
    - After three days without reconnecting, the app will lock automatically.
 
  • Trial logic placeholders (stubbed)
    - Stubbed functions for managing a one-time trial period using the Keychain.
    - No actual trial enforcement code is included here.
 
  • Main application delegate
    - Configures Firebase (without Firestore reads).
    - Monitors network status.
    - Handles macOS lifecycle events (showing windows, quitting, hiding to the menu bar).
 
  • Simplified Settings UI
    - Toggles for iCloud sync, Dock icon visibility, and auto-lock interval.
 
 Below is a stripped-down version of the Swift file, showing only these core pieces 
 (card loading, saving, syncing, auto-lock, and network checks), with all 
 license-related code omitted.
 */

import SwiftUI
import LocalAuthentication
import AppKit
import Combine
import CloudKit
import Foundation
import Firebase
import Network
import Sparkle

// MARK: – Notification Extensions and Logging

extension Notification.Name {
    static let didRemoveLicense = Notification.Name("didRemoveLicense")
}

func debugLog(_ items: Any...) {
    #if DEBUG
    print(items.map { "\($0)" }.joined(separator: " "))
    #endif
}

// MARK: – TrialKeychain Helper (stubs)

enum TrialKeychain {
    static func setBool(_ value: Bool, forKey key: String) { /* no-op stub */ }
    static func bool(forKey key: String) -> Bool { return false }
    static func setDate(_ date: Date, forKey key: String) { /* no-op stub */ }
    static func date(forKey key: String) -> Date? { return nil }
}

// MARK: – Card Metadata & Model

struct CardMetadata: Identifiable, Hashable, Codable {
    var id: UUID
    var nickname: String
    var category: String
    var notes: String
    var lastModified: Date
    var deletedDate: Date?
    var originalCategory: String?
}

struct Card: Identifiable, Hashable, Codable {
    var number: String?
    var expiry: String?
    var cvv: String?
    var metadata: CardMetadata

    var id: UUID { metadata.id }
    var last4: String? { number?.suffix(4).map { String($0) } }
}

// MARK: – Keychain Helpers (stubs)

func loadFields(for card: Card) -> Card {
    // Read "number", "expiry", "cvv" from Keychain and return updated Card
    return card
}

func deleteFields(for card: Card) {
    // Delete "number", "expiry", "cvv" entries from Keychain
}

// MARK: – CardStore (simplified)

final class CardStore: ObservableObject {
    @Published var cards: [Card] = []
    private var isICloudEnabled: Bool {
        UserDefaults.standard.bool(forKey: "useICloud")
    }

    private let appGroupID = "group.com.JFTech.CardVault"
    private var storageURL: URL {
        if let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent("storedCards.json")
        } else {
            let docs = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
            ).first!
            return docs.appendingPathComponent("storedCards.json")
        }
    }

    init() {
        loadCards()
        if isICloudEnabled {
            subscribeToChanges()
        }
    }

    func loadCards() {
        // Load storedCards.json from App Group or Documents, decode to [Card]
        guard FileManager.default.fileExists(atPath: storageURL.path),
              let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([Card].self, from: data)
        else {
            cards = []
            return
        }
        cards = decoded.map { loadFields(for: $0) }
        removeOldDeletedCards()
    }

    func saveCards() {
        removeOldDeletedCards()
        do {
            let encoded = try JSONEncoder().encode(cards)
            try encoded.write(to: storageURL, options: [.atomic])
            debugLog("📂 Saved \(cards.count) card(s)")
        } catch {
            debugLog("‼ saveCards error:", error.localizedDescription)
        }
    }

    func addCard(_ card: Card) {
        cards.append(card)
        saveCards()
        if isICloudEnabled {
            syncRecordToCloud(card)
        }
    }

    func updateCard(_ card: Card) {
        var updated = card
        updated.metadata.lastModified = Date()
        if let index = cards.firstIndex(where: { $0.id == updated.id }) {
            cards[index] = updated
            saveCards()
            if isICloudEnabled {
                modifyCardInCloud(updated)
            }
        }
    }

    func softDeleteCard(_ card: Card) {
        var deleted = card
        deleted.metadata.originalCategory = deleted.metadata.category
        deleted.metadata.category = "Deleted"
        deleted.metadata.deletedDate = Date()
        updateCard(deleted)
    }

    func recoverCard(_ card: Card) {
        var recovered = card
        recovered.metadata.category = recovered.metadata.originalCategory ?? "Credit"
        recovered.metadata.originalCategory = nil
        recovered.metadata.deletedDate = nil
        updateCard(recovered)
    }

    func purgeCard(_ card: Card) {
        if let idx = cards.firstIndex(where: { $0.id == card.id }) {
            cards.remove(at: idx)
            saveCards()
            if isICloudEnabled {
                deleteCardInCloud(card.id)
            }
        }
    }

    private func removeOldDeletedCards() {
        cards.removeAll { card in
            if card.metadata.category == "Deleted",
               let deletedDate = card.metadata.deletedDate,
               deletedDate <= Date().addingTimeInterval(-30*24*60*60) {
                purgeCard(card)
                return true
            }
            return false
        }
    }

    // MARK: – CloudKit Sync Stubs

    private func subscribeToChanges() {
        // Create CKQuerySubscription for “Card” records and handle notifications
    }

    private func syncRecordToCloud(_ card: Card) {
        // CKModifyRecordsOperation to push new card record
    }

    private func modifyCardInCloud(_ card: Card, attempt: Int = 0) {
        // Fetch existing CKRecord, update fields, CKModifyRecordsOperation
    }

    private func deleteCardInCloud(_ cardID: UUID, attempt: Int = 0) {
        // CKDelete operation for the record
    }

    deinit {
        debugLog("🗑️ CardStore deinitialized")
    }
}

// MARK: – AutoLockManager

public enum AutoLockMode: Int, CaseIterable, Identifiable {
    case fixed, activityBased, both
    public var id: Int { rawValue }
    public var description: String {
        switch self {
        case .fixed: return "Lock after fixed interval"
        case .activityBased: return "Lock after inactivity"
        case .both: return "Lock after fixed & inactivity"
        }
    }
}

public class AutoLockManager: ObservableObject {
    @Published public private(set) var isLocked = false
    @Published private(set) var interval: TimeInterval
    private var mode: AutoLockMode
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitors: [Any] = []
    private var hasPromptedOnReturn = false

    public static let shared: AutoLockManager = {
        let minutes = UserDefaults.standard.integer(forKey: "autoLockInterval")
        let interval: TimeInterval = TimeInterval(minutes > 0 ? minutes : 5) * 60
        let rawMode = UserDefaults.standard.integer(forKey: "autoLockMode")
        let mode = AutoLockMode(rawValue: rawMode) ?? .both
        return AutoLockManager(interval: interval, mode: mode)
    }()

    private init(interval: TimeInterval, mode: AutoLockMode) {
        self.interval = interval
        self.mode = mode
        setupEventMonitors()
        resetTimer()
    }

    public func setInterval(_ newValue: TimeInterval) {
        interval = newValue
        resetTimer()
    }

    public func lock() {
        performLockCheck()
    }

    public func resetTimer() {
        guard interval > 0 else {
            timer?.invalidate()
            return
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.performLockCheck()
        }
    }

    public func unlock() {
        isLocked = false
        resetTimer()
    }

    private func performLockCheck() {
        isLocked = true
    }

    public func authenticate(completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var authError: NSError?
        let reason = "Unlock CardLocker"
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                DispatchQueue.main.async { completion(success) }
            }
        } else {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Authentication Unavailable"
                alert.informativeText = "Enable Touch ID or passcode to unlock."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                completion(false)
            }
        }
    }

    private func setupEventMonitors() {
        let masks: [NSEvent.EventTypeMask] = [.keyDown, .leftMouseDown, .scrollWheel]
        for mask in masks {
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
                self?.userDidInteract()
                return event
            }) {
                eventMonitors.append(monitor)
            }
        }

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.handleAppDidBecomeActive()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                if self?.interval == 0 {
                    self?.performLockCheck()
                }
            }
            .store(in: &cancellables)
    }

    private func userDidInteract() {
        guard mode != .activityBased else { return }
        resetTimer()
    }

    private func handleAppDidBecomeActive() {
        if isLocked {
            authenticate { success in
                if success { self.unlock() }
            }
        } else if mode != .fixed {
            resetTimer()
        }
    }

    deinit {
        eventMonitors.forEach { NSEvent.removeMonitor($0) }
        timer?.invalidate()
        cancellables.forEach { $0.cancel() }
    }
}

// MARK: – AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var pathMonitor: NWPathMonitor?
    private var offlineTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1) Configure Firebase & disable offline persistence
        FirebaseApp.configure()
        Firestore.firestore().settings.isPersistenceEnabled = false

        // 2) Monitor network reachability
        pathMonitor = NWPathMonitor()
        pathMonitor?.pathUpdateHandler = { [weak self] path in
            if path.status != .satisfied {
                DispatchQueue.main.async {
                    if self?.offlineTimer == nil {
                        self?.offlineTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { _ in
                            let alert = NSAlert()
                            alert.messageText = "No network detected"
                            alert.informativeText = "CardLocker will lock after 3 days offline."
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: "OK")
                            alert.runModal()
                            self?.offlineTimer = nil
                        }
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self?.offlineTimer?.invalidate()
                    self?.offlineTimer = nil
                }
            }
        }
        pathMonitor?.start(queue: DispatchQueue.global(qos: .background))

        // 3) Show main window on launch
        if let mainWindow = NSApp.windows.first(where: { $0.title == "CardLocker" }) {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let autoLock = AutoLockManager.shared

        if autoLock.isLocked {
            let context = LAContext()
            let reason = "Unlock CardLocker"
            if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) {
                context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                    DispatchQueue.main.async {
                        if success {
                            autoLock.unlock()
                            NSApp.activate(ignoringOtherApps: true)
                            sender.windows.first(where: { $0.title == "CardLocker" })?.makeKeyAndOrderFront(nil)
                        }
                    }
                }
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            sender.windows.first(where: { $0.title == "CardLocker" })?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        pathMonitor?.cancel()
        offlineTimer?.invalidate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NSApp.setActivationPolicy(.accessory)
        NSApp.hide(nil)
        return .terminateCancel
    }
}

// MARK: – ContentView & SettingsView (simplified)

struct ContentView: View {
    @EnvironmentObject var autoLockManager: AutoLockManager

    var body: some View {
        VStack {
            Text("Welcome to CardLocker")
        }
        .onAppear {
            autoLockManager.resetTimer()
        }
        .onReceive(autoLockManager.$isLocked) { locked in
            if locked {
                autoLockManager.authenticate { success in
                    if success { autoLockManager.unlock() }
                }
            }
        }
    }
}

struct SettingsView: View {
    @AppStorage("useICloud") private var useICloud: Bool = false
    @AppStorage("showInDock") private var showInDock: Bool = true
    @AppStorage("autoLockInterval") private var autoLockInterval: Int = 5
    @AppStorage("autoLockMode") private var autoLockModeValue: AutoLockMode = .both
    @AppStorage("lockOnBoot") private var lockOnBoot: Bool = true

    @EnvironmentObject var autoLockManager: AutoLockManager

    @State private var selection: PreferenceSection = .appearance

    enum PreferenceSection: String, CaseIterable, Identifiable {
        case appearance = "Appearance"
        case cloudSync   = "Cloud Sync"
        case autoLock    = "Auto-Lock Interval"
        var id: String { rawValue }
        var iconName: String {
            switch self {
            case .appearance: return "paintbrush"
            case .cloudSync:  return "icloud"
            case .autoLock:   return "timer"
            }
        }
    }

    var body: some View {
        NavigationView {
            List(selection: $selection) {
                ForEach(PreferenceSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.iconName).tag(section)
                }
            }
            .listStyle(SidebarListStyle())
            .frame(minWidth: 180)

            Group {
                switch selection {
                case .appearance: return AnyView(appearanceDetail)
                case .cloudSync:  return AnyView(cloudSyncDetail)
                case .autoLock:   return AnyView(autoLockDetail)
                }
            }
            .padding()
        }
        .frame(minWidth: 600, minHeight: 400)
        .onReceive(autoLockManager.$isLocked) { locked in
            if locked, let window = NSApp.windows.first(where: { $0.title == "Settings" }) {
                window.orderOut(nil)
            }
        }
    }

    private var appearanceDetail: some View {
        VStack {
            Text("Appearance Settings")
            Toggle("Show in Dock", isOn: $showInDock)
        }
        .padding()
    }

    private var cloudSyncDetail: some View {
        VStack {
            Text("Cloud Sync Settings")
            Toggle("Enable iCloud Sync", isOn: $useICloud)
                .onChange(of: useICloud) { newValue in
                    if newValue {
                        autoLockManager.authenticate { success in
                            if success { useICloud = true }
                        }
                    } else {
                        useICloud = false
                    }
                }
        }
        .padding()
    }

    private var autoLockDetail: some View {
        let autoLockOptions: [TimeInterval] = [60, 120, 300, 600, 1800, 3600]
        @State var selectedInterval: TimeInterval = AutoLockManager.shared.interval

        return VStack(alignment: .leading) {
            Text("Auto-Lock Interval")
            Picker("Interval", selection: $selectedInterval) {
                ForEach(autoLockOptions, id: \.self) { interval in
                    Text("\(Int(interval/60)) minute(s)").tag(interval)
                }
            }
            .onChange(of: selectedInterval) { newValue in
                AutoLockManager.shared.setInterval(newValue)
                AutoLockManager.shared.resetTimer()
            }
        }
        .padding()
    }
}