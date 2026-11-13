package server

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path"
	"strconv"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/gallery"
)

func liveVideoContentType(p string) string {
	switch strings.ToLower(path.Ext(p)) {
	case ".mov":
		return "video/quicktime"
	case ".webm":
		return "video/webm"
	default:
		return "video/mp4"
	}
}

func (a *API) galleryLiveVideo(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	id, ok := galleryID(w, r)
	if !ok {
		return
	}
	photo, video, err := a.gallery.LiveVideoCompanion(id)
	if err != nil {
		galleryError(w, err)
		return
	}
	if !a.allowMediaAsset(w, r, photo.Path, false) || !a.allowMediaAsset(w, r, video.Path, false) {
		return
	}
	f, info, err := a.files.Read(video.Path)
	if err != nil {
		fileError(w, err)
		return
	}
	defer f.Close()
	if !info.Mode().IsRegular() || info.Size() != video.Size || info.ModTime().UnixNano() != video.Modified {
		jsonReply(w, http.StatusConflict, map[string]string{"error": "asset_changed_rescan_required"})
		return
	}
	w.Header().Set("Content-Type", liveVideoContentType(video.Path))
	w.Header().Set("Accept-Ranges", "bytes")
	w.Header().Set("Cache-Control", "private, max-age=86400")
	http.ServeContent(w, r, info.Name(), info.ModTime(), f)
}

func (a *API) galleryMemories(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	roots, ok := a.mediaRoots(w, r)
	if !ok {
		return
	}
	viewer, authenticated := a.auth.Identity(token(r))
	if !authenticated {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return
	}
	memories, err := a.gallery.MemoriesScoped(viewer.ID, roots)
	if err != nil {
		galleryError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"memories": memories})
}

type shareEligibleMember struct {
	ID       int64  `json:"id"`
	Username string `json:"username"`
}

func (a *API) ownerCanSharePersonAsset(ownerID int64, assetPath string) bool {
	if a.auth == nil || ownerID <= 0 {
		return false
	}
	if a.rootID != "" {
		ok, err := a.auth.UserCanWriteRoot(ownerID, a.rootID, assetPath)
		return err == nil && ok
	}
	if managedStorageName(assetPath) {
		return false
	}
	ok, err := a.auth.UserCanWrite(ownerID, assetPath)
	return err == nil && ok
}

func (a *API) galleryPersonSharesList(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	viewer, authenticated := a.auth.Identity(token(r))
	if !authenticated {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return
	}
	shares, err := a.gallery.ListPersonSharesForUser(viewer.ID)
	if err != nil {
		galleryError(w, err)
		return
	}
	filtered := make([]gallery.PersonShareView, 0, len(shares))
	for i := range shares {
		owner, ownerErr := a.auth.GetUser(shares[i].OwnerUserID)
		if ownerErr == nil {
			shares[i].OwnerUsername = owner.Username
		}
		if shares[i].Direction == "incoming" && (ownerErr != nil || !owner.Enabled) {
			continue
		}
		if member, mErr := a.auth.GetUser(shares[i].MemberUserID); mErr == nil {
			shares[i].MemberName = member.Username
		}
		filtered = append(filtered, shares[i])
	}
	members := make([]shareEligibleMember, 0)
	if peers, peerErr := a.auth.ListEnabledPeerUsers(token(r)); peerErr == nil {
		for _, u := range peers {
			members = append(members, shareEligibleMember{ID: u.ID, Username: u.Username})
		}
	}
	jsonReply(w, http.StatusOK, map[string]any{
		"shares":  filtered,
		"members": members,
	})
}

