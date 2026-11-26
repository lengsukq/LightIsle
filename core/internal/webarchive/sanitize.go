package webarchive

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	stdhtml "html"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"golang.org/x/net/html"
	"golang.org/x/net/html/atom"
)

func extractTitle(doc *html.Node) string {
	var title string
	var walk func(*html.Node)
	walk = func(n *html.Node) {
		if title != "" {
			return
		}
		if n.Type == html.ElementNode && n.DataAtom == atom.Title {
			title = strings.Join(strings.Fields(nodeText(n)), " ")
			return
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
	}
	walk(doc)
	return title
}

func fallbackTitle(u *url.URL) string {
	if u == nil {
		return "webpage"
	}
	seg := strings.Trim(u.Path, "/")
	if seg != "" {
		parts := strings.Split(seg, "/")
		if last := strings.TrimSpace(parts[len(parts)-1]); last != "" {
			return last
		}
	}
	if host := u.Hostname(); host != "" {
		return host
	}
	return "webpage"
}

func pickContentRoot(doc *html.Node) *html.Node {
	if article := findFirstMeaningful(doc, atom.Article); article != nil {
		return article
	}
	if mainNode := findFirstMeaningful(doc, atom.Main); mainNode != nil {
		return mainNode
	}
	if body := findFirst(doc, atom.Body); body != nil {
		return body
	}
	return doc
}

func findFirst(n *html.Node, target atom.Atom) *html.Node {
	if n.Type == html.ElementNode && n.DataAtom == target {
		return n
	}
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		if found := findFirst(c, target); found != nil {
			return found
		}
	}
	return nil
}

func findFirstMeaningful(n *html.Node, target atom.Atom) *html.Node {
	if n.Type == html.ElementNode && n.DataAtom == target {
		if strings.TrimSpace(nodeText(n)) != "" || findFirst(n, atom.Img) != nil {
			return n
		}
	}
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		if found := findFirstMeaningful(c, target); found != nil {
			return found
		}
	}
	return nil
}

func nodeText(n *html.Node) string {
	var b strings.Builder
	var walk func(*html.Node)
	walk = func(cur *html.Node) {
		if cur.Type == html.TextNode {
			b.WriteString(cur.Data)
		}
		for c := cur.FirstChild; c != nil; c = c.NextSibling {
			if c.Type == html.ElementNode && isDroppedElement(c.Data) {
				continue
			}
			walk(c)
		}
	}
	walk(n)
	return b.String()
}

type bodyPart struct {
	html string
	img  *imgCandidate
}

type imgCandidate struct {
	src   string
	alt   string
	title string
}

type sanitizeState struct {
	ctx           context.Context
	client        *http.Client
	baseURL       *url.URL
	cfg           Options
	remainingSize int64
	inlinedImages int
	skippedImages int
	parts         []bodyPart
}

var droppedElements = map[string]bool{
	"script": true, "style": true, "iframe": true, "frame": true,
	"frameset": true, "object": true, "embed": true, "applet": true,
	"svg": true, "math": true, "form": true, "input": true,
	"button": true, "select": true, "textarea": true, "meta": true,
	"link": true, "base": true, "head": true, "title": true,
	"template": true, "audio": true, "video": true, "source": true,
	"track": true, "canvas": true, "portal": true, "dialog": true,
	"noscript": true,
}

var allowedElements = map[string]bool{
	"article": true, "section": true, "main": true, "header": true,
	"footer": true, "aside": true, "nav": true, "div": true,
	"p": true, "br": true, "hr": true,
	"h1": true, "h2": true, "h3": true, "h4": true, "h5": true, "h6": true,
	"ul": true, "ol": true, "li": true, "dl": true, "dt": true, "dd": true,
	"blockquote": true, "pre": true, "code": true, "kbd": true, "samp": true,
	"table": true, "thead": true, "tbody": true, "tfoot": true,
	"tr": true, "th": true, "td": true, "caption": true,
	"figure": true, "figcaption": true,
	"strong": true, "b": true, "em": true, "i": true, "u": true,
	"s": true, "del": true, "ins": true, "mark": true, "small": true,
	"sub": true, "sup": true, "span": true, "time": true, "abbr": true,
	"cite": true, "q": true, "details": true, "summary": true,
	"a": true, "img": true,
}

