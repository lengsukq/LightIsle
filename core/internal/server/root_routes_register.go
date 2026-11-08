package server

import "net/http"

// Root endpoints keep their existing permission guard wrappers; each
// domain only registers routes, never acquires a root lease itself.
type guardedRootEndpoint func(func(*API) http.HandlerFunc) http.HandlerFunc

func registerRootRoutes(mux *http.ServeMux, api *API) {
	file := func(method func(*API) http.HandlerFunc) http.HandlerFunc { return rootHandler(api, method, rootLogin) }
	media := func(method func(*API) http.HandlerFunc) http.HandlerFunc { return rootHandler(api, method, rootMedia) }
	admin := func(method func(*API) http.HandlerFunc) http.HandlerFunc { return rootHandler(api, method, rootAdmin) }
	traverse := func(method func(*API) http.HandlerFunc) http.HandlerFunc {
		return rootHandler(api, method, rootTraverse)
	}
	public := func(method func(*API) http.HandlerFunc) http.HandlerFunc { return rootHandler(api, method, rootPublic) }
	const base = "/api/v2/roots/{rootID}"
	mux.HandleFunc("GET "+base+"/missing-media/{kind}", file(func(a *API) http.HandlerFunc { return a.missingMediaList }))
	mux.HandleFunc("POST "+base+"/missing-media/{kind}/recheck", file(func(a *API) http.HandlerFunc { return a.missingMediaRecheck }))
	mux.HandleFunc("POST "+base+"/missing-media/{kind}/{id}/attach", file(func(a *API) http.HandlerFunc { return a.missingMediaAttach }))
	mux.HandleFunc("DELETE "+base+"/missing-media/{kind}/{id}", file(func(a *API) http.HandlerFunc { return a.missingMediaDiscard }))
	registerRootFileRoutes(mux, base, file, admin, traverse, public)
	registerRootGalleryRoutes(mux, base, media, admin)
	registerRootCinemaRoutes(mux, base, media, admin)
	registerRootAdministrationRoutes(mux, base, admin)
}

