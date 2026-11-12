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

// Remote never listens on 0.0.0.0 or arbitrary public addresses. The LAN
// listener binds the selected RFC1918 physical interface, and when Tailscale
// is active on the Mac, an optional companion listener binds the private
// 100.64.0.0/10 Tailscale utun address on the exact same port.
type Remote struct {
	srv          *http.Server
	ln           net.Listener
	tailscaleSrv *http.Server
	tailscaleLn  net.Listener
	URL          string
	TailscaleURL string
	Fingerprint  string
}

func (r *Remote) Stop() {
	if r == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if r.tailscaleSrv != nil {
		_ = r.tailscaleSrv.Shutdown(ctx)
		_ = r.tailscaleSrv.Close()
	}
	if r.tailscaleLn != nil {
		_ = r.tailscaleLn.Close()
	}
	_ = r.srv.Shutdown(ctx)
	_ = r.srv.Close()
	_ = r.ln.Close()
}

func privateIP() net.IP {
	faces, err := net.Interfaces()
	if err != nil {
		return nil
	}
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

func NewRemote(handler http.Handler, store *auth.Store, dir string, port int) (*Remote, error) {
	if port < 1 || port > 65535 {
		return nil, errors.New("局域网服务端口无效")
	}
	configured, err := store.Configured()
	if err != nil {
		return nil, err
	}
	if !configured {
		return nil, errors.New("请先完成本机管理员初始化")
	}
	ip := privateIP()
	tsIP, _ := tailscaleIPv4FromInterfaces()
	if ip == nil && tsIP == nil {
		return nil, errors.New("没有可用的局域网或 Tailscale 私有 IPv4 地址")
	}
	primaryIP := ip
	if primaryIP == nil {
		primaryIP = tsIP
	}
	sanIPs := []net.IP{primaryIP}
	if tsIP != nil && !tsIP.Equal(primaryIP) {
		sanIPs = append(sanIPs, tsIP)
	}
	var dnsSANs []string
	if tsIP != nil {
		tsStatus := DetectTailscale(context.Background(), port, true, "")
		if tsStatus.MagicDNS != "" {
			dnsSANs = append(dnsSANs, tsStatus.MagicDNS)
		}
	}
	cert, fingerprint, err := certificateWithSANs(dir, sanIPs, dnsSANs)
	if err != nil {
		return nil, err
	}
	tlsCfg := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS13,
	}
	ln, err := net.Listen("tcp4", net.JoinHostPort(primaryIP.String(), fmt.Sprint(port)))
	if err != nil {
		return nil, fmt.Errorf("无法在局域网地址 %s 上监听统一端口 %d，请检查端口是否被占用：%w", primaryIP.String(), port, err)
	}
	srv := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second}
	tlsListener := tls.NewListener(ln, tlsCfg)
	r := &Remote{
		srv:         srv,
		ln:          tlsListener,
		URL:         fmt.Sprintf("https://%s", tlsListener.Addr().String()),
		Fingerprint: fingerprint,
	}
	if tsIP != nil && tsIP.Equal(primaryIP) {
		r.TailscaleURL = r.URL
	} else if tsIP != nil {
		if tsLn, tsErr := net.Listen("tcp4", net.JoinHostPort(tsIP.String(), fmt.Sprint(port))); tsErr == nil {
			tsTLS := tls.NewListener(tsLn, tlsCfg.Clone())
			tsSrv := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second}
			r.tailscaleLn = tsTLS
			r.tailscaleSrv = tsSrv
			r.TailscaleURL = fmt.Sprintf("https://%s", tsTLS.Addr().String())
			go func() { _ = tsSrv.Serve(tsTLS) }()
		}
	}
	go func() { _ = srv.Serve(tlsListener) }()
	return r, nil
}

// NewRemoteHTTP enables explicit owner-approved LAN HTTP and optional co-bound
// Tailscale private interface HTTP (WireGuard-encrypted over Tailscale).
func NewRemoteHTTP(handler http.Handler, store *auth.Store, port int) (*Remote, error) {
	if port < 1 || port > 65535 {
		return nil, errors.New("局域网服务端口无效")
	}
	configured, err := store.Configured()
	if err != nil {
		return nil, err
	}
	if !configured {
		return nil, errors.New("请先完成本机管理员初始化")
	}
	ip := privateIP()
	tsIP, _ := tailscaleIPv4FromInterfaces()
	if ip == nil && tsIP == nil {
		return nil, errors.New("没有可用的局域网或 Tailscale 私有 IPv4 地址")
	}
	primaryIP := ip
	if primaryIP == nil {
		primaryIP = tsIP
	}
	ln, err := net.Listen("tcp4", net.JoinHostPort(primaryIP.String(), fmt.Sprint(port)))
	if err != nil {
		return nil, fmt.Errorf("无法在局域网地址 %s 上监听统一端口 %d，请检查端口是否被占用：%w", primaryIP.String(), port, err)
	}
	srv := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second}
	remote := &Remote{srv: srv, ln: ln, URL: "http://" + ln.Addr().String()}
	if tsIP != nil && tsIP.Equal(primaryIP) {
		remote.TailscaleURL = remote.URL
	} else if tsIP != nil {
		if tsLn, tsErr := net.Listen("tcp4", net.JoinHostPort(tsIP.String(), fmt.Sprint(port))); tsErr == nil {
			tsSrv := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second}
			remote.tailscaleLn = tsLn
			remote.tailscaleSrv = tsSrv
			remote.TailscaleURL = "http://" + tsLn.Addr().String()
			go func() { _ = tsSrv.Serve(tsLn) }()
		}
	}
	go func() { _ = srv.Serve(ln) }()
	return remote, nil
}

func certificate(dir string, ip net.IP) (tls.Certificate, string, error) {
	return certificateWithSANs(dir, []net.IP{ip}, nil)
}

func certificateWithSANs(dir string, ips []net.IP, dnsNames []string) (tls.Certificate, string, error) {
	keyPath := filepath.Join(dir, "remote-key.pem")
	certPath := filepath.Join(dir, "remote-cert.pem")
	if data, keyErr := os.ReadFile(keyPath); keyErr == nil {
		if certBytes, certErr := os.ReadFile(certPath); certErr == nil {
			if pair, err := tls.X509KeyPair(certBytes, data); err == nil {
				if x, err := x509.ParseCertificate(pair.Certificate[0]); err == nil &&
					time.Now().After(x.NotBefore) && time.Now().Before(x.NotAfter.Add(-24*time.Hour)) &&
					certCoversAllSANs(x, ips, dnsNames) {
					sum := sha256.Sum256(x.Raw)
					return pair, hex.EncodeToString(sum[:]), nil
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
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "LightIsle Local NAS"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(90 * 24 * time.Hour),
		IPAddresses:           ips,
		DNSNames:              dnsNames,
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

func certCoversAllSANs(cert *x509.Certificate, ips []net.IP, dnsNames []string) bool {
	for _, wantIP := range ips {
		found := false
		for _, gotIP := range cert.IPAddresses {
			if gotIP.Equal(wantIP) {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	for _, wantDNS := range dnsNames {
		found := false
		for _, gotDNS := range cert.DNSNames {
			if strings.EqualFold(gotDNS, wantDNS) {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}
