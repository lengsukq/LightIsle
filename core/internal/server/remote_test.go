package server

import (
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

func TestExplicitLocalHTTPListenerAndShutdown(t *testing.T) {
	if privateIP() == nil {
		t.Skip("No usable private IPv4 interface is available in this test environment")
	}
	dir := t.TempDir()
	store, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Setup("admin", "CorrectHorseBatteryStaple123"); err != nil {
		t.Fatal(err)
	}

	handler := http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path != "/api/v2/auth/status" {
			http.NotFound(w, req)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "configured")
	})
	remote, err := NewRemoteHTTP(handler, store)
	if err != nil {
		t.Fatal(err)
	}
	defer remote.Stop()
	if !strings.HasPrefix(remote.URL, "http://") || remote.Fingerprint != "" {
		t.Fatalf("HTTP listener must have no TLS fingerprint: %s, %q", remote.URL, remote.Fingerprint)
	}
	client := &http.Client{
		Timeout:   2 * time.Second,
		Transport: &http.Transport{Proxy: nil},
	}
	response, err := client.Get(remote.URL + "/api/v2/auth/status")
	if err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil || response.StatusCode != http.StatusOK || string(body) != "configured" {
		t.Fatalf("HTTP request failed: status=%d body=%q err=%v", response.StatusCode, body, err)
	}
	remote.Stop()
	if _, err := client.Get(remote.URL + "/api/v2/auth/status"); err == nil {
		t.Fatal("HTTP listener must stop accepting traffic once explicitly disabled")
	}
}

func TestCertificatePersistsFingerprintAndIPSubjectAlternativeName(t *testing.T) {
	dir := t.TempDir()
	ip := net.ParseIP("192.168.10.22")
	first, fingerprint, err := certificate(dir, ip)
	if err != nil {
		t.Fatal(err)
	}
	if len(first.Certificate) == 0 {
		t.Fatal("certificate chain is empty")
	}
	parsed, err := x509.ParseCertificate(first.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	if len(parsed.IPAddresses) != 1 || !parsed.IPAddresses[0].Equal(ip) {
		t.Fatalf("certificate IP SANs = %v", parsed.IPAddresses)
	}
	if !time.Now().Before(parsed.NotAfter) {
		t.Fatalf("certificate already expired at %s", parsed.NotAfter)
	}
	checksum := sha256.Sum256(first.Certificate[0])
	if fingerprint != hex.EncodeToString(checksum[:]) {
		t.Fatalf("fingerprint %q does not match certificate", fingerprint)
	}

	second, secondFingerprint, err := certificate(dir, ip)
	if err != nil {
		t.Fatal(err)
	}
	if secondFingerprint != fingerprint || string(second.Certificate[0]) != string(first.Certificate[0]) {
		t.Fatal("matching certificate was not reused")
	}

	_, changedFingerprint, err := certificate(dir, net.ParseIP("192.168.10.23"))
	if err != nil {
		t.Fatal(err)
	}
	if changedFingerprint == fingerprint {
		t.Fatal("certificate was not rotated when the LAN IP changed")
	}
	if info, err := os.Stat(filepath.Join(dir, "remote-key.pem")); err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("private key permissions = %v, err=%v", info, err)
	}
}
