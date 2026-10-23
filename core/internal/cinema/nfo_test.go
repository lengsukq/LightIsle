package cinema

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestLocalNFOImportPreservesFileAndManualTitle(t *testing.T) {
	data := t.TempDir()
	store, err := files.NewManager(data)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	root := filepath.Join(data, "SharedFiles")
	movie := filepath.Join(root, "Movie.2026.mp4")
	const original = "immutable-media"
	if err := os.WriteFile(movie, []byte(original), 0600); err != nil {
		t.Fatal(err)
	}
	nfo := filepath.Join(root, "Movie.2026.nfo")
	const metadata = `<?xml version="1.0" encoding="UTF-8"?>
<movie><title>中文电影名</title><plot>电影简介 &amp; 详情。</plot><rating>8.5</rating></movie>`
	if err := os.WriteFile(nfo, []byte(metadata), 0600); err != nil {
		t.Fatal(err)
	}
	library, err := Open(data, store)
	if err != nil {
		t.Fatal(err)
	}
	defer library.Close()
	if err := library.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for library.Status().Running && time.Now().Before(deadline) {
		time.Sleep(15 * time.Millisecond)
	}
	list, _, err := library.List(1, "", "", 20, 0)
	if err != nil || len(list) != 1 {
		t.Fatalf("list: %+v %v", list, err)
	}
	asset := list[0]
	imported, err := library.ImportLocalNFO(asset.ID)
	if err != nil {
		t.Fatal(err)
	}
	if imported.Title != "中文电影名" || imported.Overview != "电影简介 & 详情。" || imported.Rating != 8.5 ||
		imported.MetadataSource != "nfo:Movie.2026.nfo" {
		t.Fatalf("imported unexpected result: %+v", imported)
	}
	if err := library.Rename(asset.ID, "管理员手动命名"); err != nil {
		t.Fatal(err)
	}
	if _, err := library.ImportLocalNFO(asset.ID); err != nil {
		t.Fatal(err)
	}
	updated, err := library.Get(asset.ID, 1)
	if err != nil || updated.Title != "管理员手动命名" || updated.Overview == "" {
		t.Fatalf("overwrote manual title: %+v %v", updated, err)
	}
	if err := library.StartScan(); err != nil {
		t.Fatal(err)
	}
	for library.Status().Running && time.Now().Before(deadline.Add(4*time.Second)) {
		time.Sleep(15 * time.Millisecond)
	}
	after, err := library.Get(asset.ID, 1)
	if err != nil || after.MetadataSource != imported.MetadataSource || after.Overview != imported.Overview {
		t.Fatalf("rescan lost metadata: %+v %v", after, err)
	}
	current, err := os.ReadFile(movie)
	if err != nil || string(current) != original {
		t.Fatalf("NFO import changed video: %q %v", string(current), err)
	}
}

func TestNFOParserRejectsMalformedAndOversizedMetadata(t *testing.T) {
	for _, value := range []string{
		`<html><title>forged</title></html>`,
		`<movie><plot>missing title</plot></movie>`,
		`<movie><title>x</title><rating>11</rating></movie>`,
		`<movie><title>x</title><rating>-1</rating></movie>`,
		`<movie><title>x</title><plot>` + strings.Repeat("a", maxNFOBytes) + `</plot></movie>`,
		`<!DOCTYPE movie [<!ENTITY bad SYSTEM "file:///etc/passwd">]><movie><title>&bad;</title></movie>`,
	} {
		if _, err := parseNFO(strings.NewReader(value)); !errors.Is(err, ErrInvalid) {
			t.Fatalf("accepted invalid or dangerous NFO: %q %v", value[:min(len(value), 70)], err)
		}
	}
}
