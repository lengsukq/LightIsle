import {ref} from 'vue';
import {readApiFailure} from './apiFailure.ts';
import {describeUserFacingError} from './userFacingError.ts';

type TaskCenterOptions = {
  role: () => string | undefined;
  ready: () => boolean;
  activePage: () => string;
  getJson: <T>(url: string) => Promise<T>;
  rootFetch: (url: string, init: RequestInit) => Promise<Response>;
  scopedApiPath: (path: string) => string;
  isAbortError: (error: unknown) => boolean;
};

// Task lifecycle belongs to the currently bound physical-root generation.
// Invalidating a root discards all pending history requests rather than
// allowing an older root to repopulate the new root's task center.
export type BackendTask = {kind:'gallery'|'cinema'|'backup'|'trash'|'uploads';running:boolean;progress:number;found?:number;bytes?:number;lastDone?:number;lastError?:string;operation?:string};
export type TaskRun = {id:number;kind:'gallery'|'cinema'|'backup'|'trash'|'uploads';operation:string;running:boolean;progress:number;bytes:number;startedAt:number;lastDone:number;lastError:string;attempts:number};

export function useTaskCenter(options: TaskCenterOptions) {
const maxLoadedTaskHistory = 1000;
const tasks = ref<BackendTask[]>([]);
const taskError = ref("");
const taskLoaded = ref(false);
const taskLoading = ref(false);
const taskHistory = ref<TaskRun[]>([]);
const taskHistoryNextCursor = ref("");
const taskHistoryLoading = ref(false);
const taskHistoryError = ref("");
let taskHistoryGeneration = 0;
let contextGeneration = 0;
let taskRequestGeneration = 0;
let taskHistoryLatestRefreshing = false;
const jsonGet = options.getJson;
const rootFetch = options.rootFetch;
const scopedApiPath = options.scopedApiPath;
const isAbortError = options.isAbortError;
async function reloadTasks(){
  if(options.role()!=="admin"||!options.ready())return;
  const generation=contextGeneration;
  const request=++taskRequestGeneration;
  taskLoading.value=true;
  try{
    const result=await jsonGet<{tasks:BackendTask[]}>(scopedApiPath("/api/v2/tasks"));
    if(generation!==contextGeneration||request!==taskRequestGeneration)return;
    tasks.value=result.tasks;
    taskLoaded.value=true;
    taskError.value="";
    if(options.activePage()==="settings"&&(tasks.value.some(task=>task.running)||taskHistory.value.some(run=>run.running)))void refreshLatestTaskHistory();
  }
  catch(e){if(generation===contextGeneration&&request===taskRequestGeneration&&!isAbortError(e))taskError.value="读取任务状态失败："+describeUserFacingError(e);}
  finally{if(generation===contextGeneration&&request===taskRequestGeneration)taskLoading.value=false;}
}
async function reloadTaskHistory(reset=true){
  if(options.role()!=="admin"||!options.ready())return;
  if(!reset&&taskHistoryLoading.value)return;
  if(reset)taskHistoryGeneration+=1;
  const generation=taskHistoryGeneration;
  const cursor=reset?"":taskHistoryNextCursor.value;
  if(!reset&&!cursor)return;
  taskHistoryLoading.value=true;
  taskHistoryError.value="";
  const query=new URLSearchParams({limit:"20"});
  if(cursor)query.set("before",cursor);
  try{
    const page=await jsonGet<{runs:TaskRun[];nextCursor:string}>(scopedApiPath("/api/v2/tasks/history")+"?"+query.toString());
    if(generation!==taskHistoryGeneration)return;
    if(reset)taskHistory.value=page.runs.slice(0,maxLoadedTaskHistory);
    else{
      const existing=new Set(taskHistory.value.map(run=>run.id));
      taskHistory.value=[...taskHistory.value,...page.runs.filter(run=>!existing.has(run.id))].slice(0,maxLoadedTaskHistory);
    }
    taskHistoryNextCursor.value=taskHistory.value.length>=maxLoadedTaskHistory?"":page.nextCursor;
  }catch(e){
    if(generation===taskHistoryGeneration&&!isAbortError(e))taskHistoryError.value="读取任务记录失败："+describeUserFacingError(e);
  }finally{
    if(generation===taskHistoryGeneration)taskHistoryLoading.value=false;
  }
}
async function refreshTaskCenter(){
  await Promise.all([reloadTasks(),reloadTaskHistory(true)]);
}
async function refreshLatestTaskHistory(){
  if(taskHistoryLoading.value||taskHistoryLatestRefreshing||options.role()!=="admin"||!options.ready())return;
  taskHistoryLatestRefreshing=true;
  const generation=taskHistoryGeneration;
  try{
    const page=await jsonGet<{runs:TaskRun[];nextCursor:string}>(scopedApiPath("/api/v2/tasks/history")+"?limit=20");
    if(generation!==taskHistoryGeneration)return;
    const latestIDs=new Set(page.runs.map(run=>run.id));
    taskHistory.value=[...page.runs,...taskHistory.value.filter(run=>!latestIDs.has(run.id))].slice(0,maxLoadedTaskHistory);
    taskHistoryNextCursor.value=taskHistory.value.length>=maxLoadedTaskHistory?"":page.nextCursor;
  }catch{/* Keep the last successful history visible while polling. */}
  finally{taskHistoryLatestRefreshing=false;}
}
async function taskControl(task:BackendTask,action:"cancel"|"retry"){
  try{
    const response=await rootFetch(scopedApiPath(`/api/v2/tasks/${task.kind}/${action}`),{method:"POST",headers:{"X-LightIsle-Request":"1"},credentials:"same-origin"});
    if(!response.ok)throw await readApiFailure(response);
    await refreshTaskCenter();
  }catch(e){if(!isAbortError(e))taskError.value="任务操作失败："+describeUserFacingError(e);}
}
function startMediaTask(kind:"gallery"|"cinema"){
  void taskControl({kind,running:false,progress:0},"retry");
}

function reset() {
  contextGeneration++;
  taskRequestGeneration++;
  taskHistoryGeneration++;
  taskHistoryLatestRefreshing = false;
  tasks.value=[];taskError.value="";taskLoaded.value=false;taskLoading.value=false;
  taskHistory.value=[];taskHistoryNextCursor.value="";
  taskHistoryLoading.value=false;taskHistoryError.value="";
}
return { tasks, taskError, taskLoaded, taskLoading, taskHistory, taskHistoryNextCursor,
  taskHistoryLoading, taskHistoryError, reloadTasks, reloadTaskHistory,
  refreshTaskCenter, refreshLatestTaskHistory, taskControl,
  startMediaTask, reset };
}