var voidElements = map[string]bool{
	"br": true, "hr": true, "img": true,
}

func isDroppedElement(tag string) bool {
	return droppedElements[strings.ToLower(tag)]
}

// sanitizeAndInline first strips untrusted markup so the remaining image budget
// is computed from the actual sanitized body size rather than raw page bloat.
func (s *sanitizeState) sanitizeAndInline(contentRoot *html.Node, bodyBudget int64) string {
	var buf bytes.Buffer
	s.renderChildren(&buf, contentRoot)
	if buf.Len() > 0 {
		s.parts = append(s.parts, bodyPart{html: buf.String()})
	}

	var sanitizedTextBytes int64
	for _, part := range s.parts {
		sanitizedTextBytes += int64(len(part.html))
	}
	s.remainingSize = max(0, bodyBudget-sanitizedTextBytes)

	var out bytes.Buffer
	out.Grow(int(sanitizedTextBytes))
	for _, part := range s.parts {
		if part.img == nil {
			out.WriteString(part.html)
			continue
		}
		s.materializeImage(&out, part.img)
	}
	return out.String()
}

func (s *sanitizeState) renderChildren(w *bytes.Buffer, n *html.Node) {
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		s.renderNode(w, c)
	}
}

func (s *sanitizeState) renderNode(w *bytes.Buffer, n *html.Node) {
	switch n.Type {
	case html.TextNode:
		w.WriteString(stdhtml.EscapeString(n.Data))
	case html.ElementNode:
		tag := strings.ToLower(n.Data)
		if isDroppedElement(tag) {
			return
		}
		if !allowedElements[tag] {
			s.renderChildren(w, n)
			return
		}
		if tag == "img" {
			s.collectImage(w, n)
			return
		}
		attrs := s.sanitizeAttrs(tag, n.Attr)
		w.WriteByte('<')
		w.WriteString(tag)
		for _, attr := range attrs {
			w.WriteByte(' ')
			w.WriteString(attr.Key)
			w.WriteString(`="`)
			w.WriteString(stdhtml.EscapeString(attr.Val))
			w.WriteByte('"')
		}
		w.WriteByte('>')
		if voidElements[tag] {
			return
		}
		s.renderChildren(w, n)
		w.WriteString("</")
		w.WriteString(tag)
		w.WriteByte('>')
	case html.DocumentNode:
		s.renderChildren(w, n)
	}
}

func (s *sanitizeState) sanitizeAttrs(tag string, attrs []html.Attribute) []html.Attribute {
	var out []html.Attribute
	hasHref := false
	for _, a := range attrs {
		key := strings.ToLower(strings.TrimSpace(a.Key))
		if key == "" || strings.HasPrefix(key, "on") || key == "style" || key == "srcdoc" {
			continue
		}
		val := strings.TrimSpace(a.Val)
		switch tag {
		case "a":
			if key == "href" {
				if safeHref, ok := s.sanitizeLinkURL(val); ok {
					out = append(out, html.Attribute{Key: "href", Val: safeHref})
					hasHref = true
				}
			} else if key == "title" && val != "" {
				out = append(out, html.Attribute{Key: "title", Val: val})
			}
		case "td", "th":
			if (key == "colspan" || key == "rowspan") && isPositiveInt(val) {
				out = append(out, html.Attribute{Key: key, Val: val})
			}
		case "time":
			if key == "datetime" && val != "" {
				out = append(out, html.Attribute{Key: "datetime", Val: val})
			}
		case "abbr":
			if key == "title" && val != "" {
				out = append(out, html.Attribute{Key: "title", Val: val})
			}
		case "ol":
			if key == "start" && isPositiveInt(val) {
				out = append(out, html.Attribute{Key: "start", Val: val})
			}
		}
	}
	if tag == "a" && hasHref {
		out = append(out,
			html.Attribute{Key: "rel", Val: "noopener noreferrer"},
			html.Attribute{Key: "target", Val: "_blank"},
		)
	}
	return out
}

