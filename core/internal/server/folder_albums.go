package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"path"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

type controlledAlbumSymlinker interface {
	CreateControlledAlbumSymlink(memberPhotosDir, linkName, targetRel string) error
	RemoveControlledAlbumSymlink(memberPhotosDir, linkName, expectedTarget string) error
}

// personalPhotoDirectory returns the authenticated owner's actual configured
// photos directory, never a path supplied by the client or inferred from a
// different root. A shared folder grant does not create an ownership claim.
func (a *API) personalPhotoDirectory(r *http.Request, write bool) (string, error) {
	if a.rootRuntime == nil || a.rootLease == nil || !a.rootLease.Valid(r.Context()) {
		return "", auth.ErrStorageUnassigned
	}
	user, ok := a.auth.Identity(token(r))
	if !ok {
		return "", auth.ErrForbidden
	}
	policy, err := a.auth.StoragePolicy(token(r), user.ID)
	if err != nil {
		return "", err
	}
	for _, location := range policy.Locations {
		if location.Category == auth.StoragePhotos && location.RootID == a.rootID && location.RootGeneration == a.rootRuntime.root.Generation {
			if !a.auth.CanAccessRoot(token(r), a.rootID, location.RelativePath, write, false) {
				return "", auth.ErrForbidden
			}
			return location.RelativePath, nil
		}
	}
	return "", auth.ErrStorageUnassigned
}

func folderAlbumName(raw string) (string, bool) {
	name := strings.TrimSpace(raw)
	if name != raw || !utf8.ValidString(name) || len([]rune(name)) < 1 || len([]rune(name)) > 60 || name == "." || name == ".." ||
		strings.ContainsAny(name, "/\\\x00") || files.IsInternalName(name) {
		return "", false
	}
	for _, char := range name {
		if unicode.IsControl(char) {
			return "", false
		}
	}
	return name, true
}

func (a *API) folderAlbumList(w http.ResponseWriter, r *http.Request) {
	root, err := a.personalPhotoDirectory(r, false)
	if err != nil {
		storageQuotaError(w, err)
		return
	}
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	cursor := r.URL.Query().Get("cursor")
	entries, next, err := a.files.Page(root, cursor, 100)
	if err != nil {
		fileError(w, err)
		return
	}
	gen := a.rootRuntime.root.Generation
	ownedShares, err := a.auth.ListOwnedFolderAlbumShares(token(r), a.rootID, gen)
	if err != nil {
		storageQuotaError(w, err)
		return
	}
	albums := make([]map[string]any, 0, len(entries))
	for _, entry := range entries {
		if entry.Type == "folder" && a.canAccess(token(r), entry.Path, false, false) {
			shares := ownedShares[entry.Name]
			if shares == nil {
				shares = []auth.SharedFolderAlbum{}
			}
			albums = append(albums, map[string]any{
				"name":     entry.Name,
				"path":     entry.Path,
				"shared":   false,
				"canWrite": true,
				"shares":   shares,
			})
		}
	}
	if cursor == "" {
		received, err := a.auth.ListReceivedFolderAlbums(token(r), a.rootID, gen)
		if err != nil {
			storageQuotaError(w, err)
			return
		}
		for _, item := range received {
			info, statErr := a.files.Stat(item.OwnerPath)
			if statErr != nil || !info.IsDir() {
				continue
			}
			albums = append(albums, map[string]any{
				"name":          item.AlbumName,
				"path":          item.OwnerPath,
				"linkName":      item.LinkName,
				"shared":        true,
				"ownerUserId":   item.OwnerUserID,
				"ownerUsername": item.OwnerUsername,
				"canWrite":      item.CanWrite,
				"shares":        []auth.SharedFolderAlbum{},
			})
		}
	}
	targets, err := a.auth.FolderAlbumShareTargets(token(r), a.rootID, gen)
	if err != nil {
		targets = []auth.FolderAlbumShareTarget{}
	}
	jsonReply(w, 200, map[string]any{
		"albums":       albums,
		"shareTargets": targets,
		"nextCursor":   next,
	})
}

