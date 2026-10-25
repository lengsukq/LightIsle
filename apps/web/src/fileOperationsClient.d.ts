export type FileOperation = "move" | "copy";
export type ConflictPolicy = "" | "skip" | "rename";
export function createFileOperationsClient(input: {
  apiPath: (path: string) => string;
  get: <T>(endpoint: string) => Promise<T>;
  write: <T>(endpoint: string, method: "POST", body: object) => Promise<T>;
  getEpoch: () => number;
}): {
  listFolders<T>(path: string, cursor: string): Promise<T>;
  commit<T>(operation: { action: FileOperation; from: string; to: string; conflict: ConflictPolicy }): Promise<T>;
};
