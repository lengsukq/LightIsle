package server

import (
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

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
