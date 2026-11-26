import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { parse } from "@vue/compiler-sfc";
import {
  buildArchiveEntryQuery,
  classifyFileReader,
  computeReadingPercent,
  computeSheetMaxColCount,
  encodeComicLocator,
  encodeEpubLocator,
  extractEpubBodyAndRewriteImages,
  extractRawJsonIntegerField,
  OFFICE_MAX_PREVIEW_BYTES,
  parseComicLocator,
  parseCsvRows,
  parseEpubContainerOpfPath,
  parseEpubLocator,
  parseEpubNcxTitles,
  parseEpubOpf,
  parseTextJsonWithMtimeToken,
  renderMarkdownToRawHtml,
  resolveEpubChapterLink,
  resolveEpubRelativePath,
  TEXT_EDIT_MAX_BYTES,
} from "../src/features/files/fileReaderSupport.ts";

test("classifyFileReader routes markdown, text, office and comic/epub formats accurately", () => {
  assert.equal(classifyFileReader("README.md"), "markdown");
  assert.equal(classifyFileReader("notes.markdown"), "markdown");
  assert.equal(classifyFileReader("config.yaml"), "text");
  assert.equal(classifyFileReader("server.go"), "text");
  assert.equal(classifyFileReader("report.docx"), "docx");
  assert.equal(classifyFileReader("budget.xlsx"), "xlsx");
  assert.equal(classifyFileReader("table.csv"), "csv");
  assert.equal(classifyFileReader("vol01.cbz"), "comic");
  assert.equal(classifyFileReader("book.epub"), "epub");
  assert.equal(classifyFileReader("comic_bundle.zip"), "zip");
  assert.equal(classifyFileReader("photo.jpg"), "none");
  assert.equal(classifyFileReader("manual.pdf"), "none");
  assert.equal(OFFICE_MAX_PREVIEW_BYTES, 20 * 1024 * 1024);
  assert.equal(TEXT_EDIT_MAX_BYTES, 2 * 1024 * 1024);
});

test("renderMarkdownToRawHtml renders headings, lists, tables, code and neutralizes unsafe URLs/HTML", () => {
  const md = [
    "# 家庭备忘录",
    "",
    "- [x] 买牛奶",
    "- [ ] 检查硬盘",
    "",
    "| 名称 | 数量 |",
    "| --- | --- |",
    "| 苹果 | 6 |",
    "",
    "[安全链接](https://example.com) [危险脚本](javascript:alert(1))",
    "<script>alert('xss')</script>",
    "",
    "```ts",
    "const x = 1 < 2;",
    "```",
  ].join("\n");

  const html = renderMarkdownToRawHtml(md);
  assert.match(html, /<h1>家庭备忘录<\/h1>/);
  assert.match(html, /☑/);
  assert.match(html, /<table><thead><tr><th>名称<\/th><th>数量<\/th><\/tr><\/thead>/);
  assert.match(html, /href="https:\/\/example\.com"/);
  assert.doesNotMatch(html, /javascript:alert/);
  assert.doesNotMatch(html, /<script>/);
  assert.match(html, /&lt;script&gt;alert/);
  assert.match(html, /const x = 1 &lt; 2;/);
});

test("parseCsvRows handles BOM, quoted commas/newlines, escaped quotes and row truncation", () => {
  const csv = '\uFEFFName,Note,Count\r\n"Alice, A","Line 1\nLine ""2""",42\r\nBob,Simple,7\r\n';
  const parsed = parseCsvRows(csv, 10);
  assert.equal(parsed.truncated, false);
  assert.deepEqual(parsed.rows, [
    ["Name", "Note", "Count"],
    ["Alice, A", 'Line 1\nLine "2"', "42"],
    ["Bob", "Simple", "7"],
  ]);

  const capped = parseCsvRows("a,b\n1,2\n3,4\n5,6\n", 2);
  assert.equal(capped.truncated, true);
  assert.equal(capped.rows.length, 2);
});

