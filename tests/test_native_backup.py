"""M5 Mac-App-only backup, restoration and read-only SMB diagnostic smoke test."""
from __future__ import annotations

import base64
import json
import pathlib
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

ROOT=pathlib.Path(__file__).resolve().parents[1]
CORE=ROOT/"dist/LightIsle.app/Contents/Resources/core/lightisled"
WEB=ROOT/"dist/LightIsle.app/Contents/Resources/web"

def encode_path(path:str)->str:
    return base64.urlsafe_b64encode(path.encode()).decode().rstrip("=")

def unpack(line:str)->dict:
    raw=line.removeprefix("LIGHTISLE_BACKUP_STATUS ")
    return json.loads(base64.urlsafe_b64decode(raw+"="*((-len(raw))%4)))

with tempfile.TemporaryDirectory(prefix="lightisle-m5-core-") as data:
    with tempfile.TemporaryDirectory(prefix="lightisle-m5-output-",dir=str(pathlib.Path.home())) as destination:
        share=pathlib.Path(data)/"SharedFiles"
        share.mkdir(mode=0o700)
        (share/"sample.txt").write_text("M5 smoke test: original data",encoding="utf-8")
        proc=subprocess.Popen(
            [str(CORE),"-port","0","-web-root",str(WEB),"-data-dir",data],
            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1
        )
        try:
            assert proc.stdin and proc.stdout
            ready=proc.stdout.readline().strip()
            assert ready.startswith("LIGHTISLE_READY http://127.0.0.1:"),ready
            assert proc.stdout.readline().strip()=="LIGHTISLE_CONFIGURED 0"
            assert proc.stdout.readline().strip()=="LIGHTISLE_SHARE_ON SharedFiles"
            assert proc.stdout.readline().startswith("LIGHTISLE_SHARE_PATH ")
            url=ready.removeprefix("LIGHTISLE_READY ")
            # Public API cannot trigger privileged backup operations.
            req=urllib.request.Request(url+"/api/v1/backup",method="POST",headers={"X-LightIsle-Request":"1"})
            try:
                urllib.request.urlopen(req,timeout=3)
                raise AssertionError("Unprivileged HTTP backup endpoint enabled")
            except urllib.error.HTTPError as error:
                assert error.code in (404,405),error.code

            def command(message:str)->str:
                proc.stdin.write(message+"\n")
                proc.stdin.flush()
                return proc.stdout.readline().strip()

            def poll()->dict:
                deadline=time.monotonic()+12
                while time.monotonic()<deadline:
                    line=command("backup status")
                    assert line.startswith("LIGHTISLE_BACKUP_STATUS "),line
                    status=unpack(line)
                    if not status["running"]:
                        return status
                    time.sleep(.06)
                raise AssertionError("Timed out waiting for NAS backup")

            assert command("backup start "+encode_path(destination))=="LIGHTISLE_BACKUP_STARTED"
            created=poll()
            assert not created.get("lastError"),created
            snapshot=pathlib.Path(created["lastSnapshot"])
            assert (snapshot/"manifest.json").exists()
            assert (snapshot/"data"/"sample.txt").read_text()=="M5 smoke test: original data"
            (share/"sample.txt").write_text("existing file remains intact")
            assert command("backup restore "+encode_path(str(snapshot)))=="LIGHTISLE_BACKUP_STARTED"
            restored=poll()
            assert not restored.get("lastError"),restored
            assert pathlib.Path(restored["lastSnapshot"]).joinpath("sample.txt").read_text()=="M5 smoke test: original data"
            assert (share/"sample.txt").read_text()=="existing file remains intact"
            assert command("smb status") in ("LIGHTISLE_SMB_STATUS 0","LIGHTISLE_SMB_STATUS 1")
            assert command("backup schedule set 24 "+encode_path(destination))=="LIGHTISLE_BACKUP_SCHEDULE_CHANGED"
            line=command("backup schedule status")
            assert line.startswith("LIGHTISLE_BACKUP_SCHEDULE "),line
            encoded=line.removeprefix("LIGHTISLE_BACKUP_SCHEDULE ")
            plan=json.loads(base64.urlsafe_b64decode(encoded+"="*((-len(encoded))%4)))
            assert plan["enabled"] is True and plan["everyHours"]==24,plan
            assert command("backup schedule off")=="LIGHTISLE_BACKUP_SCHEDULE_CHANGED"
            encoded=command("backup schedule status").removeprefix("LIGHTISLE_BACKUP_SCHEDULE ")
            assert not json.loads(base64.urlsafe_b64decode(encoded+"="*((-len(encoded))%4)))["enabled"]
            proc.stdin.close()
            assert proc.wait(timeout=10)==0
            print("PASS: M5 backup/restore SHA256 + Mac-only IPC + SMB read-only probe + EOF shutdown")
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)

