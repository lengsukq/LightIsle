package apps

import (
	"errors"
	"strconv"
	"strings"
)

const (
	DefaultOfficialStoreURL = "https://raw.githubusercontent.com/lengsukq/LightIsle/main/plugins-store/registry.json"
	DefaultOfficialStoreName = "LightIsle 官方家庭轻应用商店"
	DefaultOfficialStoreRepo = "https://github.com/lengsukq/LightIsle"
	StoreSchemaVersion      = 1

	maxStoreRegistryBytes = 2 << 20
	maxStoreIconBytes     = 256 << 10
)

var (
	ErrAlreadyInstalled      = errors.New("app_already_exists")
	ErrStoreUnavailable      = errors.New("app_store_unavailable")
	ErrStorePluginNotFound   = errors.New("app_store_plugin_not_found")
	ErrStoreChecksumMismatch = errors.New("app_store_checksum_mismatch")
	ErrStoreInvalidConfig    = errors.New("app_store_invalid_config")
	ErrStoreNoUpdate         = errors.New("app_store_no_update")
	// ErrTemplateNotFound aliases ErrStorePluginNotFound for backward compatibility.
	ErrTemplateNotFound = ErrStorePluginNotFound
)

// AppStoreConfig stores the user's preferred Git plugin registry source and optional mirror prefix.
type AppStoreConfig struct {
	RegistryURL  string `json:"registryUrl,omitempty"`
	MirrorPrefix string `json:"mirrorPrefix,omitempty"`
	UpdatedAt    string `json:"updatedAt,omitempty"`
}

// AppStoreConfigRequest updates the online store source settings.
type AppStoreConfigRequest struct {
	RegistryURL  string `json:"registryUrl"`
	MirrorPrefix string `json:"mirrorPrefix"`
	ResetDefault bool   `json:"resetDefault,omitempty"`
}

// StoreRegistryDocument represents the Git-hosted plugins-store/registry.json index.
type StoreRegistryDocument struct {
	SchemaVersion int                `json:"schemaVersion"`
	StoreName     string             `json:"storeName"`
	Repository    string             `json:"repository,omitempty"`
	UpdatedAt     string             `json:"updatedAt,omitempty"`
	Plugins       []StorePluginEntry `json:"plugins"`
}

// StorePluginEntry describes one downloadable plugin package in registry.json.
type StorePluginEntry struct {
	ID           string   `json:"id"`
	Name         string   `json:"name"`
	Version      string   `json:"version"`
	Author       string   `json:"author,omitempty"`
	Category     string   `json:"category,omitempty"`
	Mode         string   `json:"mode,omitempty"`
	DefaultScope string   `json:"defaultScope,omitempty"`
	Description  string   `json:"description,omitempty"`
	Tags         []string `json:"tags,omitempty"`
	IconPath     string   `json:"iconPath,omitempty"`
	PackagePath  string   `json:"packagePath"`
	SHA256       string   `json:"sha256"`
	SizeBytes    int64    `json:"sizeBytes,omitempty"`
}

// StorePluginView is the enriched online store catalog entry returned to clients.
type StorePluginView struct {
	ID               string   `json:"id"`
	Name             string   `json:"name"`
	Version          string   `json:"version"`
	Author           string   `json:"author,omitempty"`
	Category         string   `json:"category"`
	Mode             string   `json:"mode"`
	DefaultScope     string   `json:"defaultScope,omitempty"`
	Description      string   `json:"description"`
	Tags             []string `json:"tags,omitempty"`
	IconURL          string   `json:"iconUrl,omitempty"`
	SizeBytes        int64    `json:"sizeBytes,omitempty"`
	SHA256           string   `json:"sha256,omitempty"`
	Installed        bool     `json:"installed"`
	InstalledVersion string   `json:"installedVersion,omitempty"`
	UpdateAvailable  bool     `json:"updateAvailable"`
	LocationID       string   `json:"locationId,omitempty"`
}

// AppStoreSnapshot summarizes the online Git store configuration, cache state, and plugins.
type AppStoreSnapshot struct {
	StoreName     string            `json:"storeName"`
	RepositoryURL string            `json:"repositoryUrl,omitempty"`
	RegistryURL   string            `json:"registryUrl"`
	EffectiveURL  string            `json:"effectiveUrl"`
	DefaultURL    string            `json:"defaultUrl"`
	MirrorPrefix  string            `json:"mirrorPrefix,omitempty"`
	IsOfficial    bool              `json:"isOfficial"`
	Source        string            `json:"source"` // "remote", "cache", "empty", "unavailable"
	FetchedAt     string            `json:"fetchedAt,omitempty"`
	UpdatedAt     string            `json:"updatedAt,omitempty"`
	Error         string            `json:"error,omitempty"`
	Plugins       []StorePluginView `json:"plugins"`
}

// OfficialAppTemplate preserves the legacy JSON shape for older mobile clients reading cached store entries.
type OfficialAppTemplate struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	Version      string `json:"version"`
	Category     string `json:"category"`
	Description  string `json:"description"`
	DefaultScope string `json:"defaultScope"`
	Installed    bool   `json:"installed"`
}

// CompareSemver compares two semantic versions ("1.2.0" vs "1.10.0", optional "v" prefix and prerelease).
// Returns 1 if a > b, -1 if a < b, 0 if equal.
func CompareSemver(a, b string) int {
	pa := parseSemverParts(a)
	pb := parseSemverParts(b)
	for i := 0; i < 3; i++ {
		if pa.nums[i] > pb.nums[i] {
			return 1
		}
		if pa.nums[i] < pb.nums[i] {
			return -1
		}
	}
	// Release > prerelease when core numeric versions match.
	if pa.pre == "" && pb.pre != "" {
		return 1
	}
	if pa.pre != "" && pb.pre == "" {
		return -1
	}
	if pa.pre > pb.pre {
		return 1
	}
	if pa.pre < pb.pre {
		return -1
	}
	return 0
}

type semverParts struct {
	nums [3]int
	pre  string
}

func parseSemverParts(raw string) semverParts {
	s := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(raw), "v"))
	if idx := strings.IndexByte(s, '+'); idx >= 0 {
		s = s[:idx]
	}
	var out semverParts
	if idx := strings.IndexByte(s, '-'); idx >= 0 {
		out.pre = s[idx+1:]
		s = s[:idx]
	}
	parts := strings.Split(s, ".")
	for i := 0; i < len(parts) && i < 3; i++ {
		n, err := strconv.Atoi(strings.TrimSpace(parts[i]))
		if err == nil && n > 0 {
			out.nums[i] = n
		}
	}
	return out
}