func (s *sanitizeState) sanitizeLinkURL(raw string) (string, bool) {
	if raw == "" {
		return "", false
	}
	if strings.HasPrefix(raw, "#") {
		return raw, true
	}
	cleaned := strings.TrimSpace(raw)
	lower := strings.ToLower(cleaned)
	if strings.HasPrefix(lower, "javascript:") ||
		strings.HasPrefix(lower, "vbscript:") ||
		strings.HasPrefix(lower, "data:") {
		return "", false
	}
	parsed, err := url.Parse(cleaned)
	if err != nil {
		return "", false
	}
	if parsed.Scheme == "" && s.baseURL != nil {
		parsed = s.baseURL.ResolveReference(parsed)
	}
	switch strings.ToLower(parsed.Scheme) {
	case "http", "https", "mailto":
		return parsed.String(), true
	default:
		return "", false
	}
}

func (s *sanitizeState) collectImage(w *bytes.Buffer, n *html.Node) {
	if w.Len() > 0 {
		s.parts = append(s.parts, bodyPart{html: w.String()})
		w.Reset()
	}
	var rawSrc, dataSrc, alt, title string
	for _, a := range n.Attr {
		switch strings.ToLower(strings.TrimSpace(a.Key)) {
		case "src":
			rawSrc = strings.TrimSpace(a.Val)
		case "data-src", "data-original":
			if dataSrc == "" {
				dataSrc = strings.TrimSpace(a.Val)
			}
		case "alt":
			alt = strings.TrimSpace(a.Val)
		case "title":
			title = strings.TrimSpace(a.Val)
		}
	}
	src := rawSrc
	if (src == "" || strings.HasPrefix(strings.ToLower(src), "data:image/gif;base64,r0lgod")) && dataSrc != "" {
		src = dataSrc
	}
	s.parts = append(s.parts, bodyPart{img: &imgCandidate{src: src, alt: alt, title: title}})
}

func (s *sanitizeState) materializeImage(w *bytes.Buffer, cand *imgCandidate) {
	attrOverhead := imgTagOverhead(cand.alt, cand.title)
	dataURI, ok := s.inlineImage(cand.src, attrOverhead)
	if !ok {
		s.skippedImages++
		if cand.alt != "" {
			fallback := `<span class="li-img-alt">[图片: ` + stdhtml.EscapeString(cand.alt) + `]</span>`
			if int64(len(fallback)) <= s.remainingSize {
				s.remainingSize -= int64(len(fallback))
				w.WriteString(fallback)
			}
		}
		return
	}
	s.inlinedImages++
	w.WriteString(`<img src="`)
	w.WriteString(dataURI)
	w.WriteByte('"')
	if cand.alt != "" {
		w.WriteString(` alt="`)
		w.WriteString(stdhtml.EscapeString(cand.alt))
		w.WriteByte('"')
	}
	if cand.title != "" {
		w.WriteString(` title="`)
		w.WriteString(stdhtml.EscapeString(cand.title))
		w.WriteByte('"')
	}
	w.WriteByte('>')
}

func imgTagOverhead(alt, title string) int64 {
	overhead := int64(len(`<img src="">`))
	if alt != "" {
		overhead += int64(len(` alt=""`) + len(stdhtml.EscapeString(alt)))
	}
	if title != "" {
		overhead += int64(len(` title=""`) + len(stdhtml.EscapeString(title)))
	}
	return overhead
}

var safeImageMIMEs = map[string]bool{
	"image/png":    true,
	"image/jpeg":   true,
	"image/gif":    true,
	"image/webp":   true,
	"image/avif":   true,
	"image/bmp":    true,
	"image/x-icon": true,
}

