// Pure mapping shared by the Web shell and its tests. A saved category
// binding is only usable when discovery confirms the very same generation.
export function routePersonalCategory(policy, roots, section) {
  const category = {files:"files", photos:"photos", cinema:"videos"}[section];
  if (!category) return {kind:"shared"};
  const location = policy?.locations?.find(item=>item.category===category);
  if (!location) return {kind:"shared"};
  const root = roots.find(item=>item.rootID===location.rootID);
  if (!root || !root.online || root.generation!==location.rootGeneration) {
    return {kind:"offline", category, rootID:location.rootID};
  }
  if (!new RegExp(`^Users/u[0-9]+/${category}$`).test(location.relativePath)) {
    return {kind:"offline", category, rootID:location.rootID};
  }
  return {kind:"personal", category, rootID:root.rootID, path:location.relativePath};
}
