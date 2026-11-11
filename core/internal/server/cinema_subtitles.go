package server

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"strconv"
	"strings"
	"unicode/utf16"
	"unicode/utf8"
)

func decodeUTF16Normalized(body []byte, littleEndian bool) string {
	nUnits := len(body) / 2
	var b strings.Builder
	b.Grow(nUnits)
	readUnit := func(idx int) uint16 {
		off := idx * 2
		if littleEndian {
			return binary.LittleEndian.Uint16(body[off : off+2])
		}
		return binary.BigEndian.Uint16(body[off : off+2])
	}
	for i := 0; i < nUnits; i++ {
		u := readUnit(i)
		if u == '\r' {
			if i+1 < nUnits && readUnit(i+1) == '\n' {
				i++
			}
			b.WriteByte('\n')
			continue
		}
		r := rune(u)
		if utf16.IsSurrogate(r) {
			if i+1 < nUnits {
				r2 := rune(readUnit(i + 1))
				if decoded := utf16.DecodeRune(r, r2); decoded != utf8.RuneError {
					i++
					b.WriteRune(decoded)
					continue
				}
			}
			b.WriteRune(utf8.RuneError)
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

func decodeSubtitleText(raw []byte) string {
	switch {
	case bytes.HasPrefix(raw, []byte{0xFF, 0xFE}):
		return decodeUTF16Normalized(raw[2:], true)
	case bytes.HasPrefix(raw, []byte{0xFE, 0xFF}):
		return decodeUTF16Normalized(raw[2:], false)
	default:
		trimmed := bytes.TrimPrefix(raw, []byte{0xEF, 0xBB, 0xBF})
		if utf8.Valid(trimmed) && bytes.IndexByte(trimmed, '\r') < 0 {
			return string(trimmed)
		}
		var b strings.Builder
		b.Grow(len(trimmed))
		for i := 0; i < len(trimmed); {
			c := trimmed[i]
			if c == '\r' {
				if i+1 < len(trimmed) && trimmed[i+1] == '\n' {
					i += 2
				} else {
					i++
				}
				b.WriteByte('\n')
				continue
			}
			if c < utf8.RuneSelf {
				b.WriteByte(c)
				i++
				continue
			}
			r, width := utf8.DecodeRune(trimmed[i:])
			if r == utf8.RuneError && width == 1 {
				i++
				continue
			}
			b.WriteRune(r)
			i += width
		}
		return b.String()
	}
}

func nextSubtitleLine(text string, pos int) (string, int, bool) {
	if pos >= len(text) {
		return "", len(text), false
	}
	idx := strings.IndexByte(text[pos:], '\n')
	var line string
	if idx < 0 {
		line = text[pos:]
		pos = len(text)
	} else {
		line = text[pos : pos+idx]
		pos += idx + 1
	}
	if len(line) > 0 && line[len(line)-1] == '\r' {
		line = line[:len(line)-1]
	}
	return line, pos, true
}

func hasPrefixFold(s, prefix string) bool {
	return len(s) >= len(prefix) && strings.EqualFold(s[:len(prefix)], prefix)
}

func subtitleBytesToVTT(raw []byte, format string) (string, error) {
	text := decodeSubtitleText(raw)
	switch strings.ToLower(format) {
	case ".srt":
		return srtToVTT(text), nil
	case ".ass", ".ssa":
		return assToVTT(text), nil
	default:
		return text, nil
	}
}

// srtToVTT converts SRT timing lines to WebVTT. Shared by the sidecar and
// embedded subtitle endpoints so both behave identically.
func srtToVTT(text string) string {
	var b strings.Builder
	b.Grow(len(text) + 16)
	b.WriteString("WEBVTT\n\n")
	for pos := 0; ; {
		line, next, ok := nextSubtitleLine(text, pos)
		if !ok {
			break
		}
		pos = next
		if len(line) >= 2<<20 {
			return text
		}
		b.WriteByte('\n')
		// SRT timestamps use a decimal comma; VTT uses a period.
		if strings.Contains(line, " --> ") {
			start := 0
			for {
				comma := strings.IndexByte(line[start:], ',')
				if comma < 0 {
					b.WriteString(line[start:])
					break
				}
				b.WriteString(line[start : start+comma])
				b.WriteByte('.')
				start += comma + 1
			}
		} else {
			b.WriteString(line)
		}
	}
	return b.String()
}

func assTimeToVTT(raw string) (string, bool) {
	parts := strings.Split(strings.TrimSpace(raw), ":")
	if len(parts) != 3 {
		return "", false
	}
	h, errH := strconv.Atoi(parts[0])
	m, errM := strconv.Atoi(parts[1])
	if errH != nil || errM != nil || h < 0 || m < 0 || m >= 60 {
		return "", false
	}
	secPart := strings.ReplaceAll(parts[2], ",", ".")
	secPieces := strings.SplitN(secPart, ".", 2)
	s, errS := strconv.Atoi(secPieces[0])
	if errS != nil || s < 0 || s >= 60 {
		return "", false
	}
	frac := "000"
	if len(secPieces) == 2 {
		digits := secPieces[1]
		for len(digits) < 3 {
			digits += "0"
		}
		if len(digits) > 3 {
			digits = digits[:3]
		}
		frac = digits
	}
	return fmt.Sprintf("%02d:%02d:%02d.%s", h, m, s, frac), true
}

func stripASSOverrides(raw string) string {
	var b strings.Builder
	b.Grow(len(raw))
	depth := 0
	for i := 0; i < len(raw); {
		c := raw[i]
		if c == '{' {
			depth++
			i++
			continue
		}
		if c == '}' {
			if depth > 0 {
				depth--
			}
			i++
			continue
		}
		if depth > 0 {
			_, width := utf8.DecodeRuneInString(raw[i:])
			i += width
			continue
		}
		if c == '\\' && i+1 < len(raw) {
			switch raw[i+1] {
			case 'N', 'n':
				b.WriteByte('\n')
				i += 2
				continue
			case 'h':
				b.WriteByte(' ')
				i += 2
				continue
			}
		}
		if c < utf8.RuneSelf {
			b.WriteByte(c)
			i++
			continue
		}
		r, width := utf8.DecodeRuneInString(raw[i:])
		b.WriteRune(r)
		i += width
	}
	return strings.TrimSpace(b.String())
}

func extractASSDialogueFields(body string, fieldCount, startIdx, endIdx, textIdx int) (startRaw, endRaw, textRaw string, ok bool) {
	if fieldCount < 3 || startIdx < 0 || endIdx < 0 || textIdx < 0 ||
		startIdx >= fieldCount || endIdx >= fieldCount || textIdx >= fieldCount {
		return "", "", "", false
	}
	maxRequired := startIdx
	if endIdx > maxRequired {
		maxRequired = endIdx
	}
	if textIdx > maxRequired {
		maxRequired = textIdx
	}
	pos := 0
	seen := 0
	for field := 0; field < fieldCount; field++ {
		var val string
		if field == fieldCount-1 {
			val = body[pos:]
			seen = field + 1
		} else {
			comma := strings.IndexByte(body[pos:], ',')
			if comma < 0 {
				val = body[pos:]
				seen = field + 1
				switch field {
				case startIdx:
					startRaw = val
				case endIdx:
					endRaw = val
				case textIdx:
					textRaw = val
				}
				break
			}
			val = body[pos : pos+comma]
			pos += comma + 1
			seen = field + 1
		}
		switch field {
		case startIdx:
			startRaw = val
		case endIdx:
			endRaw = val
		case textIdx:
			textRaw = val
		}
	}
	if seen <= maxRequired {
		return "", "", "", false
	}
	return startRaw, endRaw, textRaw, true
}

func assToVTT(text string) string {
	var b strings.Builder
	b.Grow(len(text)/2 + 16)
	b.WriteString("WEBVTT\n")
	startIdx, endIdx, textIdx, fieldCount := 1, 2, 9, 10
	for pos := 0; ; {
		rawLine, next, ok := nextSubtitleLine(text, pos)
		if !ok {
			break
		}
		pos = next
		if len(rawLine) >= 2<<20 {
			break
		}
		line := strings.TrimSpace(rawLine)
		if hasPrefixFold(line, "format:") {
			cols := strings.Split(strings.TrimSpace(line[len("format:"):]), ",")
			if len(cols) >= 3 {
				fieldCount = len(cols)
				for i, col := range cols {
					colTrim := strings.TrimSpace(col)
					switch {
					case strings.EqualFold(colTrim, "start"):
						startIdx = i
					case strings.EqualFold(colTrim, "end"):
						endIdx = i
					case strings.EqualFold(colTrim, "text"):
						textIdx = i
					}
				}
			}
			continue
		}
		if !hasPrefixFold(line, "dialogue:") {
			continue
		}
		body := strings.TrimSpace(line[len("dialogue:"):])
		startRaw, endRaw, textRaw, fieldsOK := extractASSDialogueFields(body, fieldCount, startIdx, endIdx, textIdx)
		if !fieldsOK {
			continue
		}
		startVTT, okStart := assTimeToVTT(startRaw)
		endVTT, okEnd := assTimeToVTT(endRaw)
		if !okStart || !okEnd {
			continue
		}
		caption := stripASSOverrides(textRaw)
		if caption == "" {
			continue
		}
		b.WriteByte('\n')
		b.WriteString(startVTT)
		b.WriteString(" --> ")
		b.WriteString(endVTT)
		b.WriteByte('\n')
		b.WriteString(caption)
		b.WriteByte('\n')
	}
	return b.String()
}
