//go:build darwin && arm64

package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
)

const (
	stdinReaderBufSize     = 64 * 1024
	maxIPCCommandLineBytes = 256 * 1024
)

var ipcStdoutMu sync.Mutex

type lockedStdoutWriter struct{}

func (lockedStdoutWriter) Write(p []byte) (int, error) {
	ipcStdoutMu.Lock()
	defer ipcStdoutMu.Unlock()
	return os.Stdout.Write(p)
}

var ipcStdout io.Writer = lockedStdoutWriter{}

func writeStdoutLine(line string) {
	ipcStdoutMu.Lock()
	defer ipcStdoutMu.Unlock()
	_, _ = fmt.Fprintln(os.Stdout, line)
}

func sanitizeIPCText(raw string) string {
	cleaned := strings.NewReplacer("\r\n", " ", "\n", " ", "\r", " ").Replace(raw)
	return strings.TrimSpace(cleaned)
}

// readIPCCommandLines reads newline-delimited IPC commands using a 64 KiB reader
// buffer while allowing individual lines up to 256 KiB (comfortably fitting
// base64-encoded SMART reports). Lines exceeding 256 KiB are drained and logged
// without terminating the daemon; only io.EOF, a fatal stdin read error, or the
// explicit "shutdown" command stops the loop.
func readIPCCommandLines(r io.Reader, errOut io.Writer, deliver func(string) bool) {
	br := bufio.NewReaderSize(r, stdinReaderBufSize)
	var lineBuf []byte
	oversized := false

	for {
		frag, err := br.ReadSlice('\n')
		if errors.Is(err, bufio.ErrBufferFull) {
			if !oversized {
				if len(lineBuf)+len(frag) > maxIPCCommandLineBytes {
					oversized = true
					lineBuf = nil
				} else {
					lineBuf = append(lineBuf, frag...)
				}
			}
			continue
		}

		if oversized {
			oversized = false
			lineBuf = nil
			if errOut != nil {
				_, _ = fmt.Fprintf(errOut, "lightisled: dropped oversized IPC line (> %d bytes)\n", maxIPCCommandLineBytes)
			}
			if err != nil {
				if !errors.Is(err, io.EOF) && errOut != nil {
					_, _ = fmt.Fprintf(errOut, "lightisled: stdin read error: %v\n", err)
				}
				return
			}
			continue
		}

		var rawLine string
		if len(lineBuf) > 0 {
			if len(lineBuf)+len(frag) > maxIPCCommandLineBytes {
				lineBuf = nil
				if errOut != nil {
					_, _ = fmt.Fprintf(errOut, "lightisled: dropped oversized IPC line (> %d bytes)\n", maxIPCCommandLineBytes)
				}
				if err != nil {
					return
				}
				continue
			}
			lineBuf = append(lineBuf, frag...)
			rawLine = string(lineBuf)
			lineBuf = lineBuf[:0]
		} else {
			if len(frag) > maxIPCCommandLineBytes {
				if errOut != nil {
					_, _ = fmt.Fprintf(errOut, "lightisled: dropped oversized IPC line (> %d bytes)\n", maxIPCCommandLineBytes)
				}
				if err != nil {
					return
				}
				continue
			}
			rawLine = string(frag)
		}

		if rawLine != "" {
			command := strings.TrimSpace(rawLine)
			if command == "shutdown" {
				return
			}
			if command != "" && !deliver(command) {
				return
			}
		}

		if err != nil {
			if !errors.Is(err, io.EOF) && errOut != nil {
				_, _ = fmt.Fprintf(errOut, "lightisled: stdin read error: %v\n", err)
			}
			return
		}
	}
}
