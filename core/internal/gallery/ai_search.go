package gallery

import (
	"database/sql"
	"errors"
	"strconv"
	"strings"
	"unicode"

	"github.com/lengsukq/lightisle/core/internal/mediascope"
)

type AssetFaceRef struct {
	FaceID     int64   `json:"faceId"`
	PersonID   int64   `json:"personId,omitempty"`
	PersonName string  `json:"personName,omitempty"`
	BoxX       float32 `json:"boxX"`
	BoxY       float32 `json:"boxY"`
	BoxW       float32 `json:"boxW"`
	BoxH       float32 `json:"boxH"`
}

type AssetAIDetail struct {
	AssetID     int64          `json:"assetId"`
	Indexed     bool           `json:"indexed"`
	Status      string         `json:"status"`
	OCRText     string         `json:"ocrText,omitempty"`
	SceneLabels []string       `json:"sceneLabels,omitempty"`
	Faces       []AssetFaceRef `json:"faces,omitempty"`
}

type sceneConcept struct {
	displayZH string
	labels    []string
	keywords  []string
}

var coreSceneConcepts = []sceneConcept{
	{displayZH: "日落晚霞", labels: []string{"sunset_sunrise"}, keywords: []string{"日落", "夕阳", "晚霞", "日出", "朝霞", "黄昏", "sunset", "sunrise", "dusk"}},
	{displayZH: "海边沙滩", labels: []string{"beach", "ocean"}, keywords: []string{"海边", "海滩", "沙滩", "大海", "海洋", "海岸", "海岛", "海", "beach", "ocean", "seaside", "coast"}},
	{displayZH: "山川风景", labels: []string{"mountain", "waterfall"}, keywords: []string{"雪山", "山脉", "大山", "登山", "爬山", "瀑布", "山", "mountain", "waterfall"}},
	{displayZH: "湖泊水景", labels: []string{"lake", "river", "water"}, keywords: []string{"湖边", "湖泊", "江边", "河流", "溪流", "湖", "河", "lake", "river"}},
	{displayZH: "森林绿植", labels: []string{"forest", "tree", "grass"}, keywords: []string{"森林", "树林", "草地", "草坪", "郊游", "露营", "树", "林", "草", "forest", "grass", "lawn"}},
	{displayZH: "鲜花花朵", labels: []string{"flower"}, keywords: []string{"鲜花", "花朵", "赏花", "花海", "花", "flower", "blossom"}},
	{displayZH: "冰雪冬景", labels: []string{"snow"}, keywords: []string{"雪景", "下雪", "积雪", "滑雪", "雪", "snow", "winter"}},
	{displayZH: "夜景星空", labels: []string{"night", "night_sky"}, keywords: []string{"夜景", "夜空", "星空", "夜晚", "烟花", "night", "star"}},
	{displayZH: "蓝天白云", labels: []string{"sky", "cloud"}, keywords: []string{"蓝天", "白云", "晴空", "云海", "天空", "云", "sky", "cloud"}},
	{displayZH: "猫咪", labels: []string{"cat", "adult_cat"}, keywords: []string{"小猫", "猫咪", "喵星人", "猫", "cat", "kitten"}},
	{displayZH: "狗狗", labels: []string{"dog"}, keywords: []string{"小狗", "狗狗", "汪星人", "狗", "dog", "puppy"}},
	{displayZH: "宠物动物", labels: []string{"animal", "bird", "fish"}, keywords: []string{"宠物", "动物", "小鸟", "鸟", "鱼", "pet", "animal", "bird"}},
	{displayZH: "宝宝儿童", labels: []string{"baby", "child"}, keywords: []string{"宝宝", "婴儿", "小朋友", "儿童", "小孩", "孩子", "baby", "child", "kid"}},
	{displayZH: "人像合影", labels: []string{"portrait", "people", "person"}, keywords: []string{"人像", "合影", "自拍", "写真", "portrait", "selfie"}},
	{displayZH: "婚礼聚会", labels: []string{"wedding", "party", "cake"}, keywords: []string{"婚礼", "婚纱", "聚会", "派对", "生日", "蛋糕", "wedding", "party", "birthday", "cake"}},
	{displayZH: "美食餐饮", labels: []string{"food", "seafood", "dessert", "fruit", "drink", "coffee"}, keywords: []string{"美食", "海鲜", "食物", "聚餐", "甜点", "甜品", "水果", "咖啡", "奶茶", "饮料", "food", "seafood", "dessert", "coffee", "drink"}},
	{displayZH: "汽车出行", labels: []string{"car", "bicycle", "train", "airplane", "boat"}, keywords: []string{"汽车", "轿车", "自驾", "单车", "自行车", "高铁", "火车", "飞机", "游船", "车", "船", "car", "vehicle", "bike", "train", "airplane", "boat"}},
	{displayZH: "城市建筑", labels: []string{"building", "bridge", "street"}, keywords: []string{"建筑", "大楼", "大桥", "桥梁", "街景", "街道", "城市", "building", "bridge", "street", "city"}},
	{displayZH: "发票票据", labels: []string{"receipt"}, keywords: []string{"发票", "收据", "小票", "账单", "报销", "票", "receipt", "invoice", "bill"}},
	{displayZH: "文档合同", labels: []string{"document", "printed_page", "text"}, keywords: []string{"合同", "文档", "证件", "资料", "扫描件", "笔记", "document", "contract"}},
	{displayZH: "手机截图", labels: []string{"screenshot", "qr_code"}, keywords: []string{"屏幕截图", "手机截图", "截图", "二维码", "收款码", "screenshot", "qrcode"}},
}

