export function createViewerImageLoader(makeImage?: () => HTMLImageElement): {
  load(url: string): Promise<boolean>;
  cancel(): void;
};
