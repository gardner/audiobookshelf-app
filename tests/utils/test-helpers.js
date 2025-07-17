/**
 * Test utilities for Audiobookshelf app testing
 * Focused on ebook progress sync testing scenarios
 */

// Mock Vue.js test utilities
export const createMockVueComponent = (component, options = {}) => {
  const defaultOptions = {
    propsData: {},
    mocks: {
      $store: createMockStore(),
      $db: createMockDatabase(),
      $nativeHttp: createMockNativeHttp(),
      $platform: 'ios'
    },
    ...options
  }
  
  return {
    vm: {
      ...component.methods,
      ...component.computed,
      $props: defaultOptions.propsData,
      ...defaultOptions.mocks
    },
    setProps: (newProps) => {
      Object.assign(defaultOptions.propsData, newProps)
    },
    destroy: () => {
      // Cleanup
    }
  }
}

// Mock Vuex store for testing
export const createMockStore = (overrides = {}) => {
  const defaultGetters = {
    'user/getToken': 'mock-auth-token',
    'user/getServerAddress': 'https://test-server.com',
    'getIsPlayerOpen': false,
    'globals/getLocalMediaProgressById': jest.fn(() => null),
    'user/getUserMediaProgress': jest.fn(() => null)
  }

  return {
    getters: { ...defaultGetters, ...overrides.getters },
    commit: jest.fn(),
    dispatch: jest.fn()
  }
}

// Mock database plugin
export const createMockDatabase = (overrides = {}) => {
  const defaultMethods = {
    updateLocalEbookProgress: jest.fn(() => Promise.resolve({
      localMediaProgress: {
        id: 'mock-progress-id',
        ebookLocation: 'mock-cfi',
        ebookProgress: 0.5,
        lastUpdate: Date.now()
      }
    })),
    getLocalLibraryItemByLId: jest.fn(() => Promise.resolve(null)),
    syncServerMediaProgressWithLocalMediaProgress: jest.fn(() => Promise.resolve(null))
  }

  return { ...defaultMethods, ...overrides }
}

// Mock native HTTP client
export const createMockNativeHttp = (overrides = {}) => {
  const defaultMethods = {
    patch: jest.fn(() => Promise.resolve({ status: 200 })),
    get: jest.fn(() => Promise.resolve({ status: 200, data: {} })),
    post: jest.fn(() => Promise.resolve({ status: 200 }))
  }

  return { ...defaultMethods, ...overrides }
}

// Test data factories
export const createTestLibraryItem = (overrides = {}) => {
  return {
    id: 'test-library-item-id',
    serverAddress: 'https://test-server.com',
    libraryItemId: 'server-library-item-id',
    media: {
      metadata: {
        title: 'Test Book',
        author: 'Test Author'
      },
      ebookFile: {
        ino: '123456',
        metadata: {
          path: '/test/book.epub'
        }
      }
    },
    ...overrides
  }
}

export const createTestLocalMediaProgress = (overrides = {}) => {
  return {
    id: 'test-local-progress-id',
    localLibraryItemId: 'test-local-item-id',
    ebookLocation: 'epubcfi(/6/4[chapter1]!/4/1/1:0)',
    ebookProgress: 0.25,
    lastUpdate: Date.now(),
    isFinished: false,
    ...overrides
  }
}

export const createTestServerMediaProgress = (overrides = {}) => {
  return {
    id: 'test-server-progress-id',
    libraryItemId: 'server-library-item-id',
    ebookLocation: 'epubcfi(/6/4[chapter1]!/4/1/1:0)',
    ebookProgress: 0.15,
    lastUpdate: Date.now() - 300000, // 5 minutes ago
    isFinished: false,
    ...overrides
  }
}

// Network simulation utilities
export const simulateNetworkConditions = {
  online: () => {
    Object.defineProperty(window.navigator, 'onLine', {
      writable: true,
      value: true
    })
  },
  
  offline: () => {
    Object.defineProperty(window.navigator, 'onLine', {
      writable: true,
      value: false
    })
  },
  
  slowConnection: (mockHttp) => {
    // Simulate slow network responses
    const delay = (ms) => new Promise(resolve => setTimeout(resolve, ms))
    
    mockHttp.patch = jest.fn(() => 
      delay(2000).then(() => Promise.resolve({ status: 200 }))
    )
  },
  
  unreliableConnection: (mockHttp) => {
    let callCount = 0
    mockHttp.patch = jest.fn(() => {
      callCount++
      if (callCount % 3 === 0) {
        return Promise.resolve({ status: 200 })
      } else {
        return Promise.reject(new Error('Network error'))
      }
    })
  }
}

