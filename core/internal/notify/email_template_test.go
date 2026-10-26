package notify

import (
	"bytes"
	"io"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"strings"
	"testing"
)

func mailParts(t *testing.T, event Event) map[string]string {
	t.Helper()
	content, err := buildEmailMessage(Config{SMTPFrom: "a@example.com", SMTPTo: "b@example.com"}, event)
	if err != nil {
		t.Fatal(err)
	}
	head, body, found := bytes.Cut(content, []byte("\r\n\r\n"))
	if !found {
		t.Fatal("missing email MIME header")
	}
	if !bytes.Contains(head, []byte("multipart/alternative")) {
		t.Fatalf("wrong MIME content-type: %s", head)
	}
	header := strings.Split(string(head), "\r\n")
	var contentType string
	for _, h := range header {
		if strings.HasPrefix(h, "Content-Type: ") {
			contentType = strings.TrimPrefix(h, "Content-Type: ")
		}
	}
	_, params, err := mime.ParseMediaType(contentType)
	if err != nil {
		t.Fatal(err)
	}
	reader := multipart.NewReader(bytes.NewReader(body), params["boundary"])
	parts := map[string]string{}
	for {
		part, err := reader.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		var source io.Reader = part
		if part.Header.Get("Content-Transfer-Encoding") == "quoted-printable" {
			source = quotedprintable.NewReader(part)
		}
		text, err := io.ReadAll(source)
		if err != nil {
			t.Fatal(err)
		}
		kind, _, err := mime.ParseMediaType(part.Header.Get("Content-Type"))
		if err != nil {
			t.Fatal(err)
		}
		parts[kind] = string(text)
	}
	return parts
}
func TestDefaultLightIsleBrandedBorderedMail(t *testing.T) {
	event := Event{Title: "通知 <标题>", Body: "hello <world>", Severity: "info"}
	parts := mailParts(t, event)
	html := parts["text/html"]
	if !strings.Contains(html, "LIGHTISLE") || !strings.Contains(html, "border:1px solid #e0e7f0") || !strings.Contains(html, "通知 &lt;标题&gt;") || !strings.Contains(html, "hello &lt;world&gt;") {
		t.Fatalf("missing branded border or escaped fields: %s", html)
	}
	if parts["text/plain"] != "hello <world>" {
		t.Fatalf("plain fallback: %s", parts["text/plain"])
	}
}
func TestContentAndFullOverrideMail(t *testing.T) {
	fragment := "<div>Agent 自定义内容</div>"
	content := mailParts(t, Event{Title: "日常", Body: "summary", EmailMode: "content", EmailHTML: fragment})
	if !strings.Contains(content["text/html"], fragment) || !strings.Contains(content["text/html"], "LIGHTISLE") {
		t.Fatal("content must use branded shell")
	}
	full := "<!doctype html><html><body>我的完整模板</body></html>"
	custom := mailParts(t, Event{Title: "日常", Body: "summary", EmailMode: "custom", EmailHTML: full})
	if custom["text/html"] != full {
		t.Fatalf("custom mail wrapped or rewritten: %s", custom["text/html"])
	}
	if custom["text/plain"] != "summary" {
		t.Fatal("custom mode must preserve plain-text fallback")
	}
}
