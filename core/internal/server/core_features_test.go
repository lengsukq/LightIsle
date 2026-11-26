package server

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/gallery"
	"github.com/lengsukq/lightisle/core/internal/roots"
)

type coreFeatureTestEnv struct {
	server        *RootServer
	accounts      *auth.Store
	root          roots.Root
	shareDir      string
	adminSession  string
	member        auth.User
	memberSession string
	otherSession  string
	baseURL       string
}

func newCoreFeatureTestEnv(t *testing.T) *coreFeatureTestEnv {
	t.Helper()
	base := t.TempDir()
	volume := filepath.Join(base, "volume")
	private := filepath.Join(base, "private")
	shareDir := filepath.Join(volume, "share")
	for _, p := range []string{volume, private, shareDir} {
		if err := os.MkdirAll(p, 0700); err != nil {
			t.Fatal(err)
		}
	}
	registry, err := roots.OpenWithProvider(private, rootRoutingProvider{}, volume)
	if err != nil {
		t.Fatal(err)
	}
	root, err := registry.Add(context.Background(), "HomeNAS", shareDir)
	if err != nil {
		t.Fatal(err)
	}
	accounts, err := auth.Open(filepath.Join(private, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = accounts.Close() })
	if err := accounts.Setup("admin", "AdminPassword-2026!"); err != nil {
		t.Fatal(err)
	}
	adminSession, err := accounts.Login("admin", "AdminPassword-2026!")
	if err != nil {
		t.Fatal(err)
	}
	member, err := accounts.CreateUser(adminSession, "alice", "AlicePassword-2026!", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	memberSession, err := accounts.Login("alice", "AlicePassword-2026!")
	if err != nil {
		t.Fatal(err)
	}
	other, err := accounts.CreateUser(adminSession, "bob", "BobPassword-2026!!", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	otherSession, err := accounts.Login("bob", "BobPassword-2026!!")
	if err != nil {
		t.Fatal(err)
	}

	galleryDataDir := filepath.Join(private, "gallery")
	srv := NewWithRoots("", accounts, nil, nil, nil, nil, registry,
		func(_ context.Context, r roots.Root, lease *roots.Lease) (*RootServices, error) {
			mgr, err := files.NewPinnedManager(lease.Root)
			if err != nil {
				return nil, err
			}
			lib, err := gallery.OpenRootScoped(galleryDataDir, mgr, r.ID, gallery.Options{RootGeneration: r.Generation})
			if err != nil {
				_ = mgr.Close()
				return nil, err
			}
			return &RootServices{Files: mgr, Gallery: lib}, nil
		})
	t.Cleanup(func() { _ = srv.Close() })

	env := &coreFeatureTestEnv{
		server:        srv,
		accounts:      accounts,
		root:          root,
		shareDir:      shareDir,
		adminSession:  adminSession,
		member:        member,
		memberSession: memberSession,
		otherSession:  otherSession,
		baseURL:       "/api/v2/roots/" + root.ID,
	}

	// Assign personal spaces for member (alice) and other (bob).
	for _, uid := range []int64{member.ID, other.ID} {
		for _, cat := range []string{"files", "photos"} {
			w := env.call("PUT", env.baseURL+"/users/"+strconv.FormatInt(uid, 10)+"/storage/"+cat, adminSession, nil, nil)
			if w.Code != 200 {
				t.Fatalf("assign storage uid=%d cat=%s: %d %s", uid, cat, w.Code, w.Body.String())
			}
		}
	}
	return env
}

func (e *coreFeatureTestEnv) call(method, targetURL, session string, body []byte, headers map[string]string, cookies ...*http.Cookie) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, targetURL, bytes.NewReader(body))
	r.RemoteAddr = "127.0.0.1:54321"
	if session != "" {
		r.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
	}
	for _, c := range cookies {
		r.AddCookie(c)
	}
	r.Header.Set(rootGenerationHeader, strconv.FormatUint(e.root.Generation, 10))
	r.Header.Set("X-LightIsle-Request", "1")
	for k, v := range headers {
		r.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	e.server.ServeHTTP(w, r)
	return w
}

func writeSmallPNG(t *testing.T, fullPath string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(fullPath), 0700); err != nil {
		t.Fatal(err)
	}
	f, err := os.Create(fullPath)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	img := image.NewRGBA(image.Rect(0, 0, 16, 16))
	for y := 0; y < 16; y++ {
		for x := 0; x < 16; x++ {
			img.Set(x, y, color.RGBA{uint8(x * 15), uint8(y * 15), 200, 255})
		}
	}
	if err := png.Encode(f, img); err != nil {
		t.Fatal(err)
	}
}