func builtinSceneAliases(label string) []string {
	norm := strings.ToLower(strings.TrimSpace(label))
	for _, c := range coreSceneConcepts {
		for _, l := range c.labels {
			if l == norm {
				return c.keywords
			}
		}
	}
	return nil
}

func sceneDisplayLabel(label string) string {
	norm := strings.ToLower(strings.TrimSpace(label))
	for _, c := range coreSceneConcepts {
		for _, l := range c.labels {
			if l == norm {
				return c.displayZH
			}
		}
	}
	return strings.ReplaceAll(norm, "_", " ")
}

func normalizeSearchToken(raw string) string {
	trimmed := strings.ToLower(strings.TrimSpace(raw))
	trimmed = strings.TrimFunc(trimmed, func(r rune) bool {
		return unicode.IsSpace(r) || unicode.IsPunct(r) || unicode.IsSymbol(r)
	})
	if len(trimmed) == 0 || len(trimmed) > 64 {
		return ""
	}
	return trimmed
}

func validSearchMode(mode string) bool {
	switch mode {
	case "", "all", "ocr", "scene", "person", "path":
		return true
	default:
		return false
	}
}

func appendPhotoFilterSQL(userID int64, filter PhotoFilter, query *string, args *[]any) error {
	if !validSearchMode(filter.SearchMode) {
		return errors.New("invalid_filter")
	}
	if filter.Kind == "live" {
		*query += " AND a.live_video_asset_id>0"
	} else if filter.Kind != "" {
		*query += " AND a.type=?"
		*args = append(*args, filter.Kind)
	}
	if filter.PersonID > 0 {
		if userID <= 0 {
			return sql.ErrNoRows
		}
		*query += ` AND EXISTS(
			SELECT 1 FROM asset_faces af
			JOIN person_face_links pfl ON pfl.face_id=af.id AND pfl.user_id=?
			JOIN persons p ON p.id=pfl.person_id AND p.share=a.share AND p.user_id=?
			WHERE af.asset_id=a.id AND p.id=?)`
		*args = append(*args, userID, userID, filter.PersonID)
	}
	if term := strings.TrimSpace(filter.Query); term != "" {
		clause, clauseArgs := buildSmartQuerySQL(userID, term, filter.SearchMode)
		*query += " AND " + clause
		*args = append(*args, clauseArgs...)
	}
	if filter.OnThisDay {
		*query += " AND a.taken_at>0 AND strftime('%m-%d',a.taken_at,'unixepoch','localtime')=strftime('%m-%d','now','localtime')"
	}
	if filter.Camera != "" {
		*query += " AND (a.camera_model=? OR trim(a.camera_make||' '||a.camera_model)=?)"
		*args = append(*args, filter.Camera, filter.Camera)
	}
	if filter.HasLocation != nil {
		if *filter.HasLocation {
			*query += " AND a.gps_lat IS NOT NULL AND a.gps_lon IS NOT NULL"
		} else {
			*query += " AND (a.gps_lat IS NULL OR a.gps_lon IS NULL)"
		}
	}
	if filter.TakenFrom > 0 {
		*query += " AND a.taken_at>=?"
		*args = append(*args, filter.TakenFrom)
	}
	if filter.TakenTo > 0 {
		*query += " AND a.taken_at<=?"
		*args = append(*args, filter.TakenTo)
	}
	if len(filter.IDs) > 0 {
		placeholders := make([]string, len(filter.IDs))
		for i, id := range filter.IDs {
			placeholders[i] = "?"
			*args = append(*args, id)
		}
		*query += " AND a.id IN (" + strings.Join(placeholders, ",") + ")"
	}
	return nil
}

