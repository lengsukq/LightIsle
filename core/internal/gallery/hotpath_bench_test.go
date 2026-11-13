package gallery

import (
	"fmt"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func setupGalleryHotPathBench(b *testing.B) *Library {
	b.Helper()
	root := b.TempDir()
	storage, err := files.NewManager(root)
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() { _ = storage.Close() })
	lib, err := Open(filepath.Join(b.TempDir(), "gallery-meta"), storage)
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() { _ = lib.Close() })

	share, err := lib.share()
	if err != nil {
		b.Fatal(err)
	}
	tx, err := lib.db.Begin()
	if err != nil {
		b.Fatal(err)
	}
	now := time.Now().Unix()
	vec := encodeFloat32Vector([]float32{1, 0, 0, 0})
	for i := 1; i <= 60; i++ {
		res, err := tx.Exec(`INSERT INTO assets(share,path,type,size,modified,taken_at,camera_model,missing_path)
			VALUES(?,?,?,?,?,?,'iPhone 16 Pro','')`,
			share, fmt.Sprintf("Photos/2026/img_%03d.jpg", i), "photo", 204800, now*1e9, now-int64(i*3600))
		if err != nil {
			_ = tx.Rollback()
			b.Fatal(err)
		}
		assetID, _ := res.LastInsertId()
		fRes, err := tx.Exec(`INSERT INTO asset_faces(asset_id,box_x,box_y,box_w,box_h,quality,eye_openness,model_version,embedding)
			VALUES(?,0.2,0.2,0.3,0.3,0.92,0.95,'v1',?)`, assetID, vec)
		if err != nil {
			_ = tx.Rollback()
			b.Fatal(err)
		}
		faceID, _ := fRes.LastInsertId()
		pRes, err := tx.Exec(`INSERT INTO persons(share,user_id,model_version,name,cover_face_id,centroid,face_count,is_hidden,updated_at)
			VALUES(?,1,'v1',?,?,?,1,0,?)`, share, fmt.Sprintf("Person %02d", i), faceID, vec, now)
		if err != nil {
			_ = tx.Rollback()
			b.Fatal(err)
		}
		personID, _ := pRes.LastInsertId()
		if _, err := tx.Exec(`INSERT INTO person_face_links(user_id,face_id,person_id) VALUES(1,?,?)`, faceID, personID); err != nil {
			_ = tx.Rollback()
			b.Fatal(err)
		}
	}
	if err := tx.Commit(); err != nil {
		b.Fatal(err)
	}
	return lib
}

func BenchmarkHotPath_ListPersons60(b *testing.B) {
	lib := setupGalleryHotPathBench(b)
	roots := []string{"."}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		out, err := lib.ListPersonsScoped(1, false, roots)
		if err != nil || len(out) != 60 || out[0].CoverAssetID == 0 {
			b.Fatalf("unexpected ListPersonsScoped: len=%d err=%v", len(out), err)
		}
	}
}

func BenchmarkHotPath_GalleryReadsUnderWriteContention(b *testing.B) {
	lib := setupGalleryHotPathBench(b)
	roots := []string{"."}
	var stop atomic.Bool
	writerDone := make(chan struct{})
	go func() {
		defer close(writerDone)
		for !stop.Load() {
			tx, err := lib.db.Begin()
			if err != nil {
				continue
			}
			_, _ = tx.Exec(`UPDATE assets SET width=4032 WHERE id=1`)
			time.Sleep(500 * time.Microsecond)
			_ = tx.Commit()
		}
	}()
	b.Cleanup(func() {
		stop.Store(true)
		<-writerDone
	})

	b.ReportAllocs()
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			if _, err := lib.TimelineScoped(roots); err != nil {
				b.Errorf("TimelineScoped failed: %v", err)
				return
			}
			if _, err := lib.FacetsScoped(roots); err != nil {
				b.Errorf("FacetsScoped failed: %v", err)
				return
			}
			if _, _, err := lib.FaceAssetAndBox(1); err != nil {
				b.Errorf("FaceAssetAndBox failed: %v", err)
				return
			}
		}
	})
	b.StopTimer()
	stop.Store(true)
}

func TestGalleryHotPathReadsNeverBlockOnActiveWriteTransaction(t *testing.T) {
	root := t.TempDir()
	storage, err := files.NewManager(root)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	lib, err := Open(filepath.Join(t.TempDir(), "gallery-meta"), storage)
	if err != nil {
		t.Fatal(err)
	}
	defer lib.Close()

	share, err := lib.share()
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().Unix()
	vec := encodeFloat32Vector([]float32{1, 0, 0, 0})
	res, err := lib.db.Exec(`INSERT INTO assets(share,path,type,size,modified,taken_at,camera_model,missing_path)
		VALUES(?,?,?,204800,?,?,'iPhone 16 Pro','')`, share, "Photos/2026/a.jpg", "photo", now*1e9, now)
	if err != nil {
		t.Fatal(err)
	}
	assetID, _ := res.LastInsertId()
	fRes, err := lib.db.Exec(`INSERT INTO asset_faces(asset_id,box_x,box_y,box_w,box_h,quality,eye_openness,model_version,embedding)
		VALUES(?,0.2,0.2,0.3,0.3,0.9,0.9,'v1',?)`, assetID, vec)
	if err != nil {
		t.Fatal(err)
	}
	faceID, _ := fRes.LastInsertId()
	pRes, err := lib.db.Exec(`INSERT INTO persons(share,user_id,model_version,name,cover_face_id,centroid,face_count,is_hidden,updated_at)
		VALUES(?,1,'v1','Alice',?,?,1,0,?)`, share, faceID, vec, now)
	if err != nil {
		t.Fatal(err)
	}
	personID, _ := pRes.LastInsertId()
	if _, err := lib.db.Exec(`INSERT INTO person_face_links(user_id,face_id,person_id) VALUES(1,?,?)`, faceID, personID); err != nil {
		t.Fatal(err)
	}

	// Hold the single write-pool connection inside an active transaction.
	tx, err := lib.db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`UPDATE assets SET width=4032 WHERE id=?`, assetID); err != nil {
		t.Fatal(err)
	}

	done := make(chan error, 1)
	go func() {
		persons, err := lib.ListPersonsScoped(1, false, []string{"."})
		if err != nil {
			done <- err
			return
		}
		if len(persons) != 1 || persons[0].CoverAssetID != assetID {
			done <- fmt.Errorf("unexpected persons result: %+v", persons)
			return
		}
		if _, err := lib.TimelineScoped([]string{"."}); err != nil {
			done <- err
			return
		}
		if _, err := lib.FacetsScoped([]string{"."}); err != nil {
			done <- err
			return
		}
		if gotAsset, _, err := lib.FaceAssetAndBox(faceID); err != nil || gotAsset.ID != assetID {
			done <- fmt.Errorf("FaceAssetAndBox got (%+v, %v)", gotAsset, err)
			return
		}
		done <- nil
	}()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("gallery read hot-path failed under active write tx: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("gallery read hot-path blocked behind uncommitted write-pool transaction")
	}
}
