import { reactive } from "vue";

export type PendingMediaKind = "photos" | "cinema";
export type PendingMediaItem = { id:number; path:string; reason:string; data:string[]; canManage:boolean };
type Page = { items:PendingMediaItem[]; nextCursor:string; scan?:{state:string} };
type Group = { items:PendingMediaItem[]; next:string; loading:boolean; loaded:boolean; error:string; scan:string; revision:number };

// A mutation must supersede an older list request. Otherwise a slow refresh
// can put an already resolved record back on screen after the action succeeds.
export function usePendingMediaList(deps:{
  read:(kind:PendingMediaKind, query:URLSearchParams)=>Promise<Page>;
  errorLabel:(error:unknown)=>string;
  schedule?:(callback:()=>void,delay:number)=>number;
  cancel?:(timer:number)=>void;
  visible?:()=>boolean;
}) {
  const group = ():Group => ({items:[],next:"",loading:false,loaded:false,error:"",scan:"not_checked",revision:0});
  const groups = reactive<Record<PendingMediaKind,Group>>({photos:group(),cinema:group()});
  const scans:Record<PendingMediaKind,{tracking:boolean;revision:number;timer:number|null}> = {
    photos:{tracking:false,revision:0,timer:null},cinema:{tracking:false,revision:0,timer:null},
  };
  const schedule=deps.schedule??((callback,delay)=>globalThis.setTimeout(callback,delay));
  const cancel=deps.cancel??(timer=>globalThis.clearTimeout(timer));
  const visible=deps.visible??(()=>typeof document==="undefined" || !document.hidden);
  let disposed = false;

  async function load(kind:PendingMediaKind, more=false, force=false) {
    const current = groups[kind];
    if(disposed || (current.loading && !force))return;
    const revision=++current.revision;
    current.loading=true;current.error="";
    try {
      const query=new URLSearchParams({limit:"30"});
      if(more && current.next)query.set("after",current.next);
      const page=await deps.read(kind,query);
      if(disposed || current.revision!==revision)return;
      current.items=more?[...current.items,...page.items]:page.items;
      current.next=page.nextCursor;current.scan=page.scan?.state??"not_checked";current.loaded=true;
      if(current.scan==="running" && !scans[kind].tracking)trackScan(kind);
    } catch(error) {
      if(!disposed && current.revision===revision)current.error="读取失败，列表可能不完整："+deps.errorLabel(error);
    } finally {
      if(!disposed && current.revision===revision)current.loading=false;
    }
  }

  async function resolved(kind:PendingMediaKind, id:number) {
    if(disposed)return;
    const current=groups[kind];
    current.items=current.items.filter(item=>item.id!==id);
    // A later page cursor belongs to the old list and is unsafe after a
    // mutation. If refresh fails, retain only the remaining known entries.
    current.next="";
    await load(kind,false,true);
  }

  function scheduleScan(kind:PendingMediaKind) {
    const scan=scans[kind];
    if(disposed || !scan.tracking || scan.timer!==null || !visible())return;
    const revision=scan.revision;
    scan.timer=schedule(()=>{scan.timer=null;void pollScan(kind,revision)},3000);
  }

  async function pollScan(kind:PendingMediaKind, revision:number) {
    const scan=scans[kind];
    if(disposed || !scan.tracking || scan.revision!==revision || !visible())return;
    try {
      const page=await deps.read(kind,new URLSearchParams({limit:"1"}));
      if(disposed || !scan.tracking || scan.revision!==revision || !visible())return;
      const state=page.scan?.state??"not_checked";
      groups[kind].scan=state;
      if(state==="running")scheduleScan(kind);
      else { scan.tracking=false; await load(kind,false,true); }
    } catch(error) {
      if(disposed || !scan.tracking || scan.revision!==revision)return;
      scan.tracking=false;groups[kind].scan="not_checked";
      groups[kind].error="无法自动读取检查进度，请刷新列表核对："+deps.errorLabel(error);
    }
  }

  function trackScan(kind:PendingMediaKind) {
    if(disposed)return;
    const scan=scans[kind];
    if(scan.timer!==null)cancel(scan.timer);
    scan.timer=null;scan.revision++;scan.tracking=true;
    groups[kind].revision++;groups[kind].loading=false;groups[kind].scan="running";groups[kind].error="";
    scheduleScan(kind);
  }

  function visibilityChanged() {
    for(const kind of ["photos","cinema"] as const) {
      const scan=scans[kind];
      if(!visible()) {
        scan.revision++;
        if(scan.timer!==null)cancel(scan.timer);
        scan.timer=null;
      } else scheduleScan(kind);
    }
  }

  function dispose() {
    disposed=true;
    for(const item of Object.values(groups))item.revision++;
    for(const scan of Object.values(scans)) {
      scan.revision++;scan.tracking=false;
      if(scan.timer!==null)cancel(scan.timer);
      scan.timer=null;
    }
  }
  return {groups,load,resolved,trackScan,visibilityChanged,dispose};
}
