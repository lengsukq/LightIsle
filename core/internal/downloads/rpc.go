package downloads

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// ErrRPC is the stable reason code for transport-level RPC failures.
var ErrRPC = errors.New("aria2_rpc_failed")

// RPC talks to a locally supervised aria2c JSON-RPC endpoint. It only ever
// dials the loopback listener this process started; the secret token is held
// in memory and never logged.
type RPC struct {
	baseURL string
	secret  string
	client  *http.Client
}

func NewRPC(port int, secret string) *RPC {
	return &RPC{
		baseURL: fmt.Sprintf("http://127.0.0.1:%d/jsonrpc", port),
		secret:  secret,
		client:  &http.Client{Timeout: 5 * time.Second},
	}
}

type rpcRequest struct {
	JSONRPC string `json:"jsonrpc"`
	ID      string `json:"id"`
	Method  string `json:"method"`
	Params  []any  `json:"params"`
}

func (c *RPC) call(ctx context.Context, method string, params ...any) (json.RawMessage, error) {
	full := append([]any{"token:" + c.secret}, params...)
	body, err := json.Marshal(rpcRequest{JSONRPC: "2.0", ID: "lightisle", Method: method, Params: full})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	response, err := c.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %s", ErrRPC, method)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%w: http %d", ErrRPC, response.StatusCode)
	}
	var envelope struct {
		Result json.RawMessage `json:"result"`
		Error  *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.NewDecoder(response.Body).Decode(&envelope); err != nil {
		return nil, fmt.Errorf("%w: bad response for %s", ErrRPC, method)
	}
	if envelope.Error != nil {
		return nil, fmt.Errorf("%w: %s code %d", ErrRPC, envelope.Error.Message, envelope.Error.Code)
	}
	return envelope.Result, nil
}

// GIDNotFoundError marks an aria2 "Active not found"-style lookup miss.
func IsGIDNotFound(err error) bool {
	return err != nil && strings.Contains(err.Error(), "not found")
}

// AddURI enqueues one download and returns its gid. options carries
// per-download settings (dir, max-download-limit, ...).
func (c *RPC) AddURI(ctx context.Context, url string, options map[string]any) (string, error) {
	result, err := c.call(ctx, "aria2.addUri", []string{url}, options)
	if err != nil {
		return "", err
	}
	var gid string
	if err := json.Unmarshal(result, &gid); err != nil {
		return "", fmt.Errorf("%w: addUri result", ErrRPC)
	}
	return gid, nil
}

// DownloadStatus is the slice of tellStatus fields the manager tracks.
type DownloadStatus struct {
	GID              string
	Status           string // active | waiting | paused | complete | error | removed
	TotalBytes       int64
	CompletedBytes   int64
	DownloadSpeed    int64
	ErrorMessage     string
	NumSeeders       int
	VerificationOK   bool
	Files            []string // absolute paths inside the staging dir
	FollowedBy       []string // magnet → metadata → real download chains
	SequenceComplete bool
}

func (c *RPC) TellStatus(ctx context.Context, gid string) (DownloadStatus, error) {
	result, err := c.call(ctx, "aria2.tellStatus", gid, []string{
		"gid", "status", "totalLength", "completedLength", "downloadSpeed",
		"errorMessage", "numSeeders", "verifyResult", "files", "followedBy",
		"sequenceComplete",
	})
	if err != nil {
		return DownloadStatus{}, err
	}
	var raw struct {
		GID             string `json:"gid"`
		Status          string `json:"status"`
		TotalLength     string `json:"totalLength"`
		CompletedLength string `json:"completedLength"`
		DownloadSpeed   string `json:"downloadSpeed"`
		ErrorMessage    string `json:"errorMessage"`
		NumSeeders      string `json:"numSeeders"`
		VerifyResult    string `json:"verifyResult"`
		Files           []struct {
			Path string `json:"path"`
		} `json:"files"`
		FollowedBy       []string `json:"followedBy"`
		SequenceComplete string   `json:"sequenceComplete"`
	}
	if err := json.Unmarshal(result, &raw); err != nil {
		return DownloadStatus{}, fmt.Errorf("%w: tellStatus payload", ErrRPC)
	}
	status := DownloadStatus{
		GID:              raw.GID,
		Status:           raw.Status,
		ErrorMessage:     raw.ErrorMessage,
		FollowedBy:       raw.FollowedBy,
		NumSeeders:       atoiDefault(raw.NumSeeders),
		SequenceComplete: raw.SequenceComplete == "true",
	}
	status.TotalBytes, _ = strconv.ParseInt(raw.TotalLength, 10, 64)
	status.CompletedBytes, _ = strconv.ParseInt(raw.CompletedLength, 10, 64)
	status.DownloadSpeed, _ = strconv.ParseInt(raw.DownloadSpeed, 10, 64)
	status.VerificationOK = raw.VerifyResult == "true"
	for _, file := range raw.Files {
		if file.Path != "" && file.Path != "[METADATA]" {
			status.Files = append(status.Files, file.Path)
		}
	}
	return status, nil
}

func atoiDefault(value string) int {
	n, _ := strconv.Atoi(value)
	return n
}

func (c *RPC) Pause(ctx context.Context, gid string) error {
	_, err := c.call(ctx, "aria2.pause", gid)
	return err
}

func (c *RPC) Unpause(ctx context.Context, gid string) error {
	_, err := c.call(ctx, "aria2.unpause", gid)
	return err
}

// Remove deletes the download from aria2 (force-removing BT seeds too).
func (c *RPC) Remove(ctx context.Context, gid string) error {
	_, err := c.call(ctx, "aria2.forceRemove", gid)
	return err
}

// GetVersion proves the RPC endpoint is live and returns the version string.
func (c *RPC) GetVersion(ctx context.Context) (string, error) {
	result, err := c.call(ctx, "aria2.getVersion")
	if err != nil {
		return "", err
	}
	var payload struct {
		Version string `json:"version"`
	}
	if err := json.Unmarshal(result, &payload); err != nil || payload.Version == "" {
		return "", fmt.Errorf("%w: getVersion payload", ErrRPC)
	}
	return payload.Version, nil
}
