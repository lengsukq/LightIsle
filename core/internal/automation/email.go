package automation

import (
	"fmt"
	"html"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"
)

const maxEmailTemplate = 64 << 10

// renderTaskEmail expands a deliberately small set of safe HTML placeholders
// from an Agent-owned HTML file, not a template language with code execution.
// Secrets from env.json, logs and host paths are never interpolated.
func (m *Manager) renderTaskEmail(task Task, state string, exitCode int, finished time.Time) (string, error) {
	email := task.Notification.Email
	if email == nil || email.File == "" {
		return "", nil
	}
	root, err := os.OpenRoot(filepath.Join(m.scripts, task.ID))
	if err != nil {
		return "", err
	}
	defer root.Close()
	raw, err := checkedFile(root, email.File, maxEmailTemplate)
	if err != nil {
		return "", err
	}
	if !utf8.Valid(raw) {
		return "", ErrInvalid
	}
	message := map[string]string{"success": "执行成功", "failure": "执行失败", "timeout": "执行超时"}[state]
	substitutions := strings.NewReplacer(
		"{{task.name}}", html.EscapeString(task.Name),
		"{{task.id}}", html.EscapeString(task.ID),
		"{{run.state}}", html.EscapeString(state),
		"{{run.message}}", html.EscapeString(message),
		"{{run.finishedAt}}", html.EscapeString(finished.Format(time.RFC3339)),
		"{{run.exitCode}}", html.EscapeString(fmt.Sprint(exitCode)),
	)
	return substitutions.Replace(string(raw)), nil
}
