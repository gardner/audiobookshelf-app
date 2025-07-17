//
//  EbookProgressSyncManager.swift
//  App
//
//  Background sync service for ebook reading progress
//  iOS equivalent to Android's MediaProgressSyncer for ebook content
//  Uses Background App Refresh and Background Processing for sync
//

import Foundation
import Network
import RealmSwift
import BackgroundTasks
import UIKit

public class EbookProgressSyncManager: ObservableObject {
    
    private let logger = AppLogger(category: "EbookProgressSync")
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "NetworkMonitor")
    
    // Background task identifiers
    private static let backgroundTaskIdentifier = "com.audiobookshelf.app.ebook-sync"
    private static let backgroundRefreshIdentifier = "com.audiobookshelf.app.ebook-refresh"
    
    // Sync state
    private var syncTimer: Timer?
    private var retryAttempts: [String: Int] = [:] // progressId -> retry count
    private var isCurrentlySyncing = false
    
    // Sync configuration
    private let syncInterval: TimeInterval = 30.0 // Check every 30 seconds
    private let maxRetryAttempts = 5
    private let baseRetryDelay: TimeInterval = 2.0 // Start with 2 second delay
    
    public static let shared = EbookProgressSyncManager()
    
    private init() {
        registerBackgroundTasks()
        startNetworkMonitoring()
        startPeriodicSync()
    }
    
    deinit {
        stopNetworkMonitoring()
        stopPeriodicSync()
    }
    
    // MARK: - Background Task Registration
    
    private func registerBackgroundTasks() {
        // Register background processing task for sync
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundTaskIdentifier,
            using: nil
        ) { [weak self] task in
            self?.handleBackgroundSync(task: task as! BGProcessingTask)
        }
        
        // Register background app refresh task for quick sync
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundRefreshIdentifier,
            using: nil
        ) { [weak self] task in
            self?.handleBackgroundRefresh(task: task as! BGAppRefreshTask)
        }
    }
    
    // Schedule background tasks when app enters background
    public func scheduleBackgroundTasks() {
        scheduleBackgroundProcessing()
        scheduleBackgroundRefresh()
    }
    
    private func scheduleBackgroundProcessing() {
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes
        
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.log("Scheduled background processing task")
        } catch {
            logger.error("Failed to schedule background processing: \(error)")
        }
    }
    
    private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60) // 5 minutes
        
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.log("Scheduled background refresh task")
        } catch {
            logger.error("Failed to schedule background refresh: \(error)")
        }
    }
    
    // MARK: - Background Task Handlers
    
    private func handleBackgroundSync(task: BGProcessingTask) {
        logger.log("Background processing task started")
        
        // Schedule next background task
        scheduleBackgroundProcessing()
        
        // Set expiration handler
        task.expirationHandler = {
            self.logger.log("Background sync task expired")
            task.setTaskCompleted(success: false)
        }
        
        // Perform sync
        Task {
            let success = await performBackgroundSync()
            task.setTaskCompleted(success: success)
            self.logger.log("Background sync completed: \(success)")
        }
    }
    
    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        logger.log("Background refresh task started")
        
        // Schedule next refresh
        scheduleBackgroundRefresh()
        
        // Set expiration handler
        task.expirationHandler = {
            self.logger.log("Background refresh task expired")
            task.setTaskCompleted(success: false)
        }
        
        // Quick sync check
        Task {
            let success = await performQuickSync()
            task.setTaskCompleted(success: success)
            self.logger.log("Background refresh completed: \(success)")
        }
    }
    
    private func performBackgroundSync() async -> Bool {
        guard let serverConfig = Store.serverConfig else {
            logger.log("No server config for background sync")
            return false
        }
        
        guard isNetworkAvailable() else {
            logger.log("No network for background sync")
            return false
        }
        
        do {
            let pendingItems = try await getPendingProgressItems(for: serverConfig.id)
            logger.log("Background sync found \(pendingItems.count) pending items")
            
            var successCount = 0
            for progress in pendingItems.prefix(10) { // Limit to 10 items to avoid timeout
                let success = await syncProgressItemQuietly(progress, serverConfig: serverConfig)
                if success { successCount += 1 }
            }
            
            logger.log("Background sync completed \(successCount)/\(min(pendingItems.count, 10)) items")
            return successCount > 0
            
        } catch {
            logger.error("Background sync error: \(error)")
            return false
        }
    }
    
    private func performQuickSync() async -> Bool {
        // Quick check for urgent syncs (recently updated items)
        guard let serverConfig = Store.serverConfig else { return false }
        guard isNetworkAvailable() else { return false }
        
        do {
            let recentItems = try await getRecentlyUpdatedItems(for: serverConfig.id)
            if recentItems.isEmpty { return true }
            
            logger.log("Quick sync found \(recentItems.count) recent items")
            
            for progress in recentItems.prefix(3) { // Limit for quick sync
                await syncProgressItemQuietly(progress, serverConfig: serverConfig)
            }
            
            return true
        } catch {
            logger.error("Quick sync error: \(error)")
            return false
        }
    }
    
    private func getRecentlyUpdatedItems(for serverConfigId: String) async throws -> [LocalMediaProgress] {
        let oneHourAgo = Date().timeIntervalSince1970 * 1000 - (60 * 60 * 1000)
        
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let realm = try Realm()
                let recentProgress = realm.objects(LocalMediaProgress.self)
                    .filter("serverConnectionConfigId == %@ AND ebookLocation != nil", serverConfigId)
                    .filter("lastUpdate > %@", oneHourAgo)
                    .filter("lastServerSync == nil OR lastUpdate > lastServerSync")
                
                continuation.resume(returning: Array(recentProgress))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    private func syncProgressItemQuietly(
        _ progress: LocalMediaProgress,
        serverConfig: ServerConnectionConfig
    ) async -> Bool {
        do {
            await syncProgressItem(progress, serverConfig: serverConfig)
            return true
        } catch {
            logger.error("Quiet sync failed for \(progress.id): \(error)")
            return false
        }
    }
    
    // MARK: - Network Monitoring
    
    private func startNetworkMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied {
                self?.logger.log("Network connection restored")
                // Trigger immediate sync when network comes back online
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.syncPendingProgress()
                }
            } else {
                self?.logger.log("Network connection lost")
            }
        }
        monitor.start(queue: monitorQueue)
    }
    
    private func stopNetworkMonitoring() {
        monitor.cancel()
    }
    
    // MARK: - Periodic Sync
    
    private func startPeriodicSync() {
        syncTimer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
            self?.syncPendingProgress()
        }
    }
    
    private func stopPeriodicSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }
    
    // MARK: - Main Sync Logic
    
    public func syncPendingProgress() {
        guard !isCurrentlySyncing else {
            logger.log("Sync already in progress, skipping")
            return
        }
        
        guard isNetworkAvailable() else {
            logger.log("No network available for sync")
            return
        }
        
        guard let serverConfig = Store.serverConfig else {
            logger.log("No server configuration available")
            return
        }
        
        isCurrentlySyncing = true
        
        Task {
            await performSync(serverConfig: serverConfig)
            isCurrentlySyncing = false
        }
    }
    
    private func performSync(serverConfig: ServerConnectionConfig) async {
        do {
            // Get all local progress items that need syncing
            let pendingItems = try await getPendingProgressItems(for: serverConfig.id)
            
            logger.log("Found \(pendingItems.count) ebook progress items pending sync")
            
            for progress in pendingItems {
                await syncProgressItem(progress, serverConfig: serverConfig)
            }
            
        } catch {
            logger.error("Failed to get pending progress items: \(error)")
        }
    }
    
    private func getPendingProgressItems(for serverConfigId: String) async throws -> [LocalMediaProgress] {
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let realm = try Realm()
                
                // Find progress items that:
                // 1. Belong to the current server
                // 2. Have been updated since last server sync
                // 3. Are for ebook content (have ebookLocation)
                let pendingProgress = realm.objects(LocalMediaProgress.self)
                    .filter("serverConnectionConfigId == %@ AND ebookLocation != nil AND ebookLocation != ''", serverConfigId)
                    .filter("lastServerSync == nil OR lastUpdate > lastServerSync")
                
                let progressArray = Array(pendingProgress)
                continuation.resume(returning: progressArray)
                
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    private func syncProgressItem(_ progress: LocalMediaProgress, serverConfig: ServerConnectionConfig) async {
        let progressId = progress.id
        let currentRetries = retryAttempts[progressId] ?? 0
        
        if currentRetries >= maxRetryAttempts {
            logger.error("Max retry attempts reached for progress \(progressId)")
            retryAttempts.removeValue(forKey: progressId)
            return
        }
        
        // Check if we need to wait before retrying
        if currentRetries > 0 {
            let delay = calculateRetryDelay(attempt: currentRetries)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        
        logger.log("Syncing ebook progress for item \(progress.localLibraryItemId) (attempt \(currentRetries + 1))")
        
        do {
            // Get the server library item ID
            guard let serverLibraryItemId = getServerLibraryItemId(for: progress) else {
                logger.error("No server library item ID found for progress \(progressId)")
                return
            }
            
            // Check for conflicts with server progress
            let resolvedProgress = try await resolveProgressConflicts(
                localProgress: progress,
                serverLibraryItemId: serverLibraryItemId,
                serverConfig: serverConfig
            )
            
            // Send the resolved progress to server
            let success = try await sendProgressToServer(
                progress: resolvedProgress,
                serverLibraryItemId: serverLibraryItemId,
                serverConfig: serverConfig
            )
            
            if success {
                // Mark as successfully synced
                try await markProgressAsSynced(progress)
                retryAttempts.removeValue(forKey: progressId)
                logger.log("Successfully synced ebook progress for \(serverLibraryItemId)")
            } else {
                // Increment retry count
                retryAttempts[progressId] = currentRetries + 1
                logger.error("Failed to sync progress for \(progressId), will retry")
            }
            
        } catch {
            // Increment retry count for errors
            retryAttempts[progressId] = currentRetries + 1
            logger.error("Error syncing progress for \(progressId): \(error)")
        }
    }
    
    // MARK: - Conflict Resolution
    
    private func resolveProgressConflicts(
        localProgress: LocalMediaProgress,
        serverLibraryItemId: String,
        serverConfig: ServerConnectionConfig
    ) async throws -> LocalMediaProgress {
        
        // Fetch current server progress
        let serverProgress = try await fetchServerProgress(
            libraryItemId: serverLibraryItemId,
            serverConfig: serverConfig
        )
        
        guard let serverProgress = serverProgress else {
            // No server progress exists, use local
            return localProgress
        }
        
        // Conflict resolution strategy from GitHub issue #1022:
        // "Conflicts can be resolved by either preferring the furthest-read position"
        
        let localLastUpdate = localProgress.lastUpdate
        let serverLastUpdate = serverProgress.lastUpdate
        
        // Strategy 1: Prefer furthest read position
        if localProgress.ebookProgress > serverProgress.ebookProgress {
            logger.log("Local progress (\(localProgress.ebookProgress)) is further than server (\(serverProgress.ebookProgress)), using local")
            return localProgress
        } else if serverProgress.ebookProgress > localProgress.ebookProgress {
            logger.log("Server progress (\(serverProgress.ebookProgress)) is further than local (\(localProgress.ebookProgress)), updating local")
            
            // Update local progress with server data
            try await updateLocalProgressFromServer(localProgress, serverProgress: serverProgress)
            return localProgress
        }
        
        // Strategy 2: If progress is equal, prefer most recent timestamp
        if localLastUpdate > serverLastUpdate {
            logger.log("Equal progress, local is more recent, using local")
            return localProgress
        } else {
            logger.log("Equal progress, server is more recent, using server")
            try await updateLocalProgressFromServer(localProgress, serverProgress: serverProgress)
            return localProgress
        }
    }
    
    private func updateLocalProgressFromServer(
        _ localProgress: LocalMediaProgress,
        serverProgress: MediaProgress
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                let realm = try Realm()
                try realm.write {
                    localProgress.updateFromServerMediaProgress(serverProgress)
                }
                continuation.resume()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    // MARK: - API Communication
    
    private func fetchServerProgress(
        libraryItemId: String,
        serverConfig: ServerConnectionConfig
    ) async throws -> MediaProgress? {
        
        return try await withCheckedThrowingContinuation { continuation in
            ApiClient.getResource(
                endpoint: "api/me/progress/\(libraryItemId)",
                decodable: MediaProgress.self
            ) { progress in
                continuation.resume(returning: progress)
            } failure: { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    private func sendProgressToServer(
        progress: LocalMediaProgress,
        serverLibraryItemId: String,
        serverConfig: ServerConnectionConfig
    ) async throws -> Bool {
        
        let progressData: [String: Any] = [
            "ebookLocation": progress.ebookLocation ?? "",
            "ebookProgress": progress.ebookProgress,
            "lastUpdate": progress.lastUpdate,
            "isFinished": progress.isFinished
        ]
        
        return try await withCheckedThrowingContinuation { continuation in
            ApiClient.patchResource(
                endpoint: "api/me/progress/\(serverLibraryItemId)",
                parameters: progressData
            ) { success in
                continuation.resume(returning: success)
            } failure: { error in
                continuation.resume(returning: false)
            }
        }
    }
    
    private func markProgressAsSynced(_ progress: LocalMediaProgress) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                let realm = try Realm()
                try realm.write {
                    progress.lastServerSync = Date().timeIntervalSince1970 * 1000
                }
                continuation.resume()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func isNetworkAvailable() -> Bool {
        return ApiClient.isConnectedToInternet
    }
    
    private func getServerLibraryItemId(for progress: LocalMediaProgress) -> String? {
        do {
            let realm = try Realm()
            let localItem = realm.object(ofType: LocalLibraryItem.self, forPrimaryKey: progress.localLibraryItemId)
            return localItem?.libraryItemId
        } catch {
            logger.error("Failed to get server library item ID: \(error)")
            return nil
        }
    }
    
    private func calculateRetryDelay(attempt: Int) -> TimeInterval {
        // Exponential backoff: 2^attempt * baseDelay
        return pow(2.0, Double(attempt)) * baseRetryDelay
    }
    
    // MARK: - Manual Sync
    
    /// Manual sync method for "sync progress to server" button
    public func manualSyncProgress(for localLibraryItemId: String) async throws -> Bool {
        guard let serverConfig = Store.serverConfig else {
            throw EbookSyncError.noServerConfig
        }
        
        guard isNetworkAvailable() else {
            throw EbookSyncError.noNetwork
        }
        
        let realm = try Realm()
        guard let progress = realm.objects(LocalMediaProgress.self)
            .filter("localLibraryItemId == %@", localLibraryItemId).first else {
            throw EbookSyncError.progressNotFound
        }
        
        await syncProgressItem(progress, serverConfig: serverConfig)
        
        // Check if sync was successful
        let updatedProgress = realm.objects(LocalMediaProgress.self)
            .filter("localLibraryItemId == %@", localLibraryItemId).first
        
        return updatedProgress?.lastServerSync != nil &&
               updatedProgress!.lastServerSync! >= updatedProgress!.lastUpdate
    }
    
    /// Check if progress item has pending sync
    public func hasPendingSync(for localLibraryItemId: String) -> Bool {
        do {
            let realm = try Realm()
            let progress = realm.objects(LocalMediaProgress.self)
                .filter("localLibraryItemId == %@", localLibraryItemId).first
            
            guard let progress = progress else { return false }
            
            // Has pending sync if never synced or local update is newer than last sync
            return progress.lastServerSync == nil || progress.lastUpdate > progress.lastServerSync!
            
        } catch {
            logger.error("Failed to check pending sync status: \(error)")
            return false
        }
    }
    
    /// Called when progress is updated to trigger immediate sync attempt
    public func onProgressUpdated(localLibraryItemId: String) async {
        guard isNetworkAvailable() else {
            logger.log("Progress updated but no network, will sync later")
            return
        }
        
        guard let serverConfig = Store.serverConfig else {
            logger.log("Progress updated but no server config")
            return
        }
        
        do {
            let realm = try Realm()
            let progress = realm.objects(LocalMediaProgress.self)
                .filter("localLibraryItemId == %@", localLibraryItemId).first
            
            guard let progress = progress else { return }
            
            // Attempt immediate sync for this item
            await syncProgressItem(progress, serverConfig: serverConfig)
            
        } catch {
            logger.error("Failed to sync updated progress: \(error)")
        }
    }
}

// MARK: - Error Types

enum EbookSyncError: Error {
    case noServerConfig
    case noNetwork
    case progressNotFound
    case syncFailed
    
    var localizedDescription: String {
        switch self {
        case .noServerConfig:
            return "No server configuration available"
        case .noNetwork:
            return "No network connection available"
        case .progressNotFound:
            return "Progress not found"
        case .syncFailed:
            return "Failed to sync progress to server"
        }
    }
}

// MARK: - Extensions

extension LocalMediaProgress {
    
    /// Track when progress was last synced to server
    var lastServerSync: Double? {
        get { return self.value(forKey: "lastServerSync") as? Double }
        set { self.setValue(newValue, forKey: "lastServerSync") }
    }
}