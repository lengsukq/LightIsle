package server

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/gallery"
)

const quotaTrashReleaseNote = "移入回收站后可随时恢复；个人空间配额将在从回收站永久删除后释放。"

type similarCandidateResponse struct {
	gallery.SimilarPhotoCandidate
	CanTrash bool `json:"canTrash"`
}

type similarGroupResponse struct {
	GroupID            string                     `json:"groupId"`
	Kind               string                     `json:"kind"`
	TakenAt            int64                      `json:"takenAt"`
	RecommendedAssetID int64                      `json:"recommendedAssetId"`
	RecommendReason    string                     `json:"recommendReason"`
	ReclaimableBytes   int64                      `json:"reclaimableBytes"`
	Items              []similarCandidateResponse `json:"items"`
}

func (a *API) galleryAssetAI(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	id, ok := galleryID(w, r)
	if !ok {
		return
	}
	asset, err := a.gallery.Asset(id)
	if err != nil {
		galleryError(w, err)
		return
	}
	if !a.allowMediaAsset(w, r, asset.Path, false) {
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
	detail, err := a.gallery.AssetAIDetailScoped(viewer.ID, id, roots)
	if err != nil {
		galleryError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, detail)
}

func (a *API) galleryAIPause(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 256)
	defer r.Body.Close()
	var body struct {
		Paused *bool `json:"paused"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil || body.Paused == nil {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	a.gallery.SetAIPaused(*body.Paused)
	jsonReply(w, http.StatusOK, map[string]bool{"paused": a.gallery.AIPaused()})
}

func (a *API) galleryPersons(w http.ResponseWriter, r *http.Request) {
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
	includeHidden := r.URL.Query().Get("includeHidden") == "1"
	persons, err := a.gallery.ListPersonsScoped(viewer.ID, includeHidden, roots)
	if err != nil {
		galleryError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"persons": persons})
}

func (a *API) galleryUpdatePerson(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	id, ok := galleryID(w, r)
	if !ok {
		return
	}
	viewer, authenticated := a.auth.Identity(token(r))
	if !authenticated {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	defer r.Body.Close()
	var body struct {
		Name   *string `json:"name"`
		Hidden *bool   `json:"hidden"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil || (body.Name == nil && body.Hidden == nil) {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	if err := a.gallery.UpdatePerson(viewer.ID, id, body.Name, body.Hidden); err != nil {
		galleryError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]bool{"updated": true})
}

func (a *API) galleryMergePerson(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	sourceID, ok := galleryID(w, r)
	if !ok {
		return
	}
	viewer, authenticated := a.auth.Identity(token(r))
	if !authenticated {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 512)
	defer r.Body.Close()
	var body struct {
		TargetPersonID int64 `json:"targetPersonId"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil || body.TargetPersonID <= 0 {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	if err := a.gallery.MergePersons(viewer.ID, sourceID, body.TargetPersonID); err != nil {
		galleryError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"merged": true, "targetPersonId": body.TargetPersonID})
}

func ifNoneMatchContains(headerValue, etag string) bool {
	if headerValue == "" {
		return false
	}
	for _, raw := range strings.Split(headerValue, ",") {
		cand := strings.TrimSpace(raw)
		cand = strings.TrimPrefix(cand, "W/")
		if cand == "*" || cand == etag {
			return true
		}
	}
	return false
}

func (a *API) galleryFaceThumbnail(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	faceID, ok := galleryID(w, r)
	if !ok {
		return
	}
	asset, box, err := a.gallery.FaceAssetAndBox(faceID)
	if err != nil {
		galleryError(w, err)
		return
	}
	if !a.allowMediaAsset(w, r, asset.Path, false) {
		return
	}
	etag := `"` + gallery.FaceAvatarKey(faceID, asset, box) + `"`
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "private, max-age=604800, stale-while-revalidate=86400")
	if ifNoneMatchContains(r.Header.Get("If-None-Match"), etag) {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	jpegBytes, err := a.gallery.RenderFaceAvatarJPEG(r.Context(), asset.ID, box)
	if err != nil {
		galleryError(w, err)
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Content-Length", strconv.Itoa(len(jpegBytes)))
	w.WriteHeader(http.StatusOK)
	if r.Method != http.MethodHead {
		_, _ = w.Write(jpegBytes)
	}
}

func (a *API) gallerySimilarGroups(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	roots, ok := a.mediaRoots(w, r)
	if !ok {
		return
	}
	limit := 50
	if raw := r.URL.Query().Get("limit"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 1 || parsed > 100 {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_limit"})
			return
		}
		limit = parsed
	}
	groups, err := a.gallery.FindSimilarGroupsScoped(roots, limit)
	if err != nil {
		galleryError(w, err)
		return
	}
	session := token(r)
	decorated := make([]similarGroupResponse, len(groups))
	for i, g := range groups {
		items := make([]similarCandidateResponse, len(g.Items))
		for j, item := range g.Items {
			items[j] = similarCandidateResponse{
				SimilarPhotoCandidate: item,
				CanTrash:              a.canAccess(session, item.Path, true, false),
			}
		}
		decorated[i] = similarGroupResponse{
			GroupID:            g.GroupID,
			Kind:               g.Kind,
			TakenAt:            g.TakenAt,
			RecommendedAssetID: g.RecommendedAssetID,
			RecommendReason:    g.RecommendReason,
			ReclaimableBytes:   g.ReclaimableBytes,
			Items:              items,
		}
	}
	jsonReply(w, http.StatusOK, map[string]any{
		"groups":           decorated,
		"quotaReleaseNote": quotaTrashReleaseNote,
	})
}

func (a *API) galleryTrashSimilar(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
	defer r.Body.Close()
	var body struct {
		KeepAssetID   int64   `json:"keepAssetId"`
		TrashAssetIDs []int64 `json:"trashAssetIds"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil || len(body.TrashAssetIDs) == 0 || len(body.TrashAssetIDs) > 50 {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	if body.KeepAssetID <= 0 {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "must_keep_one_photo"})
		return
	}
	for _, trashID := range body.TrashAssetIDs {
		if trashID <= 0 {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_id"})
			return
		}
		if trashID == body.KeepAssetID {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "must_keep_one_photo"})
			return
		}
	}
	keepAsset, err := a.gallery.LookupAssetForTrash(body.KeepAssetID)
	if err != nil {
		galleryError(w, err)
		return
	}
	if !a.allowMediaAsset(w, r, keepAsset.Path, false) {
		return
	}
	if info, statErr := a.files.Stat(keepAsset.Path); statErr != nil || !info.Mode().IsRegular() {
		jsonReply(w, http.StatusConflict, map[string]string{"error": "asset_changed_rescan_required"})
		return
	}

	seen := make(map[int64]bool, len(body.TrashAssetIDs))
	targets := make([]gallery.Asset, 0, len(body.TrashAssetIDs))
	for _, trashID := range body.TrashAssetIDs {
		if seen[trashID] {
			continue
		}
		seen[trashID] = true
		asset, err := a.gallery.LookupAssetForTrash(trashID)
		if err != nil {
			galleryError(w, err)
			return
		}
		if !a.allowMediaAsset(w, r, asset.Path, true) {
			return
		}
		targets = append(targets, asset)
	}

	var trashedCount int
	var stagedBytes int64
	for _, asset := range targets {
		if err := a.trashCurrentFile(asset.Path); err != nil {
			fileError(w, err)
			return
		}
		trashedCount++
		stagedBytes += asset.Size
		_ = a.gallery.ReconcileRemovedAsset(asset.ID)
		if a.rootServer != nil {
			a.rootServer.QueueMediaRefresh(a.rootID, asset.Path)
		}
	}
	jsonReply(w, http.StatusOK, map[string]any{
		"trashed":          trashedCount,
		"stagedTrashBytes": stagedBytes,
		"quotaReleaseNote": quotaTrashReleaseNote,
	})
}
