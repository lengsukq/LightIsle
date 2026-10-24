// Package cloudflareapi is a minimal, purpose-built REST client for the
// Cloudflare surface the tunnel feature needs: account discovery, named
// tunnel CRUD, tunnel token retrieval, remotely-managed ingress rules and
// the DNS CNAME records that route hostnames into a tunnel. The API token
// is never logged and never embedded in error text.
package cloudflareapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	defaultBase   = "https://api.cloudflare.com/client/v4"
	requestBudget = 15 * time.Second
	maxBodyBytes  = 1 << 20
)

// APIError carries the Cloudflare error code so callers can map permission
// and credential problems to actionable, localized messages.
type APIError struct {
	Status  int
	Code    int
	Message string
}

func (e *APIError) Error() string { return e.Message }

// Friendly maps known Cloudflare failure codes to operator guidance.
func (e *APIError) Friendly() string {
	switch {
	case e.Status == http.StatusUnauthorized || e.Code == 9109 || e.Code == 10000:
		return "Cloudflare API Token 无效或已过期，请重新生成并粘贴。"
	case e.Status == http.StatusForbidden || e.Code == 9109 || e.Code == 81044:
		return "API Token 权限不足：需要 Account:Read、Cloudflare Tunnel:Edit、Zone:Read 与 DNS:Edit。"
	case e.Code == 7003:
		return "API Token 无效：Cloudflare 无法识别该凭据。"
	default:
		return e.Message
	}
}

type Client struct {
	http  *http.Client
	base  string
	token string
}

func New(token string) *Client {
	return &Client{http: &http.Client{Timeout: requestBudget}, base: defaultBase, token: strings.TrimSpace(token)}
}

// NewWithBase is used by tests to point the client at a fixture server.
func NewWithBase(token, base string) *Client {
	c := New(token)
	c.base = strings.TrimRight(base, "/")
	return c
}