test("EPUB container, OPF, NCX parsing and safe chapter image rewriting", () => {
  const containerXml = `<?xml version="1.0"?><container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>`;
  const opfPath = parseEpubContainerOpfPath(containerXml);
  assert.equal(opfPath, "OEBPS/content.opf");

  const ncxXml = `
    <ncx>
      <navMap>
        <navPoint id="p1"><navLabel><text>第一章 初见</text></navLabel><content src="text/ch1.xhtml#top"/></navPoint>
        <navPoint id="p2"><navLabel><text>第二章 启程</text></navLabel><content src="text/ch2.xhtml"/></navPoint>
      </navMap>
    </ncx>`;
  const ncxTitles = parseEpubNcxTitles(ncxXml, "OEBPS/toc.ncx");
  assert.equal(ncxTitles.get("OEBPS/text/ch1.xhtml"), "第一章 初见");

  const opfXml = `
    <package>
      <metadata><dc:title>轻屿漫记</dc:title><dc:creator>家庭作者</dc:creator></metadata>
      <manifest>
        <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
        <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
      </manifest>
      <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
    </package>`;
  const entries = [
    { name: "OEBPS/text/ch1.xhtml", size: 120, mime: "application/xhtml+xml", kind: "document" },
    { name: "OEBPS/text/ch2.xhtml", size: 140, mime: "application/xhtml+xml", kind: "document" },
    { name: "OEBPS/images/cover.jpg", size: 500, mime: "image/jpeg", kind: "image" },
  ];
  const summary = parseEpubOpf(opfXml, opfPath, entries, ncxTitles);
  assert.equal(summary.title, "轻屿漫记");
  assert.equal(summary.creator, "家庭作者");
  assert.equal(summary.chapters.length, 2);
  assert.equal(summary.chapters[0].title, "第一章 初见");
  assert.equal(resolveEpubRelativePath("OEBPS/text/ch1.xhtml", "../images/cover.jpg"), "OEBPS/images/cover.jpg");

  const chapterHtml = `<html><body><script>evil()</script><p>正文</p><img src="../images/cover.jpg"/><img src="https://tracker.invalid/x.png"/></body></html>`;
  const rewritten = extractEpubBodyAndRewriteImages(
    chapterHtml,
    "OEBPS/text/ch1.xhtml",
    (entry) => `/api/v2/roots/r1/files/archive-entry?entry=${encodeURIComponent(entry)}`,
  );
  assert.doesNotMatch(rewritten, /<script>/);
  assert.match(rewritten, /OEBPS%2Fimages%2Fcover\.jpg/);
  assert.doesNotMatch(rewritten, /tracker\.invalid/);
});

test("comic and EPUB reading progress locators round-trip cleanly", () => {
  const comicLoc = encodeComicLocator(14, "strip");
  assert.equal(comicLoc, "comic:strip:14");
  assert.deepEqual(parseComicLocator(comicLoc), { mode: "strip", pageIndex: 14 });

  const epubLoc = encodeEpubLocator(3, 0.467);
  assert.equal(epubLoc, "epub:3:47");
  assert.deepEqual(parseEpubLocator(epubLoc), { chapterIndex: 3, scrollRatio: 0.47 });

  assert.equal(computeReadingPercent(0, 10), 10);
  assert.equal(computeReadingPercent(9, 10), 100);
  assert.equal(computeReadingPercent(0, 1), 100);
});

