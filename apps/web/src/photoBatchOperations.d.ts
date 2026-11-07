export type PhotoBatchItem = {id:number;path:string;name:string};
export function photoShareUrl(origin:string, rootId:string|undefined, generation:number, token:string):string;
export function photoArchivePath(ids:number[]):string;
export function preparePhotoArchive(url:string, stillCurrent:()=>boolean,
  head:(url:string)=>Promise<{ok:boolean;status:number}>, startDownload:(url:string)=>void
):Promise<{started:boolean;stopped:boolean;status:number|null}>;
export type PhotoBatchResult = {
  completed:PhotoBatchItem[];
  stopped:boolean;
  remaining:PhotoBatchItem[];
  failure:{item:PhotoBatchItem;error:unknown}|null;
};
export function runPhotoBatch(
  items:PhotoBatchItem[],
  perform:(item:PhotoBatchItem)=>Promise<void>,
  stillCurrent:()=>boolean,
):Promise<PhotoBatchResult>;