func registerRootFileRoutes(mux *http.ServeMux, base string, file, admin, traverse, public guardedRootEndpoint) {
	mux.HandleFunc("GET "+base+"/files", file(func(a *API) http.HandlerFunc { return a.listFiles }))
	mux.HandleFunc("GET "+base+"/files/search", file(func(a *API) http.HandlerFunc { return a.searchFiles }))
	mux.HandleFunc("POST "+base+"/files/operations", file(func(a *API) http.HandlerFunc { return a.fileOperation }))
	mux.HandleFunc("DELETE "+base+"/files/trash/{id}", file(func(a *API) http.HandlerFunc { return a.purgeTrash }))
	mux.HandleFunc("DELETE "+base+"/files", file(func(a *API) http.HandlerFunc { return a.trashFile }))
	mux.HandleFunc("POST "+base+"/files/folders", file(func(a *API) http.HandlerFunc { return a.mkdir }))
	mux.HandleFunc("GET "+base+"/files/content", file(func(a *API) http.HandlerFunc { return a.readFile }))
	mux.HandleFunc("GET "+base+"/files/sha256", file(func(a *API) http.HandlerFunc { return a.fileSHA256 }))
	mux.HandleFunc("HEAD "+base+"/files/content", file(func(a *API) http.HandlerFunc { return a.readFile }))
	mux.HandleFunc("GET "+base+"/files/archive", file(func(a *API) http.HandlerFunc { return a.downloadFolderArchive }))
	mux.HandleFunc("HEAD "+base+"/files/archive", file(func(a *API) http.HandlerFunc { return a.downloadFolderArchive }))
	mux.HandleFunc("POST "+base+"/files/extract", file(func(a *API) http.HandlerFunc { return a.extractZipArchive }))
	mux.HandleFunc("PUT "+base+"/files/content", file(func(a *API) http.HandlerFunc { return a.uploadFile }))
	mux.HandleFunc("POST "+base+"/uploads", file(func(a *API) http.HandlerFunc { return a.beginUpload }))
	mux.HandleFunc("GET "+base+"/uploads/{id}", file(func(a *API) http.HandlerFunc { return a.uploadStatus }))
	mux.HandleFunc("PATCH "+base+"/uploads/{id}", file(func(a *API) http.HandlerFunc { return a.uploadChunk }))
	mux.HandleFunc("POST "+base+"/uploads/{id}/complete", file(func(a *API) http.HandlerFunc { return a.uploadComplete }))
	mux.HandleFunc("DELETE "+base+"/uploads/{id}", file(func(a *API) http.HandlerFunc { return a.uploadAbort }))
	mux.HandleFunc("GET "+base+"/admin/uploads", admin(func(a *API) http.HandlerFunc { return a.adminUploadList }))
	mux.HandleFunc("GET "+base+"/admin/uploads/unrecognized", admin(func(a *API) http.HandlerFunc { return a.adminUnknownUploadList }))
	mux.HandleFunc("DELETE "+base+"/admin/uploads/{id}", admin(func(a *API) http.HandlerFunc { return a.adminUploadCancel }))
	mux.HandleFunc("POST "+base+"/admin/uploads/cleanup-expired", admin(func(a *API) http.HandlerFunc { return a.adminUploadCleanupExpired }))
	mux.HandleFunc("POST "+base+"/files/batch", file(func(a *API) http.HandlerFunc { return a.fileBatch }))
	mux.HandleFunc("GET "+base+"/files/preview", file(func(a *API) http.HandlerFunc { return a.previewFile }))
	mux.HandleFunc("GET "+base+"/files/thumbnail", file(func(a *API) http.HandlerFunc { return a.fileThumbnail }))
	mux.HandleFunc("HEAD "+base+"/files/preview", file(func(a *API) http.HandlerFunc { return a.previewFile }))
	mux.HandleFunc("HEAD "+base+"/files/thumbnail", file(func(a *API) http.HandlerFunc { return a.fileThumbnail }))
	mux.HandleFunc("GET "+base+"/files/trash", file(func(a *API) http.HandlerFunc { return a.listTrash }))
	// The setting is global, not a per-root override. Preserve this v2
	// compatibility endpoint for clients that scope every files-page URL.
	mux.HandleFunc("GET "+base+"/trash/retention", file(func(a *API) http.HandlerFunc { return a.trashRetention }))
	mux.HandleFunc("POST "+base+"/files/trash/{id}/restore", file(func(a *API) http.HandlerFunc { return a.restoreTrash }))
	mux.HandleFunc("GET "+base+"/files/root", traverse(func(a *API) http.HandlerFunc { return a.fileRoot }))
	mux.HandleFunc("POST "+base+"/file-shares", file(func(a *API) http.HandlerFunc { return a.createFileShare }))
	mux.HandleFunc("GET "+base+"/file-shares", file(func(a *API) http.HandlerFunc { return a.listFileShares }))
	mux.HandleFunc("DELETE "+base+"/file-shares/{id}", file(func(a *API) http.HandlerFunc { return a.revokeFileShare }))
	mux.HandleFunc("GET "+base+"/public/file/{token}", public(func(a *API) http.HandlerFunc { return a.downloadSharedFile }))
	mux.HandleFunc("HEAD "+base+"/public/file/{token}", public(func(a *API) http.HandlerFunc { return a.downloadSharedFile }))
	mux.HandleFunc("POST "+base+"/public/file/{token}", public(func(a *API) http.HandlerFunc { return a.downloadSharedFile }))
}