func (a *API) folderAlbumCreate(w http.ResponseWriter, r *http.Request) {
	root, err := a.personalPhotoDirectory(r, true)
	if err != nil {
		storageQuotaError(w, err)
		return
	}
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 512)
	defer r.Body.Close()
	var body struct {
		Name string `json:"name"`
	}
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if d.Decode(&body) != nil || d.Decode(new(any)) != io.EOF {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	name, ok := folderAlbumName(body.Name)
	if !ok {
		jsonReply(w, 400, map[string]string{"error": "invalid_album_name"})
		return
	}
	target := path.Join(root, name)
	if !a.canAccess(token(r), target, true, false) {
		jsonReply(w, 403, map[string]string{"error": "file_permission_denied"})
		return
	}
	if err := a.files.Mkdir(target); err != nil {
		fileError(w, err)
		return
	}
	if !a.rootLease.Valid(r.Context()) {
		jsonReply(w, 503, map[string]string{"error": "root_unavailable"})
		return
	}
	jsonReply(w, 201, map[string]string{"name": name, "path": target})
}

func (a *API) folderAlbumDelete(w http.ResponseWriter, r *http.Request) {
	root, err := a.personalPhotoDirectory(r, true)
	if err != nil {
		storageQuotaError(w, err)
		return
	}
	name, ok := folderAlbumName(r.PathValue("name"))
	if !ok {
		jsonReply(w, 400, map[string]string{"error": "invalid_album_name"})
		return
	}
	remover, ok := a.files.(interface{ RemoveEmptyDirectory(string) error })
	if !ok {
		a.fileUnavailable(w)
		return
	}
	target := path.Join(root, name)
	if !a.canAccess(token(r), target, true, false) {
		jsonReply(w, 403, map[string]string{"error": "file_permission_denied"})
		return
	}
	if err := remover.RemoveEmptyDirectory(target); err != nil {
		if errors.Is(err, files.ErrDirectoryNotEmpty) {
			jsonReply(w, 409, map[string]string{"error": "album_not_empty"})
			return
		}
		fileError(w, err)
		return
	}
	a.cleanupDeletedAlbumShares(r, name)
	if !a.rootLease.Valid(r.Context()) {
		jsonReply(w, 503, map[string]string{"error": "root_unavailable"})
		return
	}
	jsonReply(w, 200, map[string]bool{"deleted": true})
}

func (a *API) cleanupDeletedAlbumShares(r *http.Request, albumName string) {
	if a.rootRuntime == nil {
		return
	}
	gen := a.rootRuntime.root.Generation
	ownedShares, err := a.auth.ListOwnedFolderAlbumShares(token(r), a.rootID, gen)
	if err != nil {
		return
	}
	symlinker, _ := a.files.(controlledAlbumSymlinker)
	for _, share := range ownedShares[albumName] {
		removed, err := a.auth.UnshareFolderAlbum(token(r), a.rootID, gen, share.OwnerUserID, albumName, share.MemberUserID)
		if err == nil && symlinker != nil && removed.MemberPhotos != "" && removed.LinkName != "" {
			targetRel := fmt.Sprintf("../../u%d/photos/%s", removed.OwnerUserID, removed.AlbumName)
			_ = symlinker.RemoveControlledAlbumSymlink(removed.MemberPhotos, removed.LinkName, targetRel)
		}
	}
}

