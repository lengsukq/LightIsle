package mediaworker

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"time"
)

const (
	MaxAIBatchItems        = 16
	MaxAIResponseLineBytes = 256 << 10
	defaultAIBatchTimeout  = 90 * time.Second
)

var ErrThrottled = errors.New("media_worker_throttled")

type AIBatchInput struct {
	Source *os.File
	Name   string
}

type AISceneTag struct {
	Label       string   `json:"label"`
	Confidence  float32  `json:"confidence"`
	SearchTerms []string `json:"searchTerms,omitempty"`
}

type AIFace struct {
	BoxX         float32 `json:"boxX"`
	BoxY         float32 `json:"boxY"`
	BoxW         float32 `json:"boxW"`
	BoxH         float32 `json:"boxH"`
	Quality      float32 `json:"quality"`
	EyeOpenness  float32 `json:"eyeOpenness"`
	ModelVersion string  `json:"modelVersion"`
	Embedding    []byte  `json:"-"`
	EmbeddingB64 string  `json:"embedding"`
}

type AIAnalysis struct {
	Version         int          `json:"version"`
	Index           int          `json:"index"`
	Status          string       `json:"status"`
	OCRText         string       `json:"ocrText,omitempty"`
	OCRTokens       []string     `json:"ocrTokens,omitempty"`
	SceneTags       []AISceneTag `json:"sceneTags,omitempty"`
	Faces           []AIFace     `json:"faces,omitempty"`
	FeaturePrintF16 []byte       `json:"-"`
	FeaturePrintB64 string       `json:"featurePrintF16,omitempty"`
	Sharpness       float32      `json:"sharpness,omitempty"`
	Aesthetics      *float32     `json:"aesthetics,omitempty"`
	IsUtility       *bool        `json:"isUtility,omitempty"`
	Error           string       `json:"error,omitempty"`
}

// AnalyzeBatch passes up to 16 already-open read-only file descriptors to a
// single short-lived worker invocation (fd 3..fd 3+N-1), amortizing Apple
// Vision / ANE model warmup while guaranteeing full memory release on exit.
func (c *Client) AnalyzeBatch(parent context.Context, items []AIBatchInput) ([]AIAnalysis, error) {
	if len(items) == 0 || len(items) > MaxAIBatchItems {
		return nil, ErrInvalidResponse
	}
	if parent == nil {
		parent = context.Background()
	}
	if err := c.checkExecutable(); err != nil {
		return nil, err
	}
	extraFiles := make([]*os.File, len(items))
	names := make([]string, len(items))
	for i, item := range items {
		base := filepath.Base(item.Name)
		if item.Source == nil || !validName(base) {
			return nil, ErrInvalidResponse
		}
		stat, err := item.Source.Stat()
		if err != nil || !stat.Mode().IsRegular() {
			return nil, errors.New("media_worker_source_must_be_regular_file")
		}
		extraFiles[i] = item.Source
		names[i] = base
	}
	namesJSON, err := json.Marshal(names)
	if err != nil {
		return nil, err
	}

	aiGate := c.aiSlots
	if aiGate == nil {
		aiGate = c.slots
	}
	select {
	case aiGate <- struct{}{}:
		defer func() { <-aiGate }()
	case <-parent.Done():
		return nil, parent.Err()
	}

	timeout := defaultAIBatchTimeout
	if c.timeout > 0 && c.timeout < timeout && len(items) == 1 {
		timeout = c.timeout * 2
	}
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()

	args := []string{
		"ai-batch",
		"--fd-count", strconv.Itoa(len(items)),
		"--names-json", string(namesJSON),
	}
	cmd := exec.CommandContext(ctx, c.path, args...)
	cmd.ExtraFiles = extraFiles
	totalLimit := len(items) * MaxAIResponseLineBytes
	stdout := &boundedWriter{limit: totalLimit}
	stderr := &boundedWriter{limit: MaxStderrBytes}
	cmd.Stdout, cmd.Stderr = stdout, stderr

	runErr := cmd.Run()
	c.mu.Lock()
	c.lastStderr = stderr.String()
	c.mu.Unlock()
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if stdout.overflowed() {
		return nil, ErrOutputTooLarge
	}
	parsed, parseErr := decodeAIBatchOutput(stdout.Bytes(), len(items))
	if parseErr != nil {
		if runErr != nil {
			return nil, fmt.Errorf("%w: %v", ErrInvalidResponse, runErr)
		}
		return nil, parseErr
	}
	return parsed, nil
}

func (c *Client) checkExecutable() error {
	if !filepath.IsAbs(c.path) {
		return fmt.Errorf("%w: executable path must be absolute", ErrUnavailable)
	}
	info, err := os.Lstat(c.path)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	if !info.Mode().IsRegular() || info.Mode()&0111 == 0 {
		return fmt.Errorf("%w: trusted executable is not a regular executable", ErrUnavailable)
	}
	return nil
}

func decodeAIBatchOutput(raw []byte, expected int) ([]AIAnalysis, error) {
	scanner := bufio.NewScanner(bytes.NewReader(raw))
	scanner.Buffer(make([]byte, 64<<10), MaxAIResponseLineBytes)
	results := make([]AIAnalysis, 0, expected)
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		item, err := decodeAIItem(line, len(results))
		if err != nil {
			return nil, err
		}
		results = append(results, item)
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidResponse, err)
	}
	if len(results) != expected {
		return nil, ErrInvalidResponse
	}
	return results, nil
}

func decodeAIItem(line []byte, expectedIndex int) (AIAnalysis, error) {
	decoder := json.NewDecoder(bytes.NewReader(line))
	decoder.DisallowUnknownFields()
	var item AIAnalysis
	if err := decoder.Decode(&item); err != nil {
		return AIAnalysis{}, fmt.Errorf("%w: %v", ErrInvalidResponse, err)
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return AIAnalysis{}, ErrInvalidResponse
	}
	if item.Version != ProtocolVersion || item.Index != expectedIndex {
		return AIAnalysis{}, ErrInvalidResponse
	}
	switch item.Status {
	case "ok":
		if err := hydrateAndValidateAIItem(&item); err != nil {
			return AIAnalysis{}, err
		}
		return item, nil
	case "unsupported", "throttled", "error":
		return item, nil
	default:
		return AIAnalysis{}, ErrInvalidResponse
	}
}

func hydrateAndValidateAIItem(item *AIAnalysis) error {
	if len(item.OCRText) > 16<<10 || len(item.OCRTokens) > 512 || len(item.SceneTags) > 32 || len(item.Faces) > 24 {
		return ErrInvalidResponse
	}
	if item.FeaturePrintB64 != "" {
		raw, err := base64.StdEncoding.DecodeString(item.FeaturePrintB64)
		if err != nil || len(raw) == 0 || len(raw)%2 != 0 || len(raw) > 4096 {
			return ErrInvalidResponse
		}
		item.FeaturePrintF16 = raw
	}
	for i := range item.Faces {
		f := &item.Faces[i]
		if f.BoxX < 0 || f.BoxX > 1 || f.BoxY < 0 || f.BoxY > 1 ||
			f.BoxW <= 0 || f.BoxW > 1 || f.BoxH <= 0 || f.BoxH > 1 ||
			f.ModelVersion == "" || len(f.ModelVersion) > 64 {
			return ErrInvalidResponse
		}
		raw, err := base64.StdEncoding.DecodeString(f.EmbeddingB64)
		if err != nil || len(raw) < 256 || len(raw)%4 != 0 || len(raw) > 4096 {
			return ErrInvalidResponse
		}
		f.Embedding = raw
	}
	return nil
}
