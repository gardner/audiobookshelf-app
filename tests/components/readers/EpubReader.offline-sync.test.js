/**
 * @jest-environment jsdom
 */

import { mount } from '@vue/test-utils'
import EpubReader from '@/components/readers/EpubReader.vue'

// Mock ePub.js
jest.mock('epubjs', () => ({
  __esModule: true,
  default: jest.fn(() => ({
    ready: Promise.resolve(),
    locations: {
      generate: jest.fn(() => Promise.resolve(['loc1', 'loc2', 'loc3'])),
      cfiFromLocation: jest.fn(loc => `cfi:/6/4[loc${loc}]`),
      locationFromCfi: jest.fn(cfi => parseInt(cfi.match(/loc(\d+)/)?.[1] || '0'))
    },
    renderTo: jest.fn(() => ({
      on: jest.fn(),
      display: jest.fn(() => Promise.resolve()),
      themes: {
        default: jest.fn()
      },
      resize: jest.fn()
    })),
    navigation: {
      toc: []
    }
  }))
}))

// Mock Vuex store
const mockStore = {
  getters: {
    'user/getToken': 'mock-token',
    'user/getServerAddress': 'https://server.com',
    'getIsPlayerOpen': false,
    'globals/getLocalMediaProgressById': jest.fn(() => ({
      id: 'local-progress-1',
      ebookLocation: 'cfi:/6/4[loc1]',
      ebookProgress: 0.25,
      lastUpdate: Date.now()
    })),
    'user/getUserMediaProgress': jest.fn(() => ({
      id: 'server-progress-1',
      ebookLocation: 'cfi:/6/4[loc0]',
      ebookProgress: 0.1,
      lastUpdate: Date.now() - 60000
    }))
  },
  commit: jest.fn()
}

// Mock database plugin
const mockDb = {
  updateLocalEbookProgress: jest.fn(() => Promise.resolve({
    localMediaProgress: {
      id: 'local-progress-1',
      ebookLocation: 'cfi:/6/4[loc2]',
      ebookProgress: 0.4,
      lastUpdate: Date.now()
    }
  }))
}

// Mock native HTTP plugin
const mockNativeHttp = {
  patch: jest.fn(() => Promise.resolve())
}

// Mock Navigator online status
Object.defineProperty(window.navigator, 'onLine', {
  writable: true,
  value: true
})