test("reader SFCs lazy-load mammoth, dompurify and read-excel-file via dynamic import() and stay under 800 lines", () => {
  const officeSrc = readFileSync(new URL("../src/features/files/FileOfficePreviewModal.vue", import.meta.url), "utf8");
  const mdSrc = readFileSync(new URL("../src/features/files/FileMarkdownEditorModal.vue", import.meta.url), "utf8");
  const comicSrc = readFileSync(new URL("../src/features/files/FileComicEpubReaderModal.vue", import.meta.url), "utf8");

  for (const [name, src] of [
    ["FileOfficePreviewModal.vue", officeSrc],
    ["FileMarkdownEditorModal.vue", mdSrc],
    ["FileComicEpubReaderModal.vue", comicSrc],
  ]) {
    const parsed = parse(src, { filename: name });
    assert.deepEqual(parsed.errors, [], `${name} should parse cleanly`);
    assert.ok(src.split("\n").length < 800, `${name} must be strictly < 800 lines`);
    assert.doesNotMatch(src, /<select[\s>]/i);
    assert.doesNotMatch(src, /window\.confirm\(/);
    assert.doesNotMatch(src, /:deep\(/);
  }

  assert.match(officeSrc, /import\(["']mammoth["']\)/);
  assert.match(officeSrc, /import\(["']dompurify["']\)/);
  assert.match(officeSrc, /import\(["']read-excel-file\/browser["']\)/);
  assert.doesNotMatch(officeSrc, /^import\s+.*from\s+["'](mammoth|dompurify|read-excel-file)/m);
  assert.match(mdSrc, /import\(["']dompurify["']\)/);
  assert.doesNotMatch(mdSrc, /^import\s+.*from\s+["']dompurify/m);
  assert.match(comicSrc, /import\(["']dompurify["']\)/);
  assert.doesNotMatch(comicSrc, /^import\s+.*from\s+["']dompurify/m);

  // Guard against invalid color-mix() gradient args and ensure global v-html stylesheet exists
  assert.doesNotMatch(mdSrc, /color-mix\([^)]*--fluid-card-item-fill/);
  assert.match(mdSrc, /expectedMtimeToken/);
  assert.match(mdSrc, /file_modified_conflict/);
  assert.match(comicSrc, /<template #suffix>/);
  assert.match(comicSrc, /\.epub-reader-pane\.theme-sepia\s*\{[\s\S]*--text-primary:/);
  assert.match(comicSrc, /\.epub-reader-pane\.theme-dark\s*\{[\s\S]*--text-primary:/);

  const mainTs = readFileSync(new URL("../src/main.ts", import.meta.url), "utf8");
  assert.match(mainTs, /FileReadersContent\.css/);
  const contentCss = readFileSync(new URL("../src/features/files/FileReadersContent.css", import.meta.url), "utf8");
  assert.doesNotMatch(contentCss, /:deep\(/);
  assert.match(contentCss, /\.md-preview-surface\s+pre/);
  assert.match(contentCss, /\.office-docx-sheet\s+img/);
  assert.match(contentCss, /\.epub-chapter-body\s+img/);
});

test("parseTextJsonWithMtimeToken preserves exact 19-digit nanosecond timestamps without Number truncation", () => {
  const exactNano = "1795601234567890123";
  assert.notEqual(String(Number(exactNano)), exactNano, "19-digit Unix nanos lose precision in JS Number");

  // 1) Backend returns explicit string mtimeToken
  const withToken = JSON.stringify({
    path: "notes.md",
    content: 'example "mtimeUnixNano": 999 inside content',
    mtimeToken: exactNano,
    mtimeUnixNano: 1795601234567890200,
  });
  const res1 = parseTextJsonWithMtimeToken(withToken);
  assert.equal(res1.mtimeToken, exactNano);

  // 2) Older backend without mtimeToken: extract raw integer digits outside content string
  const withoutToken = `{"path":"src.json","content":"{\\"mtimeUnixNano\\": 12345}","size":42,"mtimeUnixNano":${exactNano},"canWrite":true}`;
  assert.equal(extractRawJsonIntegerField(withoutToken, "mtimeUnixNano"), exactNano);
  const res2 = parseTextJsonWithMtimeToken(withoutToken);
  assert.equal(res2.mtimeToken, exactNano);

  // 3) 409 conflict currentMtimeUnixNano extraction
  const conflictRaw = `{"error":"file_modified_conflict","currentMtimeUnixNano":${exactNano},"currentSize":88}`;
  const res3 = parseTextJsonWithMtimeToken(conflictRaw, "currentMtimeToken", "currentMtimeUnixNano");
  assert.equal(res3.mtimeToken, exactNano);
});

test("computeSheetMaxColCount handles variable-width XLSX/CSV rows without truncating trailing columns", () => {
  assert.equal(computeSheetMaxColCount([]), 0);
  assert.equal(
    computeSheetMaxColCount([
      ["年度预算表"],
      ["项目", "Q1", "Q2", "Q3", "Q4"],
      ["水电", "120", "130"],
    ]),
    5,
  );
});

test("EPUB reader safely handles malformed percent paths, SVG cover images, chapter links and archive index params", () => {
  assert.equal(resolveEpubRelativePath("OEBPS/text/ch1.xhtml", "../images/100%off.jpg"), "OEBPS/images/100%off.jpg");

  const svgCover = `<html><body><svg viewBox="0 0 600 800"><image xlink:href="../images/cover%2001.jpg" width="600" height="800"/><image href="pic.png"/></svg></body></html>`;
  const rewritten = extractEpubBodyAndRewriteImages(
    svgCover,
    "OEBPS/text/cover.xhtml",
    (entry) => `/api/v2/files/archive-entry?entry=${encodeURIComponent(entry)}`,
  );
  assert.match(rewritten, /OEBPS%2Fimages%2Fcover%2001\.jpg/);
  assert.match(rewritten, /OEBPS%2Ftext%2Fpic\.png/);

  const chapters = [
    { id: "c1", title: "一", entryPath: "OEBPS/text/ch1.xhtml" },
    { id: "c2", title: "二", entryPath: "OEBPS/text/ch2.xhtml" },
  ];
  assert.deepEqual(resolveEpubChapterLink("OEBPS/text/ch1.xhtml", "ch2.xhtml#sec-2", chapters), {
    chapterIndex: 1,
    anchorId: "sec-2",
  });
  assert.deepEqual(resolveEpubChapterLink("OEBPS/text/ch1.xhtml", "#footnote-1", chapters), {
    chapterIndex: 0,
    anchorId: "footnote-1",
  });
  assert.equal(resolveEpubChapterLink("OEBPS/text/ch1.xhtml", "https://example.com", chapters), null);

  assert.equal(
    buildArchiveEntryQuery("manga.cbz", { name: "001.jpg", index: 7 }),
    "path=manga.cbz&entry=001.jpg&index=7",
  );
  assert.equal(buildArchiveEntryQuery("manga.cbz", "001.jpg"), "path=manga.cbz&entry=001.jpg");
});
