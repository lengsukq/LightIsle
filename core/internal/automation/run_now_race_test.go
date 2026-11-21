package automation

import (
	"errors"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestRunNowDisabledTaskPreservesEnabledStateAndRejectsConcurrentClicks(t *testing.T) {
	base := t.TempDir()
	gateFile := filepath.Join(base, "release.gate")
	startedFile := filepath.Join(base, "started.flag")
	script := "touch " + startedFile + "\nwhile [ ! -f " + gateFile + " ]; do sleep 0.02; done\necho done-ok\n"
	createTask(t, base, "paused-job", script, false)

	m, err := New(base, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()

	// Trigger concurrent RunNow calls against the same paused task.
	const callers = 8
	var succeeded atomic.Int32
	var busy atomic.Int32
	var startWG sync.WaitGroup
	start := make(chan struct{})
	for i := 0; i < callers; i++ {
		startWG.Add(1)
		go func() {
			defer startWG.Done()
			<-start
			err := m.RunNow("paused-job")
			switch {
			case err == nil:
				succeeded.Add(1)
			case errors.Is(err, ErrBusy):
				busy.Add(1)
			default:
				t.Errorf("unexpected RunNow error: %v", err)
			}
		}()
	}
	close(start)
	startWG.Wait()

	if succeeded.Load() != 1 || busy.Load() != callers-1 {
		t.Fatalf("expected exactly 1 accepted run and %d busy rejections, got ok=%d busy=%d",
			callers-1, succeeded.Load(), busy.Load())
	}

	// Wait until the script has started running.
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, statErr := os.Stat(startedFile); statErr == nil {
			break
		}
		time.Sleep(15 * time.Millisecond)
	}
	if _, statErr := os.Stat(startedFile); statErr != nil {
		t.Fatal("manual run did not start script")
	}

	// While running, Enabled must still reflect false (never temporarily flipped to true)
	// and Running must be true.
	tasks := m.List()
	if len(tasks) != 1 {
		t.Fatalf("unexpected task count: %+v", tasks)
	}
	if tasks[0].Enabled {
		t.Fatal("RunNow temporarily mutated Enabled to true")
	}
	if !tasks[0].Running {
		t.Fatal("expected task to report Running=true while executing")
	}

	// Admin enables the task while the manual run is still in progress.
	if err := m.Update("paused-job", true, Schedule{Cron: "0 9 * * *", Timezone: "UTC"}, Notification{}); err != nil {
		t.Fatalf("enable while running: %v", err)
	}

	// Release the script and wait for completion.
	if err := os.WriteFile(gateFile, []byte("go"), 0600); err != nil {
		t.Fatal(err)
	}
	deadline = time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if !m.List()[0].Running {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	final := m.List()
	if len(final) != 1 || final[0].Running {
		t.Fatalf("task did not finish cleanly: %+v", final)
	}
	if !final[0].Enabled {
		t.Fatal("manual run completion overwrote admin's Enabled=true setting back to false")
	}
	history, err := m.History("paused-job")
	if err != nil || len(history) != 1 || history[0].State != "success" {
		t.Fatalf("expected 1 successful run in history, got %+v (err=%v)", history, err)
	}
}
