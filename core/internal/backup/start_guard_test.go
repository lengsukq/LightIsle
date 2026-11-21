package backup

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestServiceCompletionSnapshotIsNotOverwrittenByNextJob(t *testing.T) {
	service := New()
	first, err := service.startWithCompletion("backup", "first", func(context.Context, string) (string, error) {
		return "first-snapshot", errors.New("first job failed")
	})
	if err != nil {
		t.Fatal(err)
	}
	var firstStatus Status
	select {
	case firstStatus = <-first:
	case <-time.After(time.Second):
		t.Fatal("first job completion was not published")
	}
	if firstStatus.LastError != "first job failed" || firstStatus.LastSnapshot != "first-snapshot" {
		t.Fatalf("first job completion did not retain its own result: %+v", firstStatus)
	}

	work := make(chan struct{})
	second, err := service.startWithCompletion("backup", "second", func(context.Context, string) (string, error) {
		<-work
		return "second-snapshot", nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if status := service.Status(); !status.Running || status.Operation != "backup" {
		t.Fatalf("second job did not start: %+v", status)
	}
	if firstStatus.LastError != "first job failed" {
		t.Fatalf("next job overwrote the previous result: %+v", firstStatus)
	}
	close(work)
	select {
	case status := <-second:
		if status.LastError != "" || status.LastSnapshot != "second-snapshot" {
			t.Fatalf("second job completion is wrong: %+v", status)
		}
	case <-time.After(time.Second):
		t.Fatal("second job completion was not published")
	}
	service.Close()
}
