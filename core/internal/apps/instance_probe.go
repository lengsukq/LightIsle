package apps

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/lengsukq/lightisle/core/internal/system"
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
		if (exclude != nil && exclude[addr.Port]) || !reservedPorts[addr.Port].IsZero() {
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
	portConnected := false
	lastHCDetail := ""
	timeoutErr := func() error {
		if portConnected && healthCheckPath != "" {
			if lastHCDetail == "" {
				lastHCDetail = "请求超时"
			}
			return fmt.Errorf("%w (%s)", errHealthCheckFailed, lastHCDetail)
		}
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return errPortListenTimeout
		}
		return ctx.Err()
	}
	for {
		select {
		case <-procDone:
			return errProcessExitedEarly
		case <-ctx.Done():
			return timeoutErr()
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
			portConnected = true
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
					lastHCDetail = fmt.Sprintf("HTTP %d", resp.StatusCode)
				} else {
					lastHCDetail = respErr.Error()
				}
			}
		}
		select {
		case <-procDone:
			return errProcessExitedEarly
		case <-ctx.Done():
			return timeoutErr()
		case <-ticker.C:
		}
	}
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
	return system.ProcessResidentBytes(pid)
}
