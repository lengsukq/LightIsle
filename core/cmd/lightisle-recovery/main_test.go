//go:build darwin && arm64

package main

import (
	"bytes"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

func TestRunListEmitsVersionedJSON(t *testing.T) {
	dataDir := filepath.Join(t.TempDir(), "LightIsle")
	var stdout, stderr bytes.Buffer
	code := run([]string{"--operation", "list", "--data-dir", dataDir}, &stdout, &stderr, os.Getppid, nil)
	if code != 0 {
		t.Fatalf("list exit=%d stderr=%s stdout=%s", code, stderr.String(), stdout.String())
	}
	var response struct {
		SchemaVersion int    `json:"schemaVersion"`
		Operation     string `json:"operation"`
		Transactions  []struct {
			ID          string `json:"id"`
			State       string `json:"state"`
			CanRollback bool   `json:"canRollback"`
			FileCount   int    `json:"fileCount"`
		} `json:"transactions"`
		Truncated bool `json:"truncated"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(stdout.Bytes()), &response); err != nil {
		t.Fatalf("invalid list JSON %q: %v", stdout.String(), err)
	}
	if response.SchemaVersion != 1 || response.Operation != "list" || response.Transactions == nil || response.Truncated {
		t.Fatalf("unexpected list response: %+v", response)
	}
}

func TestRunRejectsParentMismatchBeforeFilesystemChanges(t *testing.T) {
	dataDir := filepath.Join(t.TempDir(), "must-not-be-created")
	var stdout, stderr bytes.Buffer
	code := run([]string{"--operation", "list", "--data-dir", dataDir, "--parent-pid", "700"}, &stdout, &stderr, func() int { return 701 }, nil)
	if code != 125 {
		t.Fatalf("parent mismatch exit=%d stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
	if _, err := os.Lstat(dataDir); !os.IsNotExist(err) {
		t.Fatalf("mismatched parent created data directory: %v", err)
	}
	var response struct {
		SchemaVersion int    `json:"schemaVersion"`
		Operation     string `json:"operation"`
		Status        string `json:"status"`
		Error         struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(stdout.Bytes()), &response); err != nil {
		t.Fatalf("invalid mismatch JSON %q: %v", stdout.String(), err)
	}
	if response.SchemaVersion != 1 || response.Operation != "list" || response.Status != "blocked" || response.Error.Code != "parent_process_mismatch" {
		t.Fatalf("unexpected mismatch response: %+v", response)
	}
}

func TestPreviewRequiresNativeParentAndReturnsCountOnlyContract(t *testing.T) {
	dataDir := filepath.Join(t.TempDir(), "LightIsle")
	if err := os.Mkdir(dataDir, 0700); err != nil {
		t.Fatal(err)
	}
	writeDB := func(name string, count int) {
		t.Helper()
		db, err := sql.Open("sqlite3", name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := db.Exec(`CREATE TABLE users(id INTEGER PRIMARY KEY,username TEXT,password_hash BLOB)`); err != nil {
			db.Close()
			t.Fatal(err)
		}
		for i := 0; i < count; i++ {
			if _, err := db.Exec(`INSERT INTO users(username,password_hash) VALUES(?,x'736563726574')`, "private-user"); err != nil {
				db.Close()
				t.Fatal(err)
			}
		}
		if err := db.Close(); err != nil {
			t.Fatal(err)
		}
	}
	writeDB(filepath.Join(dataDir, "accounts.sqlite"), 1)
	stageName := "LightIsle-RestoredMetadata-cli-preview"
	stage := filepath.Join(dataDir, stageName)
	if err := os.Mkdir(stage, 0700); err != nil {
		t.Fatal(err)
	}
	writeDB(filepath.Join(stage, "accounts.sqlite"), 2)
	stagedBytes, err := os.ReadFile(filepath.Join(stage, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(stagedBytes)
	manifestBytes, err := json.Marshal([]struct {
		Path   string `json:"path"`
		Size   int64  `json:"size"`
		SHA256 string `json:"sha256"`
	}{{Path: "accounts.sqlite", Size: int64(len(stagedBytes)), SHA256: hex.EncodeToString(digest[:])}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stage, "metadata-manifest.json"), manifestBytes, 0600); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	code := run([]string{"--operation", "preview", "--data-dir", dataDir, "--stage", stageName},
		&stdout, &stderr, os.Getppid, nil)
	if code != 2 {
		t.Fatalf("preview without owner parent exit=%d stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
	var denied struct {
		Status string `json:"status"`
		Error  struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(stdout.Bytes()), &denied); err != nil || denied.Status != "failed" || denied.Error.Code != "owner_process_required" {
		t.Fatalf("unexpected unowned preview response: %+v err=%v output=%s", denied, err, stdout.String())
	}

	stdout.Reset()
	stderr.Reset()
	code = run([]string{"--operation", "preview", "--data-dir", dataDir, "--stage", stageName, "--parent-pid", "777"},
		&stdout, &stderr, func() int { return 777 }, nil)
	if code != 0 {
		t.Fatalf("owned preview exit=%d stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
	var response struct {
		SchemaVersion  int    `json:"schemaVersion"`
		Operation      string `json:"operation"`
		Status         string `json:"status"`
		Verified       bool   `json:"verified"`
		ManifestSHA256 string `json:"manifestSHA256"`
		Counts         map[string]struct {
			Current *int64 `json:"current"`
			Staged  *int64 `json:"staged"`
			Delta   *int64 `json:"delta"`
		} `json:"counts"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(stdout.Bytes()), &response); err != nil {
		t.Fatalf("invalid preview JSON %q: %v", stdout.String(), err)
	}
	count := response.Counts["accounts.users"]
	if response.SchemaVersion != 1 || response.Operation != "preview" || response.Status != "ready" || !response.Verified ||
		len(response.ManifestSHA256) != 64 || count.Current == nil || count.Staged == nil || count.Delta == nil ||
		*count.Current != 1 || *count.Staged != 2 || *count.Delta != 1 {
		t.Fatalf("unexpected preview response: %+v", response)
	}
	for _, sensitive := range []string{"private-user", "password_hash", dataDir, stageName} {
		if strings.Contains(stdout.String(), sensitive) {
			t.Fatalf("preview output leaked %q", sensitive)
		}
	}
}

func TestParentMonitorExitsWhenParentChanges(t *testing.T) {
	var current atomic.Int64
	current.Store(50)
	called := make(chan int, 1)
	done := make(chan struct{})
	go monitorParent(50, func() int { return int(current.Load()) }, func(code int) { called <- code }, done, time.Millisecond)
	current.Store(1)
	select {
	case code := <-called:
		if code != 125 {
			t.Fatalf("parent loss exit=%d, want 125", code)
		}
	case <-time.After(time.Second):
		close(done)
		t.Fatal("parent monitor did not detect parent process loss")
	}
	close(done)
}
