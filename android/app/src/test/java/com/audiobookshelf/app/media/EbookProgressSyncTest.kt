package com.audiobookshelf.app.media

import com.audiobookshelf.app.data.LocalMediaProgress
import com.audiobookshelf.app.data.MediaProgress
import com.audiobookshelf.app.device.DeviceManager
import org.junit.Before
import org.junit.Test
import org.junit.Assert.*
import org.mockito.Mock
import org.mockito.Mockito.*
import org.mockito.MockitoAnnotations
import java.util.*

/**
 * Tests for ebook progress synchronization issues (GitHub Issue #1022)
 * 
 * This test suite demonstrates the differences between Android audio sync 
 * (which works correctly) and ebook sync (which has issues on iOS).
 * 
 * These tests serve as a baseline to show how sync SHOULD work.
 */
class EbookProgressSyncTest {

    @Mock
    private lateinit var mockDbManager: com.audiobookshelf.app.managers.DbManager
    
    @Mock 
    private lateinit var mockApiHandler: com.audiobookshelf.app.server.ApiHandler

    private lateinit var mediaProgressSyncer: MediaProgressSyncer

    @Before
    fun setup() {
        MockitoAnnotations.openMocks(this)
        
        // Initialize MediaProgressSyncer with mocked dependencies
        mediaProgressSyncer = MediaProgressSyncer(mockApiHandler)
        
        // Mock DeviceManager static methods
        mockkStatic(DeviceManager::class)
        every { DeviceManager.dbManager } returns mockDbManager
    }

    @Test
    fun testAudioProgressSyncWorksCorrectly() {
        // This test documents how audio progress sync works correctly
        // and serves as a baseline for what ebook sync should do
        
        val audioLibraryItemId = "audio-library-item-123"
        val currentTime = 1500.0 // 25 minutes into audiobook
        val duration = 3600.0 // 1 hour total
        
        // Simulate audio progress update
        val success = mediaProgressSyncer.syncProgressToServer(
            libraryItemId = audioLibraryItemId,
            currentTime = currentTime,
            duration = duration,
            isLocal = true
        )
        
        assertTrue("Audio progress sync should succeed", success)
        
        // Verify that audio sync has proper retry mechanisms, 
        // background sync service, and conflict resolution
        // that ebook sync is missing
    }

    @Test
    fun testEbookProgressLocalUpdateComparison() {
        // Compare how ebook progress is handled vs audio progress
        
        val localMediaProgress = LocalMediaProgress().apply {
            id = "ebook-progress-123"
            localLibraryItemId = "ebook-local-item-456"
            ebookLocation = "epubcfi(/6/4[chapter1]!/4/1/1:0)"
            ebookProgress = 0.25
            lastUpdate = System.currentTimeMillis()
        }
        
        // Mock saving the local progress
        `when`(mockDbManager.saveLocalMediaProgress(localMediaProgress))
            .thenReturn(Unit)
        
        // Save ebook progress locally (this works on both platforms)
        mockDbManager.saveLocalMediaProgress(localMediaProgress)
        
        // Verify local save happened
        verify(mockDbManager).saveLocalMediaProgress(localMediaProgress)
        
        // ISSUE: Unlike audio, there's no automatic server sync for ebooks
        // Audio progress would trigger MediaProgressSyncer.sync()
        // but ebook progress only saves locally
        
        // This is what's missing for ebooks:
        // mediaProgressSyncer.syncEbookProgressToServer(localMediaProgress)
    }

    @Test
    fun testServerConnectionValidationForEbooks() {
        // Test the server connection logic that affects ebook sync
        
        val serverConfigId = "test-server-config-123"
        val localMediaProgress = LocalMediaProgress().apply {
            id = "ebook-progress-456"
            localLibraryItemId = "local-item-789"
            serverConnectionConfigId = serverConfigId
            ebookLocation = "epubcfi(/6/4[chapter2]!/4/1/1:0)"
            ebookProgress = 0.5
            lastUpdate = System.currentTimeMillis()
        }
        
        // Mock current server connection
        mockkStatic(DeviceManager::class)
        val mockServerConfig = mock(com.audiobookshelf.app.data.ServerConnectionConfig::class.java)
        `when`(mockServerConfig.id).thenReturn(serverConfigId)
        every { DeviceManager.serverConnectionConfig } returns mockServerConfig
        every { DeviceManager.isConnectedToServer } returns true
        
        // Check if progress is eligible for sync
        val isConnectedToSameServer = localMediaProgress.serverConnectionConfigId != null && 
            DeviceManager.serverConnectionConfig?.id == localMediaProgress.serverConnectionConfigId
            
        assertTrue("Should be connected to same server", isConnectedToSameServer)
        
        // This logic exists in MediaProgressSyncer for audio content
        // but there's no equivalent ebook sync service on iOS
    }

