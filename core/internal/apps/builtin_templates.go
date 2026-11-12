package apps

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"time"
)

var (
	ErrAlreadyInstalled = errors.New("app_already_exists")
	ErrTemplateNotFound = errors.New("app_template_not_found")
)

// OfficialAppTemplate describes an audited, zero-RSS pure local static light-app
// bundled with LightIsle so non-developer family households can install practical
// tools without remote script execution or supply-chain exposure.
type OfficialAppTemplate struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	Version      string `json:"version"`
	Category     string `json:"category"`
	Description  string `json:"description"`
	DefaultScope string `json:"defaultScope"`
	Installed    bool   `json:"installed"`
}

type builtinTemplateSpec struct {
	ID           string
	Name         string
	Version      string
	Category     string
	Description  string
	AccessPolicy string
	IconSVG      string
	IndexHTML    string
}

func builtinTemplateCatalog() []builtinTemplateSpec {
	return []builtinTemplateSpec{
		{
			ID:           "network-pulse",
			Name:         "轻屿网络与系统脉搏",
			Version:      "1.0.0",
			Category:     "system",
			Description:  "实时测量当前终端到家庭 NAS 的往返延迟、抖动与局域网/组网连通健康度。",
			AccessPolicy: AccessAllMembers,
			IconSVG:      builtInDemoIconSVG,
			IndexHTML:    builtInDemoHTML,
		},
		{
			ID:           "family-subscriptions",
			Name:         "家庭账单与订阅管家",
			Version:      "1.0.0",
			Category:     "family",
			Description:  "集中记录家庭宽带、影视会员、云服务与物业续费周期，自动换算月均开销并提醒临近扣费项目。",
			AccessPolicy: AccessAllMembers,
			IconSVG:      templateSubscriptionsIconSVG,
			IndexHTML:    templateSubscriptionsHTML,
		},
		{
			ID:           "warranty-vault",
			Name:         "电子发票与保修卡夹",
			Version:      "1.0.0",
			Category:     "family",
			Description:  "登记家电数码购买日期、保修到期日、序列号与纸质票据存放位置，30 天内过保自动高亮。",
			AccessPolicy: AccessAllMembers,
			IconSVG:      templateWarrantyIconSVG,
			IndexHTML:    templateWarrantyHTML,
		},
		{
			ID:           "family-board",
			Name:         "家庭留言板与采购清单",
			Version:      "1.0.0",
			Category:     "lifestyle",
			Description:  "温馨的家庭便签墙与周末超市采购打勾清单，支持重要提醒置顶与一键导出备份。",
			AccessPolicy: AccessAllMembers,
			IconSVG:      templateFamilyBoardIconSVG,
			IndexHTML:    templateFamilyBoardHTML,
		},
	}
}

func isOfficialTemplateID(id string) bool {
	for _, spec := range builtinTemplateCatalog() {
		if spec.ID == id {
			return true
		}
	}
	return false
}

// ListTemplates returns all bundled official static light-app templates along
// with whether each template is currently installed in pluginsDir.
func (m *Manager) ListTemplates() []OfficialAppTemplate {
	catalog := builtinTemplateCatalog()
	m.mu.RLock()
	installedSet := make(map[string]bool, len(m.apps))
	for id := range m.apps {
		installedSet[id] = true
	}
	m.mu.RUnlock()

	out := make([]OfficialAppTemplate, 0, len(catalog))
	for _, spec := range catalog {
		out = append(out, OfficialAppTemplate{
			ID:           spec.ID,
			Name:         spec.Name,
			Version:      spec.Version,
			Category:     spec.Category,
			Description:  spec.Description,
			DefaultScope: spec.AccessPolicy,
			Installed:    installedSet[spec.ID],
		})
	}
	return out
}

// InstallTemplate materializes an audited built-in static template into pluginsDir
// and activates it immediately without spawning any background process (0 MB RSS).
func (m *Manager) InstallTemplate(templateID string) (PublicApp, error) {
	var chosen *builtinTemplateSpec
	catalog := builtinTemplateCatalog()
	for i := range catalog {
		if catalog[i].ID == templateID {
			chosen = &catalog[i]
			break
		}
	}
	if chosen == nil {
		return PublicApp{}, ErrTemplateNotFound
	}
	if _, exists := m.snapshotApp(chosen.ID); exists {
		return PublicApp{}, ErrAlreadyInstalled
	}

	appDir := filepath.Join(m.pluginsDir, chosen.ID)
	if _, err := os.Lstat(appDir); err == nil {
		return PublicApp{}, ErrAlreadyInstalled
	}
	uiDir := filepath.Join(appDir, "ui")
	if err := os.MkdirAll(uiDir, 0700); err != nil {
		return PublicApp{}, err
	}
	manifest := PluginManifest{
		SchemaVersion: 2,
		ID:            chosen.ID,
		Name:          chosen.Name,
		Version:       chosen.Version,
		Author:        "LightIsle Official",
		Description:   chosen.Description,
		Category:      chosen.Category,
		Icon:          "icon.svg",
		Access:        AccessConfig{Policy: chosen.AccessPolicy, AllowedUserIDs: []int64{}},
		Web: &WebConfig{
			Enabled:   true,
			Mode:      WebModeStatic,
			Runtime:   "static",
			StaticDir: "ui",
			BasePath:  "/apps/" + chosen.ID,
		},
	}
	raw, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		_ = os.RemoveAll(appDir)
		return PublicApp{}, err
	}
	if err := os.WriteFile(filepath.Join(appDir, "plugin.json"), raw, 0600); err != nil {
		_ = os.RemoveAll(appDir)
		return PublicApp{}, err
	}
	if err := os.WriteFile(filepath.Join(appDir, "icon.svg"), []byte(chosen.IconSVG), 0600); err != nil {
		_ = os.RemoveAll(appDir)
		return PublicApp{}, err
	}
	if err := os.WriteFile(filepath.Join(uiDir, "index.html"), []byte(chosen.IndexHTML), 0600); err != nil {
		_ = os.RemoveAll(appDir)
		return PublicApp{}, err
	}

	m.mutation.Lock()
	cfg, cfgErr := readSystemConfigFile(m.configPath)
	if cfgErr == nil && !slices.Contains(cfg.ActivatedApps, chosen.ID) {
		cfg.ActivatedApps = uniqueSortedStrings(append(cfg.ActivatedApps, chosen.ID))
		cfg.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
		_ = writeSystemConfigFile(m.configPath, cfg)
	}
	m.mutation.Unlock()

	if err := m.Reload(); err != nil {
		return PublicApp{}, err
	}
	return m.GetForUser(chosen.ID, 0, "admin")
}
