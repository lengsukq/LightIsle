package cinema

import (
	"path"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"unicode"
)

var (
	episodePattern       = regexp.MustCompile(`(?i)(?:^|[\s._\-\[\(【（])s([0-9]{1,2})[\s._\-]*(?:ep|e)([0-9]{1,4})(?:[\s._\-\]\)】）]|$)`)
	altEpisodePattern    = regexp.MustCompile(`(?i)(?:^|[\s._\-\[\(【（])([0-9]{1,2})x([0-9]{1,3})(?:[\s._\-\]\)】）]|$)`)
	cnEpisodePattern     = regexp.MustCompile(`(?:第\s*([0-9]{1,2}|[一二三四五六七八九十]{1,3})\s*季[\s._\-]*)?第\s*([0-9]{1,4}|[一二三四五六七八九十百零]{1,5})\s*[集话話期]`)
	epOnlyPattern        = regexp.MustCompile(`(?i)(?:^|[\s._\-\[\(【（])(?:ep|e)([0-9]{1,4})(?:[\s._\-\]\)】）]|$)`)
	bracketEpPattern     = regexp.MustCompile(`\[([0-9]{1,3})\](?:\s*\[[^\]]*\])*$`)
	yearPattern          = regexp.MustCompile(`(?:^|[\s._\-\(\[（【])((?:19|20)[0-9]{2})(?:[\s._\-\)\]）】]|$)`)
	trailingCnSeason     = regexp.MustCompile(`[\s._\-]*第\s*([0-9]{1,2}|[一二三四五六七八九十]{1,3})\s*季$`)
	trailingEnSeason     = regexp.MustCompile(`(?i)(?:^|[\s._\-])(?:season[\s._\-]*|s)([0-9]{1,2})$`)
	folderSeasonPattern  = regexp.MustCompile(`(?i)^(?:season[\s._\-]*([0-9]{1,2})|s([0-9]{1,2})|第\s*([0-9]{1,2}|[一二三四五六七八九十]{1,3})\s*季)$`)
	pureEpisodeStemRegex = regexp.MustCompile(`^[0-9]{1,3}$`)
	tokenSplitter        = regexp.MustCompile(`[\s._\[\]\(\)【】（）：:]+`)
	extraSeparators      = regexp.MustCompile(`[._]+`)
	videoExtRegex        = regexp.MustCompile(`(?i)^\.[a-z][a-z0-9]{1,4}$`)
)

// Identify parses a single filename into display title, media kind ("movie" or
// "series"), series name, season/episode numbers and release year.
func Identify(filename string) (title, kind, series string, season, episode, year int) {
	base := trimVideoExt(path.Base(strings.ReplaceAll(filename, "\\", "/")))
	cleaned := stripLeadingDistributorBrackets(strings.TrimSpace(base))
	if cleaned == "" {
		cleaned = base
	}
	kind = "movie"
	titlePart := cleaned

	if s, ep, prefix, ok := matchEpisode(cleaned); ok {
		kind = "series"
		season, episode = s, ep
		titlePart = prefix
		if trailingSeason, trimmed, ok := stripTrailingSeason(titlePart); ok {
			if season <= 1 {
				season = trailingSeason
			}
			if strings.TrimSpace(trimmed) != "" {
				titlePart = trimmed
			}
		}
		if season <= 0 {
			season = 1
		}
	}

	if y, cutIdx, ok := findReleaseYear(titlePart); ok {
		year = y
		titlePart = titlePart[:cutIdx]
	} else if kind == "series" {
		if y, _, ok := findReleaseYear(cleaned); ok {
			year = y
		}
	}

	title = cleanTitleTokens(titlePart)
	if title == "" {
		title = strings.TrimSpace(extraSeparators.ReplaceAllString(titlePart, " "))
	}
	if title == "" {
		title = strings.TrimSpace(extraSeparators.ReplaceAllString(cleaned, " "))
	}
	if title == "" {
		title = base
	}
	if kind == "series" {
		series = title
	}
	return
}