func (a *API) galleryPersonShareCreate(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	roots, ok := a.mediaRoots(w, r)
	if !ok {
		return
	}
	viewer, authenticated := a.auth.Identity(token(r))
	if !authenticated {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return
	}
	// Restrict shareable roots to directories where the caller actually holds write ownership,
	// preventing a member with read-only shared access from re-sharing another member's folder.
	writableRoots := make([]string, 0, len(roots))
	for _, root := range roots {
		if a.canAccess(token(r), root, true, false) {
			writableRoots = append(writableRoots, root)
		}
	}
	if len(writableRoots) == 0 {
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "person_share_requires_owned_photos"})
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	defer r.Body.Close()
	var body struct {
		PersonID     int64  `json:"personId"`
		MemberUserID int64  `json:"memberUserId"`
		Label        string `json:"label"`
		SinceTakenAt int64  `json:"sinceTakenAt"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil || body.PersonID <= 0 || body.MemberUserID <= 0 || body.MemberUserID == viewer.ID {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_person_share"})
		return
	}
	targetMember, err := a.auth.GetUser(body.MemberUserID)
	if err != nil || !targetMember.Enabled {
		jsonReply(w, http.StatusNotFound, map[string]string{"error": "user_not_found"})
		return
	}

	created, err := a.gallery.CreateOrUpdatePersonShare(viewer.ID, body.PersonID, targetMember.ID, body.Label, body.SinceTakenAt, writableRoots)
	if err != nil {
		galleryError(w, err)
		return
	}
	created.OwnerUsername = viewer.Username
	created.MemberName = targetMember.Username
	jsonReply(w, http.StatusCreated, map[string]any{"share": created})
}

func (a *API) galleryPersonShareDelete(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	shareID, err := strconv.ParseInt(r.PathValue("shareID"), 10, 64)
	if err != nil || shareID <= 0 {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_id"})
		return
	}
	viewer, authenticated := a.auth.Identity(token(r))
	if !authenticated {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return
	}
	if err := a.gallery.DeletePersonShare(viewer.ID, shareID); err != nil {
		galleryError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]bool{"deleted": true})
}

func (a *API) galleryPersonShareAssets(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	shareID, err := strconv.ParseInt(r.PathValue("shareID"), 10, 64)
	if err != nil || shareID <= 0 {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_id"})
		return
	}
	viewer, authenticated := a.auth.Identity(token(r))
	if !authenticated {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return
	}
	limit := 60
	if raw := r.URL.Query().Get("limit"); raw != "" {
		parsed, convErr := strconv.Atoi(raw)
		if convErr != nil || parsed < 1 || parsed > 120 {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_limit"})
			return
		}
		limit = parsed
	}
	cursor, _ := strconv.ParseInt(r.URL.Query().Get("cursor"), 10, 64)
	assets, next, summary, err := a.gallery.ListPersonShareAssets(viewer.ID, shareID, cursor, limit)
	if err != nil {
		galleryError(w, err)
		return
	}
	owner, ownerErr := a.auth.GetUser(summary.OwnerUserID)
	if ownerErr != nil || !owner.Enabled {
		jsonReply(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	summary.OwnerUsername = owner.Username
	if member, uErr := a.auth.GetUser(summary.MemberUserID); uErr == nil {
		summary.MemberName = member.Username
	}
	decorated := make([]galleryAssetWithCapabilities, 0, len(assets))
	for _, asset := range assets {
		if !a.ownerCanSharePersonAsset(summary.OwnerUserID, asset.Path) {
			continue
		}
		decorated = append(decorated, galleryAssetWithCapabilities{Asset: asset, CanWrite: false})
	}
	jsonReply(w, http.StatusOK, map[string]any{
		"share":      summary,
		"assets":     decorated,
		"nextCursor": next,
	})
}

func (a *API) authorizeSharedPersonAssetRequest(w http.ResponseWriter, r *http.Request) (gallery.Asset, int64, bool) {
	if !a.galleryReady(w) {
		return gallery.Asset{}, 0, false
	}
	shareID, err1 := strconv.ParseInt(r.PathValue("shareID"), 10, 64)
	assetID, err2 := strconv.ParseInt(r.PathValue("assetID"), 10, 64)
	if err1 != nil || err2 != nil || shareID <= 0 || assetID <= 0 {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_id"})
		return gallery.Asset{}, 0, false
	}
	viewer, authenticated := a.auth.Identity(token(r))
	if !authenticated {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return gallery.Asset{}, 0, false
	}
	asset, ownerID, err := a.gallery.AuthorizePersonShareAssetWithOwner(viewer.ID, shareID, assetID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			jsonReply(w, http.StatusNotFound, map[string]string{"error": "not_found"})
			return gallery.Asset{}, 0, false
		}
		galleryError(w, err)
		return gallery.Asset{}, 0, false
	}
	if !a.ownerCanSharePersonAsset(ownerID, asset.Path) {
		jsonReply(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return gallery.Asset{}, 0, false
	}
	return asset, ownerID, true
}

func (a *API) galleryPersonShareThumbnail(w http.ResponseWriter, r *http.Request) {
	asset, _, ok := a.authorizeSharedPersonAssetRequest(w, r)
	if !ok {
		return
	}
	var f *os.File
	var err error
	if asset.Type == "video" {
		f, err = a.gallery.VideoThumbnailContext(r.Context(), asset.ID)
	} else {
		f, err = a.gallery.ThumbnailContext(r.Context(), asset.ID)
	}
	if err != nil {
		galleryError(w, err)
		return
	}
	defer f.Close()
	modTime := time.Time{}
	if asset.Modified > 0 {
		modTime = time.Unix(0, asset.Modified)
	}
	serveCachedJPEG(w, r, "thumbnail.jpg", modTime, f)
}

func (a *API) galleryPersonShareContent(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	asset, _, ok := a.authorizeSharedPersonAssetRequest(w, r)
	if !ok {
		return
	}
	f, info, err := a.files.Read(asset.Path)
	if err != nil {
		fileError(w, err)
		return
	}
	defer f.Close()
	if !info.Mode().IsRegular() || files.MediaFileIdentity(info) != asset.FileIdentity {
		jsonReply(w, http.StatusConflict, map[string]string{"error": "asset_changed_rescan_required"})
		return
	}
	w.Header().Set("Accept-Ranges", "bytes")
	w.Header().Set("Cache-Control", "private, max-age=3600")
	http.ServeContent(w, r, info.Name(), info.ModTime(), f)
}

func (a *API) galleryPersonShareLiveVideo(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	asset, ownerID, ok := a.authorizeSharedPersonAssetRequest(w, r)
	if !ok {
		return
	}
	_, video, err := a.gallery.LiveVideoCompanion(asset.ID)
	if err != nil {
		galleryError(w, err)
		return
	}
	if !a.ownerCanSharePersonAsset(ownerID, video.Path) {
		jsonReply(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	f, info, err := a.files.Read(video.Path)
	if err != nil {
		fileError(w, err)
		return
	}
	defer f.Close()
	if !info.Mode().IsRegular() || info.Size() != video.Size || info.ModTime().UnixNano() != video.Modified {
		jsonReply(w, http.StatusConflict, map[string]string{"error": "asset_changed_rescan_required"})
		return
	}
	w.Header().Set("Content-Type", liveVideoContentType(video.Path))
	w.Header().Set("Accept-Ranges", "bytes")
	w.Header().Set("Cache-Control", "private, max-age=86400")
	http.ServeContent(w, r, info.Name(), info.ModTime(), f)
}