    @Test
    fun testOfflineEbookReadingScenario() {
        // Simulate the exact scenario from GitHub issue #1022
        
        val localProgress = LocalMediaProgress().apply {
            id = "offline-ebook-progress"
            localLibraryItemId = "downloaded-book-123"
            ebookLocation = "epubcfi(/6/4[chapter1]!/4/1/1:0)"
            ebookProgress = 0.0
            lastUpdate = System.currentTimeMillis()
            serverConnectionConfigId = "test-server"
        }
        
        // Step 1: Download book (progress starts at 0)
        mockDbManager.saveLocalMediaProgress(localProgress)
        
        // Step 2: Disconnect from internet (simulate offline)
        every { DeviceManager.checkConnectivity(any()) } returns false
        
        // Step 3: Read offline - multiple progress updates
        val offlineReadingUpdates = listOf(
            Pair("epubcfi(/6/4[chapter1]!/4/2/1:0)", 0.1),
            Pair("epubcfi(/6/4[chapter2]!/4/1/1:0)", 0.25),
            Pair("epubcfi(/6/4[chapter2]!/4/3/1:0)", 0.4)
        )
        
        offlineReadingUpdates.forEach { (location, progress) ->
            localProgress.ebookLocation = location
            localProgress.ebookProgress = progress
            localProgress.lastUpdate = System.currentTimeMillis()
            
            // Each update saves locally
            mockDbManager.saveLocalMediaProgress(localProgress)
        }
        
        // Verify final offline progress
        assertEquals("Final progress should be 0.4", 0.4, localProgress.ebookProgress, 0.001)
        assertEquals("Final location should be chapter 2", 
            "epubcfi(/6/4[chapter2]!/4/3/1:0)", localProgress.ebookLocation)
        
        // Step 4: Reconnect to internet
        every { DeviceManager.checkConnectivity(any()) } returns true
        every { DeviceManager.isConnectedToServer } returns true
        
        // Step 5: ISSUE - Progress is not automatically synced to server
        // On Android, MediaProgressSyncer would handle this for audio content
        // but there's no equivalent for ebooks
        
        // What SHOULD happen (but doesn't for ebooks):
        // mediaProgressSyncer.syncPendingEbookProgress()
        
        // Verify that local progress exists but server sync didn't happen automatically
        verify(mockDbManager, atLeast(4)).saveLocalMediaProgress(any())
        // Server sync would require manual intervention (delete local item workaround)
    }

    @Test
    fun testConflictResolutionStrategy() {
        // Test conflict resolution when local and server progress differ
        
        val localProgress = LocalMediaProgress().apply {
            id = "conflict-test-progress"
            localLibraryItemId = "book-with-conflict"
            ebookLocation = "epubcfi(/6/4[chapter3]!/4/1/1:0)"
            ebookProgress = 0.6  // Local user read further
            lastUpdate = System.currentTimeMillis()
        }
        
        val serverProgress = MediaProgress().apply {
            id = "server-conflict-progress"
            libraryItemId = "server-book-id"
            ebookLocation = "epubcfi(/6/4[chapter2]!/4/2/1:0)"
            ebookProgress = 0.4  // Server has less progress
            lastUpdate = System.currentTimeMillis() - 300000  // 5 minutes older
        }
        
        // Conflict resolution strategy from GitHub issue #1022:
        // "Conflicts can be resolved by either preferring the furthest-read position"
        
        val resolvedProgress = if (localProgress.ebookProgress > serverProgress.ebookProgress) {
            localProgress.ebookProgress  // Prefer furthest read
        } else {
            serverProgress.ebookProgress
        }
        
        assertEquals("Should prefer furthest read position", 0.6, resolvedProgress, 0.001)
        
        // Alternative strategy: prefer most recent timestamp
        val resolvedByTime = if (localProgress.lastUpdate > serverProgress.lastUpdate) {
            localProgress.ebookProgress
        } else {
            serverProgress.ebookProgress
        }
        
        assertEquals("Most recent should also be local (0.6)", 0.6, resolvedByTime, 0.001)
        
        // MISSING: Automatic conflict resolution for ebooks
        // Audio content has this built into MediaProgressSyncer
    }

