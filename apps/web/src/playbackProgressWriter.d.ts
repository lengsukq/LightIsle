export type ProgressSnapshot = {key:string;url:string;rootGeneration:number;position:number;duration:number;completed:boolean;id:number;rootId:string};
export function createPlaybackProgressWriter(
  write:(snapshot:ProgressSnapshot)=>Promise<void>,
  callbacks?:{onSaved?:(snapshot:ProgressSnapshot)=>void;onError?:(error:unknown,snapshot:ProgressSnapshot)=>void}
):{save:(snapshot:ProgressSnapshot)=>Promise<void>;retry:()=>Promise<void>;hasPending:()=>boolean};
