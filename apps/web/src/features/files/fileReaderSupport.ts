export const OFFICE_MAX_PREVIEW_BYTES = 20 * 1024 * 1024; // 20 MiB
export const TEXT_EDIT_MAX_BYTES = 2 * 1024 * 1024; // 2 MiB

// Exact whitelist matching core/internal/server/file_text_save.go
export const EDITABLE_TEXT_EXTENSIONS = new Set([
  ".md", ".markdown", ".txt",
  ".json", ".yaml", ".yml", ".toml",
  ".ini", ".conf", ".cfg", ".properties",
  ".csv", ".tsv", ".log", ".xml",
  ".sql", ".srt", ".vtt",
  ".env", ".gitignore",
  ".css", ".js", ".ts", ".html", ".htm",
  ".sh", ".py", ".go", ".dart",
  ".swift", ".kt", ".java", ".rs",
  ".c", ".h", ".cpp", ".hpp",
]);

export type FileReaderKind =
  | "markdown"
  | "text"
  | "docx"
  | "xlsx"
  | "csv"
  | "comic"
  | "epub"
  | "zip"
  | "none";

export function fileExtensionLower(filename: string): string {
  const base = filename.split("/").pop() ?? filename;
  const dot = base.lastIndexOf(".");
  if (dot < 0) return "";
  return base.slice(dot).toLowerCase();
}

export function classifyFileReader(filename: string): FileReaderKind {
  const ext = fileExtensionLower(filename);
  if (ext === ".md" || ext === ".markdown") return "markdown";
  if (ext === ".docx") return "docx";
  if (ext === ".xlsx") return "xlsx";
  if (ext === ".csv") return "csv";
  if (ext === ".cbz") return "comic";
  if (ext === ".epub") return "epub";
  if (ext === ".zip") return "zip";
  if (EDITABLE_TEXT_EXTENSIONS.has(ext)) return "text";
  return "none";
}

export function isMarkdownFile(filename: string): boolean {
  const ext = fileExtensionLower(filename);
  return ext === ".md" || ext === ".markdown";
}

export function isEditableTextFile(filename: string): boolean {
  return EDITABLE_TEXT_EXTENSIONS.has(fileExtensionLower(filename));
}

export function isOfficePreviewFile(filename: string): boolean {
  const ext = fileExtensionLower(filename);
  return ext === ".docx" || ext === ".xlsx" || ext === ".csv";
}

export function isArchiveReaderFile(filename: string): boolean {
  const ext = fileExtensionLower(filename);
  return ext === ".cbz" || ext === ".epub" || ext === ".zip";
}

