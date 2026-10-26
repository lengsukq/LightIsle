package notify

import (
	"bytes"
	"fmt"
	"html"
	"io"
	"mime/multipart"
	"mime/quotedprintable"
	"net/textproto"
	"strings"
)

// emailHTML uses the responsive LightIsle frame by default; content mode
// replaces only its central body and custom mode replaces the whole document.
// Custom content is managed locally by the NAS administrator, not Web clients.
func emailHTML(event Event) string {
	if event.EmailMode == "custom" && event.EmailHTML != "" {
		return event.EmailHTML
	}
	body := strings.ReplaceAll(html.EscapeString(event.Body), "\n", "<br>")
	if event.EmailMode == "content" && event.EmailHTML != "" {
		body = event.EmailHTML
	}
	accent := "#5e83d6"
	status := "系统通知"
	switch event.Severity {
	case "warning", "error":
		accent = "#cc7b50"
		status = "需要关注"
	case "info":
		status = "运行消息"
	}
	return fmt.Sprintf(`<!doctype html>
<html lang="zh-CN"><head><meta charset="UTF-8"/><meta name="viewport" content="width=device-width, initial-scale=1"/></head>
<body style="margin:0;padding:28px 12px;background:#f4f7fb;font-family:-apple-system,BlinkMacSystemFont,'PingFang SC','Segoe UI',sans-serif;color:#27334a">
<table role="presentation" width="100%%" cellpadding="0" cellspacing="0" style="border-collapse:collapse"><tr><td align="center">
<table role="presentation" width="100%%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border:1px solid #e0e7f0;border-radius:18px;overflow:hidden;border-collapse:separate">
<tr><td style="padding:28px 32px 24px;border-bottom:1px solid #e9edf3;background:#fbfcff">
<div style="font-size:13px;font-weight:700;letter-spacing:.08em;color:#6485be">LIGHTISLE <span style="font-weight:400;color:#9eacc0">/ 轻屿</span></div>
<h1 style="font-size:22px;line-height:1.4;font-weight:650;margin:14px 0 8px;color:#283750">%s</h1>
<div style="display:inline-block;border-radius:100px;background:#f0f4fb;color:%s;font-size:12px;padding:6px 11px">%s</div>
</td></tr>
<tr><td style="padding:30px 32px"><div style="font-size:14px;line-height:1.85;color:#46556e;overflow-wrap:anywhere">%s</div></td></tr>
<tr><td style="padding:18px 32px;border-top:1px solid #e9edf3;font-size:12px;line-height:1.6;color:#8d99ac">由你自己的 LightIsle 家庭设备发送 · 这是一封自动通知邮件</td></tr>
</table></td></tr></table></body></html>`,
		html.EscapeString(event.Title), accent, html.EscapeString(status), body)
}

func encodeMailPart(writer *multipart.Writer, contentType, content string) error {
	part, err := writer.CreatePart(textproto.MIMEHeader{
		"Content-Type":              []string{contentType + "; charset=UTF-8"},
		"Content-Transfer-Encoding": []string{"quoted-printable"},
	})
	if err != nil {
		return err
	}
	encoded := quotedprintable.NewWriter(part)
	if _, err = io.WriteString(encoded, content); err != nil {
		return err
	}
	return encoded.Close()
}
func buildEmailMessage(cfg Config, event Event) ([]byte, error) {
	var out bytes.Buffer
	writer := multipart.NewWriter(&out)
	subject := event.Title
	if event.EmailSubject != "" {
		subject = event.EmailSubject
	}
	subject = strings.NewReplacer("\r", " ", "\n", " ").Replace(subject)
	recipients := strings.Join(smtpRecipients(cfg.SMTPTo), ", ")
	fmt.Fprintf(&out, "From: %s\r\nTo: %s\r\nSubject: %s\r\nMIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary=%q\r\n\r\n",
		cfg.SMTPFrom, recipients, mimeHeader(subject), writer.Boundary())
	if err := encodeMailPart(writer, "text/plain", event.Body); err != nil {
		return nil, err
	}
	if err := encodeMailPart(writer, "text/html", emailHTML(event)); err != nil {
		return nil, err
	}
	if err := writer.Close(); err != nil {
		return nil, err
	}
	if out.Len() > 160<<10 {
		return nil, fmt.Errorf("notify_email_too_large")
	}
	return out.Bytes(), nil
}
