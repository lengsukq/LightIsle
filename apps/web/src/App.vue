<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from "vue";
import {
  Activity, ArrowDownToLine, ArrowUpRight, Clapperboard, CloudOff,
  Folder, HardDrive, Images, LayoutDashboard, Moon, Monitor,
  RefreshCcw, Server, Settings2, ShieldCheck, Sun, WifiOff, FileText, FolderPlus,
  UploadCloud, ChevronRight, ChevronLeft, Download, Trash2
} from "lucide-vue-next";
import { applyTheme, type Theme } from "./theme";
import PhotosView from "./PhotosView.vue";
import CinemaView from "./CinemaView.vue";

type Account = { id:number; username:string; role:"admin"|"member"; enabled:boolean; createdAt:number };
const authChecking = ref(true);
const configured = ref(false);
const user = ref<{username:string;role:"admin"|"member"}|null>(null);
const authUsername = ref("");
const authPassword = ref("");
const authError = ref("");
const authSubmitting = ref(false);
const accounts = ref<Account[]>([]);
const newUsername = ref("");
const newPassword = ref("");
const newRole = ref<"admin"|"member">("member");
const userError = ref("");
const userBusy = ref(false);
type FileEntry = {name:string;path:string;type:"folder"|"file";size:number;modified:string};
const filesPath=ref(".");
const sharedRootName=ref("共享文件");
const fileEntries=ref<FileEntry[]>([]);
const fileNextCursor=ref("");
const checkedFiles=ref<string[]>([]);
const uploadProgress=ref("");
const filesLoading=ref(false);
const filesError=ref("");
const newFolderName=ref("");
const uploadBusy=ref(false);
const trashTarget=ref<FileEntry|null>(null);
type TrashEntry = {id:string;name:string;originalPath:string;deletedAt:string};
const trashItems=ref<TrashEntry[]>([]);
const showingTrash=ref(false);
const previewItem=ref<FileEntry|null>(null);
const previewText=ref("");
const previewError=ref("");
const selectedUpload=ref<HTMLInputElement|null>(null);
const pathSegments=computed(()=>{
  const p=filesPath.value;
  if(p===".")return [{name:sharedRootName.value,path:"."}];
  const parts=p.split("/");
  return [{name:sharedRootName.value,path:"."},...parts.map((name,index)=>({name,path:parts.slice(0,index+1).join("/")}))];
});
async function loadFiles(target=filesPath.value,more=false){
  if(!user.value)return;
  filesLoading.value=true;filesError.value="";
  try{
    const root=await jsonGet<{name:string}>("/api/v1/files/root");
    sharedRootName.value=root.name;
    const cursor=more?fileNextCursor.value:"";
    const data=await jsonGet<{entries:FileEntry[];nextCursor:string}>("/api/v1/files?path="+encodeURIComponent(target)+"&limit=100&cursor="+encodeURIComponent(cursor));
    filesPath.value=target;
    fileEntries.value=more?[...fileEntries.value,...data.entries]:data.entries;
    fileNextCursor.value=data.nextCursor;
    if(!more)checkedFiles.value=[];
  }catch(e){filesError.value="读取目录失败："+(e instanceof Error?e.message:"未知错误");}
  finally{filesLoading.value=false;}
}
async function loadTrash(){
  filesError.value="";
  try{
    const result=await jsonGet<{entries:TrashEntry[]}>("/api/v1/files/trash");
    trashItems.value=result.entries.sort((a,b)=>b.deletedAt.localeCompare(a.deletedAt));
  }catch(e){filesError.value="读取回收站失败："+(e instanceof Error?e.message:"未知错误");}
}
async function openTrash(){
  showingTrash.value=!showingTrash.value;
  if(showingTrash.value)await loadTrash();
}
async function restoreTrash(entry:TrashEntry){
  filesError.value="";
  try{
    await jsonWrite("/api/v1/files/trash/"+encodeURIComponent(entry.id)+"/restore","POST");
    await loadTrash();
    await loadFiles();
  }catch(e){filesError.value="恢复失败（原路径可能已被占用或不存在）："+(e instanceof Error?e.message:"未知错误");}
}
async function previewFile(item:FileEntry){
  previewItem.value=item;previewText.value="";previewError.value="";
  if(/\.(txt|md|json|log)$/i.test(item.name)){
    try{
      const response=await fetch("/api/v1/files/preview?path="+encodeURIComponent(item.path),{credentials:"same-origin"});
      if(!response.ok)throw new Error("格式不支持或文件太大");
      previewText.value=await response.text();
    }catch(e){previewError.value=e instanceof Error?e.message:"无法预览";}
  }else if(!/\.(jpe?g|png|gif|webp|mp4|webm|m4v)$/i.test(item.name)){
    previewError.value="该文件暂不支持在线预览，请下载后使用本机应用打开。";
  }
}
const previewURL=computed(()=>previewItem.value?"/api/v1/files/preview?path="+encodeURIComponent(previewItem.value.path):"");
function goUp(){
  if(filesPath.value===".")return;
  const p=filesPath.value.split("/");p.pop();
  void loadFiles(p.length?p.join("/"):".");
}
async function makeFolder(){
  const name=newFolderName.value.trim();
  if(!name)return;
  const full=filesPath.value==="."?name:filesPath.value+"/"+name;
  filesError.value="";
  try{
    await jsonWrite("/api/v1/files/folders","POST",{path:full});
    newFolderName.value="";await loadFiles();
  }catch(e){filesError.value="新建文件夹失败："+(e instanceof Error?e.message:"未知错误");}
}
async function uploadSelected(e:Event){
  const input=e.target as HTMLInputElement;
  const files=Array.from(input.files??[]);
  if(!files.length)return;
  uploadBusy.value=true;filesError.value="";
  for(const file of files){
    try{
      const dest=filesPath.value==="."?file.name:filesPath.value+"/"+file.name;
      const key="lightisle_upload_"+dest+"_"+file.size;
      const Upload=(id:string)=>"/api/v1/uploads/"+encodeURIComponent(id);
      let state:{id:string;offset:number;size:number};
      const saved=sessionStorage.getItem(key);
      if(saved){
        try{state=await jsonGet<typeof state>(Upload(saved))}
        catch{sessionStorage.removeItem(key);state=await jsonWrite<typeof state>("/api/v1/uploads","POST",{path:dest,size:file.size});}
      }else{
        state=await jsonWrite<typeof state>("/api/v1/uploads","POST",{path:dest,size:file.size});
      }
      sessionStorage.setItem(key,state.id);
      while(state.offset<file.size){
        const chunk=file.slice(state.offset,Math.min(state.offset+4*1024*1024,file.size));
        const response=await fetch(Upload(state.id),{method:"PATCH",credentials:"same-origin",
          headers:{"X-LightIsle-Request":"1","X-Upload-Offset":String(state.offset)},body:chunk});
        if(!response.ok){
          if(response.status===409){state=await jsonGet<typeof state>(Upload(state.id));continue;}
          throw new Error("chunk_error_"+response.status);
        }
        state=await response.json() as typeof state;
        uploadProgress.value=file.name+" · "+Math.round(100*state.offset/Math.max(file.size,1))+"%";
      }
      await jsonWrite(Upload(state.id)+"/complete","POST");
      sessionStorage.removeItem(key);
      uploadProgress.value="";
    }catch(err){
      filesError.value="上传 "+file.name+" 失败："+(err instanceof Error?err.message:"未知错误");
      break;
    }
  }
  input.value="";
  uploadBusy.value=false;
  await loadFiles();
}
async function batchTrash(){
  if(!checkedFiles.value.length)return;
  if(!window.confirm("将选中的 "+checkedFiles.value.length+" 项移到回收站？"))return;
  try{
    const result=await jsonWrite<{results:{success:boolean;path:string}[]}>("/api/v1/files/batch","POST",
      {action:"trash",paths:checkedFiles.value.slice(0,50)});
    const failed=result.results.filter(x=>!x.success).length;
    if(failed)filesError.value=failed+" 项处理失败";
    await loadFiles();
  }catch(e){filesError.value="批量操作失败："+(e instanceof Error?e.message:"未知错误");}
}
function downloadFile(item:FileEntry){
  const a=document.createElement("a");
  a.href="/api/v1/files/content?path="+encodeURIComponent(item.path);
  a.download=item.name;
  a.rel="noopener";
  document.body.appendChild(a);a.click();a.remove();
}
async function removeFile(){
  if(!trashTarget.value)return;
  const name=trashTarget.value.name,filepath=trashTarget.value.path;
  trashTarget.value=null;filesError.value="";
  try{
    const response=await fetch("/api/v1/files?path="+encodeURIComponent(filepath),{
      method:"DELETE",credentials:"same-origin",headers:{"X-LightIsle-Request":"1"}
    });
    if(!response.ok)throw new Error("HTTP "+response.status);
    await loadFiles();
    if(showingTrash.value)await loadTrash();
  }catch(e){filesError.value="移动 "+name+" 到回收站失败："+(e instanceof Error?e.message:"未知错误");}
}
async function jsonGet<T>(endpoint:string):Promise<T> {
  const response=await fetch(endpoint,{cache:"no-store",credentials:"same-origin"});
  if (!response.ok) throw new Error("HTTP "+response.status);
  return await response.json() as T;
}
async function jsonWrite<T>(endpoint:string,method:"POST"|"PATCH",body:object = {}):Promise<T> {
  const response=await fetch(endpoint,{
    method,credentials:"same-origin",
    headers:{"Content-Type":"application/json","X-LightIsle-Request":"1"},
    body:JSON.stringify(body)
  });
  if (!response.ok) {
    const result=await response.json().catch(()=>({error:"request_failed"})) as {error?:string};
    throw new Error(result.error??"request_failed");
  }
  return await response.json() as T;
}
async function checkAuth(){
  authChecking.value=true;
  try {
    const status=await jsonGet<{configured:boolean}>("/api/v1/auth/status");
    configured.value=status.configured;
    if(status.configured){
      try {
        const identity=await jsonGet<{username:string;role:"admin"|"member"}>("/api/v1/auth/me");
        user.value=identity;
        await loadFiles();
        if(identity.role==="admin") await loadAccounts();
      } catch { user.value=null; }
    }
  } catch {authError.value="无法连接本机账户服务，请检查 LightIsle.app 是否已打开。";}
  finally {authChecking.value=false;}
}
async function submitAuth(){
  authError.value="";
  if(!configured.value){authError.value="请先打开 Mac 上的 LightIsle.app 完成管理员初始化。";return;}
  authSubmitting.value=true;
  try {
    const result=await jsonWrite<{username:string;role:"admin"|"member"}>("/api/v1/auth/login","POST",{
      username:authUsername.value,password:authPassword.value
    });
    user.value=result;
    authPassword.value="";
    await update();
    await loadFiles();
    if(result.role==="admin") await loadAccounts();
  } catch(e) {
    const code=e instanceof Error?e.message:"request_failed";
    authError.value=({
      invalid_credentials:"用户名或密码不正确",
      too_many_attempts:"登录尝试过多，请稍后再试",
    } as Record<string,string>)[code]??("操作失败："+code);
  } finally {authSubmitting.value=false;}
}
async function logout(){
  try {await jsonWrite("/api/v1/auth/logout","POST");}catch {/* local service might have closed */}
  user.value=null;stats.value=null;accounts.value=[];active.value="overview";
}
async function loadAccounts(){
  if(user.value?.role!=="admin")return;
  try {
    const result=await jsonGet<{users:Account[]}>("/api/v1/users");
    accounts.value=result.users;
  }catch(e){userError.value="读取账号列表失败";}
}
async function addAccount(){
  userError.value="";userBusy.value=true;
  try{
    await jsonWrite("/api/v1/users","POST",{username:newUsername.value,password:newPassword.value,role:newRole.value});
    newUsername.value="";newPassword.value="";await loadAccounts();
  }catch(e){
    const code=e instanceof Error?e.message:"";
    userError.value=code==="username_exists"?"用户名已存在":code==="invalid_account"?"用户名或密码不满足要求":"创建失败："+code;
  }finally{userBusy.value=false;}
}
async function toggleAccount(account:Account){
  userError.value="";
  try{
    await jsonWrite("/api/v1/users/"+account.id,"PATCH",{enabled:!account.enabled});
    await loadAccounts();
  }catch(e){userError.value="更新账号失败："+(e instanceof Error?e.message:"未知错误");}
}
type ServerStats = {
  timestamp: string; hostname: string; architecture: string;
  cpuCount: number; cpuPercent: number | null;
  memoryTotal: number; memoryUsed: number; diskTotal: number; diskFree: number;
};
type Page = "overview" | "files" | "photos" | "cinema" | "storage" | "settings";
const isEmbedded = new URLSearchParams(location.search).has("embedded");
const items = [
  { key: "overview" as Page, title: "总览", icon: LayoutDashboard },
  { key: "files" as Page, title: "文件", icon: Folder },
  { key: "photos" as Page, title: "图库", icon: Images },
  { key: "cinema" as Page, title: "影视", icon: Clapperboard },
  { key: "storage" as Page, title: "存储", icon: HardDrive },
  { key: "settings" as Page, title: "设置", icon: Settings2 },
];
const startingPage=new URLSearchParams(location.search).get("page");
const active = ref<Page>(startingPage==="settings"?"settings":startingPage==="files"?"files":"overview");
const stats = ref<ServerStats | null>(null);
const error = ref<string | null>(null);
const polling = ref(false);
const theme = ref<Theme>("light");
let interval: number | undefined;
let abortController: AbortController | undefined;