export function escapeHtml(raw: string): string {
  return raw
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function isSafeLinkUrl(href: string): boolean {
  const trimmed = href.trim();
  if (!trimmed) return false;
  if (trimmed.startsWith("#")) return true;
  return /^(https?:|mailto:)/i.test(trimmed);
}

function formatInlineMarkdown(escapedLine: string): string {
  const codeSpans: string[] = [];
  let text = escapedLine.replace(/`([^`\n]+)`/g, (_m, code: string) => {
    const idx = codeSpans.push(`<code>${code}</code>`) - 1;
    return `\u0000CODE${idx}\u0000`;
  });

  // Images: render as safe caption pill instead of external resource request
  text = text.replace(/!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)/g, (_m, alt: string) => {
    const label = alt.trim() || "图片";
    return `<span class="md-image-placeholder">[图片：${label}]</span>`;
  });

  // Links (strict protocol allowlist)
  text = text.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_m, label: string, rawHref: string) => {
    const unescapedHref = rawHref.replace(/&amp;/g, "&");
    if (!isSafeLinkUrl(unescapedHref)) return label;
    return `<a href="${escapeHtml(unescapedHref)}" target="_blank" rel="noopener noreferrer">${label}</a>`;
  });

  text = text.replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>");
  text = text.replace(/__([^_\n]+)__/g, "<strong>$1</strong>");
  text = text.replace(/~~([^~\n]+)~~/g, "<del>$1</del>");
  text = text.replace(/(^|[\s(])\*([^*\n]+)\*(?=[\s).,!?;:]|$)/g, "$1<em>$2</em>");
  text = text.replace(/(^|[\s(])_([^_\n]+)_(?=[\s).,!?;:]|$)/g, "$1<em>$2</em>");

  return text.replace(/\u0000CODE(\d+)\u0000/g, (_m, idx: string) => codeSpans[Number(idx)] ?? "");
}

function isTableSeparatorLine(line: string): boolean {
  const trimmed = line.trim().replace(/^\|/, "").replace(/\|$/, "");
  const cols = trimmed.split("|").map((c) => c.trim());
  return cols.length >= 2 && cols.every((c) => /^:?-{3,}:?$/.test(c));
}

function splitTableRow(line: string): string[] {
  return line
    .trim()
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split("|")
    .map((c) => formatInlineMarkdown(escapeHtml(c.trim())));
}

/**
 * Lightweight, deterministic Markdown -> HTML renderer.
 * Caller MUST still pass output through DOMPurify.sanitize() before v-html.
 */
export function renderMarkdownToRawHtml(markdown: string): string {
  const lines = markdown.replace(/\r\n?/g, "\n").split("\n");
  const out: string[] = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];

    // Fenced code block
    const fence = line.match(/^```([A-Za-z0-9_+-]*)\s*$/);
    if (fence) {
      const lang = fence[1] ? ` class="language-${escapeHtml(fence[1])}"` : "";
      const buf: string[] = [];
      i += 1;
      while (i < lines.length && !/^```\s*$/.test(lines[i])) {
        buf.push(escapeHtml(lines[i]));
        i += 1;
      }
      if (i < lines.length) i += 1;
      out.push(`<pre><code${lang}>${buf.join("\n")}</code></pre>`);
      continue;
    }

    // Blank line
    if (!line.trim()) {
      i += 1;
      continue;
    }

    // Horizontal rule
    if (/^\s*(?:[-*_]\s*){3,}$/.test(line)) {
      out.push("<hr />");
      i += 1;
      continue;
    }

    // Heading
    const heading = line.match(/^(#{1,6})\s+(.+?)\s*#*$/);
    if (heading) {
      const level = heading[1].length;
      out.push(`<h${level}>${formatInlineMarkdown(escapeHtml(heading[2]))}</h${level}>`);
      i += 1;
      continue;
    }

    // GFM Table
    if (line.includes("|") && i + 1 < lines.length && isTableSeparatorLine(lines[i + 1])) {
      const headers = splitTableRow(line);
      i += 2;
      const bodyRows: string[][] = [];
      while (i < lines.length && lines[i].trim() && lines[i].includes("|")) {
        bodyRows.push(splitTableRow(lines[i]));
        i += 1;
      }
      const thead = `<thead><tr>${headers.map((h) => `<th>${h}</th>`).join("")}</tr></thead>`;
      const tbody = `<tbody>${bodyRows
        .map((row) => `<tr>${headers.map((_, idx) => `<td>${row[idx] ?? ""}</td>`).join("")}</tr>`)
        .join("")}</tbody>`;
      out.push(`<div class="md-table-wrap"><table>${thead}${tbody}</table></div>`);
      continue;
    }

    // Blockquote
    if (/^\s*>\s?/.test(line)) {
      const quoteLines: string[] = [];
      while (i < lines.length && /^\s*>\s?/.test(lines[i])) {
        quoteLines.push(lines[i].replace(/^\s*>\s?/, ""));
        i += 1;
      }
      out.push(`<blockquote>${renderMarkdownToRawHtml(quoteLines.join("\n"))}</blockquote>`);
      continue;
    }

    // Unordered list (including task list)
    if (/^\s*[-*+]\s+/.test(line)) {
      const items: string[] = [];
      while (i < lines.length && /^\s*[-*+]\s+/.test(lines[i])) {
        const content = lines[i].replace(/^\s*[-*+]\s+/, "");
        const task = content.match(/^\[( |x|X)\]\s+(.*)$/);
        if (task) {
          const checked = task[1].toLowerCase() === "x";
          items.push(
            `<li class="md-task-item"><span class="md-task-box">${checked ? "☑" : "☐"}</span> ${formatInlineMarkdown(escapeHtml(task[2]))}</li>`,
          );
        } else {
          items.push(`<li>${formatInlineMarkdown(escapeHtml(content))}</li>`);
        }
        i += 1;
      }
      out.push(`<ul>${items.join("")}</ul>`);
      continue;
    }

    // Ordered list
    if (/^\s*\d+\.\s+/.test(line)) {
      const items: string[] = [];
      while (i < lines.length && /^\s*\d+\.\s+/.test(lines[i])) {
        const content = lines[i].replace(/^\s*\d+\.\s+/, "");
        items.push(`<li>${formatInlineMarkdown(escapeHtml(content))}</li>`);
        i += 1;
      }
      out.push(`<ol>${items.join("")}</ol>`);
      continue;
    }

    // Paragraph
    const para: string[] = [];
    while (
      i < lines.length &&
      lines[i].trim() &&
      !/^```/.test(lines[i]) &&
      !/^#{1,6}\s+/.test(lines[i]) &&
      !/^\s*>\s?/.test(lines[i]) &&
      !/^\s*[-*+]\s+/.test(lines[i]) &&
      !/^\s*\d+\.\s+/.test(lines[i]) &&
      !/^\s*(?:[-*_]\s*){3,}$/.test(lines[i])
    ) {
      para.push(formatInlineMarkdown(escapeHtml(lines[i])));
      i += 1;
    }
    out.push(`<p>${para.join("<br />")}</p>`);
  }

  return out.join("\n");
}

