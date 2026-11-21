// Year/month aggregation over a takenAt-descending asset list, powering the
// timeline jump controls. Month titles reuse the timeline layout's formatter
// so a jump target always matches a rendered group header.
import { timelineMonth } from "./photoTimelineLayout.ts";

export interface TimelineMonthEntry {
  month: number;
  title: string;
  count: number;
  firstIndex: number;
}

export interface TimelineYearEntry {
  year: number;
  count: number;
  months: TimelineMonthEntry[];
}

export function buildTimelineYears(timestamps: number[]): TimelineYearEntry[] {
  const years: Array<TimelineYearEntry & { byMonth?: Map<number, TimelineMonthEntry> }> = [];
  const byYear = new Map<
    number,
    TimelineYearEntry & { byMonth: Map<number, TimelineMonthEntry> }
  >();
  for (let index = 0; index < timestamps.length; index++) {
    const timestamp = Number(timestamps[index]);
    if (!Number.isFinite(timestamp) || timestamp <= 0) continue;
    const date = new Date(timestamp * 1000);
    if (Number.isNaN(date.getTime())) continue;
    const year = date.getFullYear();
    const month = date.getMonth() + 1;
    let yearEntry = byYear.get(year);
    if (!yearEntry) {
      yearEntry = { year, count: 0, months: [], byMonth: new Map() };
      byYear.set(year, yearEntry);
      years.push(yearEntry);
    }
    let monthEntry = yearEntry.byMonth.get(month);
    if (!monthEntry) {
      monthEntry = { month, title: timelineMonth(timestamp), count: 0, firstIndex: index };
      yearEntry.byMonth.set(month, monthEntry);
      yearEntry.months.push(monthEntry);
    }
    monthEntry.count++;
    yearEntry.count++;
  }
  for (const yearEntry of years) {
    // timestamps arrive newest-first, so both levels are already descending;
    // sorting keeps the module honest even if callers reorder.
    yearEntry.months.sort((a, b) => b.month - a.month);
    delete yearEntry.byMonth;
  }
  years.sort((a, b) => b.year - a.year);
  return years;
}

// Converts a touch/mouse position on the edge rail to a month. Clamp both
// ends so moving outside the track while dragging remains predictable.
export function timelineScrubIndexAt(position: number, height: number, count: number): number {
  if (!Number.isFinite(height) || height <= 0 || !Number.isInteger(count) || count <= 0) return -1;
  const fraction = Math.max(0, Math.min(0.999999, Number(position) / height));
  return Number.isFinite(fraction) ? Math.floor(fraction * count) : -1;
}

// Server-side month counts describe the whole authorized gallery, not just
// the pages already loaded in the browser.
export function timelineYearsFromMonths(
  months: Array<{ year: number; month: number; count: number; firstIndex: number }> | null | undefined,
): TimelineYearEntry[] {
  const byYear = new Map<number, TimelineYearEntry>();
  for (const entry of months || []) {
    if (
      !Number.isInteger(entry.year) ||
      !Number.isInteger(entry.month) ||
      entry.month < 1 ||
      entry.month > 12 ||
      entry.year < 1900 ||
      !Number.isInteger(entry.count) ||
      entry.count < 1 ||
      !Number.isInteger(entry.firstIndex) ||
      entry.firstIndex < 0
    ) {
      continue;
    }
    let year = byYear.get(entry.year);
    if (!year) {
      year = { year: entry.year, count: 0, months: [] };
      byYear.set(entry.year, year);
    }
    year.count += entry.count;
    year.months.push({
      month: entry.month,
      count: entry.count,
      title: new Date(entry.year, entry.month - 1, 1).toLocaleDateString("zh-CN", {
        year: "numeric",
        month: "long",
      }),
      firstIndex: entry.firstIndex,
    });
  }
  const years = [...byYear.values()].sort((a, b) => b.year - a.year);
  for (const year of years) year.months.sort((a, b) => b.month - a.month);
  return years;
}

// Resolves a (year, month) pair to the asset index a jump should scroll to.
export function timelineJumpIndex(years: TimelineYearEntry[], year: number, month?: number): number {
  const yearEntry = years.find((entry) => entry.year === year);
  if (!yearEntry) return -1;
  const monthEntry = month
    ? yearEntry.months.find((entry) => entry.month === month)
    : yearEntry.months[yearEntry.months.length - 1];
  if (!monthEntry) return -1;
  return monthEntry.firstIndex;
}
