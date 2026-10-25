package tasks

import (
	"strings"
	"testing"
)

func TestRootMaintenanceStatusPersistsAndGenerationChangeInvalidatesSuccess(t *testing.T) {
	base:=t.TempDir()
	id:=strings.Repeat("a",32)
	other:=strings.Repeat("b",32)
	j,err:=Open(base)
	if err!=nil{t.Fatal(err)}
	if err:=j.UpdateRootMaintenance(id,1,"running");err!=nil{t.Fatal(err)}
	if err:=j.UpdateRootMaintenance(id,1,"ok");err!=nil{t.Fatal(err)}
	status,err:=j.RootMaintenanceStatus(id,1)
	if err!=nil||status.Status!="ok"||status.LastSuccess==0{t.Fatalf("recorded %+v %v",status,err)}
	if different,err:=j.RootMaintenanceStatus(other,1);err!=nil||different.Status!="pending"{
		t.Fatalf("different root leaked state: %+v %v",different,err)
	}
	if err:=j.Close();err!=nil{t.Fatal(err)}
	j,err=Open(base)
	if err!=nil{t.Fatal(err)}
	defer j.Close()
	status,err=j.RootMaintenanceStatus(id,1)
	if err!=nil||status.Status!="ok"{t.Fatalf("restart lost success: %+v %v",status,err)}
	status,err=j.RootMaintenanceStatus(id,2)
	if err!=nil||status.Status!="pending"||status.LastSuccess!=0 {
		t.Fatalf("new generation inherited prior success: %+v %v",status,err)
	}
	if err:=j.UpdateRootMaintenance(id,2,"offline");err!=nil{t.Fatal(err)}
	status,err=j.RootMaintenanceStatus(id,2)
	if err!=nil||status.Status!="offline"||status.LastSuccess!=0{t.Fatalf("new generation offline: %+v %v",status,err)}
	if err:=j.UpdateRootMaintenance("disk4",1,"ok");err==nil{t.Fatal("invalid root accepted")}
	if err:=j.UpdateRootMaintenance(id,2,"made_up");err==nil{t.Fatal("unknown state accepted")}
}

func TestRootMaintenanceInterruptedByRestartIsNotSuccess(t *testing.T){
	base:=t.TempDir()
	id:=strings.Repeat("e",32)
	j,err:=Open(base)
	if err!=nil{t.Fatal(err)}
	if err:=j.UpdateRootMaintenance(id,9,"running");err!=nil{t.Fatal(err)}
	if err:=j.Close();err!=nil{t.Fatal(err)}
	j,err=Open(base)
	if err!=nil{t.Fatal(err)}
	defer j.Close()
	state,err:=j.RootMaintenanceStatus(id,9)
	if err!=nil||state.Status!="interrupted"||state.LastSuccess!=0{
		t.Fatalf("running state survived restart as success: %+v %v",state,err)
	}
}