const percent = (value: number) => Math.min(100, Math.max(0, Math.round(value)));
const usedMemory = computed(() => stats.value ? stats.value.memoryUsed / stats.value.memoryTotal * 100 : null);
const usedDisk = computed(() => stats.value ? (stats.value.diskTotal - stats.value.diskFree) / stats.value.diskTotal * 100 : null);
const cpu = computed(() => stats.value?.cpuPercent ?? null);
function bytes(value: number): string {
  if (!Number.isFinite(value)) return "—";
  const units = ["B", "GB", "TB", "PB"];
  if (value < 1024 * 1024 * 1024) return (value / (1024 * 1024)).toFixed(1) + " MB";
  let n = value / (1024 * 1024 * 1024), i = 1;
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
  return n.toFixed(n < 10 ? 1 : 0) + " " + units[i];
}
async function update() {
  if(!user.value)return;
  if (polling.value) return;
  polling.value = true;
  abortController?.abort();
  const controller = new AbortController();
  abortController = controller;
  try {
    const res = await fetch("/api/v1/system", { cache: "no-store", signal: controller.signal });
    if (!res.ok) throw new Error("HTTP " + res.status);
    stats.value = await res.json() as ServerStats;
    error.value = null;
  } catch (e) {
    if (!controller.signal.aborted) error.value = e instanceof Error ? e.message : "连接失败";
  } finally { polling.value = false; }
}
function switchTheme() {
  theme.value = theme.value === "light" ? "dark" : "light";
  applyTheme(theme.value);
}
onMounted(() => {
  const isDark = matchMedia("(prefers-color-scheme: dark)").matches;
  theme.value = isDark ? "dark" : "light";
  applyTheme(theme.value);
  void checkAuth();
  interval = window.setInterval(() => {if(user.value)void update();}, 5000);
});
onUnmounted(() => { if (interval) clearInterval(interval); abortController?.abort(); });
watch(active,(next)=>{if(next==="files"&&user.value)void loadFiles();});
</script>

