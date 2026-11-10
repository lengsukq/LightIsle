package automation

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"syscall"
	"time"

	"github.com/robfig/cron/v3"
)

type limitedWriter struct{ bytes.Buffer }

func (w *limitedWriter) Write(p []byte) (int, error) {
	n := len(p)
	if w.Len() < maxOutput {
		remaining := maxOutput - w.Len()
		w.Buffer.Write(p[:min(len(p), remaining)])
	}
	return n, nil
}
func (m *Manager) run(id string) { m.runScheduled(id, nil, time.Time{}) }

func (m *Manager) runScheduled(id string, scheduler *cron.Cron, scheduledAt time.Time) {
	m.mu.Lock()
	task, ok := m.tasks[id]
	if !ok || !task.Enabled || m.closed || scheduler != nil && scheduler != m.scheduler {
		m.mu.Unlock()
		return
	}
	m.wg.Add(1)
	defer m.wg.Done()
	if !scheduledAt.IsZero() && time.Since(scheduledAt) >= time.Minute {
		m.mu.Unlock()
		m.recordSkipped(id, "已错过计划执行时间，等待下次调度。")
		return
	}
	if m.running[id] != nil {
		m.mu.Unlock()
		m.recordSkipped(id, "同一任务仍在运行。")
		return
	}
	select {
	case m.slots <- struct{}{}:
	default:
		m.mu.Unlock()
		m.recordSkipped(id, "已有两个任务运行，本次跳过。")
		return
	}
	duration := time.Duration(task.TimeoutSeconds) * time.Second
	if duration == 0 {
		duration = 10 * time.Minute
	}
	ctx, cancel := context.WithTimeout(context.Background(), duration)
	m.running[id] = cancel
	m.mu.Unlock()
	defer func() {
		cancel()
		<-m.slots
		m.mu.Lock()
		delete(m.running, id)
		m.mu.Unlock()
	}()
	started := time.Now().Unix()
	lock, err := m.lockScript(id)
	if err != nil {
		if errors.Is(err, syscall.EWOULDBLOCK) {
			m.recordSkipped(id, "上次启动的脚本进程仍在运行。")
		} else {
			m.recordSkipped(id, "无法取得脚本运行锁，请检查 Mac 上的自动化目录权限。")
			slog.Warn("cannot lock automation task", "task", id, "error", err)
		}
		return
	}
	defer lock.Close()
	runID, err := m.beginRun(id, started)
	if err != nil {
		slog.Warn("automation skipped: cannot record start", "task", id, "error", err)
		return
	}
	var output limitedWriter
	state := "success"
	code := 0
	root, err := m.openTaskRoot(id, task.directory)
	var entryInfo os.FileInfo
	if err == nil {
		_, err = checkedFile(root, "task.json", maxTaskJSON)
		if err == nil {
			entryInfo, err = root.Lstat(task.Entry)
			if err == nil && (!entryInfo.Mode().IsRegular() || entryInfo.Mode()&0111 == 0 || entryInfo.Size() > 2<<20) {
				err = ErrInvalid
			}
		}
	}
	env := map[string]string{}
	if err == nil && task.EnvFile != "" {
		env, err = readEnv(root, task.EnvFile)
	}
	if root != nil {
		root.Close()
	}
	if err == nil {
		command := exec.Command(filepath.Join(m.scripts, id, task.Entry), task.Args...)
		command.Dir = filepath.Join(m.scripts, id)
		command.WaitDelay = 2 * time.Second
		command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		command.ExtraFiles = []*os.File{lock}
		command.Env = []string{"PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME=" + os.Getenv("HOME"), "TMPDIR=" + os.TempDir(), "LANG=en_US.UTF-8"}
		for k, v := range env {
			command.Env = append(command.Env, k+"="+v)
		}
		command.Stdout = &output
		command.Stderr = &output
		currentDir, dirErr := os.Lstat(command.Dir)
		currentEntry, entryErr := os.Lstat(command.Path)
		if dirErr != nil || entryErr != nil || !currentDir.IsDir() || !os.SameFile(task.directory, currentDir) ||
			!os.SameFile(entryInfo, currentEntry) || currentEntry.Mode() != entryInfo.Mode() ||
			currentEntry.Size() != entryInfo.Size() || !currentEntry.ModTime().Equal(entryInfo.ModTime()) {
			err = ErrInvalid
		} else {
			err = ctx.Err()
			if err == nil {
				err = command.Start()
				if errors.Is(err, os.ErrNotExist) {
					err = errors.New("无法启动脚本，请检查首行指定的解释器是否已在 Mac 安装。")
				}
			}
		}
		if err == nil {
			done := make(chan error, 1)
			go func() { done <- command.Wait() }()
			select {
			case err = <-done:
			case <-ctx.Done():
				if command.Process != nil {
					_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
				}
				<-done
				err = ctx.Err()
			}
		}
	}
	if err != nil {
		state = "failure"
		code = -1
		switch {
		case errors.Is(err, context.DeadlineExceeded):
			state = "timeout"
		case errors.Is(err, context.Canceled):
			state = "interrupted"
		}
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			code = exit.ExitCode()
		}
		output.Write([]byte("\nLightIsle: " + err.Error()))
	}
	finishedAt := time.Now()
	channels := []string(nil)
	if m.notify != nil && slices.Contains(task.Notification.Events, state) {
		channels = task.Notification.Channels
	}
	if err := m.finishRun(runID, id, state, code, output.String(), finishedAt, channels); err != nil {
		slog.Warn("cannot record automation result", "task", id, "error", err)
		return
	}
	if len(channels) == 0 {
		return
	}
	html := ""
	if task.Notification.Email != nil && task.Notification.Email.File != "" {
		var err error
		html, err = m.renderTaskEmail(task, state, code, finishedAt)
		if err != nil {
			fallback := *task.Notification.Email
			fallback.Mode = "builtin"
			fallback.File = ""
			task.Notification.Email = &fallback
			task.LastError = "邮件 HTML 模板不可读取，本次通知已退回内置模板，请检查本地文件后刷新。"
			m.appendRunNote(runID, task.LastError)
		}
	}
	m.notify(task, state, finishedAt, code, html, func(channel, status string) {
		m.reportDelivery(runID, channel, status)
	})
}

// The child inherits the lock, so restarting Core cannot start another copy
// while a process from the previous Core still owns the descriptor.
func (m *Manager) lockScript(id string) (*os.File, error) {
	if !taskID.MatchString(id) {
		return nil, ErrInvalid
	}
	dir, _, err := openDirectoryRoot(filepath.Join(m.dir, "locks"), nil)
	if err != nil {
		return nil, err
	}
	defer dir.Close()
	file, err := dir.OpenFile(id, os.O_RDWR|os.O_CREATE|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0600)
	if err != nil {
		return nil, err
	}
	info, err := file.Stat()
	if err == nil && !info.Mode().IsRegular() {
		err = ErrInvalid
	}
	if err == nil {
		err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
	}
	if err != nil {
		_ = file.Close()
		return nil, err
	}
	return file, nil
}
