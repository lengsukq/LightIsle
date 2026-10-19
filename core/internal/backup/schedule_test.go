package backup

import (
 "os"
 "path/filepath"
 "testing"
 "time"

 "github.com/lengsukq/lightisle/core/internal/files"
)

func TestScheduledBackupPersistsAndStops(t *testing.T) {
 work:=t.TempDir()
 manager,err:=files.NewManager(work);if err!=nil{t.Fatal(err)}
 defer manager.Close()
 source:=filepath.Join(work,"SharedFiles")
 if err:=os.WriteFile(filepath.Join(source,"important.txt"),[]byte("schedule test"),0600);err!=nil{t.Fatal(err)}
 home,err:=os.UserHomeDir();if err!=nil{t.Fatal(err)}
 destination,err:=os.MkdirTemp(home,"lightisle-schedule-test-");if err!=nil{t.Fatal(err)}
 defer os.RemoveAll(destination)
 service:=New(manager);defer service.Close()
 scheduler,err:=NewScheduler(service,work);if err!=nil{t.Fatal(err)}
 if err:=scheduler.Configure(source,24);err==nil{t.Fatal("scheduled backup into source accepted")}
 if err:=scheduler.Configure(destination,12);err==nil{t.Fatal("unsupported hourly schedule accepted")}
 if err:=scheduler.Configure(destination,24);err!=nil{t.Fatal(err)}
 state:=scheduler.Status()
 if !state.Enabled||state.EveryHours!=24||state.NextRun<=time.Now().Unix(){t.Fatalf("wrong scheduled time: %+v",state)}
 scheduler.runDue(time.Unix(state.NextRun+1,0))
 done:=await(t,service)
 if done.LastError!=""||done.LastSnapshot==""{t.Fatalf("scheduled backup failed: %+v",done)}
 if scheduler.Status().LastAttempt==0{t.Fatal("scheduled run not persisted")}
 scheduler.Close()
 reopened,err:=NewScheduler(service,work);if err!=nil{t.Fatal(err)}
 if !reopened.Status().Enabled||reopened.Status().LastAttempt==0{t.Fatal("schedule not persisted")}
 if err:=reopened.Disable();err!=nil{t.Fatal(err)}
 if reopened.Status().Enabled{t.Fatal("disable failed")}
 reopened.Close()
}

