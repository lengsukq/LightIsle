package apps

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const maxLogRingBytes = 32 << 10

var (
	portMu                sync.Mutex
	reservedPorts         = map[int]time.Time{}
	errProcessExitedEarly = errors.New("process exited before binding port")
	errPortNotOwned       = errors.New("allocated port was bound by another process")
)

type ringBuffer struct {
	mu   sync.Mutex
	buf  []byte
	size int
}

func newRingBuffer(limit int) *ringBuffer {
	if limit <= 0 {
		limit = maxLogRingBytes
	}
	return &ringBuffer{size: limit}
}

func (r *ringBuffer) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	n := len(p)
	if n >= r.size {
		r.buf = append(r.buf[:0], p[n-r.size:]...)
		return n, nil
	}
	if len(r.buf)+n > r.size {
		drop := len(r.buf) + n - r.size
		r.buf = append(r.buf[:0], r.buf[drop:]...)
	}
	r.buf = append(r.buf, p...)
	return n, nil
}

func (r *ringBuffer) String() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return string(r.buf)
}

type Instance struct {
	id        string
	pluginDir string
	dataDir   string

	mu            sync.Mutex
	manifest      PluginManifest
	status        string
	port          int
	pid           int
	pgid          int
	rssBytes      int64
	lastError     string
	proxySecret   string
	cmd           *exec.Cmd
	procDone      chan struct{}
	startingCh    chan struct{}
	stopRequested bool
	sleepOnStop   bool
	restartCount  int
	closed        bool
	supCancel     context.CancelFunc

	activeStreams      atomic.Int64
	lastActiveNano     atomic.Int64
	preferStrippedPath atomic.Bool
	pathProbed         atomic.Bool
	logs               *ringBuffer
}

func newInstance(id, pluginDir, dataDir string, manifest PluginManifest) *Instance {
	inst := &Instance{
		id:        id,
		pluginDir: pluginDir,
		dataDir:   dataDir,
		manifest:  manifest,
		status:    initialWebStatus(manifest.Web),
		logs:      newRingBuffer(maxLogRingBytes),
	}
	inst.lastActiveNano.Store(time.Now().UnixNano())
	return inst
}

func initialWebStatus(w *WebConfig) string {
	if w == nil || !w.Enabled {
		return StatusDisabled
	}
	switch w.Mode {
	case WebModeStatic:
		return StatusStatic
	case WebModeOnDemand:
		return StatusSleeping
	case WebModePersistent:
		return StatusStopped
	default:
		return StatusDisabled
	}
}

func (inst *Instance) Touch() {
	inst.lastActiveNano.Store(time.Now().UnixNano())
}

func (inst *Instance) BeginStream() {
	inst.activeStreams.Add(1)
	inst.Touch()
}

func (inst *Instance) EndStream() {
	if inst.activeStreams.Add(-1) < 0 {
		inst.activeStreams.Store(0)
	}
	inst.Touch()
}

func (inst *Instance) ActiveStreams() int64 {
	return inst.activeStreams.Load()
}

func (inst *Instance) Logs() string {
	return inst.logs.String()
}

func (inst *Instance) ProxySecret() string {
	inst.mu.Lock()
	defer inst.mu.Unlock()
	return inst.proxySecret
}

func (inst *Instance) Snapshot() PublicWebView {
	inst.mu.Lock()
	defer inst.mu.Unlock()
	w := inst.manifest.Web
	if w == nil {
		return PublicWebView{
			Enabled: false,
			Mode:    "none",
			Status:  StatusDisabled,
		}
	}
	var lastActiveSec int64
	if ns := inst.lastActiveNano.Load(); ns > 0 {
		lastActiveSec = ns / int64(time.Second)
	}
	return PublicWebView{
		Enabled:             w.Enabled,
		Mode:                w.Mode,
		Runtime:             w.Runtime,
		Port:                inst.port,
		BasePath:            w.BasePath,
		IdleTimeoutSeconds:  w.IdleTimeoutSeconds,
		ReadyTimeoutSeconds: w.ReadyTimeoutSeconds,
		AutoRestart:         w.AutoRestart,
		RestartLimit:        w.RestartLimit,
		Status:              inst.status,
		PID:                 inst.pid,
		RSSBytes:            inst.rssBytes,
		ActiveStreams:       inst.activeStreams.Load(),
		LastActiveAt:        lastActiveSec,
		LastError:           inst.lastError,
	}
}

