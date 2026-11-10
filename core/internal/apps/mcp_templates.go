package apps

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func writeRuntimeScaffold(pluginDir, id, name, runtime string, hasCron bool) ([]string, error) {
	created := make([]string, 0, 4)
	rt := strings.ToLower(strings.TrimSpace(runtime))
	if rt == "" {
		rt = "python"
	}

	var webScript string
	switch rt {
	case "node":
		serverJS := fmt.Sprintf(`import http from "node:http";

const port = Number(process.env.PORT || 8080);
const proxySecret = process.env.LIGHTISLE_PROXY_SECRET || "";
const dataDir = process.env.LIGHTISLE_PLUGIN_DATA_DIR || ".";

const server = http.createServer((req, res) => {
  if (proxySecret && req.headers["x-lightisle-proxy-secret"] !== proxySecret) {
    res.writeHead(403, { "Content-Type": "application/json; charset=utf-8" });
    res.end(JSON.stringify({ error: "forbidden_direct_loopback_access" }));
    return;
  }
  const body = JSON.stringify({
    app: %q,
    name: %q,
    runtime: "node",
    path: req.url || "/",
    user: req.headers["x-lightisle-username"] || "",
    role: req.headers["x-lightisle-role"] || "",
    dataDir,
  });
  res.writeHead(200, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
  });
  res.end(body);
});

server.listen(port, "127.0.0.1");
`, id, name)
		if err := os.WriteFile(filepath.Join(pluginDir, "server.mjs"), []byte(serverJS), 0600); err != nil {
			return nil, err
		}
		created = append(created, "server.mjs")
		webScript = "#!/bin/sh\nset -eu\nexec node --max-old-space-size=64 server.mjs\n"

	case "go":
		mainGo := fmt.Sprintf(`package main

import (
	"encoding/json"
	"net/http"
	"os"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	secret := os.Getenv("LIGHTISLE_PROXY_SECRET")
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if secret != "" && r.Header.Get("X-LightIsle-Proxy-Secret") != secret {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(map[string]string{
			"app":     %q,
			"name":    %q,
			"runtime": "go",
			"path":    r.URL.Path,
			"user":    r.Header.Get("X-LightIsle-Username"),
		})
	})
	_ = http.ListenAndServe("127.0.0.1:"+port, nil)
}
`, id, name)
		if err := os.WriteFile(filepath.Join(pluginDir, "main.go"), []byte(mainGo), 0600); err != nil {
			return nil, err
		}
		created = append(created, "main.go")
		webScript = "#!/bin/sh\nset -eu\nif [ ! -x ./app ] || [ main.go -nt ./app ]; then\n  go build -o app main.go\nfi\nexec ./app\n"

	case "rust":
		mainRs := fmt.Sprintf(`use std::env;
use std::io::{Read, Write};
use std::net::TcpListener;

fn main() {
    let port = env::var("PORT").unwrap_or_else(|_| "8080".to_string());
    let secret = env::var("LIGHTISLE_PROXY_SECRET").unwrap_or_default();
    let listener = TcpListener::bind(format!("127.0.0.1:{}", port)).expect("bind failed");
    for stream in listener.incoming().flatten() {
        let mut s = stream;
        let mut buf = [0u8; 4096];
        let n = s.read(&mut buf).unwrap_or(0);
        let req_text = String::from_utf8_lossy(&buf[..n]).to_lowercase();
        if !secret.is_empty() && !req_text.contains(&format!("x-lightisle-proxy-secret: {}", secret.to_lowercase())) {
            let _ = s.write_all(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            continue;
        }
        let body = "{\"app\":\"%s\",\"runtime\":\"rust\"}";
        let resp = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        );
        let _ = s.write_all(resp.as_bytes());
    }
}
`, id)
		if err := os.WriteFile(filepath.Join(pluginDir, "main.rs"), []byte(mainRs), 0600); err != nil {
			return nil, err
		}
		created = append(created, "main.rs")
		webScript = "#!/bin/sh\nset -eu\nif [ ! -x ./app ] || [ main.rs -nt ./app ]; then\n  rustc -O main.rs -o app\nfi\nexec ./app\n"

	case "java":
		serverJava := fmt.Sprintf(`import com.sun.net.httpserver.HttpServer;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;

public class Server {
    public static void main(String[] args) throws Exception {
        int port = Integer.parseInt(System.getenv().getOrDefault("PORT", "8080"));
        String secret = System.getenv().getOrDefault("LIGHTISLE_PROXY_SECRET", "");
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", port), 0);
        server.createContext("/", exchange -> {
            String got = exchange.getRequestHeaders().getFirst("X-LightIsle-Proxy-Secret");
            if (!secret.isEmpty() && !secret.equals(got)) {
                exchange.sendResponseHeaders(403, -1);
                exchange.close();
                return;
            }
            byte[] body = ("{\"app\":\"%s\",\"runtime\":\"java\"}").getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
            exchange.sendResponseHeaders(200, body.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(body);
            }
        });
        server.start();
    }
}
`, id)
		if err := os.WriteFile(filepath.Join(pluginDir, "Server.java"), []byte(serverJava), 0600); err != nil {
			return nil, err
		}
		created = append(created, "Server.java")
		webScript = "#!/bin/sh\nset -eu\nexec java -XX:+UseSerialGC -Xms16m -Xmx64m -XX:TieredStopAtLevel=1 Server.java\n"

	case "shell":
		webScript = fmt.Sprintf(`#!/bin/sh
set -eu
PORT="${PORT:-8080}"
BODY='{"app":%q,"name":%q,"runtime":"shell"}'
LEN=$(printf '%%s' "$BODY" | wc -c | tr -d ' ')
while true; do
  printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: %%s\r\nConnection: close\r\n\r\n%%s' "$LEN" "$BODY" | nc -l 127.0.0.1 "$PORT" >/dev/null 2>&1 || break
done
`, id, name)

	case "python":
		appPy := fmt.Sprintf(`import http.server
import json
import os

port = int(os.environ.get("PORT", "8080"))
secret = os.environ.get("LIGHTISLE_PROXY_SECRET", "")

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if secret and self.headers.get("X-LightIsle-Proxy-Secret") != secret:
            self.send_response(403)
            self.end_headers()
            return
        body = json.dumps({
            "app": %q,
            "name": %q,
            "runtime": "python",
            "path": self.path,
            "user": self.headers.get("X-LightIsle-Username", ""),
        }).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass

http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
`, id, name)
		if err := os.WriteFile(filepath.Join(pluginDir, "app.py"), []byte(appPy), 0600); err != nil {
			return nil, err
		}
		created = append(created, "app.py")
		webScript = "#!/bin/sh\nset -eu\nif [ -x .venv/bin/python ]; then\n  exec .venv/bin/python app.py\nfi\nexec python3 app.py\n"

	default:
		return nil, fmt.Errorf("不支持的 runtime: %s", rt)
	}

	if err := os.WriteFile(filepath.Join(pluginDir, "run-web.sh"), []byte(webScript), 0700); err != nil {
		return nil, err
	}
	created = append(created, "run-web.sh")

	if hasCron {
		cronFiles, err := writeCronScaffold(pluginDir, id, rt)
		if err != nil {
			return nil, err
		}
		created = append(created, cronFiles...)
	}
	return created, nil
}

