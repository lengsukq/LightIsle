package server

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"html"
	"net/http"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

const collectDropPageTemplate = `<!doctype html>
<html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow,noarchive">
<title>{{TITLE}} · LightIsle 文件收集</title>
<style>
:root{color-scheme:light dark;--bg-top:#F7F6F3;--bg-btm:#F1EFEA;--card:#FFFFFF;--surface-soft:#F7F6F3;--border:#E7E4DD;--text:#1C1B19;--muted:#63605B;--accent:#0E6B74;--accent-fg:#FFFFFF;--danger:#B91C1C;--ok:#15803D;--drop:rgba(14,107,116,.08);--shadow:0 14px 36px rgba(28,27,25,.06)}
@media (prefers-color-scheme:dark){:root{--bg-top:#0E0E0D;--bg-btm:#131311;--card:#191917;--surface-soft:#22221F;--border:#2E2E2A;--text:#F2F0EC;--muted:#A6A29B;--accent:#5CC8D4;--accent-fg:#0E0E0D;--danger:#FCA5A5;--ok:#4ADE80;--drop:rgba(92,200,212,.14);--shadow:0 16px 40px rgba(0,0,0,.42)}}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:grid;place-items:center;padding:20px;background:linear-gradient(180deg,var(--bg-top) 0%,var(--bg-btm) 100%);color:var(--text);font:14px/1.55 -apple-system,BlinkMacSystemFont,"PingFang SC","SF Pro Text",sans-serif;font-variant-numeric:tabular-nums}
main{width:min(100%,520px);background:var(--card);border:1px solid var(--border);border-radius:18px;padding:26px;box-shadow:var(--shadow)}
.badge{display:inline-block;padding:3px 10px;border-radius:999px;font-size:11.5px;font-weight:600;background:var(--drop);color:var(--accent);margin-bottom:10px}
h1{font-size:20px;margin:0 0 6px;word-break:break-word;letter-spacing:-0.01em}
.meta{margin:0 0 18px;color:var(--muted);font-size:12.5px}
.box{border:1.5px dashed var(--border);border-radius:14px;padding:28px 18px;text-align:center;cursor:pointer;transition:border-color .15s ease,background-color .15s ease;background:var(--surface-soft)}
.box:hover,.box.drag{border-color:var(--accent);background:var(--drop)}
.box:focus-visible,button:focus-visible,input:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.box strong{display:block;font-size:15px;margin-bottom:4px}
.box span{color:var(--muted);font-size:12.5px}
input[type=file]{display:none}
.field{margin-bottom:12px}
.field label{display:block;font-size:12.5px;color:var(--muted);margin-bottom:6px}
.field input{width:100%;padding:11px 12px;border-radius:10px;border:1px solid var(--border);background:var(--surface-soft);color:var(--text);font-size:14px}
button{border:0;border-radius:10px;padding:11px 16px;background:var(--accent);color:var(--accent-fg);font-size:14px;font-weight:600;cursor:pointer;width:100%;transition:opacity .15s ease}
button:hover:not(:disabled){opacity:.92}
button:disabled{opacity:.55;cursor:not-allowed}
.err{color:var(--danger);font-size:12.5px;margin:8px 0 0;min-height:18px}
.list{margin-top:16px;display:flex;flex-direction:column;gap:10px}
.item{border:1px solid var(--border);border-radius:12px;padding:10px 12px;background:var(--card)}
.row{display:flex;justify-content:space-between;gap:8px;font-size:13px;align-items:center}
.name{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.st{font-size:12px;color:var(--muted);flex-shrink:0}
.st.ok{color:var(--ok)}.st.fail{color:var(--danger)}
.bar{height:6px;border-radius:999px;background:var(--border);overflow:hidden;margin-top:7px}
.bar>i{display:block;height:100%;width:0;background:var(--accent);transition:width .15s ease}
.bar>i.ok{background:var(--ok)}.bar>i.fail{background:var(--danger)}
.foot{margin-top:18px;font-size:11.5px;color:var(--muted);text-align:center}
.hidden{display:none}
@media (prefers-reduced-motion:reduce){*,*::before,*::after{transition-duration:.01ms!important;animation-duration:.01ms!important}}
</style></head><body><main>
<span class="badge">仅投递 · 不可查看已有文件</span>
<h1>{{TITLE}}</h1>
<p id="metaInfo" class="meta">{{META}}</p>
<section id="gate" class="{{GATE_CLASS}}">
  <form id="authForm">
    <div class="field">
      <label for="pwd">访问口令</label>
      <input id="pwd" type="password" autocomplete="off" placeholder="请输入创建者设置的投递口令" required>
    </div>
    <button id="authBtn" type="submit">验证并开始投递</button>
    <p id="authErr" class="err"></p>
  </form>
</section>
<section id="dropWrap" class="{{DROP_CLASS}}">
  <div id="dropZone" class="box" role="button" tabindex="0">
    <strong>点击选择文件，或拖拽照片/视频到此处</strong>
    <span>支持多文件分片续传 · 重名自动保留双方文件，绝不覆盖</span>
    <input id="fileInput" type="file" multiple {{ACCEPT}}>
  </div>
  <p id="dropErr" class="err"></p>
  <div id="fileList" class="list"></div>
</section>
<p class="foot">LightIsle 家庭安全收集箱 · 仅写入目标文件夹，目录内容对访客完全不可见。</p>
</main>
<script nonce="{{NONCE}}">
(function(){
  const cfg = {{CONFIG_JSON}};
  const gate = document.getElementById("gate");
  const dropWrap = document.getElementById("dropWrap");
  const authForm = document.getElementById("authForm");
  const authBtn = document.getElementById("authBtn");
  const authErr = document.getElementById("authErr");
  const dropZone = document.getElementById("dropZone");
  const fileInput = document.getElementById("fileInput");
  const fileList = document.getElementById("fileList");
  const dropErr = document.getElementById("dropErr");
  const metaInfo = document.getElementById("metaInfo");

  const MAX_CONCURRENCY = 3;
  const MAX_CHUNK_RETRIES = 3;
  const MAX_OFFSET_ALIGNMENTS = 5;
  const pendingQueue = [];
  let activeUploads = 0;
  let dragDepth = 0;

  function headers(extra){
    return Object.assign({"X-LightIsle-Request":"1"}, extra || {});
  }
  function fmtSize(n){
    if(n>=1073741824) return (n/1073741824).toFixed(2)+" GB";
    if(n>=1048576) return (n/1048576).toFixed(1)+" MB";
    if(n>=1024) return (n/1024).toFixed(1)+" KB";
    return n+" B";
  }
  function fmtExpiry(ts){
    const d=new Date(ts*1000);
    const pad=function(v){return String(v).padStart(2,"0");};
    return d.getFullYear()+"-"+pad(d.getMonth()+1)+"-"+pad(d.getDate())+" "+pad(d.getHours())+":"+pad(d.getMinutes());
  }
  function sleep(ms){
    return new Promise(function(resolve){setTimeout(resolve, ms);});
  }
  function requireReauth(){
    pendingQueue.length = 0;
    gate.classList.remove("hidden");
    dropWrap.classList.add("hidden");
    authErr.textContent = "投递会话已过期，请重新输入访问口令";
    const pwdEl = document.getElementById("pwd");
    if(pwdEl){pwdEl.value="";pwdEl.focus();}
  }
  async function readErr(res, fallback){
    try{const j=await res.json(); return j.message || j.error || fallback;}catch(_){return fallback;}
  }
  async function refreshQuotaMeta(){
    if(!metaInfo) return;
    try{
      const res = await fetch(cfg.base+"?format=json",{cache:"no-store",credentials:"same-origin"});
      if(res.status===401){requireReauth();return;}
      if(!res.ok) return;
      const info = await res.json();
      const parts = ["有效期至 "+fmtExpiry(info.expiresAt)];
      if(info.maxFiles>0 && typeof info.remainingFiles==="number"){
        parts.push("剩余可投递 "+info.remainingFiles+" 个文件");
      }
      if(info.maxFileBytes>0){
        parts.push("单文件上限 "+fmtSize(info.maxFileBytes));
      }
      if(info.maxTotalBytes>0 && typeof info.remainingBytes==="number"){
        parts.push("剩余容量 "+fmtSize(info.remainingBytes));
      }
      if(Array.isArray(info.allowedExts) && info.allowedExts.length>0){
        parts.push("仅限格式 "+info.allowedExts.join(" / "));
      }
      metaInfo.textContent = parts.join(" · ");
    }catch(_){}
  }

  if(authForm){
    authForm.addEventListener("submit", async function(ev){
      ev.preventDefault();
      authErr.textContent="";
      authBtn.disabled=true;
      try{
        const pwd=document.getElementById("pwd").value;
        const res=await fetch(cfg.base+"/auth",{method:"POST",headers:headers({"Content-Type":"application/json"}),body:JSON.stringify({password:pwd})});
        if(!res.ok){authErr.textContent=await readErr(res,"口令验证失败，请重试");return;}
        gate.classList.add("hidden");
        dropWrap.classList.remove("hidden");
        refreshQuotaMeta();
      }catch(_){authErr.textContent="网络异常，请稍后重试";}
      finally{authBtn.disabled=false;}
    });
  }

  async function sendChunkWithRetry(uploadId, file, offset, chunk){
    let attempt = 0;
    while(true){
      const slice = file.slice(offset, Math.min(offset+chunk, file.size));
      let patchRes;
      try{
        patchRes = await fetch(cfg.base+"/uploads/"+encodeURIComponent(uploadId),{
          method:"PATCH",
          headers:headers({"X-Upload-Offset":String(offset),"Content-Type":"application/octet-stream"}),
          body:slice
        });
      }catch(_){
        attempt++;
        if(attempt>MAX_CHUNK_RETRIES){throw new Error("网络中断，分片上传失败");}
        await sleep(400*attempt);
        continue;
      }
      if(patchRes.status===401){
        requireReauth();
        throw new Error("投递会话已过期，请重新验证口令");
      }
      if(patchRes.status===409){
        const body = await patchRes.json().catch(function(){return {};});
        const hdrOffset = Number(patchRes.headers.get("X-Upload-Offset"));
        const nextOffset = (body && typeof body.offset==="number") ? body.offset : (Number.isFinite(hdrOffset) ? hdrOffset : -1);
        if(body && body.error==="offset_mismatch" && nextOffset>=0){
          return {aligned:true, offset:nextOffset};
        }
        throw new Error((body && (body.message||body.error)) || "上传进度冲突");
      }
      if((patchRes.status>=500 || patchRes.status===429) && attempt<MAX_CHUNK_RETRIES){
        attempt++;
        await sleep(400*attempt);
        continue;
      }
      if(!patchRes.ok){throw new Error(await readErr(patchRes,"分片上传失败"));}
      const ps = await patchRes.json();
      return {aligned:false, offset:ps.offset};
    }
  }

  async function uploadJob(job){
    const file = job.file;
    const st = job.st;
    const fill = job.fill;
    st.textContent = "准备中…";

    let uploadId="";
    try{
      const beginRes=await fetch(cfg.base+"/uploads",{
        method:"POST",
        headers:headers({"Content-Type":"application/json"}),
        body:JSON.stringify({filename:file.name,size:file.size})
      });
      if(!beginRes.ok){
        if(beginRes.status===401){requireReauth();}
        throw new Error(await readErr(beginRes,"无法开始上传"));
      }
      const meta=await beginRes.json();
      uploadId=meta.uploadId;
      const chunk=meta.chunkSize || 4194304;
      let offset=meta.offset || 0;
      let alignments=0;
      while(offset<file.size){
        const res = await sendChunkWithRetry(uploadId, file, offset, chunk);
        if(res.aligned){
          alignments++;
          if(alignments>MAX_OFFSET_ALIGNMENTS){throw new Error("分片偏移校准失败，请重试");}
        }
        offset = res.offset;
        const pct=file.size>0?Math.min(100,Math.round(offset*100/file.size)):100;
        fill.style.width=pct+"%";
        st.textContent=pct+"%";
      }
      st.textContent="正在完成…";
      const doneRes=await fetch(cfg.base+"/uploads/"+encodeURIComponent(uploadId)+"/complete",{
        method:"POST",headers:headers()
      });
      if(!doneRes.ok){
        if(doneRes.status===401){requireReauth();}
        throw new Error(await readErr(doneRes,"提交失败"));
      }
      fill.style.width="100%";fill.classList.add("ok");
      st.classList.add("ok");st.textContent="已投递";
      refreshQuotaMeta();
    }catch(e){
      fill.classList.add("fail");st.classList.add("fail");
      st.textContent=e && e.message ? e.message : "上传失败";
      if(uploadId){fetch(cfg.base+"/uploads/"+encodeURIComponent(uploadId),{method:"DELETE",headers:headers()}).catch(function(){});}
    }
  }

  function pumpQueue(){
    while(activeUploads<MAX_CONCURRENCY && pendingQueue.length>0){
      const job = pendingQueue.shift();
      activeUploads++;
      uploadJob(job).finally(function(){
        activeUploads--;
        pumpQueue();
      });
    }
  }

  function handleFiles(files){
    dropErr.textContent="";
    for(const file of Array.from(files||[])){
      const card=document.createElement("div");
      card.className="item";
      const row=document.createElement("div");row.className="row";
      const nm=document.createElement("span");nm.className="name";nm.textContent=file.name+" ("+fmtSize(file.size)+")";
      const st=document.createElement("span");st.className="st";st.textContent="排队中…";
      row.appendChild(nm);row.appendChild(st);
      const bar=document.createElement("div");bar.className="bar";
      const fill=document.createElement("i");bar.appendChild(fill);
      card.appendChild(row);card.appendChild(bar);
      fileList.prepend(card);
      pendingQueue.push({file:file,st:st,fill:fill});
    }
    pumpQueue();
  }

  if(dropZone){
    dropZone.addEventListener("click",function(){fileInput.click();});
    dropZone.addEventListener("keydown",function(e){if(e.key==="Enter"||e.key===" "){e.preventDefault();fileInput.click();}});
    dropZone.addEventListener("dragenter",function(e){e.preventDefault();dragDepth++;dropZone.classList.add("drag");});
    dropZone.addEventListener("dragover",function(e){e.preventDefault();dropZone.classList.add("drag");});
    dropZone.addEventListener("dragleave",function(){dragDepth=Math.max(0,dragDepth-1);if(dragDepth===0)dropZone.classList.remove("drag");});
    dropZone.addEventListener("drop",function(e){e.preventDefault();dragDepth=0;dropZone.classList.remove("drag");handleFiles(e.dataTransfer.files);});
    fileInput.addEventListener("change",function(){handleFiles(fileInput.files);fileInput.value="";});
  }
})();
</script></body></html>`

