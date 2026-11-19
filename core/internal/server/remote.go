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
	"log/slog"
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
// listener binds the selected RFC1918 physical interface, and companion
// listeners bind active utun/tailscale VPN or mesh interfaces carrying
// RFC1918 (10/8, 172.16/12, 192.168/16) or Tailscale CGNAT (100.64/10)
// IPv4 addresses on the exact same port.
type companionListener struct {
	srv *http.Server
	ln  net.Listener
}

type Remote struct {
	srv          *http.Server
	ln           net.Listener
	companions   []companionListener
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
	for _, comp := range r.companions {
		if comp.srv != nil {
			_ = comp.srv.Shutdown(ctx)
			_ = comp.srv.Close()
		}
		if comp.ln != nil {
			_ = comp.ln.Close()
		}
	}
	if r.srv != nil {
		_ = r.srv.Shutdown(ctx)
		_ = r.srv.Close()
	}
	if r.ln != nil {
		_ = r.ln.Close()
	}
}

type ifaceCandidate struct {
	name string
	ips  []net.IP
}

type remoteTargets struct {
	primaryIP    net.IP
	tailscaleIP  net.IP
	companionIPs []net.IP
}

func isRFC1918IPv4(ip net.IP) bool {
	ip4 := ip.To4()
	if ip4 == nil {
		return false
	}
	return ip4[0] == 10 ||
		(ip4[0] == 172 && ip4[1] >= 16 && ip4[1] <= 31) ||
		(ip4[0] == 192 && ip4[1] == 168)
}

func appendUniqueIP(ips []net.IP, candidate net.IP) []net.IP {
	if candidate == nil {
		return ips
	}
	for _, existing := range ips {
		if existing.Equal(candidate) {
			return ips
		}
	}
	return append(ips, candidate)
}

func upInterfaceCandidates() []ifaceCandidate {
	faces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	candidates := make([]ifaceCandidate, 0, len(faces))
	for _, face := range faces {
		if face.Flags&net.FlagUp == 0 || face.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := face.Addrs()
		if err != nil {
			continue
		}
		ips := make([]net.IP, 0, len(addrs))
		for _, addr := range addrs {
			var ip net.IP
			switch a := addr.(type) {
			case *net.IPNet:
				ip = a.IP
			case *net.IPAddr:
				ip = a.IP
			}
			if ip4 := ip.To4(); ip4 != nil {
				ips = append(ips, ip4)
			}
		}
		if len(ips) > 0 {
			candidates = append(candidates, ifaceCandidate{name: face.Name, ips: ips})
		}
	}
	return candidates
}

func physicalPrivateIP(ifaces []ifaceCandidate) net.IP {
	var fallback net.IP
	for _, face := range ifaces {
		if strings.HasPrefix(face.name, "utun") || strings.HasPrefix(face.name, "tailscale") ||
			strings.HasPrefix(face.name, "bridge") || strings.HasPrefix(face.name, "vnic") ||
			strings.HasPrefix(face.name, "awdl") {
			continue
		}
		for _, ip := range face.ips {
			if !isRFC1918IPv4(ip) {
				continue
			}
			if face.name == "en0" || face.name == "en1" {
				return ip.To4()
			}
			if fallback == nil {
				fallback = ip.To4()
			}
		}
	}
	return fallback
}

func selectRemoteIPs(ifaces []ifaceCandidate) remoteTargets {
	primary := physicalPrivateIP(ifaces)
	var tsIP net.IP
	var vpnIPs []net.IP
	for _, face := range ifaces {
		if !strings.HasPrefix(face.name, "utun") && !strings.HasPrefix(face.name, "tailscale") {
			continue
		}
		for _, ip := range face.ips {
			ip4 := ip.To4()
			if ip4 == nil {
				continue
			}
			if IsTailscaleCGNATIPv4(ip4) {
				if tsIP == nil {
					tsIP = ip4
				}
				vpnIPs = appendUniqueIP(vpnIPs, ip4)
			} else if isRFC1918IPv4(ip4) {
				vpnIPs = appendUniqueIP(vpnIPs, ip4)
			}
		}
	}
	if primary == nil {
		if tsIP != nil {
			primary = tsIP
		} else if len(vpnIPs) > 0 {
			primary = vpnIPs[0]
		}
	}
	var companions []net.IP
	for _, ip := range vpnIPs {
		if primary != nil && ip.Equal(primary) {
			continue
		}
		companions = appendUniqueIP(companions, ip)
	}
	return remoteTargets{
		primaryIP:    primary,
		tailscaleIP:  tsIP,
		companionIPs: companions,
	}
}

