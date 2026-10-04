package main

import (
	"crypto/tls"
	"encoding/json"
	"golang.org/x/net/dns/dnsmessage"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"io"
	"net"
	"os"
	"testing"
	"time"
)

// Opt-in live integration check. Credentials arrive only on stdin, never in logs or files.
func TestLiveProxy(t *testing.T) {
	if os.Getenv("ISOLA_LIVE_TEST") != "1" {
		t.Skip("explicit live check only")
	}
	var config Config
	if err := json.NewDecoder(os.Stdin).Decode(&config); err != nil {
		t.Fatal("missing proxy config")
	}
	g, s := networkPair(t, config)
	defer func() { t.Logf("gateway counters: %v", g.metrics()) }()
	for _, domain := range []string{"example.com.", "www.google.com.", "example.com."} {
		started := time.Now()
		conn, err := gonet.DialUDP(s, nil, &tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFrom4Slice(gatewayIP), Port: 53}, ipv4.ProtocolNumber)
		if err != nil {
			t.Fatal(err)
		}
		conn.SetDeadline(time.Now().Add(15 * time.Second))
		name, _ := dnsmessage.NewName(domain)
		query := dnsmessage.Message{Header: dnsmessage.Header{ID: 1234, RecursionDesired: true}, Questions: []dnsmessage.Question{{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}}
		q, _ := query.Pack()
		conn.Write(q)
		b := make([]byte, 4096)
		n, err := conn.Read(b)
		conn.Close()
		if err != nil {
			t.Fatal("guest DNS: ", err)
		}
		var response dnsmessage.Message
		if err = response.Unpack(b[:n]); err != nil {
			t.Fatal(err)
		}
		var ip net.IP
		for _, a := range response.Answers {
			if record, ok := a.Body.(*dnsmessage.AResource); ok {
				ip = net.IP(record.A[:])
				break
			}
		}
		if ip == nil {
			t.Fatal("no A record")
		}
		raw, err := dialGuest(s, ip.String(), 443)
		if err != nil {
			t.Fatal("guest TCP: ", err)
		}
		raw.SetDeadline(time.Now().Add(15 * time.Second))
		secure := tls.Client(raw, &tls.Config{ServerName: domain[:len(domain)-1], MinVersion: tls.VersionTLS12})
		if err = secure.Handshake(); err != nil {
			raw.Close()
			t.Fatal("guest TLS: ", err)
		}
		secure.Write([]byte("GET / HTTP/1.1\r\nHost: " + domain[:len(domain)-1] + "\r\nConnection: close\r\n\r\n"))
		data, err := io.ReadAll(io.LimitReader(secure, 128*1024))
		secure.Close()
		if err != nil {
			t.Fatal("guest HTTPS: ", err)
		}
		t.Logf("%s DNS + TLS + GET: %d bytes in %s", domain, len(data), time.Since(started).Round(time.Millisecond))
	}
}
