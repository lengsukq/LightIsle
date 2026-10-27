package top.lengsu.lightisle

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.CancellationSignal
import androidx.work.Worker
import androidx.work.WorkerParameters
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import kotlin.math.min

private class NASFailure(val status: Int, val code: String = ""): IOException("NAS response $status: $code")
private class NASContentMismatch: IOException("NAS photo SHA256 mismatch")
private class StalePhotoBackupGeneration: IOException("Background photo backup generation changed")

/** A private origin-bound HTTP stack; never follows redirects with cookies. */
private class NASBackgroundClient(
    private val config: JSONObject,
    private val isCurrent: () -> Boolean,
) {
    private val base=config.getString("server").trimEnd('/')
    private val cookie=config.getString("cookie")
    private val root = BackgroundPhotoRoot(
        config.getString("rootID"), config.getLong("rootGeneration"), config.getString("photosPath")
    )
    val photosDirectory get() = root.photosPath
    private val client:OkHttpClient = OkHttpClient.Builder()
        .proxy(Proxy.NO_PROXY)
        .followRedirects(false)
        .followSslRedirects(false)
        .connectTimeout(15,TimeUnit.SECONDS)
        .readTimeout(90,TimeUnit.SECONDS)
        .writeTimeout(90,TimeUnit.SECONDS)
        .apply {
            val pin=config.optString("pin","")
            if(pin.isNotEmpty()) {
                // The native UI passes the same SHA-256 DER leaf fingerprint
                // configured by the user's foreground TLS-pinned Dart client.
                // The TLS handshake verifies it before auth headers travel.
                val trusted=object:X509TrustManager{
                    override fun getAcceptedIssuers():Array<X509Certificate> = emptyArray()
                    override fun checkClientTrusted(chain:Array<X509Certificate>,authType:String){}
                    override fun checkServerTrusted(chain:Array<X509Certificate>,authType:String){
                        if(chain.isEmpty())throw java.security.cert.CertificateException("No server certificate")
                        val actual=MessageDigest.getInstance("SHA-256").digest(chain[0].encoded)
                        val expected=pin.chunked(2).map{it.toInt(16).toByte()}.toByteArray()
                        if(!MessageDigest.isEqual(actual,expected)) {
                            throw java.security.cert.CertificateException("NAS TLS certificate pin mismatch")
                        }
                    }
                }
                val context=SSLContext.getInstance("TLS")
                context.init(null,arrayOf<TrustManager>(trusted),null)
                sslSocketFactory(context.socketFactory,trusted)
                // Leave OkHttp's standard TLS hostname verification enabled.
            }
        }.build()

    fun call(method:String,path:String,payload:ByteArray?=null,offset:Long?=null):JSONObject {
        requireCurrent()
        val target=root.endpoint(path)
        val request=Request.Builder().url(base+target).header("Cookie",cookie)
            .header("X-LightIsle-Request","1")
            .header("X-LightIsle-Root-Generation",root.generation.toString())
            .header("Accept","application/json")
        if(offset!=null)request.header("X-Upload-Offset",offset.toString())
        val body=if(method=="GET")null
            else (payload?:ByteArray(0)).toRequestBody("application/octet-stream".toMediaType())
        request.method(method,body)
        client.newCall(request.build()).execute().use { response ->
            requireCurrent()
            if(response.code !in 200..299){
                val code = try {
                    response.body?.byteStream()?.use { input ->
                        JSONObject(String(readBoundedPhotoResponse(input), Charsets.UTF_8)).optString("error")
                    } ?: ""
                } catch (_: Exception) { "" }
                throw NASFailure(response.code,code)
            }
            val input=response.body?.byteStream()?:throw IOException("NAS returned no body")
            val bytes=readBoundedPhotoResponse(input)
            requireCurrent()
            return JSONObject(String(bytes,Charsets.UTF_8))
        }
    }

    private fun requireCurrent() {
        if (!isCurrent()) throw StalePhotoBackupGeneration()
    }

    fun sha256(path:String,size:Long,digest:String):Boolean {
        val response=try{call("GET","/files/sha256?path="+q(path))}
            catch(e:NASFailure){if(e.status==404)return false else throw e}
        if(response.optString("algorithm")!="sha256")throw IOException("Unexpected NAS hash algorithm")
        if(response.optString("sha256")!=digest || response.optLong("size",-1L)!=size){
            // Do NOT overwrite/delete/replace a preexisting file with
            // unexpected bytes. An administrator must decide how to recover.
            throw NASContentMismatch()
        }
        return true
    }
    fun folder(path:String) {
        try {
            call("GET","/files?path="+q(path))
            return
        } catch(e:NASFailure) {
            if(e.status!=404 && e.status!=403)throw e
        }
        try{call("POST","/files/folders",JSONObject().put("path",path).toString().toByteArray())}
        catch(e:NASFailure){if(e.status!=409)throw e}
    }
    fun ensurePhotoFolders(parent:String,child:String){
        // A member can be granted only PhonePhotos/<deviceId>. In that case
        // listing or creating the parent is intentionally forbidden. Probe
        // the final authorized destination first instead of requiring access
        // to a broader folder.
        try{
            call("GET","/files?path="+q(child))
            return
        } catch(e:NASFailure) {
            if(e.status!=404 && e.status!=403)throw e
        }
        folder(parent)
        folder(child)
    }
    fun createUpload(path:String,size:Long):JSONObject =
        call("POST","/uploads",JSONObject().put("path",path).put("size",size).toString().toByteArray())
    fun uploadInfo(id:String):JSONObject = call("GET","/uploads/"+q(id))
    fun uploadChunk(id:String,offset:Long,bytes:ByteArray):JSONObject =
        call("PATCH","/uploads/"+q(id),bytes,offset)
    fun complete(id:String):JSONObject = call("POST","/uploads/"+q(id)+"/complete")
    private fun q(value:String):String = URLEncoder.encode(value,"UTF-8")
}

