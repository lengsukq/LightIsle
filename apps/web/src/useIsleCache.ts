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

export const MAX_META_ENTRIES = 300
export const MAX_META_TOTAL_BYTES = 12 * 1024 * 1024
const MAX_SINGLE_META_BYTES = 2 * 1024 * 1024
export const LEDGER_FLUSH_DEBOUNCE_MS = 1500
const RESOURCE_TIMING_CLEAR_THRESHOLD = 200

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
    maxEntries: MAX_META_ENTRIES,
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

// L1 in-memory stores shared across components in the SPA session (bounded by LRU + byte cap)
const memoryMetaStore = new Map<string, { value: unknown; bytes: number; updatedAt: number }>()
let memoryMetaBytes = 0

const memoryAssetLedgers: Record<IsleWebCacheCategory, Map<string, number>> = {
  thumbnails: new Map<string, number>(),
  posters: new Map<string, number>(),
  map_tiles: new Map<string, number>(),
  metadata: new Map<string, number>(),
}

const dirtyLedgers = new Set<IsleWebCacheCategory>()
const dirtyMetaWrites = new Map<string, unknown>()
let ledgerFlushTimer: ReturnType<typeof setTimeout> | null = null
let pagehideInstalled = false

const cacheEpochVersion = ref(0)
let observerInstalled = false
let ledgersHydrated = false
let observedResourceCount = 0

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

function cloneCachedValue<T>(value: T): T {
  if (value === null || typeof value !== 'object') {
    return value
  }
  if (typeof structuredClone === 'function') {
    try {
      return structuredClone(value)
    } catch {
      // Fallback to JSON round-trip for non-structuredCloneable wrappers.
    }
  }
  return JSON.parse(JSON.stringify(value)) as T
}

function estimatePayloadBytes(value: unknown, cap = MAX_SINGLE_META_BYTES + 1): number {
  let total = 0
  const stack: unknown[] = [value]
  while (stack.length > 0) {
    if (total > cap) return total
    const current = stack.pop()
    if (current === null || current === undefined) {
      total += 4
    } else if (typeof current === 'string') {
      total += 2 + current.length * 2
    } else if (typeof current === 'number') {
      total += 8
    } else if (typeof current === 'boolean') {
      total += 4
    } else if (Array.isArray(current)) {
      total += 8
      for (let i = 0; i < current.length; i++) {
        stack.push(current[i])
      }
    } else if (typeof current === 'object') {
      total += 16
      for (const [k, v] of Object.entries(current as Record<string, unknown>)) {
        total += 4 + k.length * 2
        stack.push(v)
      }
    }
  }
  return Math.max(1, total)
}

function setBoundedMetaEntry(key: string, clonedValue: unknown, bytes: number) {
  const existing = memoryMetaStore.get(key)
  if (existing) {
    memoryMetaBytes = Math.max(0, memoryMetaBytes - existing.bytes)
    memoryMetaStore.delete(key)
  }
  while (
    memoryMetaStore.size >= MAX_META_ENTRIES ||
    (memoryMetaBytes + bytes > MAX_META_TOTAL_BYTES && memoryMetaStore.size > 0)
  ) {
    const oldestKey = memoryMetaStore.keys().next().value
    if (oldestKey === undefined) break
    const evicted = memoryMetaStore.get(oldestKey)
    if (evicted) {
      memoryMetaBytes = Math.max(0, memoryMetaBytes - evicted.bytes)
    }
    memoryMetaStore.delete(oldestKey)
    memoryAssetLedgers.metadata.delete(oldestKey)
    dirtyMetaWrites.delete(oldestKey)
  }
  memoryMetaStore.set(key, { value: clonedValue, bytes, updatedAt: Date.now() })
  memoryMetaBytes += bytes
  memoryAssetLedgers.metadata.set(key, bytes)
}

function ensurePagehideFlushInstalled() {
  if (pagehideInstalled || typeof window === 'undefined' || typeof window.addEventListener !== 'function') {
    return
  }
  pagehideInstalled = true
  window.addEventListener('pagehide', flushLedgerNow)
}

