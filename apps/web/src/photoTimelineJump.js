// Year/month aggregation over a takenAt-descending asset list, powering the
// timeline jump controls. Month titles reuse the timeline layout's formatter
// so a jump target always matches a rendered group header.
import { timelineMonth } from "./photoTimelineLayout.js";

export function buildTimelineYears(timestamps) {
  const years = [];
  const byYear = new Map();
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

// Resolves a (year, month) pair to the asset index a jump should scroll to.
export function timelineJumpIndex(years, year, month) {
  const yearEntry = years.find(entry => entry.year === year);
  if (!yearEntry) return -1;
  const monthEntry = month
    ? yearEntry.months.find(entry => entry.month === month)
    : yearEntry.months[yearEntry.months.length - 1];
  if (!monthEntry) return -1;
  return monthEntry.firstIndex;
}