func privateIP() net.IP {
	return physicalPrivateIP(upInterfaceCandidates())
}

func NewRemote(handler http.Handler, store *auth.Store, dir string, port int) (*Remote, error) {
	return newRemoteWithTargets(handler, store, dir, port, true, selectRemoteIPs(upInterfaceCandidates()))
}

// NewRemoteHTTP enables explicit owner-approved LAN HTTP and optional co-bound
// VPN/mesh private interface HTTP.
func NewRemoteHTTP(handler http.Handler, store *auth.Store, port int) (*Remote, error) {
	return newRemoteWithTargets(handler, store, "", port, false, selectRemoteIPs(upInterfaceCandidates()))
}

func wrapListenerTLS(ln net.Listener, cfg *tls.Config) net.Listener {
	if cfg == nil {
		return ln
	}
	return tls.NewListener(ln, cfg.Clone())
}

func newRemoteWithTargets(
	handler http.Handler,
	store *auth.Store,
	dir string,
	port int,
	useTLS bool,
	targets remoteTargets,
) (*Remote, error) {
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
	if targets.primaryIP == nil {
		return nil, errors.New("没有可用的局域网或 Tailscale 私有 IPv4 地址")
	}

	var tlsCfg *tls.Config
	var fingerprint string
	scheme := "http"
	if useTLS {
		scheme = "https"
		sanIPs := append([]net.IP{targets.primaryIP}, targets.companionIPs...)
		var dnsSANs []string
		if targets.tailscaleIP != nil {
			tsStatus := DetectTailscale(context.Background(), port, true, "")
			if tsStatus.MagicDNS != "" {
				dnsSANs = append(dnsSANs, tsStatus.MagicDNS)
			}
		}
		cert, fp, certErr := certificateWithSANs(dir, sanIPs, dnsSANs)
		if certErr != nil {
			return nil, certErr
		}
		fingerprint = fp
		tlsCfg = &tls.Config{
			Certificates: []tls.Certificate{cert},
			MinVersion:   tls.VersionTLS13,
		}
	}

	ln, err := net.Listen("tcp4", net.JoinHostPort(targets.primaryIP.String(), fmt.Sprint(port)))
	if err != nil {
		return nil, fmt.Errorf("无法在局域网地址 %s 上监听统一端口 %d，请检查端口是否被占用：%w", targets.primaryIP.String(), port, err)
	}
	primaryLn := wrapListenerTLS(ln, tlsCfg)
	srv := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second}
	r := &Remote{
		srv:         srv,
		ln:          primaryLn,
		URL:         fmt.Sprintf("%s://%s", scheme, primaryLn.Addr().String()),
		Fingerprint: fingerprint,
	}
	if targets.tailscaleIP != nil && targets.tailscaleIP.Equal(targets.primaryIP) {
		r.TailscaleURL = r.URL
	}

	for _, compIP := range targets.companionIPs {
		compRawLn, compErr := net.Listen("tcp4", net.JoinHostPort(compIP.String(), fmt.Sprint(port)))
		if compErr != nil {
			slog.Warn("companion remote listener unavailable", "ip", compIP.String(), "port", port, "error", compErr)
			continue
		}
		compLn := wrapListenerTLS(compRawLn, tlsCfg)
		compSrv := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second}
		r.companions = append(r.companions, companionListener{srv: compSrv, ln: compLn})
		if targets.tailscaleIP != nil && compIP.Equal(targets.tailscaleIP) {
			r.TailscaleURL = fmt.Sprintf("%s://%s", scheme, compLn.Addr().String())
		}
		go func(s *http.Server, l net.Listener) { _ = s.Serve(l) }(compSrv, compLn)
	}
	go func() { _ = srv.Serve(primaryLn) }()
	return r, nil
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
