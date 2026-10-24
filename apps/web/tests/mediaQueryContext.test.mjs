import assert from "node:assert/strict";
import test from "node:test";
import { mediaQueryKey, transitionMediaQuery } from "../src/mediaQueryContext.js";

const photoQuery = (overrides = {}) => mediaQueryKey({
  root: "photos-root",
  generation: 3,
  album: 0,
  privateAlbum: 0,
  favorites: false,
  personal: false,
  ...overrides,
});

const cinemaQuery = (overrides = {}) => mediaQueryKey({
  root: "cinema-root",
  generation: 2,
  mode: "all",
  query: "",
  ...overrides,
});

test("same media query preserves its last successful content during a refresh", () => {
  const photo = photoQuery({ album: 18 });
  const cinema = cinemaQuery({ mode: "movie", query: "Arrival" });

  assert.deepEqual(transitionMediaQuery(photo, photo), { queryKey: photo, clearContent: false, resetCursor: false });
  assert.deepEqual(transitionMediaQuery(cinema, cinema), { queryKey: cinema, clearContent: false, resetCursor: false });
});

test("photo filter changes clear results from a different album or favorite view", () => {
  const all = photoQuery();
  const changes = [
    photoQuery({ album: 18 }),
    photoQuery({ privateAlbum: 18 }),
    photoQuery({ favorites: true }),
    photoQuery({ personal: true }),
  ];

  for (const query of changes) {
    assert.deepEqual(transitionMediaQuery(all, query), { queryKey: query, clearContent: true, resetCursor: true });
  }
});

test("cinema mode and search changes clear results from the previous query", () => {
  const all = cinemaQuery();
  const changes = [cinemaQuery({ mode: "series" }), cinemaQuery({ query: "Arrival" })];

  for (const query of changes) {
    assert.deepEqual(transitionMediaQuery(all, query), { queryKey: query, clearContent: true, resetCursor: true });
  }
});