// Test scenario builders
export const createOfflineReadingScenario = () => {
  const libraryItem = createTestLibraryItem()
  const initialProgress = createTestLocalMediaProgress({ ebookProgress: 0.1 })
  
  const readingUpdates = [
    { ebookLocation: 'epubcfi(/6/4[chapter1]!/4/2/1:0)', ebookProgress: 0.2 },
    { ebookLocation: 'epubcfi(/6/4[chapter2]!/4/1/1:0)', ebookProgress: 0.3 },
    { ebookLocation: 'epubcfi(/6/4[chapter2]!/4/2/1:0)', ebookProgress: 0.4 }
  ]
  
  return {
    libraryItem,
    initialProgress,
    readingUpdates,
    expectedFinalProgress: 0.4,
    expectedFinalLocation: 'epubcfi(/6/4[chapter2]!/4/2/1:0)'
  }
}

export const createSyncConflictScenario = () => {
  const libraryItem = createTestLibraryItem()
  
  // Local progress is further ahead
  const localProgress = createTestLocalMediaProgress({
    ebookProgress: 0.6,
    ebookLocation: 'epubcfi(/6/4[chapter3]!/4/1/1:0)',
    lastUpdate: Date.now()
  })
  
  // Server progress is behind
  const serverProgress = createTestServerMediaProgress({
    ebookProgress: 0.3,
    ebookLocation: 'epubcfi(/6/4[chapter2]!/4/1/1:0)',
    lastUpdate: Date.now() - 600000 // 10 minutes ago
  })
  
  return {
    libraryItem,
    localProgress,
    serverProgress,
    expectedResolution: 'prefer-furthest' // or 'prefer-latest'
  }
}

// Assertion helpers
export const assertProgressSync = {
  localSaved: (mockDb, expectedPayload) => {
    expect(mockDb.updateLocalEbookProgress).toHaveBeenCalledWith(
      expect.objectContaining(expectedPayload)
    )
  },
  
  serverSynced: (mockHttp, serverItemId, expectedPayload) => {
    expect(mockHttp.patch).toHaveBeenCalledWith(
      `/api/me/progress/${serverItemId}`,
      expectedPayload
    )
  },
  
  noServerSync: (mockHttp) => {
    expect(mockHttp.patch).not.toHaveBeenCalled()
  },
  
  syncFailed: (mockHttp) => {
    expect(mockHttp.patch).toHaveBeenCalled()
    // Should have thrown/rejected
  }
}

// localStorage management for tests
export const mockLocalStorage = {
  setup: () => {
    const store = new Map()
    
    Object.defineProperty(window, 'localStorage', {
      value: {
        getItem: jest.fn((key) => store.get(key) || null),
        setItem: jest.fn((key, value) => store.set(key, value)),
        removeItem: jest.fn((key) => store.delete(key)),
        clear: jest.fn(() => store.clear()),
        key: jest.fn((index) => Array.from(store.keys())[index] || null),
        get length() { return store.size }
      },
      writable: true
    })
    
    return store
  },
  
  addEbookLocations: (libraryItemId, locations) => {
    const locationData = {
      locations,
      lastAccessed: Date.now(),
      percentage: 0.5
    }
    localStorage.setItem(`ebookLocations-${libraryItemId}`, JSON.stringify(locationData))
  },
  
  simulateStorageFull: () => {
    // Fill localStorage near 5MB limit
    const largeData = 'x'.repeat(1000000) // 1MB
    for (let i = 0; i < 4; i++) {
      localStorage.setItem(`large-data-${i}`, largeData)
    }
  }
}

// Test timing utilities
export const waitFor = (condition, timeout = 1000) => {
  return new Promise((resolve, reject) => {
    const startTime = Date.now()
    
    const check = () => {
      if (condition()) {
        resolve()
      } else if (Date.now() - startTime > timeout) {
        reject(new Error('Condition not met within timeout'))
      } else {
        setTimeout(check, 10)
      }
    }
    
    check()
  })
}

// Clean up utilities
export const cleanup = {
  resetNavigatorOnline: () => {
    Object.defineProperty(window.navigator, 'onLine', {
      writable: true,
      value: true
    })
  },
  
  clearAllMocks: (...mocks) => {
    mocks.forEach(mock => {
      if (mock && typeof mock.mockClear === 'function') {
        mock.mockClear()
      } else if (mock && typeof mock === 'object') {
        Object.values(mock).forEach(method => {
          if (method && typeof method.mockClear === 'function') {
            method.mockClear()
          }
        })
      }
    })
  },
  
  resetLocalStorage: () => {
    if (window.localStorage) {
      localStorage.clear()
    }
  }
}