func (s *sanitizeState) inlineImage(src string, tagOverhead int64) (string, bool) {
	if src == "" || s.inlinedImages >= s.cfg.MaxImages || s.remainingSize <= tagOverhead {
		return "", false
	}
	lower := strings.ToLower(src)
	if strings.HasPrefix(lower, "data:") {
		return s.validateExistingDataURI(src, tagOverhead)
	}
	if strings.HasPrefix(lower, "javascript:") || strings.HasPrefix(lower, "vbscript:") {
		return "", false
	}
	parsed, err := url.Parse(src)
	if err != nil {
		return "", false
	}
	if s.baseURL != nil {
		parsed = s.baseURL.ResolveReference(parsed)
	}
	resolved := parsed.String()
	if ValidateURL(resolved) != nil {
		return "", false
	}
	req, err := http.NewRequestWithContext(s.ctx, http.MethodGet, resolved, nil)
	if err != nil {
		return "", false
	}
	req.Header.Set("User-Agent", s.cfg.UserAgent)
	req.Header.Set("Accept", "image/avif,image/webp,image/png,image/jpeg,image/gif,*/*;q=0.1")

	resp, err := s.client.Do(req)
	if err != nil {
		return "", false
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", false
	}
	data, err := readBounded(resp.Body, s.cfg.MaxImageBytes)
	if err != nil || len(data) == 0 {
		return "", false
	}
	mimeType := detectSafeImageMIME(resp.Header.Get("Content-Type"), data)
	if mimeType == "" {
		return "", false
	}
	encoded := "data:" + mimeType + ";base64," + base64.StdEncoding.EncodeToString(data)
	cost := int64(len(encoded)) + tagOverhead
	if cost > s.remainingSize {
		return "", false
	}
	s.remainingSize -= cost
	return encoded, true
}

func (s *sanitizeState) validateExistingDataURI(src string, tagOverhead int64) (string, bool) {
	comma := strings.IndexByte(src, ',')
	if comma <= 5 {
		return "", false
	}
	meta := strings.ToLower(strings.TrimSpace(src[5:comma]))
	if !strings.HasSuffix(meta, ";base64") {
		return "", false
	}
	declaredMIME := strings.TrimSpace(strings.TrimSuffix(meta, ";base64"))
	if !safeImageMIMEs[declaredMIME] {
		return "", false
	}
	cleaned := stripBase64Whitespace(src[comma+1:])
	if cleaned == "" {
		return "", false
	}
	decoded, err := base64.StdEncoding.DecodeString(cleaned)
	if err != nil && !strings.ContainsRune(cleaned, '=') {
		decoded, err = base64.RawStdEncoding.DecodeString(cleaned)
	}
	if err != nil || len(decoded) == 0 || int64(len(decoded)) > s.cfg.MaxImageBytes {
		return "", false
	}
	verifiedMIME := detectSafeImageMIME(declaredMIME, decoded)
	if verifiedMIME == "" {
		return "", false
	}
	cleanURI := "data:" + verifiedMIME + ";base64," + base64.StdEncoding.EncodeToString(decoded)
	cost := int64(len(cleanURI)) + tagOverhead
	if cost > s.remainingSize {
		return "", false
	}
	s.remainingSize -= cost
	return cleanURI, true
}

func stripBase64Whitespace(raw string) string {
	var b strings.Builder
	b.Grow(len(raw))
	for i := 0; i < len(raw); i++ {
		switch raw[i] {
		case ' ', '\t', '\r', '\n':
			continue
		default:
			b.WriteByte(raw[i])
		}
	}
	return b.String()
}

func detectSafeImageMIME(_ string, data []byte) string {
	if len(data) == 0 {
		return ""
	}
	sniffed := parseMediaType(http.DetectContentType(data))
	if sniffed == "image/vnd.microsoft.icon" && isICOMagic(data) {
		return "image/x-icon"
	}
	if safeImageMIMEs[sniffed] {
		return sniffed
	}
	if isAVIFMagic(data) {
		return "image/avif"
	}
	if isICOMagic(data) {
		return "image/x-icon"
	}
	return ""
}

func isAVIFMagic(data []byte) bool {
	if len(data) < 12 || string(data[4:8]) != "ftyp" {
		return false
	}
	boxSize := int(binary.BigEndian.Uint32(data[0:4]))
	if boxSize < 12 {
		return false
	}
	limit := min(len(data), min(boxSize, 64))
	major := string(data[8:12])
	if major == "avif" || major == "avis" {
		return true
	}
	for off := 16; off+4 <= limit; off += 4 {
		brand := string(data[off : off+4])
		if brand == "avif" || brand == "avis" {
			return true
		}
	}
	return false
}

func isICOMagic(data []byte) bool {
	if len(data) < 6 {
		return false
	}
	if data[0] != 0x00 || data[1] != 0x00 || (data[2] != 0x01 && data[2] != 0x02) || data[3] != 0x00 {
		return false
	}
	return binary.LittleEndian.Uint16(data[4:6]) > 0
}

