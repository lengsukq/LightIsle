package server

import (
 "net/http"
 "net/http/httptest"
 "path/filepath"
 "strings"
 "testing"

 "github.com/lengsukq/lightisle/core/internal/auth"
 "github.com/lengsukq/lightisle/core/internal/tasks"
)

func TestAdminOnlyAlertCenterAndAcknowledgement(t *testing.T){
 dir:=t.TempDir()
 users,err:=auth.Open(filepath.Join(dir,"accounts.sqlite"));if err!=nil{t.Fatal(err)};defer users.Close()
 if err:=users.Setup("root","strong-root-password");err!=nil{t.Fatal(err)}
 admin,err:=users.Login("root","strong-root-password");if err!=nil{t.Fatal(err)}
 if _,err:=users.CreateUser(admin,"child","strong-child-password",auth.RoleMember);err!=nil{t.Fatal(err)}
 child,err:=users.Login("child","strong-child-password");if err!=nil{t.Fatal(err)}
 journal,err:=tasks.Open(dir);if err!=nil{t.Fatal(err)};defer journal.Close()
 if err:=journal.SyncAlert("storage_offline",true);err!=nil{t.Fatal(err)}
 handler:=NewWithJournal("",users,nil,nil,nil,journal)
 call:=func(method,route,session string)*httptest.ResponseRecorder{
  request:=httptest.NewRequest(method,route,nil)
  request.AddCookie(&http.Cookie{Name:sessionCookie,Value:session})
  if method!="GET"{request.Header.Set("X-LightIsle-Request","1")}
  result:=httptest.NewRecorder()
  handler.ServeHTTP(result,request)
  return result
 }
 if got:=call("GET","/api/v1/alerts",child);got.Code!=403 {t.Fatalf("member accessed alerts: %d",got.Code)}
 if got:=call("POST","/api/v1/alerts/storage_offline/acknowledge",child);got.Code!=403 {t.Fatalf("member acknowledged admin alerts: %d",got.Code)}
 if got:=call("GET","/api/v1/alerts",admin);got.Code!=200||!strings.Contains(got.Body.String(),"storage_offline") {t.Fatalf("admin did not see alert: %d %s",got.Code,got.Body.String())}
 if got:=call("POST","/api/v1/alerts/storage_offline/acknowledge",admin);got.Code!=200 {t.Fatalf("admin ack failed: %d %s",got.Code,got.Body.String())}
 if got:=call("GET","/api/v1/alerts",admin);got.Code!=200||!strings.Contains(got.Body.String(),`"acknowledged":true`) {
  t.Fatalf("ack state not exposed: %d %s",got.Code,got.Body.String())
 }
 if got:=call("POST","/api/v1/alerts/unknown/acknowledge",admin);got.Code!=404{t.Fatalf("accepted arbitrary alert: %d",got.Code)}
}
