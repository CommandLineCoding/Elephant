package middlewares

import (
	"log"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"

	"github.com/commandlinecoding/elephant/server/env"
)

var cgnat = &net.IPNet{IP: net.IPv4(100, 64, 0, 0), Mask: net.CIDRMask(10, 32)}

var warnIgnoredForwarding sync.Once

// ClientIP returns the address a request should be rate-limited by.
//
// Behind a reverse proxy (Render, Cloudflare, Caddy, ...) the connecting
// address is the proxy's, so every user would share one limit. The proxy puts
// the real address in X-Forwarded-For, but anyone can send that header
// themselves, so it is only trusted from a proxy. TRUSTED_PROXY_HOPS says how:
//
//   - "auto" (default): trust it when the connecting address is loopback,
//     private or shared (CGNAT), i.e. a proxy on the same host or network, and
//     use the last entry, which the nearest proxy added.
//   - "0": never trust it.
//   - N: always trust it, and use the entry N places from the end, for N
//     proxies that each append to the header (e.g. 2 for Cloudflare in front of
//     Render).
func ClientIP(r *http.Request) string {
	return clientIP(r.RemoteAddr, r.Header.Values("X-Forwarded-For"), env.TRUSTED_PROXY_HOPS)
}

func clientIP(remoteAddr string, forwardedFor []string, mode string) string {
	peer := normalizeIP(hostOnly(remoteAddr))

	hops := 0
	switch strings.ToLower(strings.TrimSpace(mode)) {
	case "", "auto":
		ip := net.ParseIP(peer)
		if ip == nil || !isProxyAddress(ip) {
			if len(forwardedFor) > 0 {
				warnIgnoredForwarding.Do(func() {
					log.Println("Ignoring X-Forwarded-For because the connecting address isn't a private or loopback one. " +
						"If this server is behind a proxy, set TRUSTED_PROXY_HOPS to the number of proxies in front of it.")
				})
			}
			return peer
		}
		hops = 1
	default:
		n, err := strconv.Atoi(strings.TrimSpace(mode))
		if err != nil || n <= 0 {
			return peer
		}
		hops = n
	}

	var entries []string
	for _, value := range forwardedFor {
		for _, part := range strings.Split(value, ",") {
			if part = strings.TrimSpace(part); part != "" {
				entries = append(entries, part)
			}
		}
	}
	if len(entries) < hops {
		return peer
	}

	ip := net.ParseIP(hostOnly(entries[len(entries)-hops]))
	if ip == nil {
		return peer
	}
	return ip.String()
}

func isProxyAddress(ip net.IP) bool {
	if v4 := ip.To4(); v4 != nil {
		ip = v4
	}
	return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || cgnat.Contains(ip)
}

// hostOnly strips a port and the brackets around an IPv6 address.
func hostOnly(addr string) string {
	if host, _, err := net.SplitHostPort(addr); err == nil {
		return host
	}
	return strings.Trim(addr, "[]")
}

func normalizeIP(host string) string {
	if ip := net.ParseIP(host); ip != nil {
		return ip.String()
	}
	return host
}