func writeCronScaffold(pluginDir, id, rt string) ([]string, error) {
	created := make([]string, 0, 2)
	var cronScript string
	switch strings.ToLower(strings.TrimSpace(rt)) {
	case "node":
		collectJS := fmt.Sprintf(`import fs from "node:fs";
import path from "node:path";

const dataDir = process.env.LIGHTISLE_PLUGIN_DATA_DIR || ".";
fs.mkdirSync(dataDir, { recursive: true });
const out = { app: %q, runtime: "node", collectedAt: new Date().toISOString() };
fs.writeFileSync(path.join(dataDir, "last-cron.json"), JSON.stringify(out, null, 2));
console.log("[%s] cron finished:", out.collectedAt);
`, id, id)
		if err := os.WriteFile(filepath.Join(pluginDir, "collect.mjs"), []byte(collectJS), 0600); err != nil {
			return nil, err
		}
		created = append(created, "collect.mjs")
		cronScript = "#!/bin/sh\nset -eu\nexec node collect.mjs\n"

	case "python":
		collectPy := fmt.Sprintf(`import datetime
import json
import os
import pathlib

data_dir = pathlib.Path(os.environ.get("LIGHTISLE_PLUGIN_DATA_DIR", "."))
data_dir.mkdir(parents=True, exist_ok=True)
out = {
    "app": %q,
    "runtime": "python",
    "collectedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
(data_dir / "last-cron.json").write_text(json.dumps(out, indent=2), encoding="utf-8")
print(f"[%s] cron finished: {out['collectedAt']}")
`, id, id)
		if err := os.WriteFile(filepath.Join(pluginDir, "collect.py"), []byte(collectPy), 0600); err != nil {
			return nil, err
		}
		created = append(created, "collect.py")
		cronScript = "#!/bin/sh\nset -eu\nif [ -x .venv/bin/python ]; then\n  exec .venv/bin/python collect.py\nfi\nexec python3 collect.py\n"

	case "go":
		collectGo := fmt.Sprintf(`package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

func main() {
	dataDir := os.Getenv("LIGHTISLE_PLUGIN_DATA_DIR")
	if dataDir == "" {
		dataDir = "."
	}
	_ = os.MkdirAll(dataDir, 0700)
	now := time.Now().UTC().Format(time.RFC3339)
	raw, _ := json.MarshalIndent(map[string]string{
		"app":         %q,
		"runtime":     "go",
		"collectedAt": now,
	}, "", "  ")
	_ = os.WriteFile(filepath.Join(dataDir, "last-cron.json"), raw, 0600)
	fmt.Printf("[%s] cron finished: %%s\n", now)
}
`, id, id)
		if err := os.WriteFile(filepath.Join(pluginDir, "collect.go"), []byte(collectGo), 0600); err != nil {
			return nil, err
		}
		created = append(created, "collect.go")
		cronScript = "#!/bin/sh\nset -eu\nif [ ! -x ./collect-bin ] || [ collect.go -nt ./collect-bin ]; then\n  go build -o collect-bin collect.go\nfi\nexec ./collect-bin\n"

	default:
		cronScript = fmt.Sprintf("#!/bin/sh\nset -eu\necho \"[%s] cron executed at $(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)\"\n", id)
	}
	if err := os.WriteFile(filepath.Join(pluginDir, "run-cron.sh"), []byte(cronScript), 0700); err != nil {
		return nil, err
	}
	created = append(created, "run-cron.sh")
	return created, nil
}