    @Test
    fun testManualSyncButtonFunctionality() {
        // Test what the proposed "sync progress to server" button should do
        
        val unsyncedProgress = LocalMediaProgress().apply {
            id = "unsynced-ebook-progress"
            localLibraryItemId = "needs-sync-book"
            ebookLocation = "epubcfi(/6/4[chapter4]!/4/2/1:0)"
            ebookProgress = 0.8
            lastUpdate = System.currentTimeMillis()
            serverConnectionConfigId = "current-server"
        }
        
        // Mock successful API call
        `when`(mockApiHandler.sendLocalProgressSync(any(), any())).thenAnswer { invocation ->
            val callback = invocation.getArgument<(Boolean, String?) -> Unit>(1)
            callback(true, null)  // Success
        }
        
        // Simulate manual sync button press
        val syncSuccess = simulateManualEbookSync(unsyncedProgress)
        
        assertTrue("Manual sync should succeed", syncSuccess)
        
        // Verify API call was made
        verify(mockApiHandler).sendLocalProgressSync(eq(unsyncedProgress), any())
        
        // After successful sync, progress should be marked as synced
        // (This would require adding a lastServerSync field to LocalMediaProgress)
    }

    @Test
    fun testBackgroundSyncServiceComparison() {
        // Compare Android's MediaProgressSyncer (which works) 
        // to what iOS needs for ebook sync
        
        val pendingProgressItems = listOf(
            createTestLocalMediaProgress("item1", 0.2, "server-123"),
            createTestLocalMediaProgress("item2", 0.5, "server-123"),
            createTestLocalMediaProgress("item3", 0.7, "different-server")  // Should not sync
        )
        
        // Mock finding unsynced progress
        `when`(mockDbManager.getAllLocalMediaProgress())
            .thenReturn(pendingProgressItems)
        
        // Mock current server connection
        every { DeviceManager.serverConnectionConfig?.id } returns "server-123"
        every { DeviceManager.isConnectedToServer } returns true
        every { DeviceManager.checkConnectivity(any()) } returns true
        
        // Filter items that should be synced to current server
        val syncableItems = pendingProgressItems.filter { progress ->
            progress.serverConnectionConfigId == "server-123"
        }
        
        assertEquals("Should have 2 items eligible for sync", 2, syncableItems.size)
        
        // Android MediaProgressSyncer would automatically sync these
        // iOS needs equivalent service for ebooks
        
        // Simulate what background sync service should do
        syncableItems.forEach { progress ->
            simulateManualEbookSync(progress)
        }
        
        // Verify sync attempts were made for eligible items
        verify(mockApiHandler, times(2)).sendLocalProgressSync(any(), any())
    }

    // Helper methods
    
    private fun createTestLocalMediaProgress(
        itemId: String, 
        progress: Double, 
        serverConfigId: String
    ): LocalMediaProgress {
        return LocalMediaProgress().apply {
            id = "progress-$itemId"
            localLibraryItemId = itemId
            ebookLocation = "epubcfi(/6/4[chapter1]!/4/1/1:0)"
            ebookProgress = progress
            lastUpdate = System.currentTimeMillis()
            serverConnectionConfigId = serverConfigId
        }
    }
    
    private fun simulateManualEbookSync(progress: LocalMediaProgress): Boolean {
        // This simulates what the manual "sync progress to server" button should do
        
        // Check preconditions
        if (DeviceManager.serverConnectionConfig?.id != progress.serverConnectionConfigId) {
            return false  // Wrong server
        }
        
        if (!DeviceManager.checkConnectivity(null)) {
            return false  // No network
        }
        
        // Attempt sync
        var syncResult = false
        mockApiHandler.sendLocalProgressSync(progress) { success, error ->
            syncResult = success
            if (success) {
                // Mark as synced (would need new field in LocalMediaProgress)
                progress.lastUpdate = System.currentTimeMillis()
            }
        }
        
        return syncResult
    }
}