func renderCollectDropPage(w http.ResponseWriter, basePath string, access auth.CollectLinkAccess, unlocked bool) {
	nonceBytes := make([]byte, 16)
	if _, err := rand.Read(nonceBytes); err != nil {
		http.Error(w, "service unavailable", http.StatusInternalServerError)
		return
	}
	nonce := base64.RawURLEncoding.EncodeToString(nonceBytes)

	parts := []string{"有效期至 " + time.Unix(access.ExpiresAt, 0).Format("2006-01-02 15:04")}
	if access.MaxFiles > 0 {
		rem := access.MaxFiles - access.UploadedFiles
		if rem < 0 {
			rem = 0
		}
		parts = append(parts, fmt.Sprintf("剩余可投递 %d 个文件", rem))
	}
	if access.MaxFileBytes > 0 {
		parts = append(parts, "单文件上限 "+formatShareSize(access.MaxFileBytes))
	}
	if access.MaxTotalBytes > 0 {
		rem := access.MaxTotalBytes - access.UploadedBytes
		if rem < 0 {
			rem = 0
		}
		parts = append(parts, "剩余容量 "+formatShareSize(rem))
	}
	acceptAttr := ""
	if len(access.AllowedExts) > 0 {
		parts = append(parts, "仅限格式 "+strings.Join(access.AllowedExts, " / "))
		acceptAttr = `accept="` + html.EscapeString(strings.Join(access.AllowedExts, ",")) + `"`
	}

	cfgBytes, _ := json.Marshal(map[string]any{"base": basePath})
	gateClass := "hidden"
	dropClass := ""
	if len(access.PasswordHash) > 0 && !unlocked {
		gateClass = ""
		dropClass = "hidden"
	}

	body := collectDropPageTemplate
	body = strings.ReplaceAll(body, "{{TITLE}}", html.EscapeString(access.Title))
	body = strings.ReplaceAll(body, "{{META}}", html.EscapeString(strings.Join(parts, " · ")))
	body = strings.ReplaceAll(body, "{{GATE_CLASS}}", gateClass)
	body = strings.ReplaceAll(body, "{{DROP_CLASS}}", dropClass)
	body = strings.ReplaceAll(body, "{{ACCEPT}}", acceptAttr)
	body = strings.ReplaceAll(body, "{{NONCE}}", nonce)
	body = strings.ReplaceAll(body, "{{CONFIG_JSON}}", string(cfgBytes))

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'nonce-"+nonce+"'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Robots-Tag", "noindex,nofollow,noarchive")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(body))
}
