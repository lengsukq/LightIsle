export type MediaQueryContext = Record<string, string | number | boolean | null | undefined>;

export function mediaQueryKey(context: MediaQueryContext): string {
  return JSON.stringify(context);
}

export function transitionMediaQuery(
  previousKey: string,
  nextKey: string,
): {
  queryKey: string;
  clearContent: boolean;
  resetCursor: boolean;
} {
  const clearContent = previousKey !== nextKey;
  return {
    queryKey: nextKey,
    clearContent,
    resetCursor: clearContent,
  };
}