// Wake starts the dynamic web process if it is not already running, coalescing
// concurrent callers so only one process is spawned.
func (inst *Instance) Wake(ctx context.Context) (int, string, error) {
	for {
		inst.mu.Lock()
		if inst.closed {
			inst.mu.Unlock()
			return 0, "", ErrUnavailable
		}
		if inst.manifest.Web == nil || !inst.manifest.Web.Enabled {
			inst.mu.Unlock()
			return 0, "", ErrDisabled
		}
		if inst.manifest.Web.Mode == WebModeStatic {
			inst.mu.Unlock()
			return 0, "", nil
		}
		if inst.status == StatusRunning && inst.procDone != nil {
			select {
			case <-inst.procDone:
				// Process just exited; fall through to restart
			default:
				port, secret := inst.port, inst.proxySecret
				inst.Touch()
				inst.mu.Unlock()
				return port, secret, nil
			}
		}
		if waitCh := inst.startingCh; waitCh != nil {
			inst.mu.Unlock()
			select {
			case <-waitCh:
				inst.mu.Lock()
				if inst.status == StatusRunning && inst.port > 0 {
					port, secret := inst.port, inst.proxySecret
					inst.Touch()
					inst.mu.Unlock()
					return port, secret, nil
				}
				errMsg := inst.lastError
				inst.mu.Unlock()
				if errMsg == "" {
					errMsg = "应用进程启动失败"
				}
				return 0, "", errors.New(errMsg)
			case <-ctx.Done():
				return 0, "", ctx.Err()
			}
		}

		startCh := make(chan struct{})
		inst.startingCh = startCh
		inst.status = StatusStarting
		inst.stopRequested = false
		inst.sleepOnStop = false
		webCfg := *inst.manifest.Web
		inst.mu.Unlock()

		port, secret, err := inst.startProcess(ctx, webCfg)

		inst.mu.Lock()
		inst.startingCh = nil
		close(startCh)
		inst.mu.Unlock()

		return port, secret, err
	}
}

