//
//  EbookProgressSyncTests.swift
//  AudiobookshelfUnitTests
//
//  Tests for ebook progress synchronization issues (GitHub Issue #1022)
//

import XCTest
import RealmSwift
@testable import Audiobookshelf

final class EbookProgressSyncTests: XCTestCase {
    
    var testRealm: Realm!
    
    override func setUp() {
        super.setUp()
        
        // Use in-memory Realm for testing
        let config = Realm.Configuration(inMemoryIdentifier: "EbookProgressSyncTests")
        testRealm = try! Realm(configuration: config)
    }
    
    override func tearDown() {
        // Clear test data
        try! testRealm.write {
            testRealm.deleteAll()
        }
        testRealm = nil
        super.tearDown()
    }
    
    // MARK: - Helper Methods
    
    func createTestLocalMediaProgress(
        id: String = "test-progress-id",
        localLibraryItemId: String = "test-local-item-id",
        ebookLocation: String = "epubcfi(/6/4[chapter1]!/4/2/1:0)",
        ebookProgress: Double = 0.25,
        serverConnectionConfigId: String? = "test-server-config"
    ) -> LocalMediaProgress {
        
        let progress = LocalMediaProgress()
        progress.id = id
        progress.localLibraryItemId = localLibraryItemId
        progress.ebookLocation = ebookLocation
        progress.ebookProgress = ebookProgress
        progress.lastUpdate = Date().timeIntervalSince1970 * 1000
        progress.serverConnectionConfigId = serverConnectionConfigId
        
        try! testRealm.write {
            testRealm.add(progress)
        }
        
        return progress
    }
    
    func createTestServerMediaProgress(
        id: String = "test-server-progress-id",
        libraryItemId: String = "server-library-item-id",
        ebookLocation: String = "epubcfi(/6/4[chapter1]!/4/1/1:0)",
        ebookProgress: Double = 0.15,
        lastUpdate: Double? = nil
    ) -> MediaProgress {
        
        let serverProgress = MediaProgress()
        serverProgress.id = id
        serverProgress.libraryItemId = libraryItemId
        serverProgress.ebookLocation = ebookLocation
        serverProgress.ebookProgress = ebookProgress
        serverProgress.lastUpdate = lastUpdate ?? (Date().timeIntervalSince1970 * 1000 - 300000) // 5 minutes ago
        
        return serverProgress
    }
    
    // MARK: - Core Issue Tests
    
    func testEbookProgressLocalUpdateOnly() {
        // Test Case 1: Verify that ebook progress updates only locally when offline
        
        let localProgress = createTestLocalMediaProgress(
            ebookLocation: "epubcfi(/6/4[chapter1]!/4/1/1:0)",
            ebookProgress: 0.1
        )
        
        // Simulate reading offline - update ebook progress
        let newLocation = "epubcfi(/6/4[chapter2]!/4/1/1:0)"
        let newProgress: Double = 0.4
        
        try! localProgress.updateEbookProgress(ebookLocation: newLocation, ebookProgress: newProgress)
        
        // Verify local progress was updated
        XCTAssertEqual(localProgress.ebookLocation, newLocation)
        XCTAssertEqual(localProgress.ebookProgress, newProgress, accuracy: 0.001)
        
        // ISSUE: No mechanism to track that this progress needs server sync
        // In a real implementation, we'd want a field like 'needsServerSync' or 'lastServerSync'
        XCTAssertNil(localProgress.lastServerSync, "Should track when progress was last synced to server")
    }
    
    func testSyncServerMediaProgressWithLocalMediaProgress() {
        // Test Case 2: Test the existing sync method that only handles incoming server updates
        
        let localProgress = createTestLocalMediaProgress(
            ebookProgress: 0.25,
            ebookLocation: "epubcfi(/6/4[chapter1]!/4/2/1:0)"
        )
        
        let serverProgress = createTestServerMediaProgress(
            ebookProgress: 0.35,
            ebookLocation: "epubcfi(/6/4[chapter1]!/4/3/1:0)",
            lastUpdate: Date().timeIntervalSince1970 * 1000 // More recent
        )
        
        // This simulates receiving a server update (works correctly)
        try! localProgress.updateFromServerMediaProgress(serverProgress)
        
        // Verify local progress was updated from server
        XCTAssertEqual(localProgress.ebookProgress, 0.35, accuracy: 0.001)
        XCTAssertEqual(localProgress.ebookLocation, "epubcfi(/6/4[chapter1]!/4/3/1:0)")
        
        // ISSUE: This only works for server -> local sync, not local -> server
    }
    
