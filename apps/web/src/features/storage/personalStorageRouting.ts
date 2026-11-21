export type PersonalRoute =
  | { kind: "shared" }
  | { kind: "offline"; category: string; rootID: string }
  | { kind: "personal"; category: string; rootID: string; path: string };

const sectionToCategory: Record<string, string | undefined> = {
  files: "files",
  photos: "photos",
  cinema: "videos",
};

// Pure mapping shared by the Web shell and its tests. A saved category
// binding is only usable when discovery confirms the very same generation.
export function routePersonalCategory(
  policy: {
    locations: { category: string; rootID: string; rootGeneration: number; relativePath: string }[];
  } | null,
  roots: { rootID: string; generation: number; online: boolean }[],
  section: string,
): PersonalRoute {
  const category = sectionToCategory[section];
  if (!category) return { kind: "shared" };
  const location = policy?.locations?.find((item) => item.category === category);
  if (!location) return { kind: "shared" };
  const root = roots.find((item) => item.rootID === location.rootID);
  if (!root || !root.online || root.generation !== location.rootGeneration) {
    return { kind: "offline", category, rootID: location.rootID };
  }
  if (!new RegExp(`^Users/u[0-9]+/${category}$`).test(location.relativePath)) {
    return { kind: "offline", category, rootID: location.rootID };
  }
  return { kind: "personal", category, rootID: root.rootID, path: location.relativePath };
}