export interface CsvParseResult {
  rows: string[][];
  truncated: boolean;
}

export function parseCsvRows(rawText: string, maxRows = 2000): CsvParseResult {
  const text = rawText.replace(/^\uFEFF/, "");
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let inQuotes = false;
  let truncated = false;

  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    if (inQuotes) {
      if (ch === '"') {
        if (text[i + 1] === '"') {
          cell += '"';
          i += 1;
        } else {
          inQuotes = false;
        }
      } else {
        cell += ch;
      }
      continue;
    }

    if (ch === '"' && cell.length === 0) {
      inQuotes = true;
    } else if (ch === ",") {
      row.push(cell);
      cell = "";
    } else if (ch === "\r" || ch === "\n") {
      if (ch === "\r" && text[i + 1] === "\n") i += 1;
      row.push(cell);
      cell = "";
      if (row.length > 1 || row[0] !== "") {
        rows.push(row);
        if (rows.length >= maxRows) {
          truncated = i + 1 < text.length;
          return { rows, truncated };
        }
      }
      row = [];
    } else {
      cell += ch;
    }
  }

  if (cell.length > 0 || row.length > 0) {
    row.push(cell);
    rows.push(row);
  }
  return { rows, truncated };
}

export interface ArchiveEntryDescriptor {
  name: string;
  size: number;
  mime: string;
  kind: "image" | "document" | "style" | "font" | "metadata";
}

export interface EpubChapterItem {
  id: string;
  title: string;
  entryPath: string;
}

export interface EpubManifestSummary {
  title: string;
  creator: string;
  chapters: EpubChapterItem[];
}

export function resolveEpubRelativePath(baseEntryPath: string, relativeHref: string): string {
  const cleanedHref = decodeURIComponent(relativeHref.split("#")[0].split("?")[0]).replace(/\\/g, "/");
  if (!cleanedHref) return "";
  const baseParts = baseEntryPath.replace(/\\/g, "/").split("/");
  baseParts.pop();
  const combined = cleanedHref.startsWith("/")
    ? cleanedHref.slice(1).split("/")
    : [...baseParts, ...cleanedHref.split("/")];
  const resolved: string[] = [];
  for (const part of combined) {
    if (!part || part === ".") continue;
    if (part === "..") {
      resolved.pop();
    } else {
      resolved.push(part);
    }
  }
  return resolved.join("/");
}

export function parseEpubContainerOpfPath(containerXml: string): string {
  const match = containerXml.match(/full-path\s*=\s*["']([^"']+)["']/i);
  return match ? match[1].replace(/^\/+/, "") : "";
}

function readXmlAttr(tag: string, attrName: string): string {
  const regex = new RegExp(`\\b${attrName}\\s*=\\s*(?:"([^"]*)"|'([^']*)')`, "i");
  const match = tag.match(regex);
  return match ? (match[1] ?? match[2] ?? "") : "";
}

function stripXmlTags(input: string): string {
  return input
    .replace(/<[^>]+>/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\s+/g, " ")
    .trim();
}

export function parseEpubNcxTitles(ncxXml: string, ncxEntryPath: string): Map<string, string> {
  const map = new Map<string, string>();
  const navPointRegex = /<navPoint\b[\s\S]*?<navLabel\b[\s\S]*?<text\b[^>]*>([\s\S]*?)<\/text>[\s\S]*?<content\b([^>]+)\/?>/gi;
  for (const match of ncxXml.matchAll(navPointRegex)) {
    const label = stripXmlTags(match[1] ?? "");
    const src = readXmlAttr(match[2] ?? "", "src");
    if (!label || !src) continue;
    const resolved = resolveEpubRelativePath(ncxEntryPath, src);
    if (resolved && !map.has(resolved)) map.set(resolved, label);
  }
  return map;
}