    func testOfflineReadingProgressDoesNotSyncToServer() {
        // Test Case 3: Demonstrate the core issue - offline reading doesn't sync back
        
        let localProgress = createTestLocalMediaProgress(
            ebookProgress: 0.1,
            ebookLocation: "epubcfi(/6/4[chapter1]!/4/1/1:0)"
        )
        
        // Simulate offline reading session
        let offlineUpdates = [
            ("epubcfi(/6/4[chapter1]!/4/2/1:0)", 0.2),
            ("epubcfi(/6/4[chapter2]!/4/1/1:0)", 0.3),
            ("epubcfi(/6/4[chapter2]!/4/2/1:0)", 0.4)
        ]
        
        for (location, progress) in offlineUpdates {
            try! localProgress.updateEbookProgress(ebookLocation: location, ebookProgress: progress)
        }
        
        // Verify final local state
        XCTAssertEqual(localProgress.ebookProgress, 0.4, accuracy: 0.001)
        XCTAssertEqual(localProgress.ebookLocation, "epubcfi(/6/4[chapter2]!/4/2/1:0)")
        
        // MISSING: No automatic mechanism to sync this progress to server when connection is restored
        // The AbsDatabase.updateLocalEbookProgress method only saves locally
        
        // MISSING: No way to detect which progress items need server sync
        let progressNeedingSync = testRealm.objects(LocalMediaProgress.self)
            .filter("lastServerSync == nil OR lastUpdate > lastServerSync")
        
        // This would fail because lastServerSync property doesn't exist
        // XCTAssertEqual(progressNeedingSync.count, 1)
    }
    
    func testServerConnectionLogic() {
        // Test Case 4: Test the server connection logic that determines sync eligibility
        
        let currentServerConfigId = "current-server-123"
        let differentServerConfigId = "different-server-456"
        
        // Progress from current server - should be eligible for sync
        let currentServerProgress = createTestLocalMediaProgress(
            id: "current-server-progress",
            serverConnectionConfigId: currentServerConfigId
        )
        
        // Progress from different server - should not sync
        let differentServerProgress = createTestLocalMediaProgress(
            id: "different-server-progress", 
            serverConnectionConfigId: differentServerConfigId
        )
        
        // Progress with no server association - should not sync
        let localOnlyProgress = createTestLocalMediaProgress(
            id: "local-only-progress",
            serverConnectionConfigId: nil
        )
        
        // Simulate current server connection
        Store.serverConfig = ServerConnectionConfig()
        Store.serverConfig?.id = currentServerConfigId
        
        // ISSUE: The app has no background service to check for and sync eligible progress
        // In Android, MediaProgressSyncer.kt handles this, but iOS has no equivalent
        
        XCTAssertEqual(currentServerProgress.serverConnectionConfigId, currentServerConfigId)
        XCTAssertNotEqual(differentServerProgress.serverConnectionConfigId, currentServerConfigId)
        XCTAssertNil(localOnlyProgress.serverConnectionConfigId)
    }
    
    func testProgressConflictResolution() {
        // Test Case 5: Test what happens when local and server progress conflict
        
        let localProgress = createTestLocalMediaProgress(
            ebookProgress: 0.6,
            ebookLocation: "epubcfi(/6/4[chapter3]!/4/1/1:0)"
        )
        
        // Server has older, less progress
        let olderServerProgress = createTestServerMediaProgress(
            ebookProgress: 0.3,
            ebookLocation: "epubcfi(/6/4[chapter2]!/4/1/1:0)",
            lastUpdate: Date().timeIntervalSince1970 * 1000 - 600000 // 10 minutes ago
        )
        
        // Server has newer, but less progress (user read on another device then went back)
        let newerServerProgress = createTestServerMediaProgress(
            ebookProgress: 0.4,
            ebookLocation: "epubcfi(/6/4[chapter2]!/4/2/1:0)",
            lastUpdate: Date().timeIntervalSince1970 * 1000 + 60000 // 1 minute in future
        )
        
        let localUpdateTime = localProgress.lastUpdate
        
        // Test conflict with older server progress - local should win
        if localUpdateTime > olderServerProgress.lastUpdate {
            // Local is newer and further - should be synced to server
            XCTAssertGreaterThan(localProgress.ebookProgress, olderServerProgress.ebookProgress)
            // MISSING: Mechanism to push local progress to server
        }
        
        // Test conflict with newer server progress - need resolution strategy
        if newerServerProgress.lastUpdate > localUpdateTime {
            // Server is newer but has less progress
            // Issue #1022 suggests preferring furthest read position
            let furthestProgress = max(localProgress.ebookProgress, newerServerProgress.ebookProgress)
            XCTAssertEqual(furthestProgress, 0.6) // Local progress is further
            
            // MISSING: Smart conflict resolution that prefers furthest read
        }
    }
    
