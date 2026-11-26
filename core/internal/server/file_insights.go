package server

import (
	"context"
	"net/http"
	"strconv"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/files"
)

type fileInsightItemResponse struct {
	files.InsightItem
	CanWrite bool `json:"canWrite"`
}

func (a *API) fileInsights(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	scanner, ok := a.files.(interface {
		ScanInsights(context.Context, files.InsightOptions) (files.InsightResult, error)
	})
	if !ok {
		a.fileUnavailable(w)
		return
	}
	session := token(r)
	q := r.URL.Query()
	mode := strings.ToLower(strings.TrimSpace(q.Get("mode")))
	if mode == "" {
		mode = files.InsightModeLarge
	}
	if mode != files.InsightModeLarge && mode != files.InsightModeRecent {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_insights_mode")
		return
	}
	base := strings.TrimSpace(q.Get("path"))
	if base == "" {
		base = "."
	}
	if a.auth == nil || !a.canSee(session, base) {
		writeAPIErrorCode(w, http.StatusForbidden, "file_permission_denied")
		return
	}
	scanRoots, err := a.searchRoots(session, base)
	if err != nil || len(scanRoots) == 0 {
		writeAPIErrorCode(w, http.StatusForbidden, "file_permission_denied")
		return
	}

	limit := files.DefaultInsightLimit
	if raw := strings.TrimSpace(q.Get("limit")); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 1 || parsed > files.MaxInsightLimit {
			writeAPIErrorCode(w, http.StatusBadRequest, "invalid_limit")
			return
		}
		limit = parsed
	}
	var minBytes int64
	hasMinBytes := false
	if raw := strings.TrimSpace(q.Get("minBytes")); raw != "" {
		parsed, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || parsed < 0 {
			writeAPIErrorCode(w, http.StatusBadRequest, "invalid_request")
			return
		}
		minBytes = parsed
		hasMinBytes = true
	}
	days := files.DefaultRecentDays
	if raw := strings.TrimSpace(q.Get("days")); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 1 || parsed > files.MaxRecentDays {
			writeAPIErrorCode(w, http.StatusBadRequest, "invalid_request")
			return
		}
		days = parsed
	}

	ctx, cancel := context.WithTimeout(r.Context(), files.DefaultInsightTimeout)
	defer cancel()

	res, err := scanner.ScanInsights(ctx, files.InsightOptions{
		Roots:       scanRoots,
		Mode:        mode,
		MinBytes:    minBytes,
		HasMinBytes: hasMinBytes,
		Days:        days,
		Limit:       limit,
		CanTraverse: func(p string) bool { return a.canSee(session, p) },
		CanReadFile: func(p string) bool { return a.canAccess(session, p, false, false) },
	})
	if err != nil {
		fileError(w, err)
		return
	}

	items := make([]fileInsightItemResponse, 0, len(res.Items))
	for _, it := range res.Items {
		if !a.canAccess(session, it.Path, false, false) {
			continue
		}
		items = append(items, fileInsightItemResponse{
			InsightItem: it,
			CanWrite:    a.canAccess(session, it.Path, true, false),
		})
	}
	jsonReply(w, http.StatusOK, map[string]any{
		"mode":         res.Mode,
		"minBytes":     res.MinBytes,
		"days":         res.Days,
		"scannedFiles": res.ScannedFiles,
		"matchedFiles": res.MatchedFiles,
		"totalBytes":   res.TotalBytes,
		"truncated":    res.Truncated,
		"timedOut":     res.TimedOut,
		"items":        items,
	})
}
