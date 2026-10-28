package server

import (
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
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
	// Reserve the SAME port on loopback as the Core while LAN is enabled.
	// The private-IP listener must coexist rather than allocating a new port.
	loopback, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer loopback.Close()
	port := loopback.Addr().(*net.TCPAddr).Port
	remote, err := NewRemoteHTTP(handler, store, port)
	if err != nil {
		t.Fatal(err)
	}
	defer remote.Stop()
	if !strings.HasPrefix(remote.URL, "http://") || remote.Fingerprint != "" {
		t.Fatalf("HTTP listener must have no TLS fingerprint: %s, %q", remote.URL, remote.Fingerprint)
	}
	if want := ":" + strconv.Itoa(port); !strings.HasSuffix(remote.URL, want) {
		t.Fatalf("LAN must share the Core port %d, got %q", port, remote.URL)
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

func TestTLSListenerUsesSamePortAsLoopbackAndValidatesCertificate(t *testing.T) {
	if privateIP() == nil {
		t.Skip("No usable private IPv4 interface")
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
	loopback, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer loopback.Close()
	port := loopback.Addr().(*net.TCPAddr).Port
	remote, err := NewRemote(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "secure NAS")
	}), store, dir, port)
	if err != nil {
		t.Fatal(err)
	}
	defer remote.Stop()
	if !strings.HasSuffix(remote.URL, ":"+strconv.Itoa(port)) || !strings.HasPrefix(remote.URL, "https://") {
		t.Fatalf("TLS LAN listener must use Core port %d, got %q", port, remote.URL)
	}
	certBytes, err := os.ReadFile(filepath.Join(dir, "remote-cert.pem"))
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(certBytes) {
		t.Fatal("invalid LAN certificate")
	}
	client := &http.Client{Timeout: 2 * time.Second, Transport: &http.Transport{
		Proxy: nil, TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS13},
	}}
	response, err := client.Get(remote.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	contents, err := io.ReadAll(response.Body)
	if err != nil || string(contents) != "secure NAS" {
		t.Fatalf("TLS response: %q %v", contents, err)
	}
	if response.TLS == nil || len(response.TLS.PeerCertificates) == 0 {
		t.Fatal("not TLS")
	}
	thumbprint := sha256.Sum256(response.TLS.PeerCertificates[0].Raw)
	if remote.Fingerprint != hex.EncodeToString(thumbprint[:]) {
		t.Fatal("invalid advertised certificate fingerprint")
	}
}

func TestRemoteDoesNotFallBackToRandomPortWhenConfiguredPortBusy(t *testing.T) {
	if privateIP() == nil {
		t.Skip("No private IPv4 interface")
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
	busy, err := net.Listen("tcp4", net.JoinHostPort(privateIP().String(), "0"))
	if err != nil {
		t.Fatal(err)
	}
	defer busy.Close()
	port := busy.Addr().(*net.TCPAddr).Port
	if _, err := NewRemoteHTTP(http.NotFoundHandler(), store, port); err == nil {
		t.Fatal("HTTP LAN port is occupied; must fail, not pick another")
	}
	if _, err := NewRemote(http.NotFoundHandler(), store, dir, port); err == nil {
		t.Fatal("HTTPS LAN port is occupied; must fail, not pick another")
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