const maxSmartSearchTokens = 6

func splitSmartQueryTokens(rawTerm string) []string {
	fields := strings.Fields(strings.TrimSpace(rawTerm))
	if len(fields) == 0 {
		return nil
	}
	dedup := make([]string, 0, len(fields))
	seen := make(map[string]struct{}, len(fields))
	for _, f := range fields {
		key := strings.ToLower(f)
		if _, exists := seen[key]; exists {
			continue
		}
		seen[key] = struct{}{}
		dedup = append(dedup, f)
	}
	if len(dedup) > maxSmartSearchTokens {
		tail := strings.Join(dedup[maxSmartSearchTokens-1:], " ")
		dedup = append(dedup[:maxSmartSearchTokens-1], tail)
	}
	return dedup
}

func buildSmartQuerySQL(userID int64, rawTerm, mode string) (string, []any) {
	tokens := splitSmartQueryTokens(rawTerm)
	if len(tokens) == 0 {
		return "1=1", nil
	}
	if len(tokens) == 1 {
		return buildSingleTokenSmartSQL(userID, tokens[0], mode)
	}
	clauses := make([]string, 0, len(tokens))
	var allArgs []any
	for _, tok := range tokens {
		clause, args := buildSingleTokenSmartSQL(userID, tok, mode)
		clauses = append(clauses, "("+clause+")")
		allArgs = append(allArgs, args...)
	}
	return "(" + strings.Join(clauses, " AND ") + ")", allArgs
}

func buildSingleTokenSmartSQL(userID int64, rawTerm, mode string) (string, []any) {
	pat := likePattern(rawTerm)
	norm := normalizeSearchToken(rawTerm)

	pathSQL := "a.path LIKE ? ESCAPE '\\'"
	pathArgs := []any{pat}

	ocrSQL, ocrArgs := buildOCRQuerySQL(rawTerm, norm)
	sceneSQL, sceneArgs := buildSceneQuerySQL(rawTerm, norm)

	personSQL := "0=1"
	var personArgs []any
	if userID > 0 {
		personSQL = `EXISTS(
			SELECT 1 FROM asset_faces af
			JOIN person_face_links pfl ON pfl.face_id=af.id AND pfl.user_id=?
			JOIN persons p ON p.id=pfl.person_id AND p.share=a.share AND p.user_id=?
			WHERE af.asset_id=a.id AND p.name<>'' AND p.name LIKE ? ESCAPE '\')`
		personArgs = []any{userID, userID, pat}
	}

	switch mode {
	case "path":
		return pathSQL, pathArgs
	case "ocr":
		return ocrSQL, ocrArgs
	case "scene":
		return sceneSQL, sceneArgs
	case "person":
		return personSQL, personArgs
	default:
		parts := []string{
			"(" + pathSQL + ")",
			"(a.camera_make LIKE ? ESCAPE '\\' OR a.camera_model LIKE ? ESCAPE '\\')",
			`EXISTS(SELECT 1 FROM album_items ai JOIN albums al ON al.id=ai.album_id AND al.share=a.share WHERE ai.asset_id=a.id AND al.name LIKE ? ESCAPE '\')`,
		}
		args := []any{pat, pat, pat, pat}
		if userID > 0 {
			parts = append(parts, `EXISTS(SELECT 1 FROM private_album_items pai JOIN private_albums pa ON pa.id=pai.album_id WHERE pai.asset_id=a.id AND pa.user_id=? AND pa.share=a.share AND pa.name LIKE ? ESCAPE '\')`)
			args = append(args, userID, pat)
		}
		if extraSQL, extraArgs := buildTemporalOrKindTokenSQL(rawTerm); extraSQL != "" {
			parts = append(parts, "("+extraSQL+")")
			args = append(args, extraArgs...)
		}
		parts = append(parts, "("+ocrSQL+")")
		args = append(args, ocrArgs...)
		if sceneSQL != "0=1" {
			parts = append(parts, "("+sceneSQL+")")
			args = append(args, sceneArgs...)
		}
		if userID > 0 {
			parts = append(parts, "("+personSQL+")")
			args = append(args, personArgs...)
		}
		return "(" + strings.Join(parts, " OR ") + ")", args
	}
}