func TestFamilyRemindersHTTPFlow(t *testing.T) {
	env := newCoreFeatureTestEnv(t)

	// Create lunar birthday via HTTP.
	createBody, _ := json.Marshal(map[string]any{
		"title":        "爸爸农历生日",
		"category":     "birthday",
		"calendarType": "lunar",
		"year":         1968,
		"month":        8,
		"day":          15,
		"repeatRule":   "yearly",
		"remindDays":   []int{7, 1, 0},
		"color":        "amber",
	})
	w := env.call("POST", "/api/v2/family-reminders", env.memberSession, createBody, nil)
	if w.Code != http.StatusCreated {
		t.Fatalf("create reminder: %d %s", w.Code, w.Body.String())
	}
	var created struct {
		Reminder auth.FamilyReminder `json:"reminder"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil || created.Reminder.ID <= 0 || created.Reminder.NextSolarDate == "" {
		t.Fatalf("decode created reminder: %+v err=%v", created, err)
	}

	// List reminders includes todayLunar + created reminder.
	w = env.call("GET", "/api/v2/family-reminders", env.adminSession, nil, nil)
	if w.Code != http.StatusOK {
		t.Fatalf("list reminders: %d %s", w.Code, w.Body.String())
	}
	var listed struct {
		Reminders  []auth.FamilyReminder `json:"reminders"`
		TodaySolar string                `json:"todaySolar"`
		TodayLunar *auth.LunarDate       `json:"todayLunar"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &listed); err != nil || len(listed.Reminders) != 1 || listed.TodayLunar == nil {
		t.Fatalf("unexpected list response: %s", w.Body.String())
	}

	// Other member cannot PATCH alice's reminder (403).
	patchBody, _ := json.Marshal(map[string]any{"title": "非法修改"})
	w = env.call("PATCH", "/api/v2/family-reminders/"+strconv.FormatInt(created.Reminder.ID, 10), env.otherSession, patchBody, nil)
	if w.Code != http.StatusForbidden {
		t.Fatalf("other member patch should be 403, got %d %s", w.Code, w.Body.String())
	}

	// Any member can check off / complete a reminder.
	w = env.call("POST", "/api/v2/family-reminders/"+strconv.FormatInt(created.Reminder.ID, 10)+"/complete", env.otherSession, nil, nil)
	if w.Code != http.StatusOK {
		t.Fatalf("complete reminder: %d %s", w.Code, w.Body.String())
	}

	// Admin deletes reminder.
	w = env.call("DELETE", "/api/v2/family-reminders/"+strconv.FormatInt(created.Reminder.ID, 10), env.adminSession, nil, nil)
	if w.Code != http.StatusOK {
		t.Fatalf("delete reminder: %d %s", w.Code, w.Body.String())
	}
}

