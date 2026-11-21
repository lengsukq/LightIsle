//go:build darwin && arm64

package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/frpclient"
)

// FRP is deliberately reachable only through the parent Mac App's stdin
// control pipe, never from a remotely authenticated Web/API session.
type frpControl struct {
	manager *frpclient.Manager
	output  io.Writer
	initErr error
	ctx     context.Context
}

func newFRPControl(ctx context.Context) *frpControl {
	dir, err := frpclient.DefaultDir()
	control := &frpControl{output: ipcStdout, initErr: err, ctx: ctx}
	if err != nil {
		return control
	}
	control.manager = frpclient.New(ctx, dir, func(s frpclient.State) {
		if data, err := json.Marshal(s); err == nil {
			writeStdoutLine("LIGHTISLE_FRP_STATE " + base64.RawURLEncoding.EncodeToString(data))
		}
	})
	return control
}

func (c *frpControl) status() {
	if err := c.manager.EnsureConfig(); err != nil {
		c.failure(err)
	}
	if data, err := json.Marshal(c.manager.Status()); err == nil {
		fmt.Fprintln(c.output, "LIGHTISLE_FRP_STATE "+base64.RawURLEncoding.EncodeToString(data))
	}
}

func (c *frpControl) failure(err error) {
	// Never return raw subprocess output or configuration file contents.
	message := err.Error()
	if len(message) > 300 {
		limit := 300
		for limit > 0 && (message[limit]&0xC0) == 0x80 {
			limit--
		}
		message = message[:limit]
	}
	fmt.Fprintln(c.output, "LIGHTISLE_FRP_ERROR "+base64.RawURLEncoding.EncodeToString([]byte(message)))
}

func (c *frpControl) handle(command string) bool {
	if command != "frp status" && command != "frp versions" && !strings.HasPrefix(command, "frp install ") && command != "frp start" && command != "frp stop" {
		return false
	}
	if c.initErr != nil {
		c.failure(fmt.Errorf("frpc_config_directory_unavailable"))
		return true
	}
	switch command {
	case "frp status":
		c.status()
	case "frp versions":
		// Do not block the private stdin command loop on GitHub networking.
		go func() {
			fetchCtx, cancel := context.WithTimeout(c.ctx, 20*time.Second)
			defer cancel()
			items, err := c.manager.FetchVersions(fetchCtx)
			if err != nil {
				c.failure(err)
				return
			}
			if data, err := json.Marshal(items); err == nil {
				fmt.Fprintln(c.output, "LIGHTISLE_FRP_VERSIONS "+base64.RawURLEncoding.EncodeToString(data))
			}
		}()
	case "frp start":
		if err := c.manager.Start(); err != nil {
			c.failure(err)
		}
		c.status()
	case "frp stop":
		c.manager.Stop()
		c.status()
	default:
		if strings.HasPrefix(command, "frp install ") {
			if err := c.manager.BeginInstall(strings.TrimPrefix(command, "frp install ")); err != nil {
				c.failure(err)
			}
			c.status()
		}
	}
	return true
}