// IdentifyPath enriches Identify(filename) with parent directory context when
// a video is stored inside a named movie or series/season folder.
func IdentifyPath(relPath string) (title, kind, series string, season, episode, year int) {
	normalized := strings.Trim(strings.ReplaceAll(relPath, "\\", "/"), "/")
	fileName := path.Base(normalized)
	title, kind, series, season, episode, year = Identify(fileName)
	parents := meaningfulParentDirs(normalized)
	if len(parents) == 0 {
		return
	}

	stem := strings.TrimSpace(trimVideoExt(fileName))
	immediateParent := parents[0]

	// Case 1: Pure episode number inside an explicit Season folder (e.g. "庆余年/Season 2/05.mp4").
	if kind == "movie" && pureEpisodeStemRegex.MatchString(stem) {
		if folderSeason, ok := parseSeasonFolder(immediateParent); ok && len(parents) >= 2 {
			if epNum, err := strconv.Atoi(stem); err == nil && epNum > 0 && epNum <= 300 {
				pTitle, _, pSeries, _, _, pYear := Identify(parents[1])
				seriesName := pSeries
				if seriesName == "" {
					seriesName = pTitle
				}
				if seriesName != "" && !isGenericFilmStem(seriesName) {
					kind = "series"
					season = folderSeason
					episode = epNum
					series = seriesName
					title = seriesName
					if year == 0 && pYear > 0 {
						year = pYear
					}
					return
				}
			}
		}
	}

	// Case 2: Episode file inside a Season or Series folder (e.g. "庆余年/S01E02.mp4" or "庆余年/第2季/EP05.mp4").
	if kind == "series" {
		seriesFolder := immediateParent
		if folderSeason, ok := parseSeasonFolder(immediateParent); ok {
			if season <= 1 && folderSeason > 0 {
				season = folderSeason
			}
			if len(parents) >= 2 {
				seriesFolder = parents[1]
			} else {
				seriesFolder = ""
			}
		}
		if seriesFolder != "" {
			pTitle, _, pSeries, pSeason, _, pYear := Identify(seriesFolder)
			candidateSeries := pSeries
			if candidateSeries == "" {
				candidateSeries = pTitle
			}
			if season <= 1 && pSeason > 1 {
				season = pSeason
			}
			if year == 0 && pYear > 0 {
				year = pYear
			}
			if isEpisodeOrGenericStem(series) && candidateSeries != "" && !isGenericFilmStem(candidateSeries) {
				series = candidateSeries
				title = candidateSeries
			}
		}
		return
	}

	// Case 3: Movie file with a generic stem inside a named movie folder (e.g. "流浪地球2 (2023)/1080p.mp4").
	pTitle, pKind, pSeries, pSeason, pEp, pYear := Identify(immediateParent)
	if isGenericFilmStem(title) && pTitle != "" && !isGenericFilmStem(pTitle) {
		title = pTitle
		if pKind == "series" && episode == 0 {
			kind = pKind
			series = pSeries
			season = pSeason
			episode = pEp
		}
		if year == 0 && pYear > 0 {
			year = pYear
		}
		return
	}

	// Case 4: Movie filename has the title, and the parent folder carries the release year.
	if year == 0 && pYear > 0 {
		normTitle := normalizeTitle(title)
		normParent := normalizeTitle(pTitle)
		if normTitle != "" && (normTitle == normParent || strings.Contains(normParent, normTitle) || strings.Contains(normTitle, normParent)) {
			year = pYear
		}
	}
	return
}

func trimVideoExt(name string) string {
	ext := filepath.Ext(name)
	if ext == "" || !videoExtRegex.MatchString(ext) {
		return name
	}
	if isFilm(name) {
		return strings.TrimSuffix(name, ext)
	}
	switch strings.ToLower(ext) {
	case ".wmv", ".m2ts", ".mpg", ".mpeg", ".flv", ".rmvb":
		return strings.TrimSuffix(name, ext)
	}
	token := strings.ToLower(strings.TrimPrefix(ext, "."))
	if isTechOrReleaseToken(token) || episodePattern.MatchString(ext) || epOnlyPattern.MatchString(ext) {
		return name
	}
	return strings.TrimSuffix(name, ext)
}

func cleanCinemaDirectory(dir string) (string, error) {
	if dir == "" || len(dir) > 1024 || strings.HasPrefix(dir, "/") || strings.ContainsAny(dir, "\\\x00\r\n") {
		return "", ErrInvalid
	}
	cleaned := path.Clean(dir)
	if cleaned != dir || cleaned == ".." || strings.HasPrefix(cleaned, "../") {
		return "", ErrInvalid
	}
	return cleaned, nil
}

func stripLeadingDistributorBrackets(s string) string {
	for {
		s = strings.TrimLeft(s, " \t._-")
		var closeSep string
		if strings.HasPrefix(s, "[") {
			closeSep = "]"
		} else if strings.HasPrefix(s, "【") {
			closeSep = "】"
		} else {
			return s
		}
		idx := strings.Index(s, closeSep)
		if idx <= 0 {
			return s
		}
		inside := s[len(closeSep) : idx]
		if closeSep == "]" {
			inside = s[1:idx]
		} else {
			inside = s[len("【"):idx]
		}
		rest := strings.TrimLeft(s[idx+len(closeSep):], " \t._-")
		if rest == "" {
			return s
		}
		if isDistributorBracket(inside) || (!strings.HasPrefix(rest, "[") && !strings.HasPrefix(rest, "【")) {
			s = rest
			continue
		}
		return s
	}
}

