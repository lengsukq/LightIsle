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
:root{color-scheme:light dark;--bg:#f5f5f7;--card:#ffffff;--border:#e5e5ea;--text:#1d1d1f;--muted:#6e6e73;--accent:#0071e3;--danger:#d70015;--ok:#1e8e3e;--drop:#f0f6ff}
@media (prefers-color-scheme:dark){:root{--bg:#101319;--card:#1a1f29;--border:#2c3442;--text:#f2f4f8;--muted:#9aa4b5;--accent:#0a84ff;--danger:#ff6961;--ok:#30d158;--drop:#162233}}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:grid;place-items:center;padding:20px;background:var(--bg);color:var(--text);font:14px/1.55 -apple-system,BlinkMacSystemFont,"PingFang SC","SF Pro Text",sans-serif}
main{width:min(100%,520px);background:var(--card);border:1px solid var(--border);border-radius:18px;padding:26px;box-shadow:0 12px 32px rgba(0,0,0,.08)}
.badge{display:inline-block;padding:3px 10px;border-radius:999px;font-size:11.5px;font-weight:600;background:var(--drop);color:var(--accent);margin-bottom:10px}
h1{font-size:20px;margin:0 0 6px;word-break:break-word}
.meta{margin:0 0 18px;color:var(--muted);font-size:12.5px}
.box{border:1.5px dashed var(--border);border-radius:14px;padding:28px 18px;text-align:center;cursor:pointer;transition:.15s;background:transparent}
.box.drag{border-color:var(--accent);background:var(--drop)}
.box strong{display:block;font-size:15px;margin-bottom:4px}
.box span{color:var(--muted);font-size:12.5px}
input[type=file]{display:none}
.field{margin-bottom:12px}
.field label{display:block;font-size:12.5px;color:var(--muted);margin-bottom:6px}
.field input{width:100%;padding:11px 12px;border-radius:10px;border:1px solid var(--border);background:var(--bg);color:var(--text);font-size:14px}
button{border:0;border-radius:10px;padding:11px 16px;background:var(--accent);color:#fff;font-size:14px;font-weight:600;cursor:pointer;width:100%}
button:disabled{opacity:.55;cursor:not-allowed}
.err{color:var(--danger);font-size:12.5px;margin:8px 0 0;min-height:18px}
.list{margin-top:16px;display:flex;flex-direction:column;gap:10px}
.item{border:1px solid var(--border);border-radius:12px;padding:10px 12px}
.row{display:flex;justify-content:space-between;gap:8px;font-size:13px;align-items:center}
.name{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.st{font-size:12px;color:var(--muted);flex-shrink:0}
.st.ok{color:var(--ok)}.st.fail{color:var(--danger)}
.bar{height:6px;border-radius:999px;background:var(--border);overflow:hidden;margin-top:7px}
.bar>i{display:block;height:100%;width:0;background:var(--accent);transition:width .15s}
.bar>i.ok{background:var(--ok)}.bar>i.fail{background:var(--danger)}
.foot{margin-top:18px;font-size:11.5px;color:var(--muted);text-align:center}
.hidden{display:none}
</style></head><body><main>
<span class="badge">仅投递 · 不可查看已有文件</span>
<h1>{{TITLE}}</h1>
<p class="meta">{{META}}</p>
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

  function headers(extra){
    return Object.assign({"X-LightIsle-Request":"1"}, extra || {});
  }
  function fmtSize(n){
    if(n>=1073741824) return (n/1073741824).toFixed(2)+" GB";
    if(n>=1048576) return (n/1048576).toFixed(1)+" MB";
    if(n>=1024) return (n/1024).toFixed(1)+" KB";
    return n+" B";
  }
  async function readErr(res, fallback){
    try{const j=await res.json(); return j.message || j.error || fallback;}catch(_){return fallback;}
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
      }catch(_){authErr.textContent="网络异常，请稍后重试";}
      finally{authBtn.disabled=false;}
    });
  }
  async function uploadOne(file){
    const card=document.createElement("div");
    card.className="item";
    const row=document.createElement("div");row.className="row";
    const nm=document.createElement("span");nm.className="name";nm.textContent=file.name+" ("+fmtSize(file.size)+")";
    const st=document.createElement("span");st.className="st";st.textContent="准备中…";
    row.appendChild(nm);row.appendChild(st);
    const bar=document.createElement("div");bar.className="bar";
    const fill=document.createElement("i");bar.appendChild(fill);
    card.appendChild(row);card.appendChild(bar);
    fileList.prepend(card);

    let uploadId="";
    try{
      const beginRes=await fetch(cfg.base+"/uploads",{
        method:"POST",
        headers:headers({"Content-Type":"application/json"}),
        body:JSON.stringify({filename:file.name,size:file.size})
      });
      if(!beginRes.ok){
        if(beginRes.status===401){gate.classList.remove("hidden");dropWrap.classList.add("hidden");}
        throw new Error(await readErr(beginRes,"无法开始上传"));
      }
      const meta=await beginRes.json();
      uploadId=meta.uploadId;
      const chunk=meta.chunkSize || 4194304;
      let offset=meta.offset || 0;
      while(offset<file.size){
        const slice=file.slice(offset, Math.min(offset+chunk, file.size));
        const patchRes=await fetch(cfg.base+"/uploads/"+encodeURIComponent(uploadId),{
          method:"PATCH",
          headers:headers({"X-Upload-Offset":String(offset),"Content-Type":"application/octet-stream"}),
          body:slice
        });
        if(!patchRes.ok){throw new Error(await readErr(patchRes,"分片上传失败"));}
        const ps=await patchRes.json();
        offset=ps.offset;
        const pct=file.size>0?Math.min(100,Math.round(offset*100/file.size)):100;
        fill.style.width=pct+"%";
        st.textContent=pct+"%";
      }
      st.textContent="正在完成…";
      const doneRes=await fetch(cfg.base+"/uploads/"+encodeURIComponent(uploadId)+"/complete",{
        method:"POST",headers:headers()
      });
      if(!doneRes.ok){throw new Error(await readErr(doneRes,"提交失败"));}
      fill.style.width="100%";fill.classList.add("ok");
      st.classList.add("ok");st.textContent="已投递";
    }catch(e){
      fill.classList.add("fail");st.classList.add("fail");
      st.textContent=e && e.message ? e.message : "上传失败";
      if(uploadId){fetch(cfg.base+"/uploads/"+encodeURIComponent(uploadId),{method:"DELETE",headers:headers()}).catch(function(){});}
    }
  }
  function handleFiles(files){
    dropErr.textContent="";
    for(const f of Array.from(files||[])){uploadOne(f);}
  }
  if(dropZone){
    dropZone.addEventListener("click",function(){fileInput.click();});
    dropZone.addEventListener("keydown",function(e){if(e.key==="Enter"||e.key===" "){e.preventDefault();fileInput.click();}});
    dropZone.addEventListener("dragover",function(e){e.preventDefault();dropZone.classList.add("drag");});
    dropZone.addEventListener("dragleave",function(){dropZone.classList.remove("drag");});
    dropZone.addEventListener("drop",function(e){e.preventDefault();dropZone.classList.remove("drag");handleFiles(e.dataTransfer.files);});
    fileInput.addEventListener("change",function(){handleFiles(fileInput.files);fileInput.value="";});
  }
})();
</script></body></html>`

func renderCollectDropPage(w http.ResponseWriter, basePath string, access auth.CollectLinkAccess, unlocked bool) {
	nonceBytes := make([]byte, 16)
	_, _ = rand.Read(nonceBytes)
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
