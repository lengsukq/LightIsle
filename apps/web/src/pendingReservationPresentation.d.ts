export function reservationRootLabel(
  item: { rootID:string; rootGeneration:number },
  roots: Array<{rootID:string;generation:number;name:string;online:boolean}>,
  rootsKnown:boolean,
): string;
