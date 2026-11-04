export type TrashMediaRow = {path?:string;success:boolean;error?:string};
export type TrashMediaResponse = {results:TrashMediaRow[]};
export type TrashMediaResult = {completed:number;cancelled:boolean;failed:string[]};
export function trashMediaOriginals(
  paths:string[],
  request:(paths:string[])=>Promise<TrashMediaResponse>,
  stillCurrent:()=>boolean,
):Promise<TrashMediaResult>;
