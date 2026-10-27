"""M4 packaged binary integration: auth -> scan -> Range -> subtitles -> progress."""
import base64
import http.cookiejar
import json
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from test_media_worker import FIXTURE_MAKER, run_fixture_maker

ROOT=Path(__file__).resolve().parents[1]
CORE=ROOT/"dist/LightIsle.app/Contents/Resources/core/lightisled"
WEB=ROOT/"dist/LightIsle.app/Contents/Resources/web"

with tempfile.TemporaryDirectory(prefix="lightisle-m4-smoke-") as folder:
    base=Path(folder)
    shared=base/"SharedFiles"
    shared.mkdir()
    maker=base/"fixture-maker"
    subprocess.run(["swiftc","-swift-version","5","-parse-as-library","-suppress-warnings",str(FIXTURE_MAKER),"-o",str(maker)],check=True,timeout=60)
    movie_path=shared/"Example.Movie.2024.mp4"
    run_fixture_maker(maker,"mp4",movie_path)
    movie_bytes=movie_path.read_bytes()
    (shared/"Example.Movie.2024.srt").write_text("1\n00:00:00,500 --> 00:00:02,250\nExample subtitle\n",encoding="utf8")
    process=subprocess.Popen([str(CORE),"-port","0","-data-dir",str(base),"-web-root",str(WEB)],
        stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
    try:
        assert process.stdout is not None
        ready=process.stdout.readline().strip()
        assert ready.startswith("LIGHTISLE_READY http://127.0.0.1:"),ready
        url=ready.split(" ",1)[1]
        assert process.stdout.readline().strip()=="LIGHTISLE_CONFIGURED 0"
        assert process.stdout.readline().startswith("LIGHTISLE_SHARE_ON ")
        assert process.stdout.readline().startswith("LIGHTISLE_SHARE_PATH ")
        credentials={"username":"movie_owner","password":"long-movie-test-password"}
        encoded=base64.urlsafe_b64encode(json.dumps(credentials).encode()).rstrip(b"=").decode()
        assert process.stdin is not None
        process.stdin.write("admin init "+encoded+"\n")
        process.stdin.flush()
        assert process.stdout.readline().strip()=="LIGHTISLE_INITIALIZED"
        identity=base64.urlsafe_b64encode(credentials["username"].encode()).rstrip(b"=").decode()
        assert process.stdout.readline().strip()=="LIGHTISLE_ADMIN_ACCOUNT "+identity
        opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        def call(path,method="GET",payload=None,headers=None):
            req_headers=dict(headers or {})
            if method!="GET" and method!="HEAD":req_headers["X-LightIsle-Request"]="1"
            body=None
            if payload is not None:
                req_headers["Content-Type"]="application/json"
                body=json.dumps(payload).encode()
            request=urllib.request.Request(url+path,data=body,headers=req_headers,method=method)
            return opener.open(request,timeout=7)
        with call("/api/v2/auth/login","POST",credentials) as response:
            assert json.load(response)["role"]=="admin"
        with call("/api/v2/cinema/scan","POST") as response:
            assert response.status==202
        deadline=time.monotonic()+12
        while time.monotonic()<deadline:
            with call("/api/v2/cinema/status") as response:
                status=json.load(response)["status"]
            if not status["running"]:break
            time.sleep(.1)
        assert not status["running"] and status["found"]==1,status
        with call("/api/v2/cinema") as response:
            catalog=json.load(response)
        assert len(catalog["films"])==1,catalog
        movie=catalog["films"][0]
        assert movie["kind"]=="movie" and movie["year"]==2024,movie
        assert movie["probeStatus"]=="ready" and movie["browserPlayback"]=="verified-direct",movie
        movie_id=movie["id"]
        with call(f"/api/v2/cinema/{movie_id}/stream",headers={"Range":"bytes=2-6"}) as response:
            assert response.status==206 and response.read()==movie_bytes[2:7]
        with call(f"/api/v2/cinema/{movie_id}/subtitles") as response:
            subtitles=response.read().decode()
            assert "WEBVTT" in subtitles and "00:00:00.500" in subtitles
        with call(f"/api/v2/cinema/{movie_id}/progress","PUT",{"position":1,"duration":2,"completed":False}) as response:
            assert json.load(response)["saved"]
        with call(f"/api/v2/cinema/{movie_id}") as response:
            assert json.load(response)["position"]==1
        process.stdin.close()
        assert process.wait(timeout=10)==0
        print("PASS: bundled cinema scan + cookie auth + HTTP Range 206 + SRT/VTT + progress + parent exit")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)

