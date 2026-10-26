export interface CinemaTimeline { position: number; duration: number; nearEnd: boolean }
export declare function cinemaTimeline(current: number, duration: number, sessionStart?: number, originalDuration?: number): CinemaTimeline;
export declare function cinemaSeekTarget(current: number, seconds: number, total: number): number;
