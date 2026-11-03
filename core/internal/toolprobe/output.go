// Package toolprobe captures bounded output from optional tool version probes.
package toolprobe

import (
	"context"
	"errors"
	"os/exec"
	"time"
)

const maxOutput = 32 << 10

type output struct {
	data     []byte
	exceeded bool
}

func (o *output) Write(p []byte) (int, error) {
	room := maxOutput - len(o.data)
	if len(p) > room {
		o.exceeded = true
	}
	o.data = append(o.data, p[:min(len(p), room)]...)
	return len(p), nil
}

func Run(ctx context.Context, binary string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, binary, args...)
	var stdout output
	cmd.Stdout = &stdout
	// A descendant may still hold stdout even after the tool exits.
	cmd.WaitDelay = time.Second
	if err := cmd.Run(); err != nil {
		return nil, err
	}
	if stdout.exceeded {
		return nil, errors.New("tool probe output exceeds limit")
	}
	return stdout.data, nil
}
