import { ref } from 'vue'

export type IsleWebCacheCategory = 'thumbnails' | 'posters' | 'map_tiles' | 'metadata'

export interface IsleWebCacheCategoryMeta {
  id: IsleWebCacheCategory
  label: string
  subtitle: string
  color: string
  defaultEstimateBytes: number
  maxEntries: number
}

export const ISLE_WEB_CACHE_CATEGORIES: IsleWebCacheCategoryMeta[] = [
  {
    id: 'thumbnails',
    label: '相册与文件缩略图',
    subtitle: '照片网格、相册封面、大图预览及文件列表缩略图',
    color: '#007aff',
    defaultEstimateBytes: 28 * 1024,
    maxEntries: 2500,
  },
  {
    id: 'posters',
    label: '影视海报与剧照',
    subtitle: '影视巨幕、海报墙、剧集封面、历史记录与详情海报',
    color: '#af52de',
    defaultEstimateBytes: 64 * 1024,
    maxEntries: 1200,
  },
  {
    id: 'map_tiles',
    label: '足迹地图与瓦片',
    subtitle: '天地图、OpenStreetMap 与自定义底图瓦片及聚合预览',
    color: '#10b981',
    defaultEstimateBytes: 22 * 1024,
    maxEntries: 3000,
  },
  {
    id: 'metadata',
    label: '页面列表与元数据快照',
    subtitle: '相册筛选视图、影视分类列表、足迹坐标点与目录速览快照',
    color: '#ff9500',
    defaultEstimateBytes: 4 * 1024,
    maxEntries: 300,
  },
]

export interface IsleWebCategoryStats {
  id: IsleWebCacheCategory
  label: string
  subtitle: string
  color: string
  usedBytes: number
  entryCount: number
}

export interface IsleWebCacheReport {
  categories: Record<IsleWebCacheCategory, IsleWebCategoryStats>
  totalBytes: number
  totalEntries: number
}

export interface IsleServerCacheBucket {
  usedBytes: number
  maxBytes: number
  entryCount: number
}

export interface IsleServerCacheStatus {
  thumbnails: IsleServerCacheBucket
  mapTiles: IsleServerCacheBucket
}

const LEDGER_STORAGE_PREFIX = 'lightisle_cache_ledger_v2:'
const META_STORAGE_PREFIX = 'lightisle_cache_meta_v2:'
const CACHE_STORAGE_PREFIX = 'lightisle-cache-v2-'

// L1 in-memory stores shared across all components in the SPA session
const memoryMetaStore = new Map<string, { raw: string; bytes: number; updatedAt: number }>()
const memoryAssetLedgers: Record<IsleWebCacheCategory, Map<string, number>> = {
  thumbnails: new Map<string, number>(),
  posters: new Map<string, number>(),
  map_tiles: new Map<string, number>(),
  metadata: new Map<string, number>(),
}

const cacheEpochVersion = ref(0)
let observerInstalled = false
let ledgersHydrated = false

function safeStorage(): Storage | null {
  try {
    if (typeof window !== 'undefined' && window.localStorage) {
      return window.localStorage
    }
  } catch {
    // Ignore storage access errors in private/sandboxed contexts.
  }
  return null
}

function hydrateLedgersIfNeeded() {
  if (ledgersHydrated) return
  ledgersHydrated = true
  const storage = safeStorage()
  if (!storage) return
  for (const meta of ISLE_WEB_CACHE_CATEGORIES) {
    if (meta.id === 'metadata') continue
    try {
      const raw = storage.getItem(LEDGER_STORAGE_PREFIX + meta.id)
      if (!raw) continue
      const parsed = JSON.parse(raw)
      if (parsed && typeof parsed === 'object') {
        const map = memoryAssetLedgers[meta.id]
        for (const [k, v] of Object.entries(parsed)) {
          if (typeof v === 'number' && v > 0) {
            map.set(k, v)
          }
        }
      }
    } catch {
      // Ignore corrupt ledger JSON.
    }
  }
  try {
    for (let i = 0; i < storage.length; i++) {
      const key = storage.key(i)
      if (key && key.startsWith(META_STORAGE_PREFIX)) {
        const subKey = key.slice(META_STORAGE_PREFIX.length)
        const raw = storage.getItem(key)
        if (raw && !memoryMetaStore.has(subKey)) {
          const bytes = new Blob([raw]).size
          memoryMetaStore.set(subKey, { raw, bytes, updatedAt: Date.now() })
          memoryAssetLedgers.metadata.set(subKey, bytes)
        }
      }
    }
  } catch {
    // Ignore iteration errors.
  }
}