export function flushLedgerNow(): void {
  if (ledgerFlushTimer !== null) {
    clearTimeout(ledgerFlushTimer)
    ledgerFlushTimer = null
  }
  if (dirtyLedgers.size === 0 && dirtyMetaWrites.size === 0) return
  const storage = safeStorage()
  if (!storage) {
    dirtyLedgers.clear()
    dirtyMetaWrites.clear()
    return
  }

  for (const category of dirtyLedgers) {
    if (category === 'metadata') continue
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
  dirtyLedgers.clear()

  for (const [key, value] of dirtyMetaWrites.entries()) {
    try {
      storage.setItem(META_STORAGE_PREFIX + key, JSON.stringify(value))
    } catch {
      // Ignore quota error on metadata persistence.
    }
  }
  dirtyMetaWrites.clear()
}

function scheduleLedgerFlush(category?: IsleWebCacheCategory) {
  if (category && category !== 'metadata') {
    dirtyLedgers.add(category)
  }
  if (!safeStorage()) {
    dirtyLedgers.clear()
    dirtyMetaWrites.clear()
    return
  }
  ensurePagehideFlushInstalled()
  if (ledgerFlushTimer !== null) {
    clearTimeout(ledgerFlushTimer)
  }
  ledgerFlushTimer = setTimeout(flushLedgerNow, LEDGER_FLUSH_DEBOUNCE_MS)
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
          const parsed = JSON.parse(raw) as unknown
          const bytes = new Blob([raw]).size
          if (bytes <= MAX_SINGLE_META_BYTES) {
            setBoundedMetaEntry(subKey, parsed, bytes)
          }
        }
      }
    }
  } catch {
    // Ignore iteration errors.
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
  scheduleLedgerFlush(category)
}

export function getMetadata<T = unknown>(key: string): T | null {
  if (!key) return null
  hydrateLedgersIfNeeded()
  const hit = memoryMetaStore.get(key)
  if (hit) {
    // Refresh LRU order on read
    memoryMetaStore.delete(key)
    hit.updatedAt = Date.now()
    memoryMetaStore.set(key, hit)
    return cloneCachedValue(hit.value) as T
  }
  const storage = safeStorage()
  if (storage) {
    try {
      const raw = storage.getItem(META_STORAGE_PREFIX + key)
      if (raw) {
        const bytes = new Blob([raw]).size
        if (bytes <= MAX_SINGLE_META_BYTES) {
          const parsed = JSON.parse(raw) as T
          setBoundedMetaEntry(key, cloneCachedValue(parsed), bytes)
          return parsed
        }
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
    const bytes = estimatePayloadBytes(payload)
    if (bytes > MAX_SINGLE_META_BYTES) return
    const cloned = cloneCachedValue(payload)
    setBoundedMetaEntry(key, cloned, bytes)
    if (persist) {
      dirtyMetaWrites.set(key, cloned)
      scheduleLedgerFlush()
    }
  } catch {
    // Ignore clone/serialization error
  }
}

export function clearRuntimeMemoryCache(): void {
  memoryMetaStore.clear()
  memoryMetaBytes = 0
  memoryAssetLedgers.metadata.clear()
  dirtyMetaWrites.clear()
  if (dirtyLedgers.size === 0 && ledgerFlushTimer !== null) {
    clearTimeout(ledgerFlushTimer)
    ledgerFlushTimer = null
  }
  const storage = safeStorage()
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
      // Ignore storage access errors
    }
  }
  cacheEpochVersion.value += 1
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
    dirtyLedgers.delete(cat)
    if (cat === 'metadata') {
      memoryMetaStore.clear()
      memoryMetaBytes = 0
      dirtyMetaWrites.clear()
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
  if (dirtyLedgers.size === 0 && dirtyMetaWrites.size === 0 && ledgerFlushTimer !== null) {
    clearTimeout(ledgerFlushTimer)
    ledgerFlushTimer = null
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

    const observer = new PerformanceObserver((list) => {
      const entries = list.getEntries()
      for (const entry of entries) {
        ingestEntry(entry)
      }
      observedResourceCount += entries.length
      if (
        observedResourceCount >= RESOURCE_TIMING_CLEAR_THRESHOLD &&
        typeof performance !== 'undefined'
      ) {
        observedResourceCount = 0
        performance.clearResourceTimings?.()
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
    clearRuntimeMemoryCache,
    flushLedgerNow,
    inspectLocalCache,
    clearLocalCache,
    formatCacheBytes,
  }
}
