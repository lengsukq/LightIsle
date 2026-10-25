export type UploadResumeStorage = {
  collectStaleIDs(input: { legacyKey: string; prefix: string; key: string }): string[];
  read(key: string): { saved: string | null; resumable: boolean };
  save(key: string, uploadID: string): boolean;
  remove(key: string): void;
};
type ResumeStorageLike = Pick<Storage, "getItem" | "setItem" | "removeItem" | "key" | "length">;
export function createUploadResumeStorage(storageProvider: ResumeStorageLike | (() => ResumeStorageLike)): UploadResumeStorage;
