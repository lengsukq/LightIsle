package server

// apiErrorDomainCatalog supplements apiErrorCatalog with user-facing Chinese
// guidance for root routing, media (gallery/cinema), downloads, disks, uploads,
// and user storage policy endpoints.
var apiErrorDomainCatalog = map[string]apiErrorGuidance{
	// Root routing & grants
	"root_not_found": {
		message:    "未找到指定的存储位置，或当前账号无权查看该位置。",
		dataSafe:   true,
		nextAction: "请刷新存储位置列表，或在 Mac 管理端「存储 → 存储位置」确认硬盘登记状态。",
	},
	"root_services_unavailable": {
		message:    "存储位置对应的本地服务当前不可用，原有文件未受影响。",
		dataSafe:   true,
		nextAction: "请稍后重试，或在 Mac 管理端检查服务和磁盘状态。",
	},
	"root_generation_required": {
		message:    "本次修改请求缺少存储位置版本校验头，已拒绝写入以防写错磁盘。",
		dataSafe:   true,
		nextAction: "请刷新页面后重试；若使用自建客户端请附带 X-LightIsle-Root-Generation 请求头。",
	},
	"invalid_root_generation": {
		message:    "存储位置版本校验参数无效，未执行任何写入。",
		dataSafe:   true,
		nextAction: "请刷新页面重新获取最新的存储位置信息后再操作。",
	},
	"root_generation_changed": {
		message:    "目标存储位置已被重新登记或更换，本次操作已中止以保护数据安全。",
		dataSafe:   true,
		nextAction: "请刷新页面确认当前在线硬盘后再重新发起操作。",
	},
	"cannot_list_grants": {
		message:    "无权查看该成员的目录授权记录。",
		dataSafe:   true,
		nextAction: "请使用管理员账号登录后重试。",
	},
	"invalid_grant": {
		message:    "目录授权参数无效或目标目录不存在，未修改现有权限。",
		dataSafe:   true,
		nextAction: "请确认目标目录路径与权限设置后重新提交。",
	},
	"invalid_user": {
		message:    "目标成员账号标识无效。",
		dataSafe:   true,
		nextAction: "请刷新成员列表后重新选择。",
	},
	"invalid_page_size": {
		message:    "分页条数参数超出允许范围。",
		dataSafe:   true,
		nextAction: "请调整每页条数后重试。",
	},

	// Cinema & media
	"film_not_found": {
		message:    "未找到对应的影片或剧集记录。",
		dataSafe:   true,
		nextAction: "请刷新影院列表，或在添加新视频后执行一次媒体库扫描。",
	},
	"share_offline": {
		message:    "影片所在的存储硬盘当前离线，原有视频文件未受影响。",
		dataSafe:   true,
		nextAction: "请检查硬盘连接并重新挂载后刷新影院页面。",
	},
	"scan_running": {
		message:    "媒体库正在扫描或整理中，暂未启动重复任务。",
		dataSafe:   true,
		nextAction: "请等待当前扫描任务完成后再重试。",
	},
	"asset_changed_rescan_required": {
		message:    "目标媒体文件在磁盘上已被修改或移动，原有文件未被改动。",
		dataSafe:   true,
		nextAction: "请先重新扫描媒体库更新索引后再重试。",
	},
	"media_worker_unavailable": {
		message:    "本机媒体解析与缩略图组件当前不可用，原文件未受影响。",
		dataSafe:   true,
		nextAction: "请在 Mac 管理端检查运行状态或稍后重试。",
	},
	"cinema_failed": {
		message:    "影院服务处理请求失败，您的视频文件未受影响。",
		dataSafe:   true,
		nextAction: "请刷新页面重试；若持续失败请在 Mac 管理端查看日志。",
	},
	"invalid_film_id": {
		message:    "影片标识无效。",
		dataSafe:   true,
		nextAction: "请返回影院列表重新选择影片。",
	},
	"invalid_series_id": {
		message:    "剧集标识无效。",
		dataSafe:   true,
		nextAction: "请返回剧集列表重新选择。",
	},
	"invalid_limit": {
		message:    "每页数量参数超出允许范围。",
		dataSafe:   true,
		nextAction: "请使用默认分页重新加载。",
	},
	"invalid_cursor": {
		message:    "分页游标参数无效。",
		dataSafe:   true,
		nextAction: "请刷新列表从第一页重新浏览。",
	},
	"invalid_kind": {
		message:    "媒体分类筛选条件无效。",
		dataSafe:   true,
		nextAction: "请重新选择有效的分类筛选条件。",
	},
	"invalid_watched": {
		message:    "观看状态筛选条件无效。",
		dataSafe:   true,
		nextAction: "请重新选择全部、未看或已看筛选条件。",
	},
	"invalid_sort": {
		message:    "排序方式参数无效。",
		dataSafe:   true,
		nextAction: "请切换为有效的排序方式后重试。",
	},
	"invalid_progress": {
		message:    "播放进度数据格式无效，未保存此次进度。",
		dataSafe:   true,
		nextAction: "请重新打开播放器并稍后重试。",
	},
	"invalid_douban_query": {
		message:    "豆瓣搜索关键词无效。",
		dataSafe:   true,
		nextAction: "请输入有效的片名关键词后重新搜索。",
	},
	"invalid_douban_request": {
		message:    "豆瓣匹配请求参数无效。",
		dataSafe:   true,
		nextAction: "请重新选择搜索结果后再匹配。",
	},
	"douban_web_unavailable": {
		message:    "当前无法连接豆瓣网页检索，本地影片信息未被修改。",
		dataSafe:   true,
		nextAction: "请检查 Mac 网络状态或改用 TMDB / 本地 NFO 匹配。",
	},
	"invalid_tmdb_request": {
		message:    "TMDB 检索或匹配参数无效。",
		dataSafe:   true,
		nextAction: "请检查片名、条目 ID 及令牌配置后重试。",
	},
	"tmdb_auth_failed": {
		message:    "TMDB 访问令牌无效或已过期，未能获取影视资料。",
		dataSafe:   true,
		nextAction: "请在 Mac 管理端核对并重新填写 TMDB API 令牌。",
	},
	"tmdb_access_denied": {
		message:    "TMDB 拒绝了当前令牌的访问请求。",
		dataSafe:   true,
		nextAction: "请确认所使用的 TMDB 令牌权限有效后重试。",
	},
	"tmdb_upstream_failed": {
		message:    "连接 TMDB 服务超时或返回异常，本地影片资料未受影响。",
		dataSafe:   true,
		nextAction: "请检查 Mac 能否访问 TMDB 网络或稍后重试。",
	},
	"nfo_not_found": {
		message:    "影片同目录下未找到对应的本地 .nfo 资料文件。",
		dataSafe:   true,
		nextAction: "请确认与视频同名的 .nfo 文件已放入同一目录后重试。",
	},
	"invalid_nfo": {
		message:    "本地 .nfo 文件格式无法解析，未修改现有影片信息。",
		dataSafe:   true,
		nextAction: "请检查 .nfo 文件的 XML 编码与内容格式后重试。",
	},
	"forbidden_strm_url": {
		message:    "该 .strm 文件指向的地址受安全策略限制，已禁止重定向。",
		dataSafe:   true,
		nextAction: "请检查 .strm 文件内容是否为合法的外部 HTTP/HTTPS 媒体地址。",
	},
	"invalid_strm_url": {
		message:    "无法解析该 .strm 文件中的播放地址。",
		dataSafe:   true,
		nextAction: "请确认 .strm 文件包含有效的播放链接。",
	},
	"invalid_poster_path": {
		message:    "海报图片路径格式无效。",
		dataSafe:   true,
		nextAction: "请刷新影片信息后重试。",
	},
	"tmdb_poster_unavailable": {
		message:    "暂时无法下载或读取 TMDB 海报图片，影片文件本身未受影响。",
		dataSafe:   true,
		nextAction: "请检查 Mac 网络状态，或在影片同目录放置本地海报图片。",
	},
	"poster_unavailable": {
		message:    "暂无可用海报，媒体缩略图可能仍在生成中。",
		dataSafe:   true,
		nextAction: "请等待扫描完成后刷新，或手动匹配影视海报。",
	},
	"poster_unsupported": {
		message:    "当前视频格式不支持自动提取封面缩略图。",
		dataSafe:   true,
		nextAction: "可通过 TMDB/NFO 匹配海报，或在视频同目录放置 poster.jpg。",
	},

	// Gallery
	"volume_offline": {
		message:    "相册所在的存储硬盘当前离线，原有照片和视频未受影响。",
		dataSafe:   true,
		nextAction: "请检查硬盘连接并重新挂载后刷新相册。",
	},
	"gallery_failed": {
		message:    "相册服务处理请求失败，您的原始照片未受影响。",
		dataSafe:   true,
		nextAction: "请刷新页面后重试；若持续失败请在 Mac 管理端查看日志。",
	},
	"invalid_id": {
		message:    "目标条目标识无效。",
		dataSafe:   true,
		nextAction: "请刷新列表后重新选择。",
	},
	"invalid_person_name": {
		message:    "人物名称不能为空或包含非法字符。",
		dataSafe:   true,
		nextAction: "请输入合法的人物名称后重试。",
	},
	"cannot_merge_same_person": {
		message:    "不能将同一人物与自身合并。",
		dataSafe:   true,
		nextAction: "请选择两个不同的人物分组后再执行合并。",
	},
	"invalid_person_share": {
		message:    "人物共享参数无效，未修改现有共享设置。",
		dataSafe:   true,
		nextAction: "请核对共享对象和人物分组后重试。",
	},

	// Downloads
	"download_unavailable": {
		message:    "下载服务（aria2）当前未就绪或不可用，已有文件未受影响。",
		dataSafe:   true,
		nextAction: "请在 Mac 管理端确认下载组件状态与存储硬盘在线后重试。",
	},
	"download_list_failed": {
		message:    "读取下载任务列表失败。",
		dataSafe:   true,
		nextAction: "请稍后刷新页面重试。",
	},
	"download_invalid_request": {
		message:    "下载链接、目标目录或操作参数无效。",
		dataSafe:   true,
		nextAction: "请核对下载链接与目标保存目录后重新提交。",
	},
	"download_limit_reached": {
		message:    "同时进行的下载任务数量已达上限。",
		dataSafe:   true,
		nextAction: "请等待现有下载任务完成或取消部分任务后再添加。",
	},
	"download_permission_revoked": {
		message:    "当前账号已失去目标目录的写入权限，未写入文件。",
		dataSafe:   true,
		nextAction: "请确认目标目录权限或更换可写目录后重试。",
	},
	"download_storage_accounting_pending": {
		message:    "当前存储空间计费记录仍在核对中，暂未启动新下载。",
		dataSafe:   true,
		nextAction: "请稍等片刻或等待已有传输任务完成后重试。",
	},
	"download_not_found": {
		message:    "未找到指定的下载任务。",
		dataSafe:   true,
		nextAction: "请刷新下载任务列表确认最新状态。",
	},
	"download_network_admin_only": {
		message:    "仅管理员可创建外网下载任务。",
		dataSafe:   true,
		nextAction: "请联系家庭管理员代为添加下载任务。",
	},
	"download_root_changed": {
		message:    "下载任务关联的存储硬盘版本已变化，暂未自动发布文件。",
		dataSafe:   true,
		nextAction: "请确认当前在线硬盘并手动处理该下载任务的发布或清理。",
	},
	"download_root_unbound": {
		message:    "下载任务尚未绑定有效的存储位置，无法发布到目标目录。",
		dataSafe:   true,
		nextAction: "请先在 Mac 管理端「存储 → 存储位置」配置默认硬盘后重试。",
	},
	"download_root_unavailable": {
		message:    "下载目标硬盘当前离线，暂无法发布已下载文件。",
		dataSafe:   true,
		nextAction: "请重新连接并挂载硬盘后再继续发布。",
	},
	"download_action_failed": {
		message:    "执行下载任务操作失败，原有数据未受影响。",
		dataSafe:   true,
		nextAction: "请刷新下载列表后重试。",
	},

	// Disks
	"drive_discovery_unavailable": {
		message:    "暂时无法读取 Mac 磁盘列表，磁盘数据未受影响。",
		dataSafe:   true,
		nextAction: "请稍后刷新重试，或在 Mac 本机检查磁盘连接状态。",
	},
	"disk_not_available_or_identity_unknown": {
		message:    "未找到对应的外置磁盘，或无法确认该磁盘的物理标识。",
		dataSafe:   true,
		nextAction: "请刷新磁盘列表并确认外置硬盘已正确连接。",
	},
	"invalid_drive_request": {
		message:    "磁盘操作参数无效，未对任何磁盘执行操作。",
		dataSafe:   true,
		nextAction: "请刷新磁盘列表后重新发起操作。",
	},
	"disk_health_history_unavailable": {
		message:    "暂无该磁盘的 SMART 健康历史记录。",
		dataSafe:   true,
		nextAction: "请先执行一次健康检查，或确认磁盘支持 SMART 信息读取。",
	},
	"drive_identity_changed_refresh_required": {
		message:    "检测到磁盘挂载状态或标识已发生变化，已中止本次操作以防误操作。",
		dataSafe:   true,
		nextAction: "请刷新磁盘列表核对目标磁盘后再重新执行。",
	},
	"drive_in_use_or_protected": {
		message:    "该磁盘正在使用中或属于受保护的系统卷，未执行卸载/推出操作。",
		dataSafe:   true,
		nextAction: "请先停止正在进行的读写、SMB 共享或轻应用后再重试。",
	},
	"drive_operation_busy": {
		message:    "另一项磁盘管理操作正在进行中。",
		dataSafe:   true,
		nextAction: "请等待当前磁盘操作完成后再试。",
	},
	"drive_operation_not_supported": {
		message:    "当前磁盘或接口不支持该操作。",
		dataSafe:   true,
		nextAction: "请通过 macOS 磁盘工具或本机管理端检查该磁盘。",
	},
	"diskutil_operation_failed": {
		message:    "macOS 磁盘工具执行失败，请检查是否有程序仍在占用该磁盘。",
		dataSafe:   true,
		nextAction: "请关闭占用磁盘的进程或轻应用后重试。",
	},

	// User storage & switching
	"storage_registry_unavailable": {
		message:    "存储位置登记表当前不可用，现有配置与文件未受影响。",
		dataSafe:   true,
		nextAction: "请在 Mac 管理端检查服务运行状态后重试。",
	},
	"invalid_storage_category": {
		message:    "存储分类无效，仅支持文件（files）、照片（photos）或视频（videos）。",
		dataSafe:   true,
		nextAction: "请重新选择正确的存储分类后提交。",
	},
	"storage_reset_confirmation_required": {
		message:    "放弃旧存储绑定属于高风险确认操作，缺少显式确认参数，未作任何修改。",
		dataSafe:   true,
		nextAction: "请确认已不再需要该旧磁盘绑定并勾选确认后再提交。",
	},
	"storage_remove_root_first": {
		message:    "该存储位置仍在登记列表中，不能直接放弃旧绑定。",
		dataSafe:   true,
		nextAction: "请先在 Mac 管理端「存储 → 存储位置」中解除该硬盘登记，再执行放弃旧绑定。",
	},
	"storage_permission_denied": {
		message:    "当前账号无权修改成员存储配置。",
		dataSafe:   true,
		nextAction: "请使用管理员账号登录后操作。",
	},
	"storage_invalid_request": {
		message:    "存储空间或配额请求参数无效，原有配置未受影响。",
		dataSafe:   true,
		nextAction: "请核对磁盘、分类、子目录名称和配额数值后重试。",
	},
	"storage_migration_required": {
		message:    "该分类已绑定其他存储位置，不能直接覆盖绑定以防数据失联。",
		dataSafe:   true,
		nextAction: "请使用存储位置切换向导，或在确认移除旧盘后先放弃旧绑定。",
	},
	"storage_destination_not_assigned": {
		message:    "该成员尚未在此磁盘分配存储空间。",
		dataSafe:   true,
		nextAction: "请先为该成员在对应硬盘上分配存储空间后再设置配额。",
	},
	"storage_settings_unavailable": {
		message:    "暂时无法读取或保存成员存储设置，原有数据未受影响。",
		dataSafe:   true,
		nextAction: "请稍后重试，或在 Mac 管理端检查数据库与磁盘状态。",
	},
	"storage_folder_conflict": {
		message:    "目标磁盘上已存在同名的冲突文件或目录，未覆盖任何原有数据。",
		dataSafe:   true,
		nextAction: "请先检查并整理目标磁盘上的同名路径后再重试。",
	},
	"storage_folder_not_empty": {
		message:    "目标个人空间目录不为空，已拒绝自动覆写以保护原有文件。",
		dataSafe:   true,
		nextAction: "请核对目标目录内容，或选择全新的空白存储位置。",
	},
	"storage_root_not_writable": {
		message:    "目标存储硬盘当前只读或缺少写入权限，未创建目录或写入数据。",
		dataSafe:   true,
		nextAction: "请检查外置硬盘文件系统格式（如 NTFS 只读）与 macOS 目录写入权限。",
	},
	"storage_switch_busy": {
		message:    "已有存储位置切换任务正在进行中。",
		dataSafe:   true,
		nextAction: "请等待当前切换任务完成或取消后再发起新任务。",
	},
	"storage_switch_task_not_found": {
		message:    "未找到对应的存储位置切换任务记录。",
		dataSafe:   true,
		nextAction: "请刷新页面查看最新存储绑定状态。",
	},
	"storage_migration_verification_failed": {
		message:    "数据迁移后的文件校验未通过，原盘数据仍完整保留。",
		dataSafe:   true,
		nextAction: "请检查目标硬盘连接与可用空间后重新核对或重试迁移。",
	},
	"storage_quota_exceeded": {
		message:    "超出当前磁盘为该成员分配的空间上限，未写入新数据。",
		dataSafe:   true,
		nextAction: "请清理不再需要的文件，或联系管理员调整该磁盘配额。",
	},
	"storage_accounting_conflict": {
		message:    "检测到并发存储账本更新冲突，本次操作未生效。",
		dataSafe:   true,
		nextAction: "请刷新页面后重试。",
	},

	// Uploads
	"upload_server_busy": {
		message:    "当前并发上传任务已满，请稍候再试。",
		dataSafe:   true,
		nextAction: "请等待几秒后自动或手动重试上传。",
	},
	"upload_timed_out": {
		message:    "上传传输超时，已暂存的分片可在断点续传中恢复。",
		dataSafe:   true,
		nextAction: "请检查网络连接后重新尝试继续上传。",
	},
}
