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
			Version:      "1.1.0",
			Category:     "family",
			Description:  "集中记录家庭宽带、影视会员、云服务与物业续费周期，全家共享同步并自动推送临近续费提醒。",
			AccessPolicy: AccessAllMembers,
			IconSVG:      templateSubscriptionsIconSVG,
			IndexHTML:    injectTemplateSharedAssets(templateSubscriptionsHTML),
		},
		{
			ID:           "warranty-vault",
			Name:         "电子发票与保修卡夹",
			Version:      "1.1.0",
			Category:     "family",
			Description:  "登记家电数码购买日期、保修到期日、序列号与票据存放位置，全家同步并自动推送 30 天过保预警。",
			AccessPolicy: AccessAllMembers,
			IconSVG:      templateWarrantyIconSVG,
			IndexHTML:    injectTemplateSharedAssets(templateWarrantyHTML),
		},
		{
			ID:           "family-board",
			Name:         "家庭留言板与采购清单",
			Version:      "1.1.0",
			Category:     "lifestyle",
			Description:  "温馨的家庭便签墙与周末超市采购打勾清单，支持全家共享同步与一键导出备份。",
			AccessPolicy: AccessAllMembers,
			IconSVG:      templateFamilyBoardIconSVG,
			IndexHTML:    injectTemplateSharedAssets(templateFamilyBoardHTML),
		},
		{
			ID:           "medicine-expiry",
			Name:         "家庭药箱与证件有效期",
			Version:      "1.1.0",
			Category:     "family",
			Description:  "登记家庭常备药、护照、身份证与驾照到期日，全家同步并在 30 天内自动高亮与推送临期提醒。",
			AccessPolicy: AccessAllMembers,
			IconSVG:      templateMedicineExpiryIconSVG,
			IndexHTML:    injectTemplateSharedAssets(templateMedicineExpiryHTML),
		},
		{
			ID:           "utility-ledger",
			Name:         "水电燃气与月度账本",
			Version:      "1.1.0",
			Category:     "family",
			Description:  "按月记录电费、水费、燃气与物业支出及用量，全家共享同步并自动生成近 6 个月消费柱状趋势图。",
			AccessPolicy: AccessAllMembers,
			IconSVG:      templateUtilityLedgerIconSVG,
			IndexHTML:    injectTemplateSharedAssets(templateUtilityLedgerHTML),
		},
		{
			ID:           "baby-growth",
			Name:         "宝宝成长身高体重记录",
			Version:      "1.1.0",
			Category:     "lifestyle",
			Description:  "记录宝宝每次体检的身高、体重与成长里程碑，全家共享同步并自动绘制身高成长曲线。",
			AccessPolicy: AccessAllMembers,
			IconSVG:      templateBabyGrowthIconSVG,
			IndexHTML:    injectTemplateSharedAssets(templateBabyGrowthHTML),
		},
		{
			ID:           "house-info",
			Name:         "家庭公共备忘卡",
			Version:      "1.0.0",
			Category:     "family",
			Description:  "集中保管家庭 Wi-Fi 密码、宽带光猫、水电燃气户号、车架号、开票抬头与物业紧急电话，支持分组筛选与一键复制。",
			AccessPolicy: AccessAllMembers,
			IconSVG:      templateHouseInfoIconSVG,
			IndexHTML:    injectTemplateSharedAssets(templateHouseInfoHTML),
		},
		{
			ID:           "weekly-menu",
			Name:         "每周菜单与冰箱囤货",
			Version:      "1.0.0",
			Category:     "lifestyle",
			Description:  "规划周一至周日三餐排期与冷藏/冷冻食材保质期高亮，一键提取缺料采购清单并自动推送临期预警。",
			AccessPolicy: AccessAllMembers,
			IconSVG:      templateWeeklyMenuIconSVG,
			IndexHTML:    injectTemplateSharedAssets(templateWeeklyMenuHTML),
		},
		{
			ID:           "pet-care",
			Name:         "宠物健康与疫苗驱虫",
			Version:      "1.0.0",
			Category:     "lifestyle",
			Description:  "多宠物档案管理、原生 SVG 体重趋势曲线，疫苗与体内外驱虫下次到期自动推算并接入家庭推送提醒。",
			AccessPolicy: AccessAllMembers,
			IconSVG:      templatePetCareIconSVG,
			IndexHTML:    injectTemplateSharedAssets(templatePetCareHTML),
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

// InstallTemplateAt installs an audited built-in static template into the specified
// storage location ("internal", "external", or "" for default).
func (m *Manager) InstallTemplateAt(templateID, locationID string) (PublicApp, error) {
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
	if m.appIDExistsAnywhere(chosen.ID) {
		return PublicApp{}, ErrAlreadyInstalled
	}

	target, err := m.ResolveInstallTarget(locationID)
	if err != nil {
		return PublicApp{}, err
	}

	appDir := filepath.Join(target.pluginsDir, chosen.ID)
	if _, err := os.Lstat(appDir); err == nil {
		return PublicApp{}, ErrAlreadyInstalled
	}
	uiDir := filepath.Join(appDir, "ui")
	if err := os.MkdirAll(uiDir, 0700); err != nil {
		return PublicApp{}, err
	}
	_ = os.MkdirAll(filepath.Join(target.dataRoot, chosen.ID), 0700)
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
