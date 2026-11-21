import type { Movie } from "./cinemaTypes.ts";

type Shelf = "continue" | "recent";
type Page = { films: Movie[] };
export type CinemaHomeShelves = { resume: Movie[]; recent: Movie[] };

// The Core sorts 'continue' by the current viewer's last playback and
// 'recent' by ingest ID. Keep that server order, do not relabel an
// alphabetical list as recently added, and never merge cross-root results.
function uniqueFilms(items: Movie[], limit: number, filter: (item: Movie) => boolean) {
 const seen = new Set<number>();
 const result: Movie[] = [];
 for (const film of items) {
  if (!film || !Number.isSafeInteger(film.id) || film.id <= 0 || !filter(film) || seen.has(film.id)) continue;
  seen.add(film.id);
  result.push(film);
  if (result.length >= limit) break;
 }
 return result;
}

export async function readCinemaHomeShelves(
 fetchShelf: (kind: Shelf) => Promise<Page>,
 isCurrent: () => boolean,
): Promise<CinemaHomeShelves | null> {
 const [resume, recent] = await Promise.all([
  fetchShelf("continue"),
  fetchShelf("recent"),
 ]);
 if (!isCurrent()) return null;
 return {
  resume: uniqueFilms(Array.isArray(resume.films) ? resume.films : [], 8,
   film => Number.isFinite(film.position) && film.position > 5 && !film.completed),
  recent: uniqueFilms(Array.isArray(recent.films) ? recent.films : [], 8, () => true),
 };
}
