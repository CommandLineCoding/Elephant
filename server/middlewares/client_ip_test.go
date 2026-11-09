package middlewares

import "testing"

func TestClientIP(t *testing.T) {
	cases := []struct {
		name       string
		remoteAddr string
		forwarded  []string
		mode       string
		want       string
	}{
		// auto (the default)
		{"direct connection, no proxy", "203.0.113.7:5555", nil, "auto", "203.0.113.7"},
		{"empty mode means auto", "203.0.113.7:5555", nil, "", "203.0.113.7"},
		{"public peer can't spoof the header", "203.0.113.7:5555", []string{"1.2.3.4"}, "auto", "203.0.113.7"},
		{"private proxy: use the forwarded client", "10.0.0.5:4000", []string{"198.51.100.9"}, "auto", "198.51.100.9"},
		{"loopback proxy (Caddy on the same host)", "127.0.0.1:4000", []string{"198.51.100.9"}, "auto", "198.51.100.9"},
		{"docker bridge proxy", "172.18.0.2:4000", []string{"198.51.100.9"}, "auto", "198.51.100.9"},
		{"shared CGNAT proxy", "100.64.3.4:4000", []string{"198.51.100.9"}, "auto", "198.51.100.9"},
		{"IPv6 loopback proxy", "[::1]:4000", []string{"198.51.100.9"}, "auto", "198.51.100.9"},
		{"auto takes the entry the nearest proxy added", "10.0.0.5:4000", []string{"6.6.6.6, 198.51.100.9"}, "auto", "198.51.100.9"},
		{"private proxy, no header: the proxy itself", "10.0.0.5:4000", nil, "auto", "10.0.0.5"},
		{"garbage forwarded value falls back to the peer", "10.0.0.5:4000", []string{"not-an-ip"}, "auto", "10.0.0.5"},
		{"forwarded entry with a port", "10.0.0.5:4000", []string{"198.51.100.9:6000"}, "auto", "198.51.100.9"},
		{"forwarded IPv6", "10.0.0.5:4000", []string{"2001:db8::1"}, "auto", "2001:db8::1"},
		{"header split over several lines", "10.0.0.5:4000", []string{"6.6.6.6", "198.51.100.9"}, "auto", "198.51.100.9"},

		// 0: never trust
		{"0 ignores the header even from a private proxy", "10.0.0.5:4000", []string{"198.51.100.9"}, "0", "10.0.0.5"},

		// N hops: always trust, counted from the end
		{"2 hops: Cloudflare then Render", "10.0.0.5:4000", []string{"198.51.100.9, 104.16.0.1"}, "2", "198.51.100.9"},
		{"2 hops ignores a spoofed first entry", "10.0.0.5:4000", []string{"6.6.6.6, 198.51.100.9, 104.16.0.1"}, "2", "198.51.100.9"},
		{"1 hop trusts even a public peer", "203.0.113.7:5555", []string{"198.51.100.9"}, "1", "198.51.100.9"},
		{"too few entries for the hops: the peer", "10.0.0.5:4000", []string{"104.16.0.1"}, "2", "10.0.0.5"},
		{"a bad number is treated as untrusted", "10.0.0.5:4000", []string{"198.51.100.9"}, "banana", "10.0.0.5"},
		{"a negative number is treated as untrusted", "10.0.0.5:4000", []string{"198.51.100.9"}, "-1", "10.0.0.5"},

		// the peer address itself
		{"peer without a port", "203.0.113.7", nil, "auto", "203.0.113.7"},
		{"IPv6 peer is normalised", "[2001:0db8:0:0:0:0:0:1]:80", nil, "auto", "2001:db8::1"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := clientIP(c.remoteAddr, c.forwarded, c.mode); got != c.want {
				t.Errorf("clientIP(%q, %q, %q) = %q, want %q", c.remoteAddr, c.forwarded, c.mode, got, c.want)
			}
		})
	}
}