function persistLedger(category: IsleWebCacheCategory) {
  if (category === 'metadata') return
  const storage = safeStorage()
  if (!storage) return
  try {
    const map = memoryAssetLedgers[category]
    const obj: Record<string, number> = {}
    for (const [k, v] of map.entries()) {
      obj[k] = v
    }
    storage.setItem(LEDGER_STORAGE_PREFIX + category, JSON.stringify(obj))
  } catch {
    // Ignore quota errors on ledger persistence.
  }
}

export function classifyResourceUrl(url: string): IsleWebCacheCategory | null {
  const lower = String(url || '').toLowerCase()
  if (!lower) return null
  if (
    lower.includes('/api/v2/map/tiles/') ||
    lower.includes('tile.openstreetmap.org') ||
    lower.includes('tianditu.gov.cn') ||
    lower.includes('basemaps.cartocdn.com')
  ) {
    return 'map_tiles'
  }
  if (
    lower.includes('/api/v2/cinema/') &&
    (lower.includes('/poster') || lower.includes('/backdrop') || lower.includes('/still'))
  ) {
    return 'posters'
  }
  if (
    lower.includes('/thumbnail') ||
    (lower.includes('/api/v2/photos/') && lower.includes('/file'))
  ) {
    return 'thumbnails'
  }
  return null
}

export function recordAssetHit(
  category: IsleWebCacheCategory,
  key: string,
  estimatedBytes?: number,
) {
  if (!key) return
  hydrateLedgersIfNeeded()
  const meta = ISLE_WEB_CACHE_CATEGORIES.find((c) => c.id === category)
  const fallbackBytes = meta ? meta.defaultEstimateBytes : 24 * 1024
  const bytes =
    typeof estimatedBytes === 'number' && estimatedBytes > 0
      ? Math.round(estimatedBytes)
      : fallbackBytes
  const map = memoryAssetLedgers[category]
  if (map.has(key)) {
    map.delete(key)
  }
  const maxEntries = meta ? meta.maxEntries : 1500
  while (map.size >= maxEntries) {
    const oldest = map.keys().next().value
    if (oldest === undefined) break
    map.delete(oldest)
  }
  map.set(key, bytes)
  persistLedger(category)
}

export function getMetadata<T = unknown>(key: string): T | null {
  if (!key) return null
  hydrateLedgersIfNeeded()
  const hit = memoryMetaStore.get(key)
  if (hit) {
    try {
      return JSON.parse(hit.raw) as T
    } catch {
      memoryMetaStore.delete(key)
      memoryAssetLedgers.metadata.delete(key)
    }
  }
  const storage = safeStorage()
  if (storage) {
    try {
      const raw = storage.getItem(META_STORAGE_PREFIX + key)
      if (raw) {
        const bytes = new Blob([raw]).size
        memoryMetaStore.set(key, { raw, bytes, updatedAt: Date.now() })
        memoryAssetLedgers.metadata.set(key, bytes)
        return JSON.parse(raw) as T
      }
    } catch {
      // Ignore parse error
    }
  }
  return null
}

export function putMetadata<T = unknown>(
  key: string,
  payload: T,
  persist = true,
): void {
  if (!key) return
  hydrateLedgersIfNeeded()
  try {
    const raw = JSON.stringify(payload)
    const bytes = new Blob([raw]).size
    if (bytes > 2 * 1024 * 1024) return
    memoryMetaStore.set(key, { raw, bytes, updatedAt: Date.now() })
    memoryAssetLedgers.metadata.set(key, bytes)
    if (persist) {
      const storage = safeStorage()
      if (storage) {
        try {
          storage.setItem(META_STORAGE_PREFIX + key, raw)
        } catch {
          // Ignore quota error
        }
      }
    }
  } catch {
    // Ignore serialization error
  }
}

export function invalidateMetadata(prefixOrKey: string): void {
  hydrateLedgersIfNeeded()
  for (const k of Array.from(memoryMetaStore.keys())) {
    if (k === prefixOrKey || k.startsWith(prefixOrKey)) {
      memoryMetaStore.delete(k)
      memoryAssetLedgers.metadata.delete(k)
    }
  }
  const storage = safeStorage()
  if (storage) {
    try {
      const toRemove: string[] = []
      for (let i = 0; i < storage.length; i++) {
        const fullKey = storage.key(i)
        if (!fullKey || !fullKey.startsWith(META_STORAGE_PREFIX)) continue
        const subKey = fullKey.slice(META_STORAGE_PREFIX.length)
        if (subKey === prefixOrKey || subKey.startsWith(prefixOrKey)) {
          toRemove.push(fullKey)
        }
      }
      for (const fullKey of toRemove) {
        storage.removeItem(fullKey)
      }
    } catch {
      // Ignore storage error
    }
  }
}

