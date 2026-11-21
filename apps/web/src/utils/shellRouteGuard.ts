export type ShellPage =
  | "overview"
  | "files"
  | "computer"
  | "photos"
  | "cinema"
  | "downloads"
  | "apps"
  | "automation"
  | "settings";

export type ShellSettingsGroup = "account" | "files" | "cache" | "storage" | "ops";

export interface RoutePermissionContext {
  isAdmin: boolean;
  computerFilesAllowed: boolean;
  computerFilesResolved: boolean;
}

/**
 * Clamp deep-linked or history-restored page targets according to the current user's role and grants.
 */
export function resolvePermittedPage<TPage extends string>(
  page: TPage,
  ctx: RoutePermissionContext,
): TPage {
  if (page === "automation" && !ctx.isAdmin) return "overview" as TPage;
  if (page === "computer" && ctx.computerFilesResolved && !ctx.computerFilesAllowed) {
    return "overview" as TPage;
  }
  return page;
}

/**
 * Ensure ordinary members cannot remain on admin-only settings tabs after role switches or URL jumps.
 */
export function resolvePermittedSettingsGroup<TGroup extends string>(
  group: TGroup,
  isAdmin: boolean,
): TGroup {
  if (!isAdmin && (group === "storage" || group === "ops")) {
    return "account" as TGroup;
  }
  return group;
}