func (inst *Instance) startProcess(ctx context.Context, webCfg WebConfig) (int, string, error) {
	if err := os.MkdirAll(inst.dataDir, 0700); err != nil {
		inst.failStart(fmt.Sprintf("无法创建应用数据目录: %v", err))
		return 0, "", err
	}
	root, err := os.OpenRoot(inst.pluginDir)
	if err != nil {
		inst.failStart("无法打开插件目录")
		return 0, "", err
	}
	_, entryStat, err := readCheckedFile(root, webCfg.Entry, maxScriptBytes)
	if err != nil || entryStat.Mode()&0111 == 0 {
		root.Close()
		msg := fmt.Sprintf("启动脚本 %s 不可执行或不存在", webCfg.Entry)
		inst.failStart(msg)
		return 0, "", errors.New(msg)
	}
	customEnv := map[string]string{}
	if st, envErr := root.Lstat("env.json"); envErr == nil && st.Mode().IsRegular() {
		loaded, readErr := ReadEnvFile(root, "env.json")
		if readErr != nil {
			root.Close()
			inst.failStart(readErr.Error())
			return 0, "", readErr
		}
		customEnv = loaded
	}
	root.Close()

	excludedPorts := make(map[int]bool, 3)
	maxAttempts := 1
	if webCfg.Port == 0 {
		maxAttempts = 3
	}

	var lastPort int
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		port := webCfg.Port
		if port == 0 {
			allocated, allocErr := allocateLoopbackPort(excludedPorts)
			if allocErr != nil {
				inst.failStart("无法分配本地空闲端口")
				return 0, "", allocErr
			}
			port = allocated
		}
		lastPort = port

		secretBytes := make([]byte, 32)
		if _, err := rand.Read(secretBytes); err != nil {
			releaseReservedPort(port)
			inst.failStart("无法生成代理密钥")
			return 0, "", err
		}
		secret := hex.EncodeToString(secretBytes)

		entryPath := filepath.Join(inst.pluginDir, webCfg.Entry)
		cmd := exec.Command(entryPath)
		cmd.Dir = inst.pluginDir
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		cmd.Stdout = inst.logs
		cmd.Stderr = inst.logs

		basePath := webCfg.BasePath
		if basePath == "" {
			basePath = "/apps/" + inst.id
		}
		envList := make([]string, 0, len(customEnv)+14)
		for k, v := range customEnv {
			envList = append(envList, k+"="+v)
		}
		envList = append(envList,
			"PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
			"HOME="+os.Getenv("HOME"),
			"USER="+os.Getenv("USER"),
			"TMPDIR="+os.TempDir(),
			"LANG=en_US.UTF-8",
			"PORT="+strconv.Itoa(port),
			"HOST=127.0.0.1",
			"HOSTNAME=127.0.0.1",
			"BASE_PATH="+basePath,
			"NEXT_PUBLIC_BASE_PATH="+basePath,
			"LIGHTISLE_PLUGIN_ID="+inst.id,
			"LIGHTISLE_PLUGIN_DIR="+inst.pluginDir,
			"LIGHTISLE_PLUGIN_DATA_DIR="+inst.dataDir,
			"LIGHTISLE_PROXY_SECRET="+secret,
			"LIGHTISLE_TRUST_PROXY=true",
		)
		cmd.Env = envList

		if err := cmd.Start(); err != nil {
			releaseReservedPort(port)
			msg := fmt.Sprintf("启动进程失败: %v", err)
			inst.failStart(msg)
			return 0, "", errors.New(msg)
		}

		pid := cmd.Process.Pid
		procDone := make(chan struct{})
		inst.mu.Lock()
		inst.cmd = cmd
		inst.pid = pid
		inst.pgid = pid
		inst.port = port
		inst.proxySecret = secret
		inst.procDone = procDone
		inst.pathProbed.Store(false)
		inst.mu.Unlock()

		go func() {
			waitErr := cmd.Wait()
			close(procDone)
			inst.onProcessExit(procDone, waitErr)
		}()

		readyTimeout := time.Duration(webCfg.ReadyTimeoutSeconds) * time.Second
		if readyTimeout <= 0 {
			readyTimeout = 15 * time.Second
		}
		readyCtx, cancel := context.WithTimeout(ctx, readyTimeout)
		waitErr := waitPortReady(readyCtx, port, pid, pid, webCfg.HealthCheckPath, secret, procDone)
		cancel()

		if waitErr == nil {
			rss := sampleProcessRSS(pid)
			inst.mu.Lock()
			inst.status = StatusRunning
			inst.lastError = ""
			inst.rssBytes = rss
			inst.Touch()
			inst.mu.Unlock()
			return port, secret, nil
		}

		killProcessGroup(pid)
		<-procDone
		releaseReservedPort(port)
		excludedPorts[port] = true
		if webCfg.Port == 0 && (errors.Is(waitErr, errProcessExitedEarly) || errors.Is(waitErr, errPortNotOwned)) && attempt < maxAttempts {
			continue
		}
	}

	msg := fmt.Sprintf("等待本地端口 127.0.0.1:%d 就绪超时或进程提前退出", lastPort)
	inst.failStart(msg)
	return 0, "", errors.New(msg)
}

func (inst *Instance) failStart(msg string) {
	inst.mu.Lock()
	defer inst.mu.Unlock()
	inst.status = StatusCrashed
	inst.lastError = msg
	inst.pid = 0
	inst.pgid = 0
	inst.port = 0
	inst.rssBytes = 0
}

func (inst *Instance) onProcessExit(doneCh chan struct{}, waitErr error) {
	inst.mu.Lock()
	if inst.procDone != doneCh {
		inst.mu.Unlock()
		return
	}
	inst.pid = 0
	inst.pgid = 0
	inst.port = 0
	inst.rssBytes = 0
	inst.cmd = nil

	if inst.closed {
		inst.status = StatusStopped
		inst.mu.Unlock()
		return
	}
	if inst.stopRequested {
		if inst.sleepOnStop {
			inst.status = StatusSleeping
		} else if inst.manifest.Web == nil || !inst.manifest.Web.Enabled {
			inst.status = StatusDisabled
		} else {
			inst.status = StatusStopped
		}
		inst.mu.Unlock()
		return
	}

	// Unexpected exit while running
	w := inst.manifest.Web
	if w != nil && w.Enabled && (w.Mode == WebModePersistent || w.AutoRestart) {
		limit := w.RestartLimit
		if limit <= 0 {
			limit = 5
		}
		if inst.restartCount < limit {
			inst.restartCount++
			attempt := inst.restartCount
			inst.status = StatusStarting
			inst.lastError = fmt.Sprintf("进程异常退出，正在第 %d/%d 次自动重启", attempt, limit)
			supCtx, cancel := context.WithCancel(context.Background())
			if inst.supCancel != nil {
				inst.supCancel()
			}
			inst.supCancel = cancel
			inst.mu.Unlock()

			go func() {
				backoff := time.Duration(150*(1<<min(attempt, 5))) * time.Millisecond
				select {
				case <-time.After(backoff):
					_, _, _ = inst.Wake(supCtx)
				case <-supCtx.Done():
				}
			}()
			return
		}
		inst.status = StatusCrashed
		inst.lastError = fmt.Sprintf("进程异常退出且已超过最大重启次数 (%d 次)", limit)
		inst.mu.Unlock()
		return
	}

	if waitErr != nil {
		inst.status = StatusCrashed
		inst.lastError = fmt.Sprintf("进程异常退出: %v", waitErr)
	} else if w != nil && w.Mode == WebModeOnDemand {
		inst.status = StatusSleeping
	} else {
		inst.status = StatusStopped
	}
	inst.mu.Unlock()
}