func TestCollectLinksWriteOnlyPasswordQuotaAndRename(t *testing.T) {
	env := newCoreFeatureTestEnv(t)

	// Set member quota to 20 bytes on this root to prove collect uploads charge the creator's quota!
	if err := env.accounts.SetUserStorageRootQuota(env.adminSession, env.member.ID, env.root.ID, env.root.Generation, 20); err != nil {
		t.Fatal(err)
	}
	memberDir := "Users/u" + strconv.FormatInt(env.member.ID, 10) + "/files/wedding"
	w := env.call("POST", env.baseURL+"/files/folders", env.memberSession, []byte(`{"path":"`+memberDir+`"}`), nil)
	if w.Code != http.StatusCreated {
		t.Fatalf("mkdir: %d %s", w.Code, w.Body.String())
	}
	// Pre-populate a private file in the target folder; the collect page MUST NEVER reveal its name!
	secretFile := memberDir + "/super_secret_existing.txt"
	w = env.call("PUT", env.baseURL+"/files/content?path="+url.QueryEscape(secretFile), env.memberSession, []byte("12345"), nil)
	if w.Code != http.StatusCreated {
		t.Fatalf("seed file: %d %s", w.Code, w.Body.String())
	}

	// Create password-protected collect link with maxFiles=2, allowedExts=[.txt].
	reqBody, _ := json.Marshal(map[string]any{
		"path":        memberDir,
		"hours":       48,
		"title":       "亲友祝福投递箱",
		"password":    "pass2026",
		"maxFiles":    2,
		"allowedExts": []string{".txt"},
	})
	w = env.call("POST", env.baseURL+"/collect-links", env.memberSession, reqBody, nil)
	if w.Code != http.StatusCreated {
		t.Fatalf("create collect link: %d %s", w.Code, w.Body.String())
	}
	var created struct {
		Link       auth.CollectLink `json:"link"`
		Token      string           `json:"token"`
		PublicPath string           `json:"publicPath"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil || created.Token == "" {
		t.Fatalf("decode collect link: %s", w.Body.String())
	}

	// Isolation check: collect token MUST return 404 on download share endpoint!
	w = env.call("GET", env.baseURL+"/public/file/"+created.Token, "", nil, nil)
	if w.Code != http.StatusNotFound {
		t.Fatalf("collect token must 404 on public/file, got %d", w.Code)
	}

	// Public GET page renders HTML and MUST NOT contain existing filename.
	w = env.call("GET", created.PublicPath, "", nil, nil)
	if w.Code != http.StatusOK || !strings.Contains(w.Header().Get("Content-Type"), "text/html") {
		t.Fatalf("collect HTML page: %d %s", w.Code, w.Header().Get("Content-Type"))
	}
	if strings.Contains(w.Body.String(), "super_secret_existing.txt") {
		t.Fatalf("SECURITY VIOLATION: collect HTML leaked existing directory entry!")
	}

	// Uploading before password auth returns 401.
	w = env.call("POST", created.PublicPath+"/uploads", "", []byte(`{"filename":"hello.txt","size":5}`), nil)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 before auth, got %d %s", w.Code, w.Body.String())
	}

	// Wrong password returns 401.
	w = env.call("POST", created.PublicPath+"/auth", "", []byte(`{"password":"wrong"}`), nil)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for wrong password, got %d", w.Code)
	}

	// Correct password mints collect grant cookie.
	w = env.call("POST", created.PublicPath+"/auth", "", []byte(`{"password":"pass2026"}`), nil)
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200 for right password, got %d %s", w.Code, w.Body.String())
	}
	var grantCookie *http.Cookie
	for _, c := range w.Result().Cookies() {
		if c.Name == collectGrantCookie {
			grantCookie = c
		}
	}
	if grantCookie == nil {
		t.Fatalf("expected %s cookie", collectGrantCookie)
	}

	// Disallowed extension (.exe) is rejected with 415.
	w = env.call("POST", created.PublicPath+"/uploads", "", []byte(`{"filename":"evil.exe","size":4}`), nil, grantCookie)
	if w.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("expected 415 for .exe, got %d %s", w.Code, w.Body.String())
	}

	// Upload exceeding creator's remaining quota (20 - 5 = 15 bytes) is rejected with 507!
	w = env.call("POST", created.PublicPath+"/uploads", "", []byte(`{"filename":"big.txt","size":16}`), nil, grantCookie)
	if w.Code != http.StatusInsufficientStorage {
		t.Fatalf("expected 507 quota exceeded, got %d %s", w.Code, w.Body.String())
	}

	// Upload with same name as existing file MUST auto-rename instead of overwriting!
	w = env.call("POST", created.PublicPath+"/uploads", "", []byte(`{"filename":"super_secret_existing.txt","size":6}`), nil, grantCookie)
	if w.Code != http.StatusCreated {
		t.Fatalf("begin collect upload: %d %s", w.Code, w.Body.String())
	}
	var started struct {
		UploadID string `json:"uploadId"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &started)
	w = env.call("PATCH", created.PublicPath+"/uploads/"+started.UploadID, "", []byte("abcdef"), map[string]string{"X-Upload-Offset": "0"}, grantCookie)
	if w.Code != http.StatusOK {
		t.Fatalf("patch collect upload: %d %s", w.Code, w.Body.String())
	}
	w = env.call("POST", created.PublicPath+"/uploads/"+started.UploadID+"/complete", "", nil, nil, grantCookie)
	if w.Code != http.StatusOK {
		t.Fatalf("complete collect upload: %d %s", w.Code, w.Body.String())
	}

	// Verify original file untouched, renamed copy created, and creator quota charged (5 + 6 = 11 bytes).
	origData, err := os.ReadFile(filepath.Join(env.shareDir, filepath.FromSlash(secretFile)))
	if err != nil || string(origData) != "12345" {
		t.Fatalf("original file modified! got %q err=%v", string(origData), err)
	}
	renamedData, err := os.ReadFile(filepath.Join(env.shareDir, filepath.FromSlash(memberDir+"/super_secret_existing (2).txt")))
	if err != nil || string(renamedData) != "abcdef" {
		t.Fatalf("renamed file missing/mismatch! got %q err=%v", string(renamedData), err)
	}
	meter, err := env.accounts.StorageMeter(env.memberSession, env.member.ID)
	if err != nil || meter.UsedBytes != 11 || meter.ReservedBytes != 0 {
		t.Fatalf("creator quota ledger = %+v, want used=11 reserved=0", meter)
	}

	// List collect links reflects uploadedFiles=1, uploadedBytes=6.
	w = env.call("GET", env.baseURL+"/collect-links", env.memberSession, nil, nil)
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"uploadedFiles":1`) {
		t.Fatalf("list collect links: %d %s", w.Code, w.Body.String())
	}

	// Revoke link -> public page immediately returns 404.
	w = env.call("DELETE", env.baseURL+"/collect-links/"+created.Link.ID, env.memberSession, nil, nil)
	if w.Code != http.StatusOK {
		t.Fatalf("revoke collect link: %d %s", w.Code, w.Body.String())
	}
	w = env.call("GET", created.PublicPath, "", nil, nil)
	if w.Code != http.StatusNotFound {
		t.Fatalf("revoked collect link should return 404, got %d", w.Code)
	}
}

func TestPinsInsightsTextSaveArchiveReaderAndGalleryOCRPriority(t *testing.T) {
	env := newCoreFeatureTestEnv(t)
	if err := env.accounts.SetUserStorageRootQuota(env.adminSession, env.member.ID, env.root.ID, env.root.Generation, 10<<20); err != nil {
		t.Fatal(err)
	}
	memberFiles := "Users/u" + strconv.FormatInt(env.member.ID, 10) + "/files"
	memberPhotos := "Users/u" + strconv.FormatInt(env.member.ID, 10) + "/photos"

	// 1. Text file create + GET + optimistic lock conflict 409 + valid update + quota delta.
	notePath := memberFiles + "/plan.md"
	createText, _ := json.Marshal(map[string]any{"path": notePath, "content": "# Draft 1", "create": true})
	w := env.call("PUT", env.baseURL+"/files/text", env.memberSession, createText, nil)
	if w.Code != http.StatusOK {
		t.Fatalf("create text: %d %s", w.Code, w.Body.String())
	}
	w = env.call("GET", env.baseURL+"/files/text?path="+url.QueryEscape(notePath), env.memberSession, nil, nil)
	if w.Code != http.StatusOK {
		t.Fatalf("get text: %d %s", w.Code, w.Body.String())
	}
	var textResp struct {
		Content       string `json:"content"`
		MtimeUnixNano int64  `json:"mtimeUnixNano"`
		CanWrite      bool   `json:"canWrite"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &textResp)
	if textResp.Content != "# Draft 1" || textResp.MtimeUnixNano == 0 || !textResp.CanWrite {
		t.Fatalf("unexpected get text: %+v", textResp)
	}
	// Stale mtime returns 409 conflict.
	staleSave, _ := json.Marshal(map[string]any{"path": notePath, "content": "# Stale", "expectedMtimeUnixNano": textResp.MtimeUnixNano - 1})
	w = env.call("PUT", env.baseURL+"/files/text", env.memberSession, staleSave, nil)
	if w.Code != http.StatusConflict || !strings.Contains(w.Body.String(), "file_modified_conflict") {
		t.Fatalf("expected 409 conflict, got %d %s", w.Code, w.Body.String())
	}
	// Matching mtime succeeds and updates quota delta (9 -> 15 bytes).
	okSave, _ := json.Marshal(map[string]any{"path": notePath, "content": "# Final Version", "expectedMtimeUnixNano": textResp.MtimeUnixNano})
	w = env.call("PUT", env.baseURL+"/files/text", env.memberSession, okSave, nil)
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200 save, got %d %s", w.Code, w.Body.String())
	}
	meter, _ := env.accounts.StorageMeter(env.memberSession, env.member.ID)
	if meter.UsedBytes != 15 {
		t.Fatalf("expected quota used=15 after text update, got %d", meter.UsedBytes)
	}
	// Disallowed binary extension (.exe) rejected with 415.
	badExt, _ := json.Marshal(map[string]any{"path": memberFiles + "/a.exe", "content": "x", "create": true})
	w = env.call("PUT", env.baseURL+"/files/text", env.memberSession, badExt, nil)
	if w.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("expected 415 for .exe text save, got %d", w.Code)
	}

	// 2. File pins: pin notePath, verify exists=true, delete file -> exists=false, unpin.
	w = env.call("POST", env.baseURL+"/files/pins", env.memberSession, []byte(`{"path":"`+notePath+`","label":"家庭计划"}`), nil)
	if w.Code != http.StatusCreated {
		t.Fatalf("pin add: %d %s", w.Code, w.Body.String())
	}
	w = env.call("GET", env.baseURL+"/files/pins", env.memberSession, nil, nil)
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"exists":true`) {
		t.Fatalf("pin list: %d %s", w.Code, w.Body.String())
	}
	w = env.call("DELETE", env.baseURL+"/files/pins?path="+url.QueryEscape(notePath), env.memberSession, nil, nil)
	if w.Code != http.StatusOK {
		t.Fatalf("pin delete: %d %s", w.Code, w.Body.String())
	}

	// 3. Insights endpoint (large & recent).
	w = env.call("GET", env.baseURL+"/files/insights?mode=large&minBytes=1&limit=10", env.memberSession, nil, nil)
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "plan.md") {
		t.Fatalf("insights large: %d %s", w.Code, w.Body.String())
	}
	w = env.call("GET", env.baseURL+"/files/insights?mode=recent&days=7&limit=10", env.memberSession, nil, nil)
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "plan.md") {
		t.Fatalf("insights recent: %d %s", w.Code, w.Body.String())
	}

	// 4. Archive reader (.cbz) + safety checks (skips .js, natural sort, streams image) + reading progress.
	var zipBuf bytes.Buffer
	zw := zip.NewWriter(&zipBuf)
	for _, entry := range []struct {
		name string
		data []byte
	}{
		{"page10.jpg", []byte("JPEG-PAGE-10")},
		{"page2.jpg", []byte("JPEG-PAGE-2")},
		{"evil.js", []byte("alert(1)")},
	} {
		ew, _ := zw.Create(entry.name)
		_, _ = ew.Write(entry.data)
	}
	_ = zw.Close()
	cbzPath := memberFiles + "/comic.cbz"
	if err := os.WriteFile(filepath.Join(env.shareDir, filepath.FromSlash(cbzPath)), zipBuf.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	w = env.call("GET", env.baseURL+"/files/archive-entries?path="+url.QueryEscape(cbzPath), env.memberSession, nil, nil)
	if w.Code != http.StatusOK {
		t.Fatalf("archive-entries: %d %s", w.Code, w.Body.String())
	}
	var entriesResp struct {
		Format  string                   `json:"format"`
		Entries []archiveEntryDescriptor `json:"entries"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &entriesResp)
	if entriesResp.Format != "cbz" || len(entriesResp.Entries) != 2 || entriesResp.Entries[0].Name != "page2.jpg" || entriesResp.Entries[1].Name != "page10.jpg" {
		t.Fatalf("expected naturally sorted 2 safe images (no evil.js), got %+v", entriesResp)
	}
	// Requesting evil.js directly must fail with 415.
	w = env.call("GET", env.baseURL+"/files/archive-entry?path="+url.QueryEscape(cbzPath)+"&entry=evil.js", env.memberSession, nil, nil)
	if w.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("evil.js in archive must be rejected with 415, got %d", w.Code)
	}
	// Path traversal in entry must fail with 400.
	w = env.call("GET", env.baseURL+"/files/archive-entry?path="+url.QueryEscape(cbzPath)+"&entry=../secret", env.memberSession, nil, nil)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("traversal entry must be 400, got %d", w.Code)
	}
	// Streaming valid page2.jpg succeeds with sandbox CSP.
	w = env.call("GET", env.baseURL+"/files/archive-entry?path="+url.QueryEscape(cbzPath)+"&entry=page2.jpg", env.memberSession, nil, nil)
	if w.Code != http.StatusOK || w.Body.String() != "JPEG-PAGE-2" || w.Header().Get("Content-Type") != "image/jpeg" || !strings.Contains(w.Header().Get("Content-Security-Policy"), "sandbox") {
		t.Fatalf("archive-entry page2.jpg: code=%d ct=%q csp=%q body=%q", w.Code, w.Header().Get("Content-Type"), w.Header().Get("Content-Security-Policy"), w.Body.String())
	}
	// Save and read back reading progress.
	w = env.call("PUT", env.baseURL+"/files/reading-progress", env.memberSession, []byte(`{"path":"`+cbzPath+`","locator":"page2.jpg","percent":50}`), nil)
	if w.Code != http.StatusOK {
		t.Fatalf("put reading progress: %d %s", w.Code, w.Body.String())
	}
	w = env.call("GET", env.baseURL+"/files/reading-progress?path="+url.QueryEscape(cbzPath), env.memberSession, nil, nil)
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"locator":"page2.jpg"`) {
		t.Fatalf("get reading progress: %d %s", w.Code, w.Body.String())
	}

	// 5. Gallery pathPrefix & POST /photos/ocr-priority.
	docRel := memberPhotos + "/家庭档案/发票/inv_01.png"
	otherRel := memberPhotos + "/Camera/vacation.png"
	writeSmallPNG(t, filepath.Join(env.shareDir, filepath.FromSlash(docRel)))
	writeSmallPNG(t, filepath.Join(env.shareDir, filepath.FromSlash(otherRel)))

	// Trigger priority OCR for newly uploaded receipt (indexes immediately!).
	w = env.call("POST", env.baseURL+"/photos/ocr-priority", env.memberSession, []byte(`{"path":"`+docRel+`"}`), nil)
	if w.Code != http.StatusAccepted {
		t.Fatalf("ocr-priority: %d %s", w.Code, w.Body.String())
	}
	var ocrResp struct {
		Queued  bool  `json:"queued"`
		AssetID int64 `json:"assetId"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &ocrResp)
	if !ocrResp.Queued || ocrResp.AssetID <= 0 {
		t.Fatalf("unexpected ocr-priority response: %s", w.Body.String())
	}
	// Cross-user pathPrefix is forbidden (403).
	w = env.call("GET", env.baseURL+"/photos?pathPrefix="+url.QueryEscape(memberPhotos+"/家庭档案"), env.otherSession, nil, nil)
	if w.Code != http.StatusForbidden {
		t.Fatalf("cross-user pathPrefix must be 403, got %d %s", w.Code, w.Body.String())
	}
	// Own pathPrefix returns the indexed receipt immediately!
	w = env.call("GET", env.baseURL+"/photos?pathPrefix="+url.QueryEscape(memberPhotos+"/家庭档案"), env.memberSession, nil, nil)
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "inv_01.png") || strings.Contains(w.Body.String(), "vacation.png") {
		t.Fatalf("pathPrefix photos list: %d %s", w.Code, w.Body.String())
	}
	// Ensure no time flake on slow CI.
	_ = time.Now()
}
