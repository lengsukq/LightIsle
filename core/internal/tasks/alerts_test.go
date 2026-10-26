package tasks

import "testing"

func TestAlertsDeduplicateAckResolveAndReopen(t *testing.T) {
	j, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer j.Close()
	if becameActive, err := j.SyncAlert("storage_offline", true); err != nil || !becameActive {
		t.Fatalf("initial activation = %v %v", becameActive, err)
	}
	first, err := j.Alerts(true)
	if err != nil || len(first) != 1 || first[0].Acknowledged || !first[0].Active {
		t.Fatalf("initial notification: %+v %v", first, err)
	}
	if err := j.AcknowledgeAlert("storage_offline"); err != nil {
		t.Fatal(err)
	}
	if becameActive, err := j.SyncAlert("storage_offline", true); err != nil || becameActive {
		t.Fatalf("duplicate polling re-announced = %v %v", becameActive, err)
	}
	repeated, err := j.Alerts(true)
	if err != nil || len(repeated) != 1 || !repeated[0].Acknowledged || repeated[0].FirstSeen != first[0].FirstSeen {
		t.Fatalf("duplicate polling reset acknowledgment: %+v %v", repeated, err)
	}
	if becameActive, err := j.SyncAlert("storage_offline", false); err != nil || becameActive {
		t.Fatalf("resolution announced = %v %v", becameActive, err)
	}
	active, err := j.Alerts(true)
	if err != nil || len(active) != 0 {
		t.Fatalf("resolved alert remains active: %+v %v", active, err)
	}
	if becameActive, err := j.SyncAlert("storage_offline", true); err != nil || !becameActive {
		t.Fatalf("reopen did not re-announce = %v %v", becameActive, err)
	}
	reopened, err := j.Alerts(true)
	if err != nil || len(reopened) != 1 || reopened[0].Acknowledged {
		t.Fatalf("new incident did not notify again: %+v %v", reopened, err)
	}
	if _, err := j.SyncAlert("anything", true); err == nil {
		t.Fatal("unknown alert accepted")
	}
	if err := j.AcknowledgeAlert("anything"); err == nil {
		t.Fatal("unknown alert acknowledge accepted")
	}
}