describe('EpubReader Offline Sync Tests', () => {
  let wrapper
  let localVue

  beforeEach(() => {
    // Reset all mocks
    jest.clearAllMocks()
    
    // Clear localStorage
    localStorage.clear()
    
    // Mock Nuxt plugins
    const mocks = {
      $store: mockStore,
      $db: mockDb,
      $nativeHttp: mockNativeHttp,
      $platform: 'ios'
    }

    wrapper = mount(EpubReader, {
      propsData: {
        url: '/test-book.epub',
        libraryItem: {
          id: 'test-item-id',
          serverAddress: 'https://server.com',
          libraryItemId: 'server-item-id'
        },
        isLocal: true,
        keepProgress: true
      },
      mocks
    })
  })

  afterEach(() => {
    if (wrapper) {
      wrapper.destroy()
    }
  })

  describe('Basic Progress Update', () => {
    it('should update local progress when keepProgress is enabled', async () => {
      const progressPayload = {
        ebookLocation: 'cfi:/6/4[loc2]',
        ebookProgress: 0.4
      }

      await wrapper.vm.updateProgress(progressPayload)

      expect(mockDb.updateLocalEbookProgress).toHaveBeenCalledWith({
        localLibraryItemId: undefined, // No local library item ID in this test setup
        ...progressPayload
      })
    })

    it('should not update progress when keepProgress is disabled', async () => {
      await wrapper.setProps({ keepProgress: false })
      
      const progressPayload = {
        ebookLocation: 'cfi:/6/4[loc2]',
        ebookProgress: 0.4
      }

      await wrapper.vm.updateProgress(progressPayload)

      expect(mockDb.updateLocalEbookProgress).not.toHaveBeenCalled()
      expect(mockNativeHttp.patch).not.toHaveBeenCalled()
    })
  })

  describe('Offline Sync Issues', () => {
    it('should fail to sync to server when offline and not retry automatically', async () => {
      // Simulate offline state
      Object.defineProperty(window.navigator, 'onLine', {
        value: false
      })
      
      // Mock server sync failure
      mockNativeHttp.patch.mockRejectedValueOnce(new Error('Network error'))

      const progressPayload = {
        ebookLocation: 'cfi:/6/4[loc3]',
        ebookProgress: 0.6
      }

      await wrapper.vm.updateProgress(progressPayload)

      // Local progress should still be saved
      expect(mockDb.updateLocalEbookProgress).toHaveBeenCalled()
      
      // Server sync should be attempted and fail
      expect(mockNativeHttp.patch).toHaveBeenCalledWith(
        '/api/me/progress/server-item-id',
        progressPayload
      )

      // Simulate coming back online
      Object.defineProperty(window.navigator, 'onLine', {
        value: true
      })

      // ISSUE: No automatic retry mechanism exists
      // The progress remains unsynced until user manually triggers sync
      
      // Reset the mock to simulate successful network
      mockNativeHttp.patch.mockResolvedValueOnce({})
      
      // Even after network is restored, no automatic retry happens
      await new Promise(resolve => setTimeout(resolve, 100))
      
      // Verify no additional sync attempts were made
      expect(mockNativeHttp.patch).toHaveBeenCalledTimes(1)
    })

    it('should demonstrate the sync gap when server connection is different', async () => {
      // Simulate a local item that was downloaded from a different server
      await wrapper.setProps({
        libraryItem: {
          id: 'test-item-id',
          serverAddress: 'https://old-server.com', // Different server
          libraryItemId: 'server-item-id'
        }
      })

      const progressPayload = {
        ebookLocation: 'cfi:/6/4[loc4]',
        ebookProgress: 0.8
      }

      await wrapper.vm.updateProgress(progressPayload)

      // Local progress should be saved
      expect(mockDb.updateLocalEbookProgress).toHaveBeenCalled()
      
      // Server sync should NOT be attempted because serverLibraryItemId returns null
      expect(mockNativeHttp.patch).not.toHaveBeenCalled()
      
      // This demonstrates the issue: progress is saved locally but never synced
      // even when the user reconnects to the original server
    })
  })

  describe('Progress Conflict Resolution', () => {
    it('should prioritize local progress over server when reading offline', async () => {
      const localProgress = wrapper.vm.localItemProgress
      const serverProgress = wrapper.vm.serverItemProgress

      // Local progress is more recent (higher percentage)
      expect(localProgress?.ebookProgress).toBe(0.25)
      expect(serverProgress?.ebookProgress).toBe(0.1)

      // When isLocal is true, should use local progress
      expect(wrapper.vm.userItemProgress).toBe(localProgress)
    })

    it('should identify when local and server progress are out of sync', async () => {
      const localProgress = wrapper.vm.localItemProgress
      const serverProgress = wrapper.vm.serverItemProgress

      // Different progress values indicate sync issue
      expect(localProgress?.ebookProgress).not.toBe(serverProgress?.ebookProgress)
      expect(localProgress?.ebookLocation).not.toBe(serverProgress?.ebookLocation)

      // This scenario should trigger automatic sync resolution, but doesn't
    })
  })

  describe('Server Connection Logic', () => {
    it('should return null serverLibraryItemId when not connected to same server', () => {
      // Current server address doesn't match item's server address
      mockStore.getters['user/getServerAddress'] = 'https://different-server.com'
      
      expect(wrapper.vm.serverLibraryItemId).toBeNull()
    })

    it('should return serverLibraryItemId when connected to same server', () => {
      // Ensure server addresses match
      mockStore.getters['user/getServerAddress'] = 'https://server.com'
      
      expect(wrapper.vm.serverLibraryItemId).toBe('server-item-id')
    })

    it('should handle missing server connection data gracefully', async () => {
      await wrapper.setProps({
        libraryItem: {
          id: 'test-item-id',
          // Missing serverAddress and libraryItemId
        }
      })

      expect(wrapper.vm.serverLibraryItemId).toBeNull()
      
      const progressPayload = {
        ebookLocation: 'cfi:/6/4[loc1]',
        ebookProgress: 0.1
      }

      await wrapper.vm.updateProgress(progressPayload)

      // Should only update local, no server sync attempted
      expect(mockDb.updateLocalEbookProgress).toHaveBeenCalled()
      expect(mockNativeHttp.patch).not.toHaveBeenCalled()
    })
  })

  describe('localStorage Management', () => {
    beforeEach(() => {
      // Mock localStorage with some existing data
      const mockLocationData = {
        locations: ['loc1', 'loc2', 'loc3'],
        lastAccessed: Date.now() - 86400000, // 1 day ago
        percentage: 0.5
      }
      localStorage.setItem('ebookLocations-test-item-id', JSON.stringify(mockLocationData))
    })

    it('should manage localStorage for ebook locations', () => {
      const allData = wrapper.vm.getAllEbookLocationData()
      
      expect(allData.locations).toHaveLength(1)
      expect(allData.locations[0].key).toBe('ebookLocations-test-item-id')
    })

    it('should handle localStorage cleanup when limit exceeded', () => {
      // Fill localStorage near capacity (3MB limit)
      const largeData = 'x'.repeat(1000000) // 1MB string
      localStorage.setItem('ebookLocations-large1', largeData)
      localStorage.setItem('ebookLocations-large2', largeData)
      localStorage.setItem('ebookLocations-large3', largeData)

      const allData = wrapper.vm.getAllEbookLocationData()
      
      // Should detect size limits
      expect(allData.totalSize).toBeGreaterThan(3000000)
    })
  })

  describe('Proposed Solutions Validation', () => {
    it('should demonstrate need for background sync service', async () => {
      // Simulate offline reading session
      Object.defineProperty(window.navigator, 'onLine', { value: false })
      
      const progressUpdates = [
        { ebookLocation: 'cfi:/6/4[loc1]', ebookProgress: 0.1 },
        { ebookLocation: 'cfi:/6/4[loc2]', ebookProgress: 0.2 },
        { ebookLocation: 'cfi:/6/4[loc3]', ebookProgress: 0.3 }
      ]

      // Multiple progress updates while offline
      for (const update of progressUpdates) {
        await wrapper.vm.updateProgress(update)
      }

      expect(mockDb.updateLocalEbookProgress).toHaveBeenCalledTimes(3)
      expect(mockNativeHttp.patch).toHaveBeenCalledTimes(3) // All fail silently

      // Come back online
      Object.defineProperty(window.navigator, 'onLine', { value: true })

      // MISSING: No background service to retry failed syncs
      // This is what needs to be implemented
    })

    it('should demonstrate need for manual sync button', async () => {
      // Simulate unsync'd local progress
      mockDb.updateLocalEbookProgress.mockResolvedValueOnce({
        localMediaProgress: {
          id: 'local-progress-1',
          ebookLocation: 'cfi:/6/4[loc5]',
          ebookProgress: 0.9,
          lastUpdate: Date.now(),
          needsServerSync: true // Proposed field
        }
      })

      const progressPayload = {
        ebookLocation: 'cfi:/6/4[loc5]',
        ebookProgress: 0.9
      }

      await wrapper.vm.updateProgress(progressPayload)

      // MISSING: Manual sync method
      // expect(wrapper.vm.syncToServer).toBeDefined()
      // expect(wrapper.vm.hasPendingSync).toBe(true)
    })
  })
})