export function parseEpubOpf(
  opfXml: string,
  opfEntryPath: string,
  availableEntries: ArchiveEntryDescriptor[],
  ncxTitles?: Map<string, string>,
): EpubManifestSummary {
  const availableSet = new Set(availableEntries.map((e) => e.name));
  const titleMatch = opfXml.match(/<dc:title\b[^>]*>([\s\S]*?)<\/dc:title>/i);
  const creatorMatch = opfXml.match(/<dc:creator\b[^>]*>([\s\S]*?)<\/dc:creator>/i);
  const title = titleMatch ? stripXmlTags(titleMatch[1]) : "";
  const creator = creatorMatch ? stripXmlTags(creatorMatch[1]) : "";

  const manifestById = new Map<string, { href: string; mediaType: string }>();
  for (const match of opfXml.matchAll(/<item\b([^>]+)\/?>/gi)) {
    const attrs = match[1] ?? "";
    const id = readXmlAttr(attrs, "id");
    const href = readXmlAttr(attrs, "href");
    const mediaType = readXmlAttr(attrs, "media-type");
    if (id && href) manifestById.set(id, { href, mediaType });
  }

  const chapters: EpubChapterItem[] = [];
  for (const match of opfXml.matchAll(/<itemref\b([^>]+)\/?>/gi)) {
    const idref = readXmlAttr(match[1] ?? "", "idref");
    const item = manifestById.get(idref);
    if (!item) continue;
    const entryPath = resolveEpubRelativePath(opfEntryPath, item.href);
    if (!entryPath || !availableSet.has(entryPath)) continue;
    const baseName = entryPath.split("/").pop()?.replace(/\.(xhtml|html|htm)$/i, "") || `第 ${chapters.length + 1} 章`;
    chapters.push({
      id: idref,
      title: ncxTitles?.get(entryPath) || baseName,
      entryPath,
    });
  }

  if (chapters.length === 0) {
    const docs = availableEntries.filter((e) => e.kind === "document");
    docs.forEach((doc, idx) => {
      const baseName = doc.name.split("/").pop()?.replace(/\.(xhtml|html|htm|txt|md)$/i, "") || `第 ${idx + 1} 节`;
      chapters.push({
        id: `doc-${idx}`,
        title: ncxTitles?.get(doc.name) || baseName,
        entryPath: doc.name,
      });
    });
  }

  return { title, creator, chapters };
}

export function extractEpubBodyAndRewriteImages(
  rawXhtml: string,
  chapterEntryPath: string,
  buildEntryUrl: (entryName: string) => string,
): string {
  const bodyMatch = rawXhtml.match(/<body\b[^>]*>([\s\S]*?)<\/body>/i);
  const content = bodyMatch ? bodyMatch[1] : rawXhtml;
  // Strip script/style/iframe/object/embed tags before DOMPurify as defense-in-depth
  const stripped = content
    .replace(/<(script|style|iframe|object|embed|link|meta)\b[\s\S]*?<\/\1>/gi, "")
    .replace(/<(script|style|iframe|object|embed|link|meta)\b[^>]*\/?>/gi, "");

  return stripped.replace(
    /(<img\b[^>]*?\bsrc\s*=\s*)(["'])([^"']+)\2/gi,
    (_m, prefix: string, quote: string, src: string) => {
      if (/^(https?:|data:|javascript:|vbscript:)/i.test(src.trim())) {
        return `${prefix}${quote}${quote}`;
      }
      const resolved = resolveEpubRelativePath(chapterEntryPath, src);
      if (!resolved) return `${prefix}${quote}${quote}`;
      return `${prefix}${quote}${escapeHtml(buildEntryUrl(resolved))}${quote}`;
    },
  );
}

export function encodeComicLocator(pageIndex: number, mode: "single" | "strip"): string {
  const safeIndex = Math.max(0, Math.trunc(pageIndex));
  return `comic:${mode}:${safeIndex}`;
}

export function parseComicLocator(locator: string): { pageIndex: number; mode?: "single" | "strip" } {
  const match = locator.match(/^comic:(single|strip):(\d+)$/);
  if (match) {
    return { mode: match[1] as "single" | "strip", pageIndex: Number(match[2]) };
  }
  const legacy = locator.match(/^page:(\d+)$/);
  if (legacy) return { pageIndex: Number(legacy[1]) };
  return { pageIndex: 0 };
}

export function encodeEpubLocator(chapterIndex: number, scrollRatio = 0): string {
  const safeIdx = Math.max(0, Math.trunc(chapterIndex));
  const clamped = Math.max(0, Math.min(1, Number.isFinite(scrollRatio) ? scrollRatio : 0));
  return `epub:${safeIdx}:${Math.round(clamped * 100)}`;
}

export function parseEpubLocator(locator: string): { chapterIndex: number; scrollRatio: number } {
  const match = locator.match(/^epub:(\d+)(?::(\d+))?$/);
  if (match) {
    return {
      chapterIndex: Number(match[1]),
      scrollRatio: match[2] ? Math.min(1, Number(match[2]) / 100) : 0,
    };
  }
  return { chapterIndex: 0, scrollRatio: 0 };
}

export function computeReadingPercent(currentIndex: number, total: number): number {
  if (!Number.isFinite(total) || total <= 0) return 0;
  if (total === 1) return 100;
  const clamped = Math.max(0, Math.min(total - 1, currentIndex));
  return Math.round(((clamped + 1) / total) * 1000) / 10;
}
