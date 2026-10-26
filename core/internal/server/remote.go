package server

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

// Remote never listens on 0.0.0.0 or arbitrary public addresses.
// Each explicit "remote on" command is sent only from the local Mac App
// over its private child stdin pipe, not from the remote HTTP API.
type Remote struct {
	srv         *http.Server
	ln          net.Listener
	URL         string
	Fingerprint string
}

func (r *Remote) Stop() {
	if r == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = r.srv.Shutdown(ctx)
	// Shutdown can time out while a client is streaming. Close all active
	// connections so turning remote access off actually revokes the listener.
	_ = r.srv.Close()
	_ = r.ln.Close()
}
func privateIP() net.IP {
	faces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	// Prefer the primary macOS physical interface. Virtual adapters, VPNs and
	// Docker bridges often have RFC1918 addresses not reachable by Android.
	var fallback net.IP
	for _, face := range faces {
		if face.Flags&net.FlagUp == 0 || face.Flags&net.FlagLoopback != 0 {
			continue
		}
		if strings.HasPrefix(face.Name, "utun") || strings.HasPrefix(face.Name, "bridge") ||
			strings.HasPrefix(face.Name, "vnic") || strings.HasPrefix(face.Name, "awdl") {
			continue
		}
		addrs, _ := face.Addrs()
		for _, addr := range addrs {
			var ip net.IP
			switch a := addr.(type) {
			case *net.IPNet:
				ip = a.IP
			case *net.IPAddr:
				ip = a.IP
			}
			ip = ip.To4()
			if ip == nil {
				continue
			}
			if ip[0] == 10 || ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31 ||
				ip[0] == 192 && ip[1] == 168 {
				if face.Name == "en0" || face.Name == "en1" {
					return ip
				}
				if fallback == nil {
					fallback = ip
				}
			}
		}
	}
	return fallback
}
func NewRemote(handler http.Handler, store *auth.Store, dir string) (*Remote, error) {
	configured, err := store.Configured()
	if err != nil {
		return nil, err
	}
	if !configured {
		return nil, errors.New("请先完成本机管理员初始化")
	}
	ip := privateIP()
	if ip == nil {
		return nil, errors.New("没有可用的局域网私有 IPv4 地址")
	}
	cert, fingerprint, err := certificate(dir, ip)
	if err != nil {
		return nil, err
	}
	ln, err := net.Listen("tcp4", net.JoinHostPort(ip.String(), "0"))
	if err != nil {
		return nil, err
	}
	srv := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second}
	tlsListener := tls.NewListener(ln, &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS13,
	})
	r := &Remote{
		srv: srv, ln: tlsListener,
		URL:         fmt.Sprintf("https://%s", tlsListener.Addr().String()),
		Fingerprint: fingerprint,
	}
	go func() { _ = srv.Serve(tlsListener) }()
	return r, nil
}

// NewRemoteHTTP enables explicit owner-approved LAN HTTP. The only listener
// is bound to the selected private IPv4 interface, never all/public networks.
// The Mac UI must warn that credentials and files are not encrypted.
func NewRemoteHTTP(handler http.Handler, store *auth.Store) (*Remote, error) {
	configured, err := store.Configured()
	if err != nil {
		return nil, err
	}
	if !configured {
		return nil, errors.New("请先完成本机管理员初始化")
	}
	ip := privateIP()
	if ip == nil {
		return nil, errors.New("没有可用的局域网私有 IPv4 地址")
	}
	ln, err := net.Listen("tcp4", net.JoinHostPort(ip.String(), "0"))
	if err != nil {
		return nil, err
	}
	srv := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second}
	remote := &Remote{srv: srv, ln: ln, URL: "http://" + ln.Addr().String()}
	go func() { _ = srv.Serve(ln) }()
	return remote, nil
}

func certificate(dir string, ip net.IP) (tls.Certificate, string, error) {
	keyPath := filepath.Join(dir, "remote-key.pem")
	certPath := filepath.Join(dir, "remote-cert.pem")
	if data, keyErr := os.ReadFile(keyPath); keyErr == nil {
		if certBytes, certErr := os.ReadFile(certPath); certErr == nil {
			if pair, err := tls.X509KeyPair(certBytes, data); err == nil {
				if x, err := x509.ParseCertificate(pair.Certificate[0]); err == nil &&
					time.Now().After(x.NotBefore) && time.Now().Before(x.NotAfter.Add(-24*time.Hour)) {
					for _, a := range x.IPAddresses {
						if a.Equal(ip) {
							sum := sha256.Sum256(x.Raw)
							return pair, hex.EncodeToString(sum[:]), nil
						}
					}
				}
			}
		}
	}
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return tls.Certificate{}, "", err
	}
	now := time.Now()
	template := x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: "LightIsle Local NAS"},
		NotBefore:    now.Add(-time.Hour), NotAfter: now.Add(90 * 24 * time.Hour),
		IPAddresses:           []net.IP{ip},
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, &template, &template, &privateKey.PublicKey, privateKey)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	keyDer, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDer})
	if err := os.MkdirAll(dir, 0700); err != nil {
		return tls.Certificate{}, "", err
	}
	if err := os.WriteFile(keyPath, keyPEM, 0600); err != nil {
		return tls.Certificate{}, "", err
	}
	if err := os.WriteFile(certPath, certPEM, 0600); err != nil {
		return tls.Certificate{}, "", err
	}
	pair, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	sum := sha256.Sum256(der)
	return pair, hex.EncodeToString(sum[:]), nil
}
