//go:build darwin && arm64

package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
)

const ipcEnvelopeSchemaVersion = 1

// ipcResponseEnvelope standardizes versioned JSON responses framed over the
// trusted native parent stdout pipe (`<PREFIX> <base64url(json)>`).
type ipcResponseEnvelope struct {
	SchemaVersion int    `json:"schemaVersion"`
	Operation     string `json:"operation"`
	RequestID     string `json:"requestID"`
	Result        any    `json:"result,omitempty"`
	Error         string `json:"error,omitempty"`
}

type ipcEnvelopeOptions struct {
	Output        io.Writer
	Prefix        string
	RequestID     string
	Operation     string
	Result        any
	IncludeResult bool
	ErrorMessage  string
	FallbackError string
	MaxJSONBytes  int
}

func writeIPCEnvelope(opts ipcEnvelopeOptions) {
	out := opts.Output
	if out == nil {
		out = ipcStdout
	}
	env := ipcResponseEnvelope{
		SchemaVersion: ipcEnvelopeSchemaVersion,
		Operation:     opts.Operation,
		RequestID:     opts.RequestID,
	}
	if opts.ErrorMessage != "" {
		env.Error = opts.ErrorMessage
	}
	if opts.IncludeResult {
		env.Result = opts.Result
	}
	data, err := json.Marshal(env)
	if err != nil || (opts.MaxJSONBytes > 0 && len(data) > opts.MaxJSONBytes) {
		fallback := ipcResponseEnvelope{
			SchemaVersion: ipcEnvelopeSchemaVersion,
			Operation:     opts.Operation,
			RequestID:     opts.RequestID,
			Error:         opts.FallbackError,
		}
		var fallbackErr error
		data, fallbackErr = json.Marshal(fallback)
		if fallbackErr != nil {
			return
		}
	}
	_, _ = fmt.Fprintln(out, opts.Prefix+" "+base64.RawURLEncoding.EncodeToString(data))
}
