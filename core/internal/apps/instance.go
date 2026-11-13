package apps

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
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
	lastDiag      *AppDiagnostic
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

func (inst *Instance) Diagnostic() *AppDiagnostic {
	inst.mu.Lock()
	defer inst.mu.Unlock()
	if inst.lastDiag == nil {
		return nil
	}
	copied := *inst.lastDiag
	return &copied
}

func (inst *Instance) IsRunning() bool {
	inst.mu.Lock()
	running := inst.cmd != nil && inst.pid > 0 && inst.status == StatusRunning
	inst.mu.Unlock()
	return running
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
				diag := inst.lastDiag
				inst.mu.Unlock()
				if diag != nil {
					return 0, "", errors.New(formatActionableWakeError(*diag))
				}
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

func (inst *Instance) failPreStart(entry, msg string) error {
	diag := buildPreStartDiagnostic(inst.id, entry, msg)
	inst.failStart(diag.Summary, &diag)
	return errors.New(formatActionableWakeError(diag))
}

func (inst *Instance) startProcess(ctx context.Context, webCfg WebConfig) (int, string, error) {
	if err := os.MkdirAll(inst.dataDir, 0700); err != nil {
		return 0, "", inst.failPreStart(webCfg.Entry, fmt.Sprintf("无法创建应用数据目录: %v", err))
	}
	root, err := os.OpenRoot(inst.pluginDir)
	if err != nil {
		return 0, "", inst.failPreStart(webCfg.Entry, "无法打开插件目录")
	}
	_, entryStat, err := readCheckedFile(root, webCfg.Entry, maxScriptBytes)
	if err != nil || entryStat.Mode()&0111 == 0 {
		root.Close()
		return 0, "", inst.failPreStart(webCfg.Entry, fmt.Sprintf("启动脚本 %s 不可执行或不存在", webCfg.Entry))
	}
	customEnv := map[string]string{}
	if st, envErr := root.Lstat("env.json"); envErr == nil && st.Mode().IsRegular() {
		loaded, readErr := ReadEnvFile(root, "env.json")
		if readErr != nil {
			root.Close()
			return 0, "", inst.failPreStart(webCfg.Entry, readErr.Error())
		}
		customEnv = loaded
	}
	root.Close()

	excludedPorts := make(map[int]bool, 3)
	maxAttempts := 1
	if webCfg.Port == 0 {
		maxAttempts = 3
	}

	readyTimeout := time.Duration(webCfg.ReadyTimeoutSeconds) * time.Second
	if readyTimeout <= 0 {
		readyTimeout = 15 * time.Second
	}

	var (
		lastPort       int
		lastWaitErr    error
		lastExitErr    error
		lastAttemptOut string
	)
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		port := webCfg.Port
		if port == 0 {
			allocated, allocErr := allocateLoopbackPort(excludedPorts)
			if allocErr != nil {
				return 0, "", inst.failPreStart(webCfg.Entry, "无法分配本地空闲回环端口")
			}
			port = allocated
		}
		lastPort = port

		secretBytes := make([]byte, 32)
		if _, err := rand.Read(secretBytes); err != nil {
			releaseReservedPort(port)
			return 0, "", inst.failPreStart(webCfg.Entry, "无法生成本地代理密钥")
		}
		secret := hex.EncodeToString(secretBytes)

		attemptBuf := newBoundedCaptureBuffer(8 << 10)
		_, _ = fmt.Fprintf(inst.logs, "--- [%s] 启动 %s (PORT=%d) ---\n", time.Now().Format("2006-01-02 15:04:05"), webCfg.Entry, port)

		entryPath := filepath.Join(inst.pluginDir, webCfg.Entry)
		cmd := exec.Command(entryPath)
		cmd.Dir = inst.pluginDir
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		outWriter := io.MultiWriter(inst.logs, attemptBuf)
		cmd.Stdout = outWriter
		cmd.Stderr = outWriter

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
			return 0, "", inst.failPreStart(webCfg.Entry, fmt.Sprintf("启动进程失败: %v", err))
		}

		pid := cmd.Process.Pid
		procDone := make(chan struct{})
		exitHandled := make(chan struct{})
		var procExitErr error
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
			waitRes := cmd.Wait()
			procExitErr = waitRes
			close(procDone)
			inst.onProcessExit(procDone, waitRes)
			close(exitHandled)
		}()

		readyCtx, cancel := context.WithTimeout(ctx, readyTimeout)
		waitErr := waitPortReady(readyCtx, port, pid, pid, webCfg.HealthCheckPath, secret, procDone)
		cancel()

		if waitErr == nil {
			rss := sampleProcessRSS(pid)
			inst.mu.Lock()
			inst.status = StatusRunning
			inst.lastError = ""
			inst.lastDiag = nil
			inst.rssBytes = rss
			inst.Touch()
			inst.mu.Unlock()
			return port, secret, nil
		}

		killProcessGroup(pid)
		<-exitHandled
		releaseReservedPort(port)
		excludedPorts[port] = true

		lastWaitErr = waitErr
		lastExitErr = procExitErr
		lastAttemptOut = attemptBuf.String()

		lowerAttempt := strings.ToLower(lastAttemptOut)
		portRace := errors.Is(waitErr, errPortNotOwned) ||
			(errors.Is(waitErr, errProcessExitedEarly) &&
				(strings.Contains(lowerAttempt, "eaddrinuse") || strings.Contains(lowerAttempt, "address already in use")))
		if webCfg.Port == 0 && portRace && attempt < maxAttempts {
			continue
		}
		break
	}

	diag := buildStartFailureDiagnostic(
		inst.id, webCfg.Entry, webCfg.Runtime, webCfg.HealthCheckPath,
		lastPort, int(readyTimeout/time.Second),
		lastWaitErr, lastExitErr, lastAttemptOut,
	)
	inst.failStart(diag.Summary, &diag)
	return 0, "", errors.New(formatActionableWakeError(diag))
}

func (inst *Instance) failStart(msg string, diag *AppDiagnostic) {
	inst.mu.Lock()
	defer inst.mu.Unlock()
	inst.status = StatusCrashed
	inst.lastError = msg
	inst.lastDiag = diag
	inst.procDone = nil
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

	// During startProcess, startProcess itself owns failure reporting and diagnostics.
	if inst.startingCh != nil {
		inst.mu.Unlock()
		return
	}

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
	entryName := "run-web.sh"
	if w != nil && w.Entry != "" {
		entryName = w.Entry
	}
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
		inst.lastDiag = buildRuntimeCrashDiagnostic(inst.id, entryName, inst.lastError, inst.logs.String())
		inst.mu.Unlock()
		return
	}

	if waitErr != nil {
		inst.status = StatusCrashed
		inst.lastError = fmt.Sprintf("进程异常退出: %v", waitErr)
		inst.lastDiag = buildRuntimeCrashDiagnostic(inst.id, entryName, inst.lastError, inst.logs.String())
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
	inst.lastDiag = nil
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