class BackgroundPhotoWorker(context:Context,params:WorkerParameters):Worker(context,params) {
    @Volatile private var activePhotoCopy: CancellationSignal? = null

    override fun onStopped() {
        activePhotoCopy?.cancel()
        super.onStopped()
    }

    override fun doWork():Result {
        val ctx=applicationContext
        val generation=inputData.getLong(BackgroundPhotoBackup.workerGenerationKey,0L)
        if(generation<=0)return Result.success()
        // Existing installs may still have the old periodic request, whose
        // input predates workerKindKey. Treat it as a trigger during migration.
        if(inputData.getString(BackgroundPhotoBackup.workerKindKey)!=BackgroundPhotoBackup.scanWorkerKind){
            if(BackgroundPhotoBackup.loadForWorker(ctx,generation)==null)return Result.success()
            val queued=BackgroundPhotoBackup.enqueueTriggeredScan(ctx,generation)
            return if(queued)Result.success()
                else if(BackgroundPhotoBackup.isGenerationCurrent(ctx,generation))Result.retry()
                else Result.success()
        }
        val config=BackgroundPhotoBackup.loadForWorker(ctx,generation)?:return Result.success()
        val current={ !isStopped && BackgroundPhotoBackup.isGenerationCurrent(ctx,generation) }
        val readPermission=if(Build.VERSION.SDK_INT>=33) Manifest.permission.READ_MEDIA_IMAGES else Manifest.permission.READ_EXTERNAL_STORAGE
        if(ctx.checkSelfPermission(readPermission)!=PackageManager.PERMISSION_GRANTED) {
            return if(BackgroundPhotoBackup.disable(ctx,generation,"照片权限已被撤销，后台备份已关闭"))
                Result.failure() else Result.success()
        }
        if(!AndroidPhotoImport.isWifi(ctx))return if(current()) Result.retry() else Result.success()
        val client=try{NASBackgroundClient(config,current)}catch(_:Exception){
            BackgroundPhotoBackup.disable(ctx,generation,"后台连接配置无效，已关闭备份")
            return if(current()) Result.failure() else Result.success()
        }
        val device=config.getString("device")
        val base=client.photosDirectory
        val folder="$base/$device"
        val versionKey="mediastoreVersion"
        try {
            if(!current())return Result.success()
            client.ensurePhotoFolders(base,folder)
            var lastVersion=BackgroundPhotoBackup.state(ctx,versionKey,generation)?:""
            val savedCursor=BackgroundPhotoBackup.cursor(ctx,generation)
            var cursor=savedCursor.toLongOrNull()
            if(savedCursor.isNotEmpty() && cursor==null)throw IOException("Invalid MediaStore cursor")
            var visited=0
            var pages=0
            var requiresForeground=0
            while(true){
                if(!current())return Result.success()
                if(!AndroidPhotoImport.isWifi(ctx))return if(current())Result.retry() else Result.success()
                val page=AndroidPhotoImport.list(ctx,cursor,10)
                pages++
                if(!current())return Result.success()
                val version=page["version"] as? String? ?: ""
                if(lastVersion.isNotEmpty() && version.isNotEmpty() && lastVersion!=version){
                    // MediaStore IDs/generations might have been remapped.
                    // Clear cursor, rescan from newest and recompute hashes.
                    if(!BackgroundPhotoBackup.saveCursor(ctx,generation,""))return if(current())Result.retry() else Result.success()
                    if(!BackgroundPhotoBackup.saveState(ctx,versionKey,generation,version))return if(current())Result.retry() else Result.success()
                    if(!current())return Result.success()
                    BackgroundPhotoBackup.note(ctx,generation,"照片库发生变化，正在重新核对")
                    return if(BackgroundPhotoBackup.enqueueContinuation(ctx,generation))Result.success()
                        else if(current())Result.retry() else Result.success()
                }
                @Suppress("UNCHECKED_CAST")
                val items=page["items"] as? List<Map<String,Any>> ?: emptyList()
                // The native scanner can omit files >2 GiB; these are NOT
                // protected by a background run and must be reported.
                requiresForeground += (page["oversizedCount"] as? Number)?.toInt()?.coerceIn(0,10000) ?: 0
                for(item in items){
                    if(!current() || BackgroundPhotoBackup.loadForWorker(ctx,generation)==null)return Result.success()
                    if(!AndroidPhotoImport.isWifi(ctx))return Result.retry()
                    visited++
                    val id=(item["id"] as? String)?.toLongOrNull() ?: continue
                    val size=(item["size"] as? Number)?.toLong() ?: continue
                    val modified=(item["modified"] as? Number)?.toLong() ?: continue
                    if(size<1)continue
                    if(size>100L*1024*1024){
                        requiresForeground++
                        continue // background intentionally capped at 100 MiB
                    }
                    if(!current())return Result.success()
                    val cancellation=CancellationSignal()
                    activePhotoCopy=cancellation
                    val candidate=try {
                        AndroidPhotoImport.prepare(ctx,id,cancellation)
                    } finally {
                        if(activePhotoCopy===cancellation)activePhotoCopy=null
                    }
                    val localPath=candidate["path"] as String
                    try{
                        val local=File(localPath)
                        if(!local.isFile||local.length()!=size)throw IOException("Photo changed during copy")
                        val digest=File(localPath).inputStream().use { input ->
                            val hash=MessageDigest.getInstance("SHA-256")
                            val buf=ByteArray(256*1024)
                            while(true){
                                if(!current())throw StalePhotoBackupGeneration()
                                val count=input.read(buf)
                                if(count<0)break
                                hash.update(buf,0,count)
                            }
                            hash.digest().joinToString(""){"%02x".format(it)}
                        }
                        val extension=(item["name"] as? String?:"")
                            .substringAfterLast('.',"jpg").lowercase().let {
                                if(it in setOf("jpg","jpeg","png","heic","heif","webp","gif","avif","tiff","bmp"))it else "jpg"
                            }
                        val target="$folder/photo_${id}_${modified}_${digest.substring(0,16)}.$extension"
                        if(client.sha256(target,size,digest))continue
                        upload(client,ctx,generation,local,target,size,digest)
                    } finally {
                        AndroidPhotoImport.release(ctx,localPath)
                    }
                }
                val next=page["nextCursor"] as? String ?: ""
                val checkpoint=BackgroundPhotoGeneration.checkpointAfterPage(
                    nextCursor=next,
                    pageSucceeded=true,
                    generationCurrent=BackgroundPhotoBackup.isGenerationCurrent(ctx,generation),
                    cancelled=isStopped,
                )?:return Result.success()
                if(!BackgroundPhotoBackup.saveCursor(ctx,generation,checkpoint))return if(current())Result.retry() else Result.success()
                if(!BackgroundPhotoBackup.saveState(ctx,versionKey,generation,version))return if(current())Result.retry() else Result.success()
                lastVersion=version
                when(BackgroundPhotoGeneration.afterPage(
                    pages=pages,
                    visited=visited,
                    nextCursor=checkpoint,
                    generationCurrent=current(),
                    cancelled=isStopped,
                )){
                    BackgroundPhotoGeneration.BatchDecision.FETCH_NEXT_PAGE -> {
                        cursor=checkpoint.toLongOrNull()?:throw IOException("Invalid MediaStore cursor")
                    }
                    BackgroundPhotoGeneration.BatchDecision.ENQUEUE_CONTINUATION -> {
                        BackgroundPhotoBackup.note(ctx,generation,
                            "已检查 $visited 张照片，保存进度并继续后台备份" +
                            if(requiresForeground>0) "；本批有 $requiresForeground 张过大尚未备份，需前台处理" else "")
                        return if(BackgroundPhotoBackup.enqueueContinuation(ctx,generation))Result.success()
                            else if(current())Result.retry() else Result.success()
                    }
                    BackgroundPhotoGeneration.BatchDecision.COMPLETE -> {
                        BackgroundPhotoBackup.note(ctx,generation,
                            "本轮照片核对完成，检查了 $visited 张照片" +
                            if(requiresForeground>0) "；有 $requiresForeground 张过大尚未备份，请前台检查" else "")
                        return Result.success()
                    }
                    BackgroundPhotoGeneration.BatchDecision.STOP -> return Result.success()
                }
            }
        } catch(_:StalePhotoBackupGeneration) {
            return Result.success()
        } catch(_:NASContentMismatch) {
            BackgroundPhotoBackup.note(ctx,generation,"NAS 已存在内容不一致的照片，未覆盖；请人工核对备份文件")
            return Result.failure()
        } catch(e:NASFailure){
            if(e.status==401){
                return if(BackgroundPhotoBackup.disable(ctx,generation,"登录已失效，需打开 LightIsle 重新授权"))
                    Result.failure() else Result.success()
            }
            if(e.code=="root_generation_changed" || e.code=="root_not_found" ||
                e.code=="storage_destination_not_assigned") {
                return if(BackgroundPhotoBackup.disable(ctx,generation,
                    "照片存储硬盘已更换或绑定失效，后台备份已安全停止；请在图库重新确认硬盘后开启"))
                    Result.failure() else Result.success()
            }
            if(e.status==507){
                BackgroundPhotoBackup.note(ctx,generation,"照片硬盘存储额度或空间不足；请清理空间或调整配额后重新开启")
                return Result.failure()
            }
            if(e.status==403){
                BackgroundPhotoBackup.note(ctx,generation,"NAS 目录没有写入权限，请检查账号目录授权")
                return Result.failure()
            }
            BackgroundPhotoBackup.note(ctx,generation,
                if(e.status==503 || e.code=="root_unavailable") "照片硬盘暂时离线，保留进度等待原硬盘恢复"
                else "NAS 暂不可用，保留进度等待系统下次重试")
            return if(current()) Result.retry() else Result.success()
        } catch(_:Exception){
            BackgroundPhotoBackup.note(ctx,generation,"备份被中断或网络暂不可用，等待重试")
            return if(current()) Result.retry() else Result.success()
        }
    }

