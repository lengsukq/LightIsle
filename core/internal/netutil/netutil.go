package netutil

import (
	"net"
	"strings"
)

// DetectPrivateLANIPv4 returns the host's primary private RFC1918 IPv4 address
// on an active non-virtual network interface, preferring en0/en1.
func DetectPrivateLANIPv4() string {
	faces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	var fallback string
	for _, face := range faces {
		if face.Flags&net.FlagUp == 0 || face.Flags&net.FlagLoopback != 0 || face.Flags&net.FlagPointToPoint != 0 {
			continue
		}
		if strings.HasPrefix(face.Name, "utun") ||
			strings.HasPrefix(face.Name, "vnic") ||
			strings.HasPrefix(face.Name, "awdl") {
			continue
		}
		addrs, err := face.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			var ip net.IP
			switch a := addr.(type) {
			case *net.IPNet:
				ip = a.IP
			case *net.IPAddr:
				ip = a.IP
			}
			ip4 := ip.To4()
			if ip4 == nil || ip4.IsLoopback() || ip4.IsLinkLocalUnicast() || !ip4.IsPrivate() {
				continue
			}
			if face.Name == "en0" || face.Name == "en1" {
				return ip4.String()
			}
			if fallback == "" && (strings.HasPrefix(face.Name, "en") || strings.HasPrefix(face.Name, "bridge")) {
				fallback = ip4.String()
			}
		}
	}
	return fallback
}