func isDistributorBracket(text string) bool {
	lower := strings.ToLower(strings.TrimSpace(text))
	for _, kw := range []string{
		"www.", ".com", ".net", ".org", ".cc", ".tv", ".me", ".cn", ".vip",
		"电影", "影院", "影视", "天堂", "之家", "首发", "字幕", "压制", "出品",
		"资源", "论坛", "高清", "蓝光", "国漫", "新番", "动漫", "剧集",
		"team", "sub", "group", "raws", "rip", "studio", "hd", "bd",
	} {
		if strings.Contains(lower, kw) {
			return true
		}
	}
	return false
}

func matchEpisode(s string) (season, episode int, prefix string, ok bool) {
	if loc := episodePattern.FindStringSubmatchIndex(s); loc != nil {
		season, _ = strconv.Atoi(s[loc[2]:loc[3]])
		episode, _ = strconv.Atoi(s[loc[4]:loc[5]])
		return season, episode, s[:loc[0]], true
	}
	if loc := altEpisodePattern.FindStringSubmatchIndex(s); loc != nil {
		season, _ = strconv.Atoi(s[loc[2]:loc[3]])
		episode, _ = strconv.Atoi(s[loc[4]:loc[5]])
		return season, episode, s[:loc[0]], true
	}
	if loc := cnEpisodePattern.FindStringSubmatchIndex(s); loc != nil {
		season = 1
		if loc[2] >= 0 && loc[3] > loc[2] {
			if parsed := parseChineseOrArabicNumber(s[loc[2]:loc[3]]); parsed > 0 {
				season = parsed
			}
		}
		episode = parseChineseOrArabicNumber(s[loc[4]:loc[5]])
		if episode > 0 {
			return season, episode, s[:loc[0]], true
		}
	}
	if loc := epOnlyPattern.FindStringSubmatchIndex(s); loc != nil {
		episode, _ = strconv.Atoi(s[loc[2]:loc[3]])
		if episode > 0 {
			return 1, episode, s[:loc[0]], true
		}
	}
	if loc := bracketEpPattern.FindStringSubmatchIndex(s); loc != nil && loc[0] > 0 {
		ep, _ := strconv.Atoi(s[loc[2]:loc[3]])
		if ep > 0 && ep < 1900 {
			return 1, ep, s[:loc[0]], true
		}
	}
	return 0, 0, "", false
}

func stripTrailingSeason(s string) (season int, trimmed string, ok bool) {
	if loc := trailingCnSeason.FindStringSubmatchIndex(s); loc != nil {
		if parsed := parseChineseOrArabicNumber(s[loc[2]:loc[3]]); parsed > 0 {
			return parsed, s[:loc[0]], true
		}
	}
	if loc := trailingEnSeason.FindStringSubmatchIndex(s); loc != nil && loc[0] > 0 {
		if parsed, err := strconv.Atoi(s[loc[2]:loc[3]]); err == nil && parsed > 0 {
			return parsed, s[:loc[0]], true
		}
	}
	return 0, s, false
}

func parseSeasonFolder(name string) (int, bool) {
	cleaned := strings.TrimSpace(name)
	m := folderSeasonPattern.FindStringSubmatch(cleaned)
	if m == nil {
		return 0, false
	}
	for _, group := range m[1:] {
		if group != "" {
			if n := parseChineseOrArabicNumber(group); n > 0 {
				return n, true
			}
		}
	}
	return 0, false
}

func findReleaseYear(s string) (year int, cutIdx int, ok bool) {
	offset := 0
	for offset < len(s) {
		loc := yearPattern.FindStringSubmatchIndex(s[offset:])
		if loc == nil {
			break
		}
		matchStart := offset + loc[0]
		digitStart := offset + loc[2]
		digitEnd := offset + loc[3]
		if matchStart == 0 {
			// A year at index 0 is part of the title itself (e.g. "1917.2019.1080p" or "2046.2004").
			offset = digitEnd
			continue
		}
		prefix := strings.Trim(s[:matchStart], " \t._-([【（")
		if prefix == "" {
			offset = digitEnd
			continue
		}
		y, err := strconv.Atoi(s[digitStart:digitEnd])
		if err == nil && y >= 1900 && y <= 2099 {
			return y, matchStart, true
		}
		offset = digitEnd
	}
	return 0, 0, false
}

