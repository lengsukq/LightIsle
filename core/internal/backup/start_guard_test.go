package backup

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestServiceStartGuardRejectsAndReleasesAfterRunningTransition(t *testing.T) {
	blocked := New(nil)
	blocked.SetStartGuard(func() (func(), bool) { return nil, false })
	if err := blocked.start("backup", "unused", func(context.Context, string) (string, error) {
		t.Fatal("rejected job executed")
		return "", nil
	}); !errors.Is(err, files.ErrLegacyTransitionBusy) {
		t.Fatalf("rejected start did not return busy: %v", err)
	}
	if blocked.Status().Running {
		t.Fatal("rejected job changed service state")
	}
	blocked.Close()

	service := New(nil)
	guardReleased := make(chan bool, 1)
	service.SetStartGuard(func() (func(), bool) {
		return func() { guardReleased <- service.Status().Running }, true
	})
	work := make(chan struct{})
	if err := service.start("backup", "unused", func(context.Context, string) (string, error) {
		<-work
		return "snapshot", nil
	}); err != nil {
		t.Fatal(err)
	}
	select {
	case running := <-guardReleased:
		if !running {
			t.Fatal("start guard was released before Running became true")
		}
	case <-time.After(time.Second):
		t.Fatal("start guard was not released")
	}
	close(work)
	waitForServiceIdle(t, service)
	service.Close()
}

func TestServiceCompletionSnapshotIsNotOverwrittenByNextJob(t *testing.T) {
	service := New(nil)
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

func TestClosingCompletedPlanDoesNotCancelSubsequentManualJob(t *testing.T) {
	for attempt := 0; attempt < 64; attempt++ {
		service := New(nil)
		manualCanceled := make(chan struct{})
		manualCompletion, err := service.startWithCompletion("backup", "manual", func(ctx context.Context, _ string) (string, error) {
			<-ctx.Done()
			close(manualCanceled)
			return "", ctx.Err()
		})
		if err != nil {
			t.Fatalf("start manual job on attempt %d: %v", attempt, err)
		}

		planCtx, cancelPlan := context.WithCancel(context.Background())
		planCompletion := make(chan Status, 1)
		planCompletion <- Status{LastDone: time.Now().Unix()}
		close(planCompletion)
		// Make both cases ready before the tracker starts. A plan close must
		// only release the completed plan lease, never cancel a later manual job.
		cancelPlan()
		scheduler := &Scheduler{rootPlan: true, ctx: planCtx, cancel: cancelPlan}
		scheduler.trackScheduledJob(planCompletion, func() error { return nil })
		if err := scheduler.Close(); err != nil {
			t.Fatalf("close scheduler on attempt %d: %v", attempt, err)
		}
		select {
		case <-manualCanceled:
			t.Fatalf("closing completed plan cancelled manual job on attempt %d", attempt)
		case <-time.After(5 * time.Millisecond):
		}

		if !service.Cancel() {
			t.Fatalf("manual job was no longer running on attempt %d", attempt)
		}
		select {
		case <-manualCanceled:
		case <-time.After(time.Second):
			t.Fatalf("manual job did not respond to its own cancellation on attempt %d", attempt)
		}
		select {
		case <-manualCompletion:
		case <-time.After(time.Second):
			t.Fatalf("manual job did not finish on attempt %d", attempt)
		}
		service.Close()
	}
}

func waitForServiceIdle(t *testing.T, service *Service) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if !service.Status().Running {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("backup service stayed busy: %+v", service.Status())
}