func (inst *Instance) Stop(sleep bool) error {
	inst.mu.Lock()
	if inst.supCancel != nil {
		inst.supCancel()
		inst.supCancel = nil
	}
	inst.stopRequested = true
	inst.sleepOnStop = sleep
	pgid := inst.pgid
	done := inst.procDone
	if pgid <= 0 || done == nil {
		if sleep && inst.manifest.Web != nil && inst.manifest.Web.Enabled && inst.manifest.Web.Mode == WebModeOnDemand {
			inst.status = StatusSleeping
		} else if inst.manifest.Web == nil || !inst.manifest.Web.Enabled {
			inst.status = StatusDisabled
		} else if inst.manifest.Web.Mode == WebModeStatic {
			inst.status = StatusStatic
		} else {
			inst.status = StatusStopped
		}
		inst.pid = 0
		inst.port = 0
		inst.rssBytes = 0
		inst.mu.Unlock()
		return nil
	}
	inst.mu.Unlock()

	_ = syscall.Kill(-pgid, syscall.SIGTERM)
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
		<-done
	}

	inst.mu.Lock()
	if sleep && inst.manifest.Web != nil && inst.manifest.Web.Enabled && inst.manifest.Web.Mode == WebModeOnDemand {
		inst.status = StatusSleeping
	} else if inst.manifest.Web == nil || !inst.manifest.Web.Enabled {
		inst.status = StatusDisabled
	} else {
		inst.status = StatusStopped
	}
	inst.pid = 0
	inst.pgid = 0
	inst.port = 0
	inst.rssBytes = 0
	inst.mu.Unlock()
	return nil
}

func (inst *Instance) Restart(ctx context.Context) error {
	inst.mu.Lock()
	inst.restartCount = 0
	inst.lastError = ""
	inst.mu.Unlock()
	if err := inst.Stop(false); err != nil {
		return err
	}
	inst.mu.Lock()
	enabled := inst.manifest.Web != nil && inst.manifest.Web.Enabled && inst.manifest.Web.Mode != WebModeStatic
	inst.mu.Unlock()
	if !enabled {
		return nil
	}
	_, _, err := inst.Wake(ctx)
	return err
}

func (inst *Instance) Close() {
	inst.mu.Lock()
	inst.closed = true
	inst.mu.Unlock()
	_ = inst.Stop(false)
}

func (inst *Instance) ReapIfIdle(now time.Time) bool {
	inst.mu.Lock()
	if inst.status != StatusRunning || inst.pid <= 0 || inst.manifest.Web == nil {
		inst.mu.Unlock()
		return false
	}
	pid := inst.pid
	mode := inst.manifest.Web.Mode
	idleSec := inst.manifest.Web.IdleTimeoutSeconds
	inst.mu.Unlock()

	rss := sampleProcessRSS(pid)
	inst.mu.Lock()
	if inst.status == StatusRunning && inst.pid == pid {
		inst.rssBytes = rss
	}
	inst.mu.Unlock()

	if mode != WebModeOnDemand || inst.activeStreams.Load() > 0 {
		return false
	}
	if idleSec <= 0 {
		idleSec = 300
	}
	lastActive := time.Unix(0, inst.lastActiveNano.Load())
	if now.Sub(lastActive) < time.Duration(idleSec)*time.Second {
		return false
	}
	_ = inst.Stop(true)
	return true
}