func cleanTitleTokens(raw string) string {
	tokens := tokenSplitter.Split(strings.TrimSpace(raw), -1)
	kept := make([]string, 0, len(tokens))
	for _, tok := range tokens {
		tok = strings.Trim(tok, "-_")
		if tok == "" {
			continue
		}
		if len(kept) > 0 && isTechOrReleaseToken(tok) {
			break
		}
		kept = append(kept, tok)
	}
	return strings.TrimSpace(strings.Join(kept, " "))
}

var techTokens = map[string]struct{}{
	"480p": {}, "540p": {}, "576p": {}, "720p": {}, "1080p": {}, "1080i": {}, "2160p": {}, "4320p": {},
	"4k": {}, "8k": {}, "uhd": {}, "fhd": {}, "hd1080p": {}, "hd720p": {}, "bd1080p": {}, "bd720p": {},
	"bluray": {}, "blu-ray": {}, "bdrip": {}, "brrip": {}, "remux": {}, "web-dl": {}, "webdl": {},
	"webrip": {}, "hdtv": {}, "hdrip": {}, "dvdrip": {}, "dvdr": {}, "hdcam": {}, "cam": {},
	"x264": {}, "x265": {}, "h264": {}, "h265": {}, "hevc": {}, "avc": {}, "av1": {}, "xvid": {}, "divx": {},
	"10bit": {}, "8bit": {}, "hdr": {}, "hdr10": {}, "hdr10+": {}, "dv": {}, "dolbyvision": {}, "sdr": {},
	"60fps": {}, "120fps": {}, "hq": {}, "aac": {}, "ac3": {}, "eac3": {}, "ddp": {}, "dts": {},
	"dts-hd": {}, "dtshd": {}, "truehd": {}, "atmos": {}, "flac": {}, "mp3": {}, "lpcm": {},
	"bd": {}, "hd": {}, "chs": {}, "cht": {}, "gb": {}, "big5": {}, "mp4": {}, "mkv": {},
	"国语中字": {}, "国语": {}, "粤语": {}, "国粤双语": {}, "中英双字": {}, "中英字幕": {}, "中文字幕": {},
	"简繁中字": {}, "简体中字": {}, "繁体中字": {}, "中字": {}, "双语字幕": {}, "双字": {}, "特效字幕": {},
	"内嵌字幕": {}, "内封字幕": {}, "无水印": {}, "未删减": {}, "未删减版": {}, "导演剪辑版": {}, "加长版": {},
	"高码版": {}, "修正版": {}, "hd国语中字": {}, "bd中英双字": {}, "hd中字": {}, "bd国语中字": {},
}

func isTechOrReleaseToken(token string) bool {
	lower := strings.ToLower(strings.TrimSpace(token))
	if _, ok := techTokens[lower]; ok {
		return true
	}
	for _, prefix := range []string{"1080p", "2160p", "720p", "4k", "x264", "x265", "h264", "h265", "hevc", "aac", "ddp5", "dd5", "dts", "hd1080", "bd1080"} {
		if strings.HasPrefix(lower, prefix) {
			return true
		}
	}
	return false
}

func isGenericFilmStem(value string) bool {
	lower := strings.ToLower(strings.TrimSpace(value))
	if lower == "" {
		return true
	}
	if isTechOrReleaseToken(lower) {
		return true
	}
	switch lower {
	case "movie", "video", "film", "main", "index", "sample", "stream", "play",
		"正片", "电影", "视频", "影片", "未命名", "全集":
		return true
	}
	return false
}

func isEpisodeOrGenericStem(value string) bool {
	if isGenericFilmStem(value) {
		return true
	}
	trimmed := strings.TrimSpace(value)
	return episodePattern.MatchString(trimmed) || altEpisodePattern.MatchString(trimmed) ||
		cnEpisodePattern.MatchString(trimmed) || epOnlyPattern.MatchString(trimmed) ||
		pureEpisodeStemRegex.MatchString(trimmed)
}

var ignoredCategoryDirs = map[string]struct{}{
	".": {}, "": {}, "影视": {}, "电影": {}, "电视剧": {}, "剧集": {}, "动漫": {}, "动画": {},
	"综艺": {}, "纪录片": {}, "视频": {}, "个人视频": {}, "家庭视频": {}, "共享视频": {},
	"videos": {}, "video": {}, "movies": {}, "movie": {}, "tv": {}, "series": {}, "anime": {},
	"shows": {}, "downloads": {}, "download": {}, "下载": {}, "sharedfiles": {}, "users": {},
	"未分类": {}, "其他": {}, "other": {},
}