func buildTemporalOrKindTokenSQL(rawToken string) (string, []any) {
	lower := strings.ToLower(strings.TrimSpace(rawToken))
	switch lower {
	case "视频", "录像", "video":
		return "a.type='video'", nil
	case "实况", "实况照片", "live", "livephoto":
		return "a.live_video_asset_id>0", nil
	case "照片", "图片", "photo":
		return "a.type='photo'", nil
	}
	yearCandidate := strings.TrimSuffix(lower, "年")
	if len(yearCandidate) == 4 {
		if year, err := strconv.Atoi(yearCandidate); err == nil && year >= 1970 && year <= 2099 {
			return "a.taken_at>0 AND strftime('%Y',a.taken_at,'unixepoch','localtime')=?", []any{yearCandidate}
		}
	}
	if strings.HasSuffix(lower, "月") {
		monthCandidate := strings.TrimSuffix(lower, "月")
		if month, err := strconv.Atoi(monthCandidate); err == nil && month >= 1 && month <= 12 {
			return "a.taken_at>0 AND CAST(strftime('%m',a.taken_at,'unixepoch','localtime') AS INTEGER)=?", []any{month}
		}
	}
	return "", nil
}

func buildOCRQuerySQL(rawTerm, norm string) (string, []any) {
	trimmed := strings.TrimSpace(rawTerm)
	words := strings.Fields(strings.ToLower(trimmed))
	queryTokens := extractOCRQueryTokens(trimmed)
	if len(words) <= 1 {
		if len(queryTokens) > 0 {
			clauses := make([]string, 0, len(queryTokens)+1)
			args := make([]any, 0, len(queryTokens)+2)
			for _, qt := range queryTokens {
				clauses = append(clauses, `EXISTS(SELECT 1 FROM asset_search_tokens t WHERE t.token=? AND t.source='ocr' AND t.asset_id=a.id)`)
				args = append(args, qt)
			}
			clauses = append(clauses, `EXISTS(SELECT 1 FROM asset_ocr ao WHERE ao.asset_id=a.id AND ao.raw_text LIKE ? ESCAPE '\')`)
			args = append(args, likePattern(trimmed))
			if norm != "" {
				return `(EXISTS(SELECT 1 FROM asset_search_tokens t0 WHERE t0.token=? AND t0.source='ocr' AND t0.asset_id=a.id) OR (` + strings.Join(clauses, " AND ") + `))`,
					append([]any{norm}, args...)
			}
			return "(" + strings.Join(clauses, " AND ") + ")", args
		}
		if norm != "" {
			return `(EXISTS(SELECT 1 FROM asset_search_tokens t WHERE t.token=? AND t.source='ocr' AND t.asset_id=a.id)
				OR EXISTS(SELECT 1 FROM asset_ocr ao WHERE ao.asset_id=a.id AND ao.raw_text LIKE ? ESCAPE '\'))`,
				[]any{norm, likePattern(trimmed)}
		}
		return `EXISTS(SELECT 1 FROM asset_ocr ao WHERE ao.asset_id=a.id AND ao.raw_text LIKE ? ESCAPE '\')`,
			[]any{likePattern(trimmed)}
	}
	clauses := make([]string, 0, len(queryTokens)+len(words))
	args := make([]any, 0, len(queryTokens)+len(words))
	for _, qt := range queryTokens {
		clauses = append(clauses, `EXISTS(SELECT 1 FROM asset_search_tokens t WHERE t.token=? AND t.source='ocr' AND t.asset_id=a.id)`)
		args = append(args, qt)
	}
	for _, w := range words {
		clauses = append(clauses, `EXISTS(SELECT 1 FROM asset_ocr ao WHERE ao.asset_id=a.id AND ao.raw_text LIKE ? ESCAPE '\')`)
		args = append(args, likePattern(w))
	}
	return "(" + strings.Join(clauses, " AND ") + ")", args
}

