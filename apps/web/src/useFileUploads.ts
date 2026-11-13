import { computed, ref, watch, type Ref } from "vue";
import { fingerprintFile, isWithinUploadSizeLimit, supportsContentFingerprint, uploadSessionIdentity } from "./uploadIdentity.ts";
import { adoptUploadTask, refreshAfterPublishedUpload } from "./uploadLifecycle.ts";
import { createUploadResumeStorage } from "./uploadResumeStorage.ts";
import {
  createUploadContinuation, uploadContextMatches, uploadContinuationIsCurrent,
  type UploadBatchContext, type UploadContinuation,
} from "./filePageState.ts";
import { rootApiPath } from "./rootApi.ts";
import {recoverUploadOffset} from "./uploadChunkRecovery.ts";

type UploadDependencies = {
  username: () => string | undefined;
  selectedRootID: () => string;
  selectedRootGeneration: () => number;
  rootEpoch: () => number;
  multiRoot: () => boolean;
  filesPath: () => string;
  currentFolderCanWrite: () => boolean;
  filesLoading: () => boolean;
  showingTrash: () => boolean;
  searchingFiles: () => boolean;
  filesError: Ref<string>;
  rootFetch: (path: string, init?: RequestInit, allowDuringRootSwitch?: boolean) => Promise<Response>;
  read: <T>(path: string, signal?: AbortSignal) => Promise<T>;
  write: <T>(path: string, method: "POST" | "PATCH", body?: object, signal?: AbortSignal) => Promise<T>;
  loadFiles: () => Promise<unknown>;
  describeError: (error: unknown) => string;
};