func registerRootGalleryRoutes(mux *http.ServeMux, base string, media, admin guardedRootEndpoint) {
	mux.HandleFunc("GET "+base+"/photos", media(func(a *API) http.HandlerFunc { return a.galleryList }))
	mux.HandleFunc("GET "+base+"/photos/status", media(func(a *API) http.HandlerFunc { return a.galleryStatus }))
	mux.HandleFunc("GET "+base+"/photos/geo", media(func(a *API) http.HandlerFunc { return a.galleryGeo }))
	mux.HandleFunc("GET "+base+"/photos/timeline", media(func(a *API) http.HandlerFunc { return a.galleryTimeline }))
	mux.HandleFunc("GET "+base+"/photos/facets", media(func(a *API) http.HandlerFunc { return a.galleryFacets }))
	mux.HandleFunc("GET "+base+"/photos/archive", media(func(a *API) http.HandlerFunc { return a.gallerySelectedArchive }))
	mux.HandleFunc("HEAD "+base+"/photos/archive", media(func(a *API) http.HandlerFunc { return a.gallerySelectedArchive }))
	mux.HandleFunc("POST "+base+"/photos/scan", admin(func(a *API) http.HandlerFunc { return a.galleryScan }))
	mux.HandleFunc("GET "+base+"/photos/{id}/thumbnail", media(func(a *API) http.HandlerFunc { return a.galleryThumbnail }))
	mux.HandleFunc("POST "+base+"/photos/{id}/favorite", media(func(a *API) http.HandlerFunc { return a.galleryFavorite }))
	mux.HandleFunc("POST "+base+"/photos/{id}/personal-favorite", media(func(a *API) http.HandlerFunc { return a.galleryPersonalFavorite }))
	mux.HandleFunc("GET "+base+"/photos/albums", media(func(a *API) http.HandlerFunc { return a.galleryAlbums }))
	mux.HandleFunc("GET "+base+"/photos/private-albums", media(func(a *API) http.HandlerFunc { return a.galleryPrivateAlbums }))
	mux.HandleFunc("GET "+base+"/photos/folder-albums", media(func(a *API) http.HandlerFunc { return a.folderAlbumList }))
	mux.HandleFunc("POST "+base+"/photos/folder-albums", media(func(a *API) http.HandlerFunc { return a.folderAlbumCreate }))
	mux.HandleFunc("DELETE "+base+"/photos/folder-albums/{name}", media(func(a *API) http.HandlerFunc { return a.folderAlbumDelete }))
	mux.HandleFunc("POST "+base+"/photos/folder-albums/{name}/shares", media(func(a *API) http.HandlerFunc { return a.folderAlbumShareSet }))
	mux.HandleFunc("DELETE "+base+"/photos/folder-albums/{name}/shares/{memberID}", media(func(a *API) http.HandlerFunc { return a.folderAlbumShareRemove }))
	mux.HandleFunc("POST "+base+"/photos/private-albums", media(func(a *API) http.HandlerFunc { return a.galleryCreatePrivateAlbum }))
	mux.HandleFunc("PATCH "+base+"/photos/private-albums/{id}", media(func(a *API) http.HandlerFunc { return a.galleryRenamePrivateAlbum }))
	mux.HandleFunc("DELETE "+base+"/photos/private-albums/{id}", media(func(a *API) http.HandlerFunc { return a.galleryDeletePrivateAlbum }))
	mux.HandleFunc("POST "+base+"/photos/private-albums/{id}/items", media(func(a *API) http.HandlerFunc { return a.galleryAddToPrivateAlbum }))
	mux.HandleFunc("DELETE "+base+"/photos/private-albums/{id}/items/{assetID}", media(func(a *API) http.HandlerFunc { return a.galleryRemoveFromPrivateAlbum }))
	mux.HandleFunc("POST "+base+"/photos/albums", admin(func(a *API) http.HandlerFunc { return a.galleryCreateAlbum }))
	mux.HandleFunc("POST "+base+"/photos/albums/{id}/items", admin(func(a *API) http.HandlerFunc { return a.galleryAddToAlbum }))
	mux.HandleFunc("PATCH "+base+"/photos/albums/{id}", admin(func(a *API) http.HandlerFunc { return a.galleryRenameAlbum }))
	mux.HandleFunc("DELETE "+base+"/photos/albums/{id}", admin(func(a *API) http.HandlerFunc { return a.galleryDeleteAlbum }))
	mux.HandleFunc("DELETE "+base+"/photos/albums/{id}/items/{assetID}", admin(func(a *API) http.HandlerFunc { return a.galleryRemoveFromAlbum }))
}