func buildSceneQuerySQL(rawTerm, norm string) (string, []any) {
	lower := strings.ToLower(strings.TrimSpace(rawTerm))
	var matchedGroups [][]string
	// Exact keyword match first so single-character keywords (e.g. "花", "海", "车")
	// never hijack compound words (e.g. "烟花", "海鲜", "风车").
	for _, concept := range coreSceneConcepts {
		for _, kw := range concept.keywords {
			if lower == kw {
				tokens := append([]string{}, concept.labels...)
				tokens = append(tokens, concept.keywords...)
				matchedGroups = append(matchedGroups, tokens)
				break
			}
		}
	}
	if len(matchedGroups) == 0 {
		for _, concept := range coreSceneConcepts {
			for _, kw := range concept.keywords {
				if len([]rune(kw)) >= 2 && strings.Contains(lower, kw) {
					tokens := append([]string{}, concept.labels...)
					tokens = append(tokens, concept.keywords...)
					matchedGroups = append(matchedGroups, tokens)
					break
				}
			}
		}
	}
	if len(matchedGroups) > 0 {
		groupClauses := make([]string, 0, len(matchedGroups))
		var args []any
		for _, group := range matchedGroups {
			seen := map[string]bool{}
			var placeholders []string
			for _, tok := range group {
				t := normalizeSearchToken(tok)
				if t == "" || seen[t] {
					continue
				}
				seen[t] = true
				placeholders = append(placeholders, "?")
				args = append(args, t)
			}
			groupClauses = append(groupClauses,
				`EXISTS(SELECT 1 FROM asset_search_tokens st WHERE st.asset_id=a.id AND st.source='scene' AND st.token IN (`+strings.Join(placeholders, ",")+`))`)
		}
		return "(" + strings.Join(groupClauses, " AND ") + ")", args
	}
	if norm == "" {
		return "0=1", nil
	}
	return `EXISTS(SELECT 1 FROM asset_search_tokens st WHERE st.asset_id=a.id AND st.source='scene' AND (st.token=? OR st.token LIKE ? ESCAPE '\'))`,
		[]any{norm, likePattern(norm)}
}

func (l *Library) AssetAIDetailScoped(userID, assetID int64, roots []string) (AssetAIDetail, error) {
	share, err := l.share()
	if err != nil {
		return AssetAIDetail{}, err
	}
	fragment, scopedArgs, err := mediascope.Clause("a.path", roots)
	if err != nil {
		return AssetAIDetail{}, err
	}
	checkArgs := append([]any{share, assetID}, scopedArgs...)
	rdb := l.readDB()
	var exists int
	if err := rdb.QueryRow(`SELECT 1 FROM assets a WHERE a.share=? AND a.id=? AND a.missing_path=''`+fragment, checkArgs...).Scan(&exists); err != nil {
		return AssetAIDetail{}, err
	}

	detail := AssetAIDetail{AssetID: assetID, Status: "pending"}
	var status string
	if err := rdb.QueryRow(`SELECT status FROM ai_index_state WHERE asset_id=?`, assetID).Scan(&status); err == nil {
		detail.Indexed = status == "ok" || status == "unsupported"
		detail.Status = status
	}
	var ocrText string
	if err := rdb.QueryRow(`SELECT raw_text FROM asset_ocr WHERE asset_id=?`, assetID).Scan(&ocrText); err == nil {
		detail.OCRText = ocrText
	}

	tagRows, err := rdb.Query(`SELECT label FROM asset_scene_tags WHERE asset_id=? ORDER BY confidence DESC LIMIT 8`, assetID)
	if err == nil {
		seenDisplay := map[string]bool{}
		for tagRows.Next() {
			var label string
			if tagRows.Scan(&label) == nil {
				disp := sceneDisplayLabel(label)
				if disp != "" && !seenDisplay[disp] {
					seenDisplay[disp] = true
					detail.SceneLabels = append(detail.SceneLabels, disp)
				}
			}
		}
		tagRows.Close()
	}

	faceRows, err := rdb.Query(`
		SELECT af.id, COALESCE(p.id, 0), COALESCE(p.name, ''), af.box_x, af.box_y, af.box_w, af.box_h
		FROM asset_faces af
		LEFT JOIN person_face_links pfl ON pfl.face_id=af.id AND pfl.user_id=?
		LEFT JOIN persons p ON p.id=pfl.person_id AND p.share=? AND p.user_id=?
		WHERE af.asset_id=?
		ORDER BY (af.box_w * af.box_h) DESC`,
		userID, share, userID, assetID)
	if err == nil {
		for faceRows.Next() {
			var f AssetFaceRef
			if faceRows.Scan(&f.FaceID, &f.PersonID, &f.PersonName, &f.BoxX, &f.BoxY, &f.BoxW, &f.BoxH) == nil {
				detail.Faces = append(detail.Faces, f)
			}
		}
		faceRows.Close()
	}
	return detail, nil
}