func (a *API) folderAlbumShareSet(w http.ResponseWriter, r *http.Request) {
	ownerPhotos, err := a.personalPhotoDirectory(r, true)
	if err != nil {
		storageQuotaError(w, err)
		return
	}
	symlinker, ok := a.files.(controlledAlbumSymlinker)
	if !ok || a.files == nil {
		a.fileUnavailable(w)
		return
	}
	albumName, ok := folderAlbumName(r.PathValue("name"))
	if !ok {
		jsonReply(w, 400, map[string]string{"error": "invalid_album_name"})
		return
	}
	albumPath := path.Join(ownerPhotos, albumName)
	info, err := a.files.Stat(albumPath)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			jsonReply(w, 404, map[string]string{"error": "not_found"})
			return
		}
		fileError(w, err)
		return
	}
	if !info.IsDir() {
		jsonReply(w, 400, map[string]string{"error": "invalid_album_name"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 512)
	defer r.Body.Close()
	var body struct {
		MemberUserID int64 `json:"memberUserId"`
		CanWrite     bool  `json:"canWrite"`
	}
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if d.Decode(&body) != nil || d.Decode(new(any)) != io.EOF || body.MemberUserID <= 0 {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	viewer, ok := a.auth.Identity(token(r))
	if !ok {
		jsonReply(w, 401, map[string]string{"error": "authentication_required"})
		return
	}
	gen := a.rootRuntime.root.Generation
	_, memberPhotos, ownerUsername, existingLink, err := a.auth.InspectFolderAlbumShareTarget(token(r), a.rootID, gen, albumName, body.MemberUserID)
	if err != nil {
		storageQuotaError(w, err)
		return
	}
	targetRel := fmt.Sprintf("../../u%d/photos/%s", viewer.ID, albumName)
	linkName := existingLink
	if linkName == "" {
		linkName = albumName
	}
	if err := symlinker.CreateControlledAlbumSymlink(memberPhotos, linkName, targetRel); err != nil {
		if existingLink == "" && errors.Is(err, files.ErrExists) {
			fallback, valid := folderAlbumName(fmt.Sprintf("%s (%s)", albumName, ownerUsername))
			if !valid {
				fileError(w, err)
				return
			}
			linkName = fallback
			err = symlinker.CreateControlledAlbumSymlink(memberPhotos, linkName, targetRel)
		}
		if err != nil {
			fileError(w, err)
			return
		}
	}
	share, err := a.auth.ShareFolderAlbum(token(r), a.rootID, gen, albumName, linkName, body.MemberUserID, body.CanWrite)
	if err != nil {
		if existingLink == "" {
			_ = symlinker.RemoveControlledAlbumSymlink(memberPhotos, linkName, targetRel)
		}
		storageQuotaError(w, err)
		return
	}
	jsonReply(w, 200, share)
}

func (a *API) folderAlbumShareRemove(w http.ResponseWriter, r *http.Request) {
	if a.rootRuntime == nil || a.rootLease == nil || !a.rootLease.Valid(r.Context()) {
		jsonReply(w, 503, map[string]string{"error": "root_unavailable"})
		return
	}
	albumName, ok := folderAlbumName(r.PathValue("name"))
	if !ok {
		jsonReply(w, 400, map[string]string{"error": "invalid_album_name"})
		return
	}
	memberID, err := strconv.ParseInt(r.PathValue("memberID"), 10, 64)
	if err != nil || memberID <= 0 {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	viewer, ok := a.auth.Identity(token(r))
	if !ok {
		jsonReply(w, 401, map[string]string{"error": "authentication_required"})
		return
	}
	ownerID := viewer.ID
	if rawOwner := r.URL.Query().Get("ownerUserId"); rawOwner != "" {
		parsed, parseErr := strconv.ParseInt(rawOwner, 10, 64)
		if parseErr != nil || parsed <= 0 {
			jsonReply(w, 400, map[string]string{"error": "invalid_request"})
			return
		}
		ownerID = parsed
	}
	gen := a.rootRuntime.root.Generation
	removed, err := a.auth.UnshareFolderAlbum(token(r), a.rootID, gen, ownerID, albumName, memberID)
	if err != nil {
		if errors.Is(err, auth.ErrNotFound) {
			jsonReply(w, 404, map[string]string{"error": "not_found"})
			return
		}
		storageQuotaError(w, err)
		return
	}
	if symlinker, ok := a.files.(controlledAlbumSymlinker); ok && removed.MemberPhotos != "" && removed.LinkName != "" {
		targetRel := fmt.Sprintf("../../u%d/photos/%s", removed.OwnerUserID, removed.AlbumName)
		_ = symlinker.RemoveControlledAlbumSymlink(removed.MemberPhotos, removed.LinkName, targetRel)
	}
	jsonReply(w, 200, map[string]bool{"deleted": true})
}
