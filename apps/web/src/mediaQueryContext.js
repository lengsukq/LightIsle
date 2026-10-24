export function mediaQueryKey(context) {
  return JSON.stringify(context);
}

export function transitionMediaQuery(previousKey, nextKey) {
  const clearContent = previousKey !== nextKey;
  return {
    queryKey: nextKey,
    clearContent,
    resetCursor: clearContent,
  };
}