type envelope struct {
	Success bool `json:"success"`
	Errors  []struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"errors"`
	Messages []json.RawMessage `json:"messages"`
	Result   json.RawMessage   `json:"result"`
}

func (c *Client) call(ctx context.Context, method, path string, body any, out any) error {
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(encoded)
	}
	request, err := http.NewRequestWithContext(ctx, method, c.base+path, reader)
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", "Bearer "+c.token)
	request.Header.Set("Content-Type", "application/json")
	response, err := c.http.Do(request)
	if err != nil {
		return fmt.Errorf("无法连接 Cloudflare API：%w", err)
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, maxBodyBytes))
	if err != nil {
		return err
	}
	var decoded envelope
	if err := json.Unmarshal(data, &decoded); err != nil {
		return &APIError{Status: response.StatusCode, Message: fmt.Sprintf("Cloudflare 返回了无法解析的响应（HTTP %d）。", response.StatusCode)}
	}
	if !decoded.Success {
		first := APIError{Status: response.StatusCode, Message: "Cloudflare 拒绝了该请求。"}
		if len(decoded.Errors) > 0 {
			first.Code = decoded.Errors[0].Code
			first.Message = strings.TrimSpace(decoded.Errors[0].Message)
		}
		return &first
	}
	if out != nil && len(decoded.Result) > 0 {
		if err := json.Unmarshal(decoded.Result, out); err != nil {
			return fmt.Errorf("Cloudflare 响应格式不符合预期：%w", err)
		}
	}
	return nil
}

type Account struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// ListAccounts validates the token and discovers the account ID.
func (c *Client) ListAccounts(ctx context.Context) ([]Account, error) {
	var accounts []Account
	if err := c.call(ctx, http.MethodGet, "/accounts?per_page=5", nil, &accounts); err != nil {
		return nil, err
	}
	if len(accounts) == 0 {
		return nil, errors.New("该 API Token 没有关联的 Cloudflare 账户。")
	}
	return accounts, nil
}

type Tunnel struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	Status       string `json:"status"`
	Connections  int    `json:"conns_active"`
	CreatedAt    string `json:"created_at"`
	RemoteConfig bool   `json:"-"`
}

func (t Tunnel) Healthy() bool { return t.Status == "healthy" }

type tunnelRaw struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Status      string `json:"status"`
	Connections int    `json:"conns_active"`
	CreatedAt   string `json:"created_at"`
	ConfigSrc   string `json:"config_src"`
}

func (c *Client) ListTunnels(ctx context.Context, accountID string) ([]Tunnel, error) {
	if !validID(accountID) {
		return nil, errInvalidAccount
	}
	var raws []tunnelRaw
	if err := c.call(ctx, http.MethodGet, "/accounts/"+url.PathEscape(accountID)+"/cfd_tunnel?is_deleted=false&per_page=50", nil, &raws); err != nil {
		return nil, err
	}
	tunnels := make([]Tunnel, 0, len(raws))
	for _, raw := range raws {
		tunnels = append(tunnels, Tunnel{
			ID: raw.ID, Name: raw.Name, Status: raw.Status,
			Connections: raw.Connections, CreatedAt: raw.CreatedAt,
			RemoteConfig: raw.ConfigSrc == "cloudflare",
		})
	}
	return tunnels, nil
}

// CreateTunnel creates a remotely-managed tunnel so ingress rules can be
// edited through the API without a local config file.
func (c *Client) CreateTunnel(ctx context.Context, accountID, name string) (Tunnel, error) {
	if !validID(accountID) || len(name) == 0 || len(name) > 64 {
		return Tunnel{}, errInvalidAccount
	}
	var tunnel Tunnel
	body := map[string]string{"name": name, "config_src": "cloudflare"}
	if err := c.call(ctx, http.MethodPost, "/accounts/"+url.PathEscape(accountID)+"/cfd_tunnel", body, &tunnel); err != nil {
		return Tunnel{}, err
	}
	tunnel.RemoteConfig = true
	return tunnel, nil
}

func (c *Client) DeleteTunnel(ctx context.Context, accountID, tunnelID string) error {
	if !validID(accountID) || !validID(tunnelID) {
		return errInvalidAccount
	}
	return c.call(ctx, http.MethodDelete, "/accounts/"+url.PathEscape(accountID)+"/cfd_tunnel/"+url.PathEscape(tunnelID)+"?cleanup_on=true", nil, nil)
}

// TunnelToken fetches the run token for an existing tunnel.
func (c *Client) TunnelToken(ctx context.Context, accountID, tunnelID string) (string, error) {
	if !validID(accountID) || !validID(tunnelID) {
		return "", errInvalidAccount
	}
	var token string
	if err := c.call(ctx, http.MethodGet, "/accounts/"+url.PathEscape(accountID)+"/cfd_tunnel/"+url.PathEscape(tunnelID)+"/token", nil, &token); err != nil {
		return "", err
	}
	if token == "" {
		return "", errors.New("Cloudflare 未返回隧道 Token，请确认隧道存在且 Token 权限完整。")
	}
	return token, nil
}

type IngressRule struct {
	Hostname string `json:"hostname,omitempty"`
	Service  string `json:"service"`
	Path     string `json:"path,omitempty"`
}

type TunnelConfig struct {
	Ingress []IngressRule `json:"ingress"`
}

func (c *Client) TunnelConfigurations(ctx context.Context, accountID, tunnelID string) (TunnelConfig, error) {
	var config TunnelConfig
	if !validID(accountID) || !validID(tunnelID) {
		return config, errInvalidAccount
	}
	err := c.call(ctx, http.MethodGet, "/accounts/"+url.PathEscape(accountID)+"/cfd_tunnel/"+url.PathEscape(tunnelID)+"/configurations", nil, &config)
	return config, err
}

// PutTunnelConfigurations replaces the ingress list; the caller is expected
// to have read the current rules first (read-modify-write).
func (c *Client) PutTunnelConfigurations(ctx context.Context, accountID, tunnelID string, config TunnelConfig) error {
	if !validID(accountID) || !validID(tunnelID) {
		return errInvalidAccount
	}
	if len(config.Ingress) == 0 || config.Ingress[len(config.Ingress)-1].Hostname != "" {
		config.Ingress = append(config.Ingress, IngressRule{Service: "http_status:404"})
	}
	return c.call(ctx, http.MethodPut, "/accounts/"+url.PathEscape(accountID)+"/cfd_tunnel/"+url.PathEscape(tunnelID)+"/configurations", map[string]any{"config": config}, nil)
}

type Zone struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Status string `json:"status"`
}

func (c *Client) ListZones(ctx context.Context) ([]Zone, error) {
	var zones []Zone
	if err := c.call(ctx, http.MethodGet, "/zones?per_page=50", nil, &zones); err != nil {
		return nil, err
	}
	return zones, nil
}

type DNSRecord struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Type    string `json:"type"`
	Content string `json:"content"`
}

func (c *Client) findDNSRecord(ctx context.Context, zoneID, hostname string) (*DNSRecord, error) {
	var records []DNSRecord
	path := "/zones/" + url.PathEscape(zoneID) + "/dns_records?type=CNAME&name=" + url.QueryEscape(hostname) + "&per_page=5"
	if err := c.call(ctx, http.MethodGet, path, nil, &records); err != nil {
		return nil, err
	}
	for i := range records {
		if strings.EqualFold(records[i].Name, hostname) {
			return &records[i], nil
		}
	}
	return nil, nil
}

// EnsureHostnameRoute creates (or verifies) the proxied CNAME that points a
// public hostname at the tunnel. Existing records are left untouched so a
// hostname already serving other traffic is never clobbered.
func (c *Client) EnsureHostnameRoute(ctx context.Context, zoneID, hostname, tunnelID string) (created bool, err error) {
	if !validID(zoneID) || !validID(tunnelID) || !validHostname(hostname) {
		return false, errors.New("主机名或区域 ID 无效。")
	}
	existing, err := c.findDNSRecord(ctx, zoneID, hostname)
	if err != nil {
		return false, err
	}
	if existing != nil {
		if existing.Content != tunnelID+".cfargotunnel.com" {
			return false, fmt.Errorf("%s 已指向其他目标（%s），请在 Cloudflare 控制台确认后手动调整。", hostname, existing.Content)
		}
		return false, nil
	}
	body := map[string]any{
		"type": "CNAME", "name": hostname,
		"content": tunnelID + ".cfargotunnel.com", "proxied": true, "ttl": 1,
		"comment": "LightIsle managed tunnel route",
	}
	if err := c.call(ctx, http.MethodPost, "/zones/"+url.PathEscape(zoneID)+"/dns_records", body, nil); err != nil {
		return false, err
	}
	return true, nil
}

func (c *Client) DeleteDNSRecord(ctx context.Context, zoneID, recordID string) error {
	if !validID(zoneID) || !validID(recordID) {
		return errors.New("DNS 记录 ID 无效。")
	}
	return c.call(ctx, http.MethodDelete, "/zones/"+url.PathEscape(zoneID)+"/dns_records/"+url.PathEscape(recordID), nil, nil)
}

// RemoveHostnameRoute deletes the CNAME for a hostname only when it still
// points at this tunnel; foreign records are never touched.
func (c *Client) RemoveHostnameRoute(ctx context.Context, zoneID, hostname, tunnelID string) (removed bool, err error) {
	if !validID(zoneID) || !validID(tunnelID) || !validHostname(hostname) {
		return false, errors.New("主机名或区域 ID 无效。")
	}
	existing, err := c.findDNSRecord(ctx, zoneID, hostname)
	if err != nil || existing == nil {
		return false, err
	}
	if existing.Content != tunnelID+".cfargotunnel.com" {
		return false, nil
	}
	return true, c.DeleteDNSRecord(ctx, zoneID, existing.ID)
}

var errInvalidAccount = errors.New("账户或隧道 ID 无效。")

func validID(id string) bool {
	if id == "" || len(id) > 64 {
		return false
	}
	for _, r := range id {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_') {
			return false
		}
	}
	return true
}

func validHostname(hostname string) bool {
	if len(hostname) == 0 || len(hostname) > 253 {
		return false
	}
	labels := strings.Split(strings.TrimSuffix(hostname, "."), ".")
	if len(labels) < 2 {
		return false
	}
	for _, label := range labels {
		if label == "" || len(label) > 63 {
			return false
		}
		for _, r := range label {
			if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-') {
				return false
			}
		}
	}
	return true
}