func allocateLoopbackPort(exclude map[int]bool) (int, error) {
	portMu.Lock()
	defer portMu.Unlock()
	now := time.Now()
	for p, exp := range reservedPorts {
		if now.After(exp) {
			delete(reservedPorts, p)
		}
	}
	held := make([]net.Listener, 0, 8)
	defer func() {
		for _, ln := range held {
			_ = ln.Close()
		}
	}()
	for range 16 {
		ln, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			return 0, err
		}
		addr, ok := ln.Addr().(*net.TCPAddr)
		if !ok || addr.Port <= 0 {
			_ = ln.Close()
			return 0, errors.New("failed to allocate loopback port")
		}
		if (exclude != nil && exclude[addr.Port]) || ! reservedPorts[addr.Port].IsZero() {
			held = append(held, ln)
			continue
		}
		_ = ln.Close()
		reservedPorts[addr.Port] = now.Add(45 * time.Second)
		return addr.Port, nil
	}
	return 0, errors.New("failed to allocate unique loopback port")
}

func releaseReservedPort(port int) {
	if port <= 0 {
		return
	}
	portMu.Lock()
	delete(reservedPorts, port)
	portMu.Unlock()
}

func waitPortReady(ctx context.Context, port, pid, pgid int, healthCheckPath, proxySecret string, procDone <-chan struct{}) error {
	target := fmt.Sprintf("127.0.0.1:%d", port)
	ticker := time.NewTicker(40 * time.Millisecond)
	defer ticker.Stop()
	httpClient := &http.Client{Timeout: 300 * time.Millisecond}
	for {
		select {
		case <-procDone:
			return errProcessExitedEarly
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		conn, err := net.DialTimeout("tcp4", target, 150*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			select {
			case <-procDone:
				return errProcessExitedEarly
			case <-time.After(15 * time.Millisecond):
			}
			select {
			case <-procDone:
				return errProcessExitedEarly
			default:
			}
			if !verifyPortOwnedByInstance(port, pid, pgid) {
				return errPortNotOwned
			}
			if healthCheckPath == "" {
				return nil
			}
			hcPath := healthCheckPath
			if !strings.HasPrefix(hcPath, "/") {
				hcPath = "/" + hcPath
			}
			req, reqErr := http.NewRequestWithContext(ctx, http.MethodGet, "http://"+target+hcPath, nil)
			if reqErr == nil {
				req.Header.Set("X-LightIsle-Proxy-Secret", proxySecret)
				if resp, respErr := httpClient.Do(req); respErr == nil {
					_ = resp.Body.Close()
					if resp.StatusCode < 500 {
						return nil
					}
				}
			}
		}
		select {
		case <-procDone:
			return errProcessExitedEarly
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

func verifyPortOwnedByInstance(port, pid, pgid int) bool {
	if port <= 0 || pid <= 0 {
		return true
	}
	lsofBin := "/usr/sbin/lsof"
	if _, err := os.Stat(lsofBin); err != nil {
		if found, lookErr := exec.LookPath("lsof"); lookErr == nil {
			lsofBin = found
		} else {
			return true
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	out, err := exec.CommandContext(ctx, lsofBin, "-nP", fmt.Sprintf("-iTCP:%d", port), "-sTCP:LISTEN", "-Fp").Output()
	if err != nil || len(out) == 0 {
		return true
	}
	var listenerPIDs []int
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "p") {
			if p, convErr := strconv.Atoi(strings.TrimPrefix(line, "p")); convErr == nil && p > 0 {
				listenerPIDs = append(listenerPIDs, p)
			}
		}
	}
	if len(listenerPIDs) == 0 {
		return true
	}
	for _, lpid := range listenerPIDs {
		if lpid == pid || lpid == pgid {
			return true
		}
		psOut, psErr := exec.Command("/bin/ps", "-o", "pgid=,ppid=", "-p", strconv.Itoa(lpid)).Output()
		if psErr == nil {
			fields := strings.Fields(string(psOut))
			for _, f := range fields {
				if v, convErr := strconv.Atoi(f); convErr == nil && (v == pid || v == pgid) {
					return true
				}
			}
		}
	}
	return false
}

func killProcessGroup(pgid int) {
	if pgid <= 0 {
		return
	}
	_ = syscall.Kill(-pgid, syscall.SIGTERM)
	time.Sleep(100 * time.Millisecond)
	_ = syscall.Kill(-pgid, syscall.SIGKILL)
}

func sampleProcessRSS(pid int) int64 {
	if pid <= 0 {
		return 0
	}
	out, err := exec.Command("/bin/ps", "-o", "rss=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return 0
	}
	kb, err := strconv.ParseInt(strings.TrimSpace(string(bytes.TrimSpace(out))), 10, 64)
	if err != nil || kb <= 0 {
		return 0
	}
	return kb * 1024
}