func meaningfulParentDirs(relPath string) []string {
	dir := path.Dir(strings.Trim(strings.ReplaceAll(relPath, "\\", "/"), "/"))
	if dir == "." || dir == "" || dir == "/" {
		return nil
	}
	segments := strings.Split(dir, "/")
	if len(segments) >= 3 && strings.EqualFold(segments[0], "users") {
		segments = segments[3:]
	}
	result := make([]string, 0, len(segments))
	for i := len(segments) - 1; i >= 0; i-- {
		seg := strings.TrimSpace(segments[i])
		if seg == "" {
			continue
		}
		if _, ignored := ignoredCategoryDirs[strings.ToLower(seg)]; ignored {
			continue
		}
		result = append(result, seg)
	}
	return result
}

func parseChineseOrArabicNumber(s string) int {
	s = strings.TrimSpace(s)
	if n, err := strconv.Atoi(s); err == nil {
		return n
	}
	digits := map[rune]int{'零': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9}
	total := 0
	current := 0
	for _, r := range s {
		switch r {
		case '百':
			if current == 0 {
				current = 1
			}
			total += current * 100
			current = 0
		case '十':
			if current == 0 {
				current = 1
			}
			total += current * 10
			current = 0
		default:
			if d, ok := digits[r]; ok {
				current = d
			}
		}
	}
	return total + current
}

// titleSearchVariants extracts candidate query strings for TMDB search and
// matching, splitting bilingual CJK + English titles (such as
// "流浪地球2 The Wandering Earth II" or "热辣滚烫 YOLO") into their Chinese and
// English components while preserving single-letter CJK titles like "头文字D".
func titleSearchVariants(title string) []string {
	trimmed := strings.TrimSpace(title)
	if trimmed == "" {
		return nil
	}
	seen := map[string]struct{}{}
	var out []string
	add := func(v string) {
		v = strings.TrimSpace(v)
		if v == "" {
			return
		}
		key := strings.ToLower(v)
		if _, exists := seen[key]; !exists {
			seen[key] = struct{}{}
			out = append(out, v)
		}
	}

	cjkPart, latinPart := splitBilingualTitle(trimmed)
	if cjkPart != "" && latinPart != "" {
		add(cjkPart)
		add(latinPart)
	}
	add(trimmed)
	for _, sep := range []string{"：", ":"} {
		if idx := strings.Index(trimmed, sep); idx > 0 {
			prefix := strings.TrimSpace(trimmed[:idx])
			if len([]rune(prefix)) >= 2 {
				add(prefix)
			}
		}
	}
	return out
}

func splitBilingualTitle(title string) (cjkPart, latinPart string) {
	words := strings.Fields(title)
	if len(words) < 2 {
		return "", ""
	}
	hasCJK := func(s string) bool {
		for _, r := range s {
			if unicode.Is(unicode.Han, r) {
				return true
			}
		}
		return false
	}
	latinLetters := func(s string) int {
		count := 0
		for _, r := range s {
			if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') {
				count++
			}
		}
		return count
	}
	// Pattern 1: CJK tokens followed by Latin tokens (e.g. "流浪地球2 The Wandering Earth II").
	splitIdx := -1
	for i, w := range words {
		if !hasCJK(w) {
			splitIdx = i
			break
		}
	}
	if splitIdx > 0 {
		allLatinAfter := true
		totalLatin := 0
		for _, w := range words[splitIdx:] {
			if hasCJK(w) {
				allLatinAfter = false
				break
			}
			totalLatin += latinLetters(w)
		}
		if allLatinAfter && totalLatin >= 3 {
			return strings.Join(words[:splitIdx], " "), strings.Join(words[splitIdx:], " ")
		}
	}
	// Pattern 2: Latin tokens followed by CJK tokens (e.g. "The Wandering Earth II 流浪地球2").
	splitIdx = -1
	for i, w := range words {
		if hasCJK(w) {
			splitIdx = i
			break
		}
	}
	if splitIdx > 0 {
		allCJKAfter := true
		totalLatin := 0
		for _, w := range words[:splitIdx] {
			totalLatin += latinLetters(w)
		}
		for _, w := range words[splitIdx:] {
			if !hasCJK(w) {
				allCJKAfter = false
				break
			}
		}
		if allCJKAfter && totalLatin >= 3 {
			return strings.Join(words[splitIdx:], " "), strings.Join(words[:splitIdx], " ")
		}
	}
	return "", ""
}