export function useFileUploads(deps: UploadDependencies) {
  const uploadProgress=ref("");
  const uploadPercent=ref(0);
  const uploadStage=ref<"idle"|"hashing"|"uploading"|"done"|"error"|"cancelled">("idle");
  const uploadCurrent=ref(0);
  const uploadTotal=ref(0);
  const uploadFileName=ref("");
  const uploadSize=ref(0);
  const uploadTransferred=ref(0);
  const uploadDropActive=ref(false);
  const uploadAutoRenameConflicts=ref(false);
  const uploadCompleted=ref(0);
  const uploadResult=ref("");
  const uploadFailure=ref("");
  const uploadBusy=ref(false);
  const selectedUpload=ref<HTMLInputElement|null>(null);
  const uploadContinuation=ref<UploadContinuation<File>|null>(null);
  const uploadResumeStorage=createUploadResumeStorage(()=>sessionStorage);
  let uploadAbortController:AbortController|null=null;
  let uploadCancelled=false;
  let cancelUnconfirmed=false;
  let uploadGeneration=0;
  let activeUploadPromise:Promise<void>|null=null;
  let activeUploadContext:UploadBatchContext|null=null;
  const currentUploadContext=computed<UploadBatchContext>(()=>({
    username:deps.username()??"",
    rootID:deps.multiRoot()?deps.selectedRootID():"",
    rootGeneration:deps.multiRoot()?deps.selectedRootGeneration():0,
    rootEpoch:deps.rootEpoch(),
    directory:deps.filesPath()
  }));
  const canContinueUploads=computed(()=>!uploadBusy.value&&!deps.filesLoading()&&!deps.showingTrash()&&
    deps.currentFolderCanWrite()&&!deps.searchingFiles()&&uploadContinuationIsCurrent(uploadContinuation.value,currentUploadContext.value));
  watch(deps.username,()=>{uploadContinuation.value=null;});

  function cancelCurrentUpload(){uploadCancelled=true;uploadAbortController?.abort();}
  function hasActiveUpload(){return activeUploadPromise!==null;}
  async function cancelAndWaitForUpload(){
    const running=activeUploadPromise;
    const batchContext=activeUploadContext;
    if(!running)return;
    const cancellationGeneration=++uploadGeneration;
    cancelCurrentUpload();
    await running.catch(()=>{});
    const currentContext=currentUploadContext.value;
    const sameUploadScope=batchContext&&batchContext.username===currentContext.username&&
      batchContext.rootID===currentContext.rootID&&batchContext.rootGeneration===currentContext.rootGeneration&&
      batchContext.rootEpoch===currentContext.rootEpoch;
    if(cancellationGeneration===uploadGeneration&&sameUploadScope){
      uploadBusy.value=false;
      uploadProgress.value="";
      uploadStage.value="cancelled";
      uploadFailure.value=cancelUnconfirmed?"已停止本次上传，但未能确认服务端清理结果；请联系管理员检查未完成上传和容量预占。":"已取消上传和文件校验。";
    }
  }
  function resetUploadsForRoot(){
    uploadProgress.value="";uploadBusy.value=false;uploadStage.value="idle";uploadDropActive.value=false;uploadFailure.value="";
    uploadContinuation.value=null;
  }

  function uploadErrorLabel(err:unknown):string {
    const code=err instanceof Error?err.message:"unknown_error";
    const messages:Record<string,string>={
      file_already_exists:"目标目录中已经存在同名文件。为防止覆盖原文件，请先重命名后重新上传。",
      upload_busy:"该文件正在被另一项上传占用，请等待后重试。",
      upload_inventory_limit:"上传任务数量达到上限，请清理过期任务后重试。",
      insufficient_storage_space:"目标硬盘剩余空间不足，已停止写入且保留上传进度。请清理空间后选择同一文件继续。",
      storage_quota_exceeded:"你的个人存储总额度已经不足，请清理永久不再使用的文件，或联系管理员提高配额。",
      storage_reservation_missing:"续传记录与容量预占不一致，为避免超额写入，请取消该任务后重新上传。",
      storage_accounting_conflict:"目标文件正在计费或已存在，请刷新目录后重新命名。",
      storage_accounting_uncertain:"文件可能已经写入，但账本未确认；请勿重复上传，先刷新并核对文件。",
      storage_destination_not_assigned:"存储位置尚未分配或原硬盘已离线，请联系管理员检查存储设置。",
      shared_volume_offline:"存储硬盘已离线，请接回原硬盘并重新连接。",
      permission_denied:"文件夹或磁盘不可写，请检查目录权限和磁盘格式。",
      file_permission_denied:"当前账户没有此文件夹的写入权限。",
      upload_too_large:"文件超过 32 GiB 上限。",
      upload_owner_mismatch:"续传记录与当前账号不匹配，请重新选择文件。",
      upload_outcome_uncertain:"服务未能确认文件是否写入成功，请先刷新目录核对，避免重复上传。",
      upload_begin_uncertain:"上传任务可能已在原硬盘创建，请检查原硬盘连接，让管理员核对未完成上传和容量预占。",
      storage_durability_failure:"存储设备未能确认数据持久写入，请检查磁盘连接和健康状态。",
      invalid_chunk_size:"上传分块异常，请重新选择文件。",
      root_scope_unavailable:"共享目录尚未准备好，请刷新后重试。",
      root_generation_changed:"共享目录已变化，请刷新并重新选择目标。",
    };
    if(code.startsWith("chunk_error_"))return "传输连接异常（"+code.slice(12)+"），请检查网络后重新选择同一文件续传。";
    return messages[code]??deps.describeError(err);
  }
  function chooseUploadFiles(){
    if(uploadBusy.value || deps.filesLoading() || deps.showingTrash() || !deps.currentFolderCanWrite())return;
    if(selectedUpload.value){selectedUpload.value.value="";selectedUpload.value.click();}
  }
  function startUpload(e:Event){
    const input=e.target as HTMLInputElement;
    const files=Array.from(input.files??[]);
    input.value=""; // Selecting the same file again must trigger a new change event.
    enqueueUploads(files);
  }
  function dragOverUpload(e:DragEvent){if(deps.currentFolderCanWrite()&&!deps.showingTrash()&&!uploadBusy.value){e.preventDefault();uploadDropActive.value=true;}}
  function dragLeaveUpload(e:DragEvent){if(!e.currentTarget || !(e.currentTarget as HTMLElement).contains(e.relatedTarget as Node|null))uploadDropActive.value=false;}
  function dropUpload(e:DragEvent){
    e.preventDefault();uploadDropActive.value=false;
    if(!deps.currentFolderCanWrite()||uploadBusy.value||deps.showingTrash())return;
    enqueueUploads(Array.from(e.dataTransfer?.files??[]));
  }
  function launchUploadBatch(files:File[],context:UploadBatchContext){
    const running=uploadSelected(files,context);
    activeUploadPromise=running;
    activeUploadContext=context;
    const finished=()=>{
      if(activeUploadPromise===running){activeUploadPromise=null;activeUploadContext=null;}
    };
    void running.then(finished,finished);
  }
  function enqueueUploads(files:File[]){
    if(!deps.currentFolderCanWrite()){deps.filesError.value="当前目录为只读，请选择有写入权限的目录。";return;}
    if(!files.length)return;
    if(uploadBusy.value)return;
    uploadContinuation.value=null;
    launchUploadBatch(files,currentUploadContext.value);
  }
  function continueIncompleteUploads(){
    const continuation=uploadContinuation.value;
    if(!continuation||!canContinueUploads.value){uploadContinuation.value=null;return;}
    uploadContinuation.value=null;
    launchUploadBatch(continuation.files,continuation.context);
  }
  function closeUploadActivity(){
    uploadContinuation.value=null;
    uploadStage.value="idle";uploadResult.value="";uploadProgress.value="";uploadFailure.value="";
  }
  async function uploadSelected(files:File[],batchContext:UploadBatchContext){
    uploadContinuation.value=null;
    const uploadConflictPolicy=uploadAutoRenameConflicts.value?"rename":"";
    const uploadUsername=batchContext.username;
    if(!uploadUsername){deps.filesError.value="登录状态已失效，请重新登录后上传。";return;}
    if(!uploadContextMatches(batchContext,currentUploadContext.value))return;
    const uploadDirectory=batchContext.directory;
    const uploadRootID=batchContext.rootID;
    const uploadRootGeneration=batchContext.rootGeneration;
    const uploadRootEpoch=batchContext.rootEpoch;
    const uploadPath=(path:string)=>rootApiPath(uploadRootID||undefined,path);
    const generation=++uploadGeneration;
    const isCurrentUpload=()=>generation===uploadGeneration&&deps.username()===uploadUsername&&
      deps.rootEpoch()===uploadRootEpoch&&deps.selectedRootID()===uploadRootID&&deps.selectedRootGeneration()===uploadRootGeneration;
    uploadBusy.value=true;deps.filesError.value="";uploadCancelled=false;cancelUnconfirmed=false;
    uploadCompleted.value=0;uploadCurrent.value=0;uploadTotal.value=files.length;
    uploadResult.value="";uploadFailure.value="";uploadStage.value="hashing";uploadPercent.value=0;
    for(const [fileIndex,file] of files.entries()){
      uploadCurrent.value=fileIndex+1;uploadFileName.value=file.name;
      uploadSize.value=file.size;uploadTransferred.value=0;uploadPercent.value=0;
      if(uploadCancelled||!isCurrentUpload())break;
      if(!isWithinUploadSizeLimit(file.size)){
        uploadStage.value="error";uploadFailure.value="文件超过 32 GiB 上限，未开始校验或上传。";
        break;
      }
      let taskId="";
      let taskCreationRequested=false;
      let savedKey="";
      let resumable=false;
      const controller=new AbortController();
      uploadAbortController=controller;
      const ensureCurrentUpload=()=>{
        if(uploadCancelled||!isCurrentUpload()){
          controller.abort();
          const error=new Error("upload_cancelled");error.name="AbortError";throw error;
        }
      };
      try{
        const dest=uploadDirectory==="."?file.name:uploadDirectory+"/"+file.name;
        const legacyKey=uploadRootID?"":"lightisle_upload_"+dest+"_"+file.size;
        let key="";
        let prefix="";
        if(supportsContentFingerprint()){
          uploadStage.value="hashing";
          uploadProgress.value=file.name+" · 正在完整校验文件内容 0%";
          const fingerprint=await fingerprintFile(file,{
            signal:controller.signal,
            onProgress:(processed,total)=>{
              uploadPercent.value=Math.round(100*processed/Math.max(total,1));
              uploadProgress.value=file.name+" · 正在完整校验文件内容 "+Math.round(100*processed/Math.max(total,1))+"%";
            }
          });
          ensureCurrentUpload();
          const identity=await uploadSessionIdentity(uploadUsername,dest,file,fingerprint,globalThis.crypto,uploadRootID,uploadRootGeneration);
          ensureCurrentUpload();
          key=identity.key;
          prefix=identity.prefix;
          resumable=true;
          savedKey=key;
        }else{
          uploadStage.value="uploading";
          uploadProgress.value=file.name+" · 当前连接不支持内容校验，此次上传无法断点续传";
        }

        const staleIDs=uploadResumeStorage.collectStaleIDs({legacyKey,prefix,key});
        await Promise.all(staleIDs.map(id=>abortUpload(id,uploadPath)));
        ensureCurrentUpload();

        const Upload=(id:string)=>uploadPath("/api/v2/uploads/"+encodeURIComponent(id));
        let state:{id:string;offset:number;size:number;path?:string};
        const startUpload=async():Promise<typeof state>=>{
          taskCreationRequested=true;
          let requestedID="";
          if(typeof globalThis.crypto?.getRandomValues==="function"){
            requestedID=Array.from(globalThis.crypto.getRandomValues(new Uint8Array(16)),
              value=>value.toString(16).padStart(2,"0")).join("");
            taskId=requestedID;
            if(resumable&&!uploadResumeStorage.save(key,requestedID)){resumable=false;savedKey="";}
          }
          try{
            return await deps.write<typeof state>(uploadPath("/api/v2/uploads"),"POST",{
              path:dest,size:file.size,onConflict:uploadConflictPolicy,
              ...(requestedID?{uploadID:requestedID}:{})
            },controller.signal);
          }catch(err){
            if(!requestedID||uploadCancelled)throw err;
            ensureCurrentUpload();
            try{return await deps.read<typeof state>(Upload(requestedID),controller.signal);}
            catch{throw err;}
          }
        };
        let saved:string|null=null;
        if(resumable){
          const previous=uploadResumeStorage.read(key);
          saved=previous.saved;
          if(!previous.resumable){resumable=false;savedKey="";}
        }
        if(saved){
          taskId=saved;
          try{state=await deps.read<typeof state>(Upload(saved),controller.signal);ensureCurrentUpload();}
          catch(err){
            if(uploadCancelled)throw err;
            // deps.read surfaces the server's JSON error code ("not_found") rather
            // than the HTTP status. Recreate only a genuinely missing upload;
            // permission and generation errors must remain visible to the user.
            if(!(err instanceof Error)||err.message!=="not_found")throw err;
            uploadResumeStorage.remove(key);
            taskId="";
            state=await startUpload();
            state=adoptUploadTask(state,id=>{taskId=id;},ensureCurrentUpload);
          }
        }else{
          state=await startUpload();
          state=adoptUploadTask(state,id=>{taskId=id;},ensureCurrentUpload);
        }
        taskId=state.id;
        if(state.path&&state.path!==dest)uploadFileName.value=state.path+"（自动改名）";
        uploadStage.value="uploading";uploadTransferred.value=state.offset;
        uploadPercent.value=Math.round(100*state.offset/Math.max(file.size,1));
        if(resumable){
          if(!uploadResumeStorage.save(key,state.id)){resumable=false;savedKey="";}
        }
        while(state.offset<file.size){
          if(uploadCancelled)throw new Error("cancelled");
          const chunk=file.slice(state.offset,Math.min(state.offset+4*1024*1024,file.size));
          const response=await deps.rootFetch(Upload(state.id),{method:"PATCH",credentials:"same-origin",
            headers:{"X-LightIsle-Request":"1","X-Upload-Offset":String(state.offset)},body:chunk,signal:controller.signal});
          ensureCurrentUpload();
          if(!response.ok){
            state=await recoverUploadOffset(response,
              ()=>deps.read<typeof state>(Upload(state.id),controller.signal));
            ensureCurrentUpload();
            continue;
          }
          state=await response.json() as typeof state;
          ensureCurrentUpload();
          uploadTransferred.value=state.offset;
          uploadPercent.value=Math.round(100*state.offset/Math.max(file.size,1));
          uploadProgress.value=file.name+" · "+Math.round(100*state.offset/Math.max(file.size,1))+"%";
        }
        if(uploadCancelled)throw new Error("cancelled");
        await deps.write(Upload(state.id)+"/complete","POST",{},controller.signal);
        ensureCurrentUpload();
        if(resumable)uploadResumeStorage.remove(key);
        uploadCompleted.value+=1;uploadPercent.value=100;uploadProgress.value="";
      }catch(err){
        if(uploadCancelled){
          const cancelled=taskId?await abortUpload(taskId,uploadPath):!taskCreationRequested;
          cancelUnconfirmed=!cancelled;
          if(savedKey&&cancelled)uploadResumeStorage.remove(savedKey);
          uploadProgress.value="";
          if(isCurrentUpload()){uploadStage.value="cancelled";uploadFailure.value=cancelled?"已取消上传和文件校验。":"已停止本次上传，但未能确认服务端清理结果；请联系管理员检查未完成上传和容量预占。";}
        }else{
          const cleanupConfirmed=taskId&&!resumable?await abortUpload(taskId,uploadPath):true;
          if(isCurrentUpload()){uploadStage.value="error";uploadFailure.value="上传「"+file.name+"」失败："+uploadErrorLabel(err)+
            (err instanceof Error&&err.message==="upload_begin_uncertain"?"；未确认前请勿重复创建任务。":resumable?"；重新选择相同文件可从已完成部分继续。":cleanupConfirmed?"；当前连接不支持完整内容校验，无法安全续传，请重新选择文件从头上传。":"；未能确认服务端清理结果，请联系管理员检查未完成上传和容量预占。");
          }
        }
        break;
      }finally{uploadAbortController=null;}
    }
    if(isCurrentUpload()){
      uploadBusy.value=false;
      if(uploadCancelled&&!uploadFailure.value){uploadFailure.value="已取消上传和文件校验。";uploadStage.value="cancelled";}
      if(uploadCompleted.value===files.length){uploadStage.value="done";uploadResult.value="已成功上传 "+uploadCompleted.value+" 个文件。";}
      else if(uploadCompleted.value>0){uploadResult.value="已完成 "+uploadCompleted.value+" / "+files.length+" 个文件。";}
      const uploadContextStillVisible=uploadContextMatches(batchContext,currentUploadContext.value)&&!deps.showingTrash()&&!deps.searchingFiles();
      uploadContinuation.value=uploadContextStillVisible&&uploadCompleted.value<files.length
        ?createUploadContinuation(files,uploadCompleted.value,batchContext)
        :null;
      if(uploadContextStillVisible)await refreshAfterPublishedUpload(uploadCompleted.value,()=>deps.loadFiles());
    }
  }
  async function abortUpload(id:string,path:(path:string)=>string){
    const response=await deps.rootFetch(path("/api/v2/uploads/"+encodeURIComponent(id)),{
      method:"DELETE",headers:{"X-LightIsle-Request":"1"},credentials:"same-origin"
    },true).catch(()=>null);
    return response?.ok===true;
  }

  return {
    selectedUpload, uploadProgress, uploadPercent, uploadStage, uploadCurrent,
    uploadTotal, uploadFileName, uploadSize, uploadTransferred, uploadDropActive,
    uploadAutoRenameConflicts, uploadCompleted, uploadResult, uploadFailure,
    uploadBusy, uploadContinuation, currentUploadContext, canContinueUploads,
    cancelCurrentUpload, cancelAndWaitForUpload, hasActiveUpload, resetUploadsForRoot,
    chooseUploadFiles, startUpload, dragOverUpload, dragLeaveUpload, dropUpload,
    enqueueUploads, continueIncompleteUploads, closeUploadActivity,
  };
}