<template>
  <div v-if="authChecking" class="auth-scene">
    <div class="auth-card" style="text-align: center; align-items: center;">
      <div class="auth-logo"><img src="/brand-icon.svg" alt="轻屿 Logo" class="brand-image" /></div>
      <h2>轻屿 LightIsle</h2>
      <p>正在读取本机账户安全状态…</p>
    </div>
  </div>
  <div v-else-if="!configured" class="auth-scene">
    <div class="auth-card">
      <div class="auth-logo"><img src="/brand-icon.svg" alt="轻屿 Logo" class="brand-image" /></div>
      <span class="eyebrow">FIRST RUN SETUP</span>
      <h1>请先在 Mac 上初始化轻屿</h1>
      <p>首次管理员账号必须在 LightIsle.app 的原生初始化页面创建。Web 只提供用户登录、文件、相册与影视服务，不向外开放未授权注册。</p>
      <button type="button" class="auth-submit" @click="checkAuth">已在 Mac 完成初始化，刷新状态</button>
      <small>管理员创建其他成员账号的入口位于登录后的 Web「设置」中。</small>
    </div>
  </div>
  <div v-else-if="!user" class="auth-scene">
    <form class="auth-card" @submit.prevent="submitAuth">
      <div class="auth-logo"><img src="/brand-icon.svg" alt="轻屿 Logo" class="brand-image" /></div>
      <span class="eyebrow">YOUR PRIVATE SPACE</span>
      <h1>欢迎回到轻屿</h1>
      <p>使用管理员在 Mac 初始化或之后创建的账号登录你的私人空间。</p>
      <label>用户名<input v-model.trim="authUsername" required maxlength="32" minlength="3" autocomplete="username" placeholder="输入账号用户名" /></label>
      <label>密码<input v-model="authPassword" required type="password" minlength="12" autocomplete="current-password" placeholder="输入至少 12 位密码" /></label>
      <p v-if="authError" class="form-error" role="alert">{{ authError }}</p>
      <button class="auth-submit" :disabled="authSubmitting" type="submit">{{ authSubmitting ? "正在验证…" : "登录轻屿空间" }}</button>
      <small>数据安全保护 · 原片与文件均存放于本地 Mac</small>
    </form>
  </div>
  <div v-else class="shell" :class="{ embedded: isEmbedded }">
    <aside v-if="!isEmbedded" class="sidebar">
      <div class="brand"><span class="brand-symbol"><img src="/brand-icon.svg" alt="轻屿 Logo" class="brand-image" /></span><span><b>轻屿</b><small>LightIsle</small></span></div>
      <span class="side-label">工作空间</span>
      <nav aria-label="主导航" class="side-nav">
        <button v-for="item in items" :key="item.key" :class="{ chosen: active === item.key }" @click="active = item.key" type="button">
          <component :is="item.icon" :size="18" :stroke-width="1.9" /><span>{{ item.title }}</span>
        </button>
      </nav>
      <div class="sidebar-bottom"><span class="dot" :class="{ off: !!error }"></span><span>{{ error ? "服务已断开" : "已登录 · " + user.username }}</span></div>
    </aside>

    <main class="main">
      <header v-if="!isEmbedded" class="topbar glass">
        <div class="breadcrumb"><img src="/brand-icon.svg" alt="" class="breadcrumb-logo" /><span>LightIsle</span><span class="crumb-slash">/</span><strong>{{ items.find(i => i.key === active)?.title }}</strong></div>
        <div class="top-actions">
          <span class="local-pill">{{ user.username }} · {{ user.role === "admin" ? "管理员" : "普通用户" }}</span>
          <button class="refresh" type="button" @click="logout">退出登录</button>
          <span class="local-pill"><ShieldCheck :size="14" /> 账户保护</span>
          <button class="circle-action" type="button" @click="switchTheme" :aria-label="theme === 'dark' ? '切换浅色' : '切换深色'">
            <Sun v-if="theme === 'dark'" :size="18" /><Moon v-else :size="18" />
          </button>
        </div>
      </header>

      <Transition name="ios-fade" mode="out-in">
        <div :key="active">
          <div v-if="active === 'overview'" class="content">
            <div class="hero">
              <div class="hero-text">
                <p class="eyebrow">YOUR PERSONAL SPACE</p>
                <h1>让每一份珍贵，<br /><span>都有自己的栖息之地。</span></h1>
                <p class="hero-desc">轻屿将文件、照片与影像收纳于你的 Mac。轻巧、安全，尽在掌握。</p>
                <div class="hero-actions"><span class="hero-status"><span class="dot" :class="{ off: !!error }"></span>{{ error ? "核心连接异常" : "本机服务运行中" }}</span><span class="version">M1 · 预览版本</span></div>
              </div>
              <div class="hero-art" aria-hidden="true">
                <div class="orb orb-a"></div><div class="orb orb-b"></div><div class="orb orb-c"></div>
                <div class="hero-glass"><img src="/brand-icon.svg" alt="" class="hero-brand-image" /></div>
              </div>
            </div>

            <div class="section-heading"><div><h2>设备概览</h2><p>实时了解这台 Mac 的运行情况</p></div><button class="refresh" type="button" @click="update" :disabled="polling"><RefreshCcw :size="16" :class="{ spinning: polling }" /> 刷新</button></div>
            <div v-if="error" class="error-notice"><WifiOff :size="17" /> 无法读取系统状态：{{ error }}。请确认 Mac App 仍在运行。</div>
            <section class="stat-grid" aria-label="系统指标">
              <div class="metric-card">
                <div class="metric-top"><span class="metric-icon violet"><Activity :size="19" /></span><span class="metric-category">处理器</span></div>
                <div class="metric-value">{{ cpu == null ? '—' : percent(cpu) + '%' }}</div>
                <div class="metric-sub">Apple Silicon · {{ stats?.cpuCount ?? '—' }} 核</div>
                <div class="progress-track"><div class="progress-bar purple" :style="{ width: cpu == null ? '0' : percent(cpu) + '%' }"></div></div>
              </div>
              <div class="metric-card">
                <div class="metric-top"><span class="metric-icon blue"><Server :size="19" /></span><span class="metric-category">内存</span></div>
                <div class="metric-value">{{ usedMemory == null ? '—' : percent(usedMemory) + '%' }}</div>
                <div class="metric-sub">{{ stats ? bytes(stats.memoryUsed) + ' / ' + bytes(stats.memoryTotal) : '等待采集' }}</div>
                <div class="progress-track"><div class="progress-bar bright-blue" :style="{ width: usedMemory == null ? '0' : percent(usedMemory) + '%' }"></div></div>
              </div>
              <div class="metric-card">
                <div class="metric-top"><span class="metric-icon teal"><HardDrive :size="19" /></span><span class="metric-category">系统存储</span></div>
                <div class="metric-value">{{ usedDisk == null ? '—' : percent(usedDisk) + '%' }}</div>
                <div class="metric-sub">{{ stats ? bytes(stats.diskFree) + ' 可用' : '等待采集' }}</div>
                <div class="progress-track"><div class="progress-bar aqua" :style="{ width: usedDisk == null ? '0' : percent(usedDisk) + '%' }"></div></div>
              </div>
              <div class="metric-card">
                <div class="metric-top"><span class="metric-icon orange"><Monitor :size="19" /></span><span class="metric-category">运行环境</span></div>
                <div class="metric-value small">macOS</div>
                <div class="metric-sub">{{ stats?.architecture ?? 'darwin/arm64' }}</div>
                <div class="progress-track"><div class="progress-bar amber" style="width: 100%"></div></div>
              </div>
            </section>

            <div class="section-heading apps-heading"><div><h2>你的空间</h2><p>所有重要的数字生活，从这里开始</p></div><span class="planned-tag">文件与图库开发版</span></div>
            <div class="feature-grid">
              <button type="button" class="feature-card" @click="active = 'files'"><span class="feature-icon file"><Folder :size="23" /></span><div><h3>文件</h3><p>管理与分享所有文件</p></div><ArrowUpRight :size="17" class="feature-arrow" /></button>
              <button type="button" class="feature-card" @click="active = 'photos'"><span class="feature-icon photos"><Images :size="23" /></span><div><h3>图库</h3><p>珍藏每一个精彩瞬间</p></div><ArrowUpRight :size="17" class="feature-arrow" /></button>
              <button type="button" class="feature-card" @click="active = 'cinema'"><span class="feature-icon cinema"><Clapperboard :size="23" /></span><div><h3>影视</h3><p>打造自己的私人影院</p></div><ArrowUpRight :size="17" class="feature-arrow" /></button>
            </div>

            <div class="footnote"><ShieldCheck :size="15" /> <span>基础文件管理已开放；图库、影视等功能接入本地 Mac 目录。所有操作均受安全会话保护。</span></div>
          </div>
          <div v-else-if="active === 'files'" class="content">
            <div class="section-heading">
              <div><h2>文件管理 · {{ sharedRootName }}</h2><p>按页浏览、续传上传及回收站；仅操作已授权的共享目录。</p></div>
              <button class="refresh" type="button" @click="loadFiles()" :disabled="filesLoading"><RefreshCcw :size="16" /> 刷新</button>
            </div>
            <section class="files-panel">
              <div class="files-toolbar">
                <div class="file-crumbs" aria-label="当前位置">
                  <button v-for="(segment,index) in pathSegments" :key="segment.path" type="button" @click="loadFiles(segment.path)">
                    <ChevronRight v-if="index" :size="14" /><span>{{ segment.name }}</span>
                  </button>
                </div>
                <div class="file-actions">
                  <button type="button" @click="openTrash"><Trash2 :size="16"/> {{ showingTrash ? "退出回收站" : "回收站" }}</button>
                  <button type="button" @click="selectedUpload?.click()" :disabled="uploadBusy"><UploadCloud :size="16" /> {{ uploadBusy ? "上传中…" : "上传文件" }}</button>
                  <input ref="selectedUpload" type="file" class="visually-hidden" multiple @change="uploadSelected" />
                  <button type="button" @click="loadFiles()" :disabled="filesLoading"><RefreshCcw :size="16" /> 刷新</button>
                </div>
              </div>
              <div v-if="uploadProgress" class="scan-banner">{{uploadProgress}}</div>
              <div v-if="checkedFiles.length && !showingTrash" class="file-batch-bar">
                <span>已选 {{checkedFiles.length }} 项（每次最多 50 项）</span>
                <button type="button" @click="batchTrash" :disabled="checkedFiles.length>50"><Trash2 :size="15"/> 批量移到回收站</button>
              </div>
              <form v-if="!showingTrash" class="create-folder-form" @submit.prevent="makeFolder">
                <FolderPlus :size="18" />
                <input v-model="newFolderName" maxlength="150" placeholder="新建文件夹名称" aria-label="新建文件夹名称" />
                <button :disabled="!newFolderName.trim()" type="submit">新建文件夹</button>
              </form>
              <div v-if="filesError" class="error-notice" role="alert">{{ filesError }}</div>
              <div v-if="showingTrash" class="trash-list">
                <div v-if="trashItems.length===0" class="files-empty">回收站是空的</div>
                <div v-for="entry in trashItems" :key="entry.id" class="file-entry">
                  <div class="file-name"><strong>{{ entry.name }}</strong><small>原路径：{{ entry.originalPath }} · {{ new Date(entry.deletedAt).toLocaleString() }}</small></div>
                  <button type="button" class="account-action" @click="restoreTrash(entry)">恢复</button>
                </div>
              </div>
              <div v-if="!showingTrash && filesPath !== '.'" class="file-entry" role="button" tabindex="0" @click="goUp" @keydown.enter="goUp">
                <span class="file-icon"><ChevronLeft :size="22" /></span>
                <div class="file-name"><strong>返回上一级</strong><small>..</small></div>
              </div>
              <div v-if="!showingTrash && filesLoading" class="files-empty">正在读取目录…</div>
              <div v-else-if="!showingTrash && !fileEntries.length" class="files-empty"><Folder :size="30"/><span>此文件夹目前是空的</span></div>
              <div v-for="entry in showingTrash ? [] : fileEntries" :key="entry.path" class="file-entry">
                <input type="checkbox" :value="entry.path" v-model="checkedFiles" :aria-label="'选择 '+entry.name" class="file-checkbox"/>
                <button type="button" class="file-open" @click="entry.type === 'folder' ? loadFiles(entry.path) : previewFile(entry)" :title="entry.name">
                  <span class="file-icon" :class="entry.type"><Folder v-if="entry.type === 'folder'" :size="21"/><FileText v-else :size="20"/></span>
                  <span class="file-name"><strong>{{ entry.name }}</strong><small>{{ entry.type === "folder" ? "文件夹" : bytes(entry.size) }} · {{ new Date(entry.modified).toLocaleString() }}</small></span>
                </button>
                <div class="file-entry-actions">
                  <button v-if="entry.type === 'file'" type="button" @click="previewFile(entry)" title="预览"><Images :size="17"/></button>
                  <button v-if="entry.type === 'file'" type="button" @click="downloadFile(entry)" title="下载"><Download :size="17"/></button>
                  <button type="button" @click="trashTarget=entry" title="移到回收站"><Trash2 :size="17"/></button>
                </div>
              </div>
              <div v-if="!showingTrash && fileNextCursor" class="gallery-load">
                <button type="button" :disabled="filesLoading" @click="loadFiles(filesPath,true)">{{filesLoading?"加载中…":"加载更多文件"}}</button>
              </div>
            </section>
            <p class="footnote">支持断点续传上传，照片和视频预览按格式支持。每次批量删除最多 50 项，恢复不会覆盖现有文件。</p>
          </div>
          <PhotosView v-else-if="active === 'photos'" :admin="user.role==='admin'" />
          <CinemaView v-else-if="active === 'cinema'" :admin="user.role==='admin'" />
          <div v-else-if="active === 'settings'" class="content">
            <div class="section-heading"><div><h2>账号与权限</h2><p>管理员可以创建其他账号并控制账号是否有效。</p></div><button class="refresh" @click="logout">退出登录</button></div>
            <div v-if="user.role === 'admin'" class="account-manager">
              <section class="account-panel">
                <h3>创建新成员账号</h3>
                <p>新账号默认是普通用户。只有管理员能添加账号，禁止外部公开注册。</p>
                <form class="account-form" @submit.prevent="addAccount">
                  <label>用户名<input v-model.trim="newUsername" placeholder="3–32 位英文字母、数字等" minlength="3" maxlength="32" required /></label>
                  <label>初始密码<input v-model="newPassword" type="password" minlength="12" placeholder="至少 12 位密码" required /></label>
                  <label>用户角色<select v-model="newRole"><option value="member">普通用户</option><option value="admin">管理员</option></select></label>
                  <button type="submit" class="auth-submit" :disabled="userBusy">{{ userBusy ? "正在处理…" : "确认添加账号" }}</button>
                </form>
                <p v-if="userError" class="form-error">{{ userError }}</p>
              </section>
              <section class="account-panel">
                <div class="account-heading"><h3>已有空间成员</h3><button type="button" class="refresh" @click="loadAccounts">刷新</button></div>
                <div v-for="account in accounts" :key="account.id" class="account-row">
                  <div><strong>{{ account.username }}</strong><small>{{ account.role === "admin" ? "管理员" : "普通用户" }} · {{ account.enabled ? "已启用" : "已停用" }}</small></div>
                  <button v-if="account.id!==1 && account.username !== user.username" class="account-action" @click="toggleAccount(account)">{{ account.enabled ? "停用" : "启用" }}</button>
                  <span v-else class="protected-account">受保护</span>
                </div>
              </section>
            </div>
            <div v-else class="account-panel"><h3>当前用户</h3><p>{{ user.username }}（普通用户）</p><p>账号由管理员统一创建和维护。</p></div>
          </div>
          <div v-else class="content"><div class="empty-panel"><CloudOff :size="38" :stroke-width="1.4" /><h2>{{ items.find(i => i.key === active)?.title }} 正在开发</h2><p>该模块将在 LightIsle 的后续里程碑上线。目前此页面仅展示产品结构，不会对你的文件执行任何操作。</p><button type="button" @click="active='overview'">返回总览 <ArrowDownToLine class="back-icon" :size="15" /></button></div></div>
        </div>
      </Transition>
    </main>
    <div v-if="trashTarget" class="dialog-backdrop" @click.self="trashTarget=null">
      <div class="confirm-dialog" role="alertdialog" aria-modal="true" aria-label="移到回收站">
        <div class="dialog-symbol"><Trash2 :size="23" /></div>
        <h3>移到回收站？</h3>
        <p>“{{ trashTarget.name }}”将从共享目录移至内部回收站，暂不会永久删除。</p>
        <div class="dialog-buttons"><button type="button" @click="trashTarget=null">取消</button><button class="destructive" type="button" @click="removeFile">确认移入</button></div>
      </div>
    </div>
    <div v-if="previewItem" class="dialog-backdrop" @click.self="previewItem=null">
      <div class="preview-dialog" role="dialog" aria-modal="true" aria-label="文件预览">
        <div class="preview-toolbar"><strong>{{ previewItem.name }}</strong><button type="button" @click="previewItem=null">关闭</button></div>
        <p v-if="previewError" class="form-error">{{ previewError }}</p>
        <pre v-else-if="/\.(txt|md|json|log)$/i.test(previewItem.name)" class="preview-text">{{ previewText }}</pre>
        <img v-else-if="/\.(jpe?g|png|gif|webp)$/i.test(previewItem.name)" :src="previewURL" :alt="previewItem.name" class="preview-image"/>
        <video v-else-if="/\.(mp4|webm|m4v)$/i.test(previewItem.name)" :src="previewURL" controls playsinline class="preview-video"/>
      </div>
    </div>
    <nav v-if="!isEmbedded" class="mobile-nav glass" aria-label="移动导航">
      <button v-for="item in items.slice(0, 5)" :key="item.key" type="button" :class="{ chosen: active === item.key }" @click="active = item.key">
        <component :is="item.icon" :size="20" /><span>{{ item.title }}</span>
      </button>
    </nav>
  </div>
</template>

