import { describeRootOperationFailure } from "./rootDiscovery.ts";

export function dateLabel(timestamp:number){
 return new Date(timestamp*1000).toLocaleDateString("zh-CN",{year:"numeric",month:"long",day:"numeric"});
}
export function capturedLabel(asset:{capturedAt?:string}){
 if(!asset.capturedAt)return"";
 const parsed=new Date(asset.capturedAt);
 if(Number.isNaN(parsed.getTime()))return"";
 return parsed.toLocaleString("zh-CN",{year:"numeric",month:"long",day:"numeric",hour:"2-digit",minute:"2-digit"});
}
export function formatBytes(size:number){
 if(size>=1<<30)return (size/(1<<30)).toFixed(2)+" GB";
 if(size>=1<<20)return (size/(1<<20)).toFixed(1)+" MB";
 if(size>=1<<10)return (size/1024).toFixed(0)+" KB";
 return size+" B";
}
export function formatExposure(seconds:number){
 if(seconds>=1)return seconds.toFixed(1)+" s";
 const denominator=Math.round(1/seconds);
 return denominator>0&&Number.isFinite(denominator)?"1/"+denominator+" s":"";
}
export function formatAperture(value:number){return"f/"+(value<10?value.toFixed(1):Math.round(value))}
export function formatDuration(seconds:number){
 const total=Math.round(seconds);
 const m=Math.floor(total/60),s=total%60;
 return m+":"+String(s).padStart(2,"0");
}
export function coordinateLabel(latitude:number,longitude:number){
 const ns=latitude>=0?"N":"S";
 const ew=longitude>=0?"E":"W";
 return Math.abs(latitude).toFixed(5)+"°"+ns+"，"+Math.abs(longitude).toFixed(5)+"°"+ew;
}

export function albumError(error:unknown){
 const code=error instanceof Error?error.message:"request_failed";
 const messages:Record<string,string>={
  invalid_album_name:"相册名称需为 1–60 个字符，且不能包含控制字符。",
  invalid_or_duplicate_album:"相册名称无效或已存在；请调整名称后重试。",
  invalid_request:"请求无效，请检查相册信息。",
  album_name_exists:"已有同名相册。",
  not_found:"相册或照片已不存在，图库已刷新。",
  volume_offline:"媒体所在磁盘当前不可用，请稍后重试。",
  gallery_unavailable:"图库当前不可用，请稍后重试。",
 };
 return messages[code]??describeRootOperationFailure(error);
}
