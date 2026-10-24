export type MediaQueryContext = Record<string, string | number | boolean | null | undefined>;

export function mediaQueryKey(context: MediaQueryContext): string;
export function transitionMediaQuery(previousKey: string, nextKey: string): {
  queryKey: string;
  clearContent: boolean;
  resetCursor: boolean;
};
