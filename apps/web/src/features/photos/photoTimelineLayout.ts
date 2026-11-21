// A virtualizable calendar timeline. Headers contribute to geometry before
// visible photo positions are calculated, so 10k+ items never require 10k
// mounted DOM nodes. All date calculations use the viewer's local timezone.
const minTileWidth = 160;
const gap = 12;
const groupHeaderHeight = 60;
const monthFormatter = new Intl.DateTimeFormat("zh-CN", { year: "numeric", month: "long" });

export interface PhotoTimelinePosition {
  left: number;
  top: number;
}

export interface PhotoTimelineGroup {
  title: string;
  top: number;
  startIndex: number;
  count: number;
}

export interface PhotoTimelineLayout {
  columns: number;
  tileSize: number;
  rowPitch: number;
  gap: number;
  totalHeight: number;
  positions: PhotoTimelinePosition[];
  groups: PhotoTimelineGroup[];
}

export interface PhotoTimelineWindow {
  startIndex: number;
  endIndex: number;
  headers: PhotoTimelineGroup[];
}

export function timelineMonth(timestamp: number): string {
  const date = new Date(Number(timestamp) * 1000);
  if (!Number.isFinite(date.getTime()) || Number(timestamp) <= 0) return "日期未知";
  return monthFormatter.format(date);
}

export function createPhotoTimelineLayout(
  timestamps: number[],
  containerWidth: number,
  options: { compact?: boolean } = {},
): PhotoTimelineLayout {
  const compact = options && options.compact === true;
  const tileMinWidth = compact ? 114 : minTileWidth;
  const tileGap = compact ? 8 : gap;
  const width = Math.max(0, Number(containerWidth) || 0);
  const columns = Math.max(1, Math.floor((width + tileGap) / (tileMinWidth + tileGap)));
  const tileSize = Math.max(0, (width - tileGap * (columns - 1)) / columns);
  const rowPitch = tileSize + tileGap;
  const positions = new Array<PhotoTimelinePosition>(timestamps.length);
  const groups: PhotoTimelineGroup[] = [];
  let group: PhotoTimelineGroup | null = null;
  let height = 0;
  let rowIndex = 0;
  for (let index = 0; index < timestamps.length; index++) {
    const month = timelineMonth(timestamps[index]);
    if (!group || group.title !== month) {
      if (group && rowIndex) height += rowIndex * rowPitch - tileGap;
      group = { title: month, top: height, startIndex: index, count: 0 };
      groups.push(group);
      height += groupHeaderHeight;
      rowIndex = 0;
    }
    const localIndex = group.count++;
    const row = Math.floor(localIndex / columns);
    positions[index] = {
      left: (localIndex % columns) * rowPitch,
      top: height + row * rowPitch,
    };
    rowIndex = row + 1;
  }
  if (rowIndex) height += rowIndex * rowPitch - tileGap;
  return { columns, tileSize, rowPitch, gap: tileGap, totalHeight: height, positions, groups };
}

function firstAfter<T>(items: T[], value: number, getOffset: (item: T) => number): number {
  let low = 0;
  let high = items.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if (getOffset(items[middle]) < value) low = middle + 1;
    else high = middle;
  }
  return low;
}

export function getPhotoTimelineWindow(
  layout: PhotoTimelineLayout,
  viewportTop: number,
  viewportHeight: number,
): PhotoTimelineWindow {
  const first = Math.max(0, Number(viewportTop) || 0);
  const last = first + Math.max(0, Number(viewportHeight) || 0);
  const overscan = Math.max(240, 2 * layout.rowPitch);
  const start = firstAfter(
    layout.positions,
    first - overscan - layout.tileSize,
    (item) => item.top,
  );
  const end = firstAfter(layout.positions, last + overscan, (item) => item.top);
  const headerStart = firstAfter(
    layout.groups,
    first - overscan - groupHeaderHeight,
    (item) => item.top,
  );
  const headerEnd = firstAfter(layout.groups, last + overscan, (item) => item.top);
  return {
    startIndex: start,
    endIndex: end,
    headers: layout.groups.slice(headerStart, headerEnd),
  };
}