func isPositiveInt(s string) bool {
	n, err := strconv.Atoi(s)
	return err == nil && n > 0 && n <= 1000
}

func buildArchiveDocument(title, sourceURL string, archivedAt time.Time, bodyHTML string) []byte {
	escapedTitle := stdhtml.EscapeString(title)
	escapedURL := stdhtml.EscapeString(sourceURL)
	escapedTime := stdhtml.EscapeString(archivedAt.Format(time.RFC3339))

	var b strings.Builder
	b.WriteString("<!DOCTYPE html>\n<html lang=\"zh-CN\">\n<head>\n")
	b.WriteString("<meta charset=\"utf-8\">\n")
	b.WriteString("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n")
	b.WriteString("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline';\">\n")
	b.WriteString("<title>")
	b.WriteString(escapedTitle)
	b.WriteString("</title>\n<style>\n")
	b.WriteString(":root{color-scheme:light dark;--bg:#F7F6F3;--card:#FFFFFF;--fg:#1C1B19;--muted:#63605B;--border:#E7E4DD;--link:#0E6B74;}\n")
	b.WriteString("@media(prefers-color-scheme:dark){:root{--bg:#0E0E0D;--card:#191917;--fg:#F2F0EC;--muted:#A6A29B;--border:#2E2E2A;--link:#5CC8D4;}}\n")
	b.WriteString("body{margin:0;padding:24px 16px 48px;background:var(--bg);color:var(--fg);font:16px/1.75 -apple-system,BlinkMacSystemFont,'SF Pro Text','PingFang SC',sans-serif;}\n")
	b.WriteString(".li-wrap{max-width:780px;margin:0 auto;}\n")
	b.WriteString(".li-archive-meta{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:18px 20px;margin-bottom:24px;}\n")
	b.WriteString(".li-archive-meta h1{margin:0 0 10px;font-size:1.5rem;line-height:1.35;}\n")
	b.WriteString(".li-archive-meta dl{margin:0;display:grid;grid-template-columns:auto 1fr;gap:4px 12px;font-size:.875rem;color:var(--muted);}\n")
	b.WriteString(".li-archive-meta dt{font-weight:600;}\n")
	b.WriteString(".li-archive-meta dd{margin:0;word-break:break-all;}\n")
	b.WriteString(".li-archive-body{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:24px 26px;}\n")
	b.WriteString(".li-archive-body img{max-width:100%;height:auto;border-radius:8px;display:block;margin:14px auto;}\n")
	b.WriteString(".li-archive-body pre{overflow-x:auto;padding:12px 14px;border-radius:8px;background:var(--bg);border:1px solid var(--border);}\n")
	b.WriteString(".li-archive-body blockquote{margin:16px 0;padding:4px 16px;border-left:3px solid var(--border);color:var(--muted);}\n")
	b.WriteString(".li-archive-body table{border-collapse:collapse;width:100%;margin:16px 0;}\n")
	b.WriteString(".li-archive-body th,.li-archive-body td{border:1px solid var(--border);padding:8px 10px;text-align:left;}\n")
	b.WriteString(".li-img-alt{display:inline-block;padding:2px 8px;border-radius:6px;background:var(--bg);color:var(--muted);font-size:.85rem;}\n")
	b.WriteString("a{color:var(--link);}\n")
	b.WriteString("</style>\n</head>\n<body>\n<div class=\"li-wrap\">\n")
	b.WriteString("<header class=\"li-archive-meta\">\n<h1>")
	b.WriteString(escapedTitle)
	b.WriteString("</h1>\n<dl>\n<dt>原链接</dt><dd><a href=\"")
	b.WriteString(escapedURL)
	b.WriteString("\" rel=\"noopener noreferrer\" target=\"_blank\">")
	b.WriteString(escapedURL)
	b.WriteString("</a></dd>\n<dt>归档时间</dt><dd>")
	b.WriteString(escapedTime)
	b.WriteString("</dd>\n</dl>\n</header>\n<main class=\"li-archive-body\">\n")
	b.WriteString(bodyHTML)
	b.WriteString("\n</main>\n</div>\n</body>\n</html>\n")
	return []byte(b.String())
}