export async function inspectLocalCache(): Promise<IsleWebCacheReport> {
  hydrateLedgersIfNeeded()
  const categories = {} as Record<IsleWebCacheCategory, IsleWebCategoryStats>
  let totalBytes = 0
  let totalEntries = 0

  for (const meta of ISLE_WEB_CACHE_CATEGORIES) {
    const ledger = memoryAssetLedgers[meta.id]
    let usedBytes = 0
    for (const b of ledger.values()) {
      usedBytes += b
    }
    let entryCount = ledger.size

    if (typeof window !== 'undefined' && 'caches' in window && window.caches) {
      try {
        const cacheName = CACHE_STORAGE_PREFIX + meta.id
        const hasCache = await window.caches.has(cacheName)
        if (hasCache) {
          const cache = await window.caches.open(cacheName)
          const keys = await cache.keys()
          if (keys.length > entryCount) {
            entryCount = keys.length
            usedBytes = Math.max(usedBytes, keys.length * meta.defaultEstimateBytes)
          }
        }
      } catch {
        // Ignore CacheStorage inspection errors
      }
    }

    categories[meta.id] = {
      id: meta.id,
      label: meta.label,
      subtitle: meta.subtitle,
      color: meta.color,
      usedBytes,
      entryCount,
    }
    totalBytes += usedBytes
    totalEntries += entryCount
  }

  return {
    categories,
    totalBytes,
    totalEntries,
  }
}

export async function clearLocalCache(
  categories: IsleWebCacheCategory[],
): Promise<void> {
  hydrateLedgersIfNeeded()
  const storage = safeStorage()
  for (const cat of categories) {
    memoryAssetLedgers[cat]?.clear()
    if (cat === 'metadata') {
      memoryMetaStore.clear()
      if (storage) {
        try {
          const toRemove: string[] = []
          for (let i = 0; i < storage.length; i++) {
            const k = storage.key(i)
            if (k && k.startsWith(META_STORAGE_PREFIX)) {
              toRemove.push(k)
            }
          }
          for (const k of toRemove) {
            storage.removeItem(k)
          }
        } catch {
          // Ignore
        }
      }
    } else if (storage) {
      try {
        storage.removeItem(LEDGER_STORAGE_PREFIX + cat)
      } catch {
        // Ignore
      }
    }

    if (typeof window !== 'undefined' && 'caches' in window && window.caches) {
      try {
        await window.caches.delete(CACHE_STORAGE_PREFIX + cat)
      } catch {
        // Ignore
      }
    }
  }
  cacheEpochVersion.value += 1
}

export function installImageResourceObserver(): void {
  if (observerInstalled || typeof window === 'undefined') return
  observerInstalled = true
  hydrateLedgersIfNeeded()
  try {
    if (typeof PerformanceObserver === 'undefined') return
    const ingestEntry = (entry: PerformanceEntry) => {
      const cat = classifyResourceUrl(entry.name)
      if (!cat) return
      const res = entry as PerformanceResourceTiming
      const bytes =
        (typeof res.decodedBodySize === 'number' && res.decodedBodySize > 0
          ? res.decodedBodySize
          : 0) ||
        (typeof res.encodedBodySize === 'number' && res.encodedBodySize > 0
          ? res.encodedBodySize
          : 0) ||
        (typeof res.transferSize === 'number' && res.transferSize > 0
          ? res.transferSize
          : 0)
      recordAssetHit(cat, entry.name, bytes > 0 ? bytes : undefined)
    }

    if (typeof performance !== 'undefined' && performance.getEntriesByType) {
      for (const entry of performance.getEntriesByType('resource')) {
        ingestEntry(entry)
      }
    }

    const observer = new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) {
        ingestEntry(entry)
      }
    })
    observer.observe({ type: 'resource', buffered: true })
  } catch {
    // Ignore in environments without PerformanceObserver resource support.
  }
}

export function formatCacheBytes(bytes: number): string {
  const n = Number(bytes) || 0
  if (n <= 0) return '0 B'
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  if (n < 1024 * 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MB`
  return `${(n / (1024 * 1024 * 1024)).toFixed(2)} GB`
}

export function useIsleCache() {
  installImageResourceObserver()
  return {
    categoriesMeta: ISLE_WEB_CACHE_CATEGORIES,
    cacheEpochVersion,
    recordAssetHit,
    getMetadata,
    putMetadata,
    invalidateMetadata,
    inspectLocalCache,
    clearLocalCache,
    formatCacheBytes,
  }
}
