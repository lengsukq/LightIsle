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
export function buildTimelineYears(timestamps: number[]): TimelineYearEntry[];
export function timelineJumpIndex(years: TimelineYearEntry[], year: number, month: number): number;
export function timelineYearsFromMonths(months: Array<{year:number;month:number;count:number;firstIndex:number}>): TimelineYearEntry[];
