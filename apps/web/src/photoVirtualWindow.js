const DEFAULT_TILE_MIN_WIDTH = 160;
const DEFAULT_GAP = 12;
const DEFAULT_OVERSCAN_ROWS = 2;

export function getPhotoVirtualWindow({
  itemCount,
  containerWidth,
  viewportTop = 0,
  viewportHeight = 0,
  minTileWidth = DEFAULT_TILE_MIN_WIDTH,
  gap = DEFAULT_GAP,
  overscanRows = DEFAULT_OVERSCAN_ROWS,
}) {
  const count = Math.max(0, Math.floor(Number(itemCount) || 0));
  const width = Math.max(0, Number(containerWidth) || 0);
  const safeGap = Math.max(0, Number(gap) || 0);
  const minWidth = Math.max(1, Number(minTileWidth) || DEFAULT_TILE_MIN_WIDTH);
  const columns = Math.max(1, Math.floor((width + safeGap) / (minWidth + safeGap)));
  const tileSize = Math.max(0, (width - safeGap * (columns - 1)) / columns);
  const rowPitch = tileSize + safeGap;
  const rowCount = count === 0 ? 0 : Math.ceil(count / columns);
  const totalHeight = rowCount === 0 ? 0 : rowCount * tileSize + (rowCount - 1) * safeGap;
  const top = Math.max(0, Number(viewportTop) || 0);
  const height = Math.max(0, Number(viewportHeight) || 0);
  const overscan = Math.max(0, Math.floor(Number(overscanRows) || 0));
  const firstVisibleRow = rowPitch > 0 ? Math.floor(top / rowPitch) : 0;
  const lastVisibleRow = rowPitch > 0 ? Math.ceil((top + height) / rowPitch) : 0;
  const startRow = Math.min(rowCount, Math.max(0, firstVisibleRow - overscan));
  const endRow = Math.min(rowCount, Math.max(startRow, lastVisibleRow + overscan));
  const startIndex = Math.min(count, startRow * columns);
  const endIndex = Math.min(count, endRow * columns);

  return {
    columns,
    tileSize,
    gap: safeGap,
    rowPitch,
    rowCount,
    totalHeight,
    startRow,
    endRow,
    startIndex,
    endIndex,
    topSpacer: Math.min(totalHeight, startRow * rowPitch),
    bottomSpacer: Math.max(0, totalHeight - Math.min(totalHeight, endRow * rowPitch)),
  };
}