func registerRootCinemaRoutes(mux *http.ServeMux, base string, media, admin guardedRootEndpoint) {
	mux.HandleFunc("GET "+base+"/cinema", media(func(a *API) http.HandlerFunc { return a.cinemaList }))
	mux.HandleFunc("GET "+base+"/cinema/status", media(func(a *API) http.HandlerFunc { return a.cinemaStatus }))
	mux.HandleFunc("POST "+base+"/cinema/scan", admin(func(a *API) http.HandlerFunc { return a.cinemaScan }))
	mux.HandleFunc("GET "+base+"/cinema/{id}", media(func(a *API) http.HandlerFunc { return a.cinemaGet }))
	mux.HandleFunc("PATCH "+base+"/cinema/{id}", admin(func(a *API) http.HandlerFunc { return a.cinemaRename }))
	mux.HandleFunc("POST "+base+"/cinema/{id}/metadata/nfo", admin(func(a *API) http.HandlerFunc { return a.cinemaImportNFO }))
	mux.HandleFunc("POST "+base+"/cinema/{id}/metadata/tmdb/search", admin(func(a *API) http.HandlerFunc { return a.cinemaTMDBSearch }))
	mux.HandleFunc("POST "+base+"/cinema/{id}/metadata/tmdb/match", admin(func(a *API) http.HandlerFunc { return a.cinemaTMDBMatch }))
	mux.HandleFunc("POST "+base+"/cinema/{id}/metadata/douban/search", admin(func(a *API) http.HandlerFunc { return a.cinemaDoubanSearch }))
	mux.HandleFunc("POST "+base+"/cinema/{id}/metadata/douban/match", admin(func(a *API) http.HandlerFunc { return a.cinemaDoubanMatch }))
	mux.HandleFunc("GET "+base+"/cinema/{id}/poster", media(func(a *API) http.HandlerFunc { return a.cinemaPoster }))
	mux.HandleFunc("HEAD "+base+"/cinema/{id}/poster", media(func(a *API) http.HandlerFunc { return a.cinemaPoster }))
	mux.HandleFunc("GET "+base+"/cinema/{id}/stream", media(func(a *API) http.HandlerFunc { return a.cinemaStream }))
	mux.HandleFunc("HEAD "+base+"/cinema/{id}/stream", media(func(a *API) http.HandlerFunc { return a.cinemaStream }))
	mux.HandleFunc("GET "+base+"/cinema/{id}/subtitles", media(func(a *API) http.HandlerFunc { return a.cinemaSubtitle }))
	mux.HandleFunc("GET "+base+"/cinema/{id}/progress", media(func(a *API) http.HandlerFunc { return a.cinemaProgress }))
	mux.HandleFunc("PUT "+base+"/cinema/{id}/progress", media(func(a *API) http.HandlerFunc { return a.cinemaSaveProgress }))
	mux.HandleFunc("GET "+base+"/cinema/transcode/status", media(func(a *API) http.HandlerFunc { return a.cinemaTranscodeStatus }))
	mux.HandleFunc("GET "+base+"/cinema/{id}/hls/session", media(func(a *API) http.HandlerFunc { return a.cinemaHLSSession }))
	mux.HandleFunc("GET "+base+"/cinema/{id}/hls/{session}/{file}", media(func(a *API) http.HandlerFunc { return a.cinemaHLSFile }))
	mux.HandleFunc("GET "+base+"/cinema/{id}/tracks", media(func(a *API) http.HandlerFunc { return a.cinemaTracks }))
	mux.HandleFunc("GET "+base+"/cinema/{id}/embedded-subtitles", media(func(a *API) http.HandlerFunc { return a.cinemaEmbeddedSubtitle }))
	mux.HandleFunc("GET "+base+"/series", media(func(a *API) http.HandlerFunc { return a.cinemaSeriesList }))
	mux.HandleFunc("GET "+base+"/series/{id}", media(func(a *API) http.HandlerFunc { return a.cinemaSeriesGet }))
	mux.HandleFunc("POST "+base+"/series/{id}/metadata/tmdb/match", admin(func(a *API) http.HandlerFunc { return a.cinemaSeriesTMDBMatch }))
	mux.HandleFunc("POST "+base+"/cinema/scrape/start", admin(func(a *API) http.HandlerFunc { return a.cinemaScrapeStart }))
	mux.HandleFunc("GET "+base+"/cinema/scrape/status", admin(func(a *API) http.HandlerFunc { return a.cinemaScrapeStatus }))
	mux.HandleFunc("GET "+base+"/cinema/history", media(func(a *API) http.HandlerFunc { return a.cinemaHistory }))
	mux.HandleFunc("DELETE "+base+"/cinema/history", media(func(a *API) http.HandlerFunc { return a.cinemaClearHistory }))
	mux.HandleFunc("POST "+base+"/cinema/{id}/watched", media(func(a *API) http.HandlerFunc { return a.cinemaMarkWatched }))
}

func registerRootAdministrationRoutes(mux *http.ServeMux, base string, admin guardedRootEndpoint) {
	mux.HandleFunc("GET "+base+"/tasks", admin(func(a *API) http.HandlerFunc { return a.taskList }))
	mux.HandleFunc("GET "+base+"/tasks/history", admin(func(a *API) http.HandlerFunc { return a.taskHistory }))
	mux.HandleFunc("POST "+base+"/tasks/{kind}/cancel", admin(func(a *API) http.HandlerFunc { return a.taskCancel }))
	mux.HandleFunc("POST "+base+"/tasks/{kind}/retry", admin(func(a *API) http.HandlerFunc { return a.taskRetry }))
	mux.HandleFunc("GET "+base+"/alerts", admin(func(a *API) http.HandlerFunc { return a.alertList }))
	mux.HandleFunc("POST "+base+"/alerts/{code}/acknowledge", admin(func(a *API) http.HandlerFunc { return a.alertAcknowledge }))
	mux.HandleFunc("GET "+base+"/users/{userID}/file-grants", admin(func(a *API) http.HandlerFunc { return a.rootFileGrants }))
	mux.HandleFunc("PUT "+base+"/users/{userID}/file-grants", admin(func(a *API) http.HandlerFunc { return a.rootSetFileGrant }))
	mux.HandleFunc("DELETE "+base+"/users/{userID}/file-grants", admin(func(a *API) http.HandlerFunc { return a.rootDeleteFileGrant }))
	mux.HandleFunc("POST "+base+"/users/{userID}/storage", admin(func(a *API) http.HandlerFunc { return a.allocateUserStorageSpace }))
	mux.HandleFunc("PUT "+base+"/users/{userID}/storage/{category}", admin(func(a *API) http.HandlerFunc { return a.assignUserStorageRoot }))
	mux.HandleFunc("GET "+base+"/storage/users/{userID}/usage-check", admin(func(a *API) http.HandlerFunc { return a.checkStorageLiveUsage }))
}