    private fun upload(client:NASBackgroundClient,ctx:Context,generation:Long,
                       local:File,target:String,size:Long,digest:String) {
        val sessionKey="upload_${generation}_${digest}_${target.hashCode()}"
        var id=BackgroundPhotoBackup.state(ctx,sessionKey,generation)
        var offset=0L
        if(id!=null) {
            try {
                val previous=client.uploadInfo(id)
                if(previous.optString("path")!=target||previous.optLong("size")!=size)throw IOException("Other upload target")
                offset=previous.optLong("offset",-1)
                if(offset<0||offset>size)throw IOException("Bad upload cursor")
            }catch(e:NASFailure) {
                if(e.status!=404)throw e
                BackgroundPhotoBackup.removeState(ctx,sessionKey,generation)
                id=null
            }
        }
        if(id==null) {
            val started=client.createUpload(target,size)
            id=started.getString("id")
            offset=started.optLong("offset",0)
            if(started.optString("path")!=target||started.optLong("size")!=size){
                throw IOException("Unexpected upload session")
            }
            if(!BackgroundPhotoBackup.saveState(ctx,sessionKey,generation,id!!)) {
                throw StalePhotoBackupGeneration()
            }
        }
        val uploadID=id ?:throw IOException("Missing session")
        java.io.RandomAccessFile(local,"r").use { reader ->
            val buffer=ByteArray(4*1024*1024)
            while(offset<size){
                if(isStopped || !BackgroundPhotoBackup.isGenerationCurrent(applicationContext,generation)) {
                    throw StalePhotoBackupGeneration()
                }
                if(!AndroidPhotoImport.isWifi(applicationContext))throw IOException("Upload interrupted")
                val count=min(buffer.size.toLong(),size-offset).toInt()
                reader.seek(offset)
                reader.readFully(buffer,0,count)
                val current=offset
                val reply=try{client.uploadChunk(uploadID,current,buffer.copyOf(count))}
                    catch(e:Exception){
                        if(e is StalePhotoBackupGeneration)throw e
                        // Lost acknowledgement is not a failed upload. Always
                        // obtain the authoritative server offset first.
                        val server=client.uploadInfo(uploadID)
                        val next=server.optLong("offset",-1)
                        if(server.optString("path")!=target||server.optLong("size")!=size||
                            next<current||next>size)throw e
                        if(next==current)throw e
                        server
                    }
                val next=reply.optLong("offset",-1)
                if(next<=offset||next>size)throw IOException("Upload did not advance")
                offset=next
            }
        }
        if(isStopped || !BackgroundPhotoBackup.isGenerationCurrent(applicationContext,generation)) {
            throw StalePhotoBackupGeneration()
        }
        try{client.complete(uploadID)}catch(e:Exception){
            if(e is StalePhotoBackupGeneration)throw e
            if(!client.sha256(target,size,digest))throw e
        }
        if(!client.sha256(target,size,digest))throw IOException("NAS SHA256 mismatch")
        BackgroundPhotoBackup.removeState(ctx,sessionKey,generation)
    }
}

/** Periodic work only queues the serial one-time photo scan chain. */
class BackgroundPhotoTriggerWorker(context:Context,params:WorkerParameters):Worker(context,params) {
    override fun doWork():Result {
        val ctx=applicationContext
        val generation=inputData.getLong(BackgroundPhotoBackup.workerGenerationKey,0L)
        if(generation<=0||BackgroundPhotoBackup.loadForWorker(ctx,generation)==null)return Result.success()
        val queued=BackgroundPhotoBackup.enqueueTriggeredScan(ctx,generation)
        return if(queued)Result.success()
            else if(BackgroundPhotoBackup.isGenerationCurrent(ctx,generation))Result.retry()
            else Result.success()
    }
}
