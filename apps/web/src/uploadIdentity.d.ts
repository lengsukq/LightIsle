export type UploadFile = {
  size: number;
  lastModified: number;
  slice(start?: number, end?: number): Blob;
};

export type FingerprintOptions = {
  signal?: AbortSignal;
  onProgress?: (processedBytes: number, totalBytes: number) => void;
  cryptoProvider?: Crypto;
};

export function supportsContentFingerprint(cryptoProvider?: Crypto): boolean;
export function isWithinUploadSizeLimit(size: number): boolean;
export function fingerprintFile(file: UploadFile, options?: FingerprintOptions): Promise<string>;
export function uploadSessionIdentity(
  username: string,
  targetPath: string,
  file: UploadFile,
  contentFingerprint: string,
  cryptoProvider?: Crypto,
  rootID?: string,
  rootGeneration?: number,
): Promise<{ prefix: string; key: string }>;
export const uploadFingerprintChunkSize: number;
export const maxUploadSizeBytes: number;
