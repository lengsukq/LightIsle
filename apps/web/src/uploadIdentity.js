const CONTENT_CHUNK_SIZE = 4 * 1024 * 1024;
export const maxUploadSizeBytes = 32 * 1024 * 1024 * 1024;
const DIGEST_BYTES = 32;
const CHUNK_RECORD_BYTES = 4 + 8 + DIGEST_BYTES;
const encoder = new TextEncoder();

function toHex(bytes) {
  return Array.from(new Uint8Array(bytes), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function throwIfAborted(signal) {
  if (!signal?.aborted) return;
  const error = new Error("upload_cancelled");
  error.name = "AbortError";
  throw error;
}

export function supportsContentFingerprint(cryptoProvider = globalThis.crypto) {
  return typeof cryptoProvider?.subtle?.digest === "function";
}

export function isWithinUploadSizeLimit(size) {
  return Number.isSafeInteger(size) && size >= 0 && size <= maxUploadSizeBytes;
}

/**
 * Hashes every file byte in bounded 4 MiB slices. Each chunk is SHA-256 hashed,
 * then the ordered chunk length and digest records are SHA-256 hashed together.
 */
export async function fingerprintFile(file, options = {}) {
  const { signal, onProgress, cryptoProvider = globalThis.crypto } = options;
  if (!supportsContentFingerprint(cryptoProvider)) {
    throw new Error("content_fingerprint_unavailable");
  }

  const count = Math.ceil(file.size / CONTENT_CHUNK_SIZE);
  const prefix = encoder.encode("LightIsle upload content fingerprint v1\0");
  const headerBytes = prefix.length + 8 + 4;
  const records = new Uint8Array(headerBytes + count * CHUNK_RECORD_BYTES);
  records.set(prefix);
  const header = new DataView(records.buffer);
  header.setBigUint64(prefix.length, BigInt(file.size));
  header.setUint32(prefix.length + 8, CONTENT_CHUNK_SIZE);

  let offset = headerBytes;
  for (let index = 0; index < count; index += 1) {
    throwIfAborted(signal);
    const start = index * CONTENT_CHUNK_SIZE;
    const end = Math.min(start + CONTENT_CHUNK_SIZE, file.size);
    const chunk = await file.slice(start, end).arrayBuffer();
    throwIfAborted(signal);
    const digest = await cryptoProvider.subtle.digest("SHA-256", chunk);
    throwIfAborted(signal);

    const length = end - start;
    const view = new DataView(records.buffer);
    view.setUint32(offset, index);
    view.setBigUint64(offset + 4, BigInt(length));
    records.set(new Uint8Array(digest), offset + 12);
    offset += CHUNK_RECORD_BYTES;
    onProgress?.(end, file.size);
    throwIfAborted(signal);
  }

  throwIfAborted(signal);
  return toHex(await cryptoProvider.subtle.digest("SHA-256", records));
}

/**
 * Returns a metadata prefix and a content-specific storage key. Including the
 * account and target prevents another user's upload session from being reused.
 */
export async function uploadSessionIdentity(username, targetPath, file, contentFingerprint, cryptoProvider = globalThis.crypto, rootID = "", rootGeneration = 0) {
  if (!supportsContentFingerprint(cryptoProvider)) {
    throw new Error("content_fingerprint_unavailable");
  }

  const metadata = JSON.stringify({
    version: 3,
    username,
    targetPath,
    rootID,
    rootGeneration,
    size: file.size,
    lastModified: file.lastModified,
  });
  const metadataDigest = await cryptoProvider.subtle.digest("SHA-256", encoder.encode(metadata));
  const prefix = `lightisle_upload_v3_${toHex(metadataDigest)}_`;
  return { prefix, key: `${prefix}${contentFingerprint}` };
}

export const uploadFingerprintChunkSize = CONTENT_CHUNK_SIZE;