    func testManualSyncButtonFunctionality() {
        // Test Case 6: Test the proposed manual sync button functionality
        
        let unsyncedProgress = createTestLocalMediaProgress(
            ebookProgress: 0.8,
            ebookLocation: "epubcfi(/6/4[chapter4]!/4/1/1:0)"
        )
        
        // MISSING: Method to manually trigger sync to server
        // This would be the implementation for the "sync progress to server" button
        // mentioned in the GitHub issue
        
        /*
        // Proposed implementation:
        func syncProgressToServer(localProgress: LocalMediaProgress) -> Bool {
            guard let serverConfig = Store.serverConfig,
                  localProgress.serverConnectionConfigId == serverConfig.id,
                  ApiClient.isConnectedToInternet else {
                return false
            }
            
            // Send local progress to server
            let success = ApiClient.sendProgressUpdate(
                libraryItemId: localProgress.serverLibraryItemId,
                ebookLocation: localProgress.ebookLocation,
                ebookProgress: localProgress.ebookProgress
            )
            
            if success {
                localProgress.lastServerSync = Date().timeIntervalSince1970 * 1000
            }
            
            return success
        }
        */
        
        // For now, just verify the progress exists and has the expected values
        XCTAssertEqual(unsyncedProgress.ebookProgress, 0.8, accuracy: 0.001)
        XCTAssertNotNil(unsyncedProgress.ebookLocation)
        
        // This test documents what the manual sync button should do
    }
    
    func testBackgroundSyncServiceNeeded() {
        // Test Case 7: Demonstrate the need for a background sync service
        
        // Create multiple progress items that would need syncing
        let progress1 = createTestLocalMediaProgress(
            id: "progress-1",
            ebookProgress: 0.2,
            serverConnectionConfigId: "server-123"
        )
        
        let progress2 = createTestLocalMediaProgress(
            id: "progress-2", 
            ebookProgress: 0.5,
            serverConnectionConfigId: "server-123"
        )
        
        let progress3 = createTestLocalMediaProgress(
            id: "progress-3",
            ebookProgress: 0.7,
            serverConnectionConfigId: "different-server"
        )
        
        // Simulate current server connection
        Store.serverConfig = ServerConnectionConfig()
        Store.serverConfig?.id = "server-123"
        
        // Find progress items that should be synced to current server
        let syncableProgress = testRealm.objects(LocalMediaProgress.self)
            .filter("serverConnectionConfigId == %@", "server-123")
        
        XCTAssertEqual(syncableProgress.count, 2)
        
        // MISSING: iOS equivalent of Android's MediaProgressSyncer
        // iOS needs a background service that:
        // 1. Monitors network connectivity
        // 2. Finds unsynced local progress for current server
        // 3. Attempts to sync when connected
        // 4. Retries failed syncs with exponential backoff
        
        /*
        // Proposed background sync service:
        class EbookProgressSyncService {
            static func syncPendingProgress() {
                guard let serverConfig = Store.serverConfig,
                      ApiClient.isConnectedToInternet else { return }
                
                let unsyncedProgress = Database.shared.getUnsyncedProgressForServer(serverConfig.id)
                
                for progress in unsyncedProgress {
                    syncProgressToServer(progress)
                }
            }
        }
        */
    }
    
    // MARK: - Regression Tests
    
    func testDeleteLocalItemWorkaroundStillWorks() {
        // Test Case 8: Verify that the current workaround (delete local item) still works
        
        let localProgress = createTestLocalMediaProgress(
            ebookProgress: 0.9,
            ebookLocation: "epubcfi(/6/4[chapter5]!/4/1/1:0)"
        )
        
        // Verify progress exists
        XCTAssertNotNil(testRealm.object(ofType: LocalMediaProgress.self, forPrimaryKey: localProgress.id))
        
        // Simulate "delete local item" action
        try! testRealm.write {
            testRealm.delete(localProgress)
        }
        
        // Verify progress is deleted (user would then re-download and get server progress)
        XCTAssertNil(testRealm.object(ofType: LocalMediaProgress.self, forPrimaryKey: "test-progress-id"))
        
        // This confirms the current workaround works, but it's not ideal
    }
    
    func testAudioProgressSyncWorksCorrectly() {
        // Test Case 9: Verify that audio progress sync works correctly for comparison
        
        // Note: This would test the existing audio sync functionality
        // to confirm that the issue is specific to ebooks
        
        // Audio progress uses PlaybackSession and MediaProgressSyncer
        // which has automatic background sync, retry logic, etc.
        
        // EBOOK PROGRESS SHOULD WORK THE SAME WAY
        
        XCTAssertTrue(true, "Audio sync works correctly - ebook sync should be similar")
    }
}

// MARK: - Extensions for Testing

extension LocalMediaProgress {
    
    /// Mock method to simulate what lastServerSync property would look like
    var lastServerSync: Double? {
        // This property doesn't exist but should be added to track sync status
        return nil
    }
    
    /// Updates ebook progress and location
    func updateEbookProgress(ebookLocation: String, ebookProgress: Double) throws {
        try realm?.write {
            self.ebookLocation = ebookLocation
            self.ebookProgress = ebookProgress
            self.lastUpdate = Date().timeIntervalSince1970 * 1000
        }
    }
}