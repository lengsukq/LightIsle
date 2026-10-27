export type PersonalRoute =
  | {kind:'shared'}
  | {kind:'offline';category:string;rootID:string}
  | {kind:'personal';category:string;rootID:string;path:string};
export function routePersonalCategory(
  policy:{locations:{category:string;rootID:string;rootGeneration:number;relativePath:string}[]}|null,
  roots:{rootID:string;generation:number;online:boolean}[],
  section:string,
):PersonalRoute;
