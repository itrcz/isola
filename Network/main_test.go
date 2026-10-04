package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/google/gopacket"
	"github.com/google/gopacket/layers"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
)

type fakeSOCKS struct {
	listener net.Listener
	mu       sync.Mutex
	targets  []string
	reject   bool
}

func socksServer(t *testing.T, reject bool) (*fakeSOCKS, Config) {
	t.Helper()
	l, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	f := &fakeSOCKS{listener: l, reject: reject}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, e := l.Accept()
			if e != nil {
				return
			}
			go f.serve(c)
		}
	}()
	return f, Config{Host: "127.0.0.1", Port: l.Addr().(*net.TCPAddr).Port, Username: "alice", Password: "secret"}
}
func (f *fakeSOCKS) serve(c net.Conn) {
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	var h [2]byte
	if _, e := io.ReadFull(c, h[:]); e != nil {
		return
	}
	methods := make([]byte, h[1])
	io.ReadFull(c, methods)
	c.Write([]byte{5, 2})
	if _, e := io.ReadFull(c, h[:]); e != nil {
		return
	}
	user := make([]byte, h[1])
	io.ReadFull(c, user)
	var b [1]byte
	io.ReadFull(c, b[:])
	pass := make([]byte, b[0])
	io.ReadFull(c, pass)
	if f.reject || string(user) != "alice" || string(pass) != "secret" {
		c.Write([]byte{1, 1})
		return
	}
	c.Write([]byte{1, 0})
	var req [4]byte
	if _, e := io.ReadFull(c, req[:]); e != nil {
		return
	}
	if req[1] != 1 {
		return
	}
	var ip net.IP
	switch req[3] {
	case 1:
		ip = make([]byte, 4)
	case 4:
		ip = make([]byte, 16)
	default:
		return
	}
	io.ReadFull(c, ip)
	io.ReadFull(c, h[:])
	port := binary.BigEndian.Uint16(h[:])
	f.mu.Lock()
	f.targets = append(f.targets, ip.String())
	f.mu.Unlock()
	c.Write([]byte{5, 0, 0, 1, 127, 0, 0, 1, 0, 1})
	if port == 53 {
		if _, e := io.ReadFull(c, h[:]); e != nil {
			return
		}
		q := make([]byte, binary.BigEndian.Uint16(h[:]))
		io.ReadFull(c, q)
		if len(q) >= 12 {
			q[2] |= 0x80
		}
		c.Write(h[:])
		c.Write(q)
		return
	}
	io.Copy(c, c)
}
func (f *fakeSOCKS) count() int { f.mu.Lock(); defer f.mu.Unlock(); return len(f.targets) }
func networkPair(t *testing.T, c Config) (*Gateway, *stack.Stack) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	link := channel.New(1024, 1500, "")
	s := stack.New(stack.Options{NetworkProtocols: []stack.NetworkProtocolFactory{ipv4.NewProtocol}, TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol}})
	if e := s.CreateNIC(1, link); e != nil {
		t.Fatal(e)
	}
	if e := s.AddProtocolAddress(1, tcpip.ProtocolAddress{Protocol: ipv4.ProtocolNumber, AddressWithPrefix: tcpip.AddrFrom4Slice(guestIP).WithPrefix()}, stack.AddressProperties{}); e != nil {
		t.Fatal(e)
	}
	s.SetRouteTable([]tcpip.Route{{Destination: header.IPv4EmptySubnet, NIC: 1}})
	g, err := newGateway(c, func(frame []byte) {
		p := gopacket.NewPacket(frame, layers.LayerTypeEthernet, gopacket.Default)
		if ip := p.Layer(layers.LayerTypeIPv4); ip != nil {
			eth := p.Layer(layers.LayerTypeEthernet).(*layers.Ethernet)
			pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(append([]byte(nil), eth.Payload...))})
			link.InjectInbound(ipv4.ProtocolNumber, pkt)
			pkt.DecRef()
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			p := link.ReadContext(ctx)
			if p == nil {
				return
			}
			v := p.ToView()
			b := gopacket.NewSerializeBuffer()
			gopacket.SerializeLayers(b, gopacket.SerializeOptions{FixLengths: true}, &layers.Ethernet{SrcMAC: guestMAC, DstMAC: gatewayMAC, EthernetType: layers.EthernetTypeIPv4}, gopacket.Payload(v.AsSlice()))
			g.frame(b.Bytes())
			v.Release()
			p.DecRef()
		}
	}()
	t.Cleanup(func() { cancel(); g.close(); s.Close(); link.Close() })
	return g, s
}
func dialGuest(s *stack.Stack, ip string, port uint16) (net.Conn, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	return gonet.DialContextTCP(ctx, s, tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFrom4Slice(net.ParseIP(ip).To4()), Port: port}, ipv4.ProtocolNumber)
}
func TestEthernetTCPTraversesAuthenticatedSOCKS(t *testing.T) {
	f, c := socksServer(t, false)
	_, s := networkPair(t, c)
	conn, err := dialGuest(s, "93.184.216.34", 443)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(2 * time.Second))
	payload := []byte("isolated guest TCP payload")
	conn.Write(payload)
	got := make([]byte, len(payload))
	if _, err = io.ReadFull(conn, got); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, payload) || f.count() != 1 {
		t.Fatal("traffic did not traverse SOCKS")
	}
}
func TestDNSUsesSOCKSTCP(t *testing.T) {
	f, c := socksServer(t, false)
	_, s := networkPair(t, c)
	conn, err := gonet.DialUDP(s, nil, &tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFrom4Slice(gatewayIP), Port: 53}, ipv4.ProtocolNumber)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(2 * time.Second))
	q := []byte{0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 'a', 0, 0, 1, 0, 1}
	conn.Write(q)
	out := make([]byte, 512)
	n, err := conn.Read(out)
	if err != nil {
		t.Fatal(err)
	}
	if n != len(q) || out[2]&0x80 == 0 || f.count() != 1 {
		t.Fatal("DNS did not use SOCKS TCP")
	}
}
func TestPrivateDestinationRejected(t *testing.T) {
	f, c := socksServer(t, false)
	_, s := networkPair(t, c)
	for _, ip := range []string{"127.0.0.1", "192.168.1.1", "169.254.169.254", "10.77.0.1"} {
		conn, err := dialGuest(s, ip, 80)
		if err == nil {
			conn.Close()
			t.Fatalf("private address %s accepted", ip)
		}
	}
	if f.count() != 0 {
		t.Fatal("private connection reached proxy")
	}
}
func TestWrongCredentialsFailClosed(t *testing.T) {
	f, c := socksServer(t, true)
	_, s := networkPair(t, c)
	conn, err := dialGuest(s, "93.184.216.34", 443)
	if err == nil {
		conn.Close()
		t.Fatal("connection succeeded with rejected credentials")
	}
	if f.count() != 0 {
		t.Fatal("unauthenticated connection forwarded")
	}
}
func TestDeadProxyFailClosed(t *testing.T) {
	f, c := socksServer(t, false)
	f.listener.Close()
	_, s := networkPair(t, c)
	conn, err := dialGuest(s, "93.184.216.34", 443)
	if err == nil {
		conn.Close()
		t.Fatal("connection succeeded without proxy")
	}
}
func TestNonDNSUDPBlocked(t *testing.T) {
	f, c := socksServer(t, false)
	_, s := networkPair(t, c)
	conn, err := gonet.DialUDP(s, nil, &tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFrom4Slice([]byte{1, 1, 1, 1}), Port: 443}, ipv4.ProtocolNumber)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(100 * time.Millisecond))
	conn.Write([]byte("QUIC or STUN"))
	b := make([]byte, 32)
	if _, err = conn.Read(b); err == nil {
		t.Fatal("unexpected UDP reply")
	}
	if f.count() != 0 {
		t.Fatal("UDP egress")
	}
}
func TestDHCPAndARP(t *testing.T) {
	_, c := socksServer(t, false)
	c.GuestMAC = "02:ab:cd:12:34:56"
	guestMAC, _ := net.ParseMAC(c.GuestMAC)
	frames := make(chan []byte, 8)
	g, err := newGateway(c, func(b []byte) { frames <- append([]byte(nil), b...) })
	if err != nil {
		t.Fatal(err)
	}
	defer g.close()
	for _, kind := range []byte{1, 3} {
		g.dhcp(&layers.DHCPv4{Operation: layers.DHCPOpRequest, ClientHWAddr: guestMAC, Xid: 42, Options: layers.DHCPOptions{layers.NewDHCPOption(layers.DHCPOptMessageType, []byte{kind})}})
		p := gopacket.NewPacket(<-frames, layers.LayerTypeEthernet, gopacket.Default)
		l := p.Layer(layers.LayerTypeDHCPv4)
		if l == nil {
			t.Fatal("no DHCP reply")
		}
		d := l.(*layers.DHCPv4)
		if !bytes.Equal(d.ClientHWAddr, guestMAC) || d.Xid != 42 || !d.YourClientIP.Equal(guestIP) {
			t.Fatal("bad lease")
		}
		dns := false
		for _, o := range d.Options {
			if o.Type == layers.DHCPOptDNS {
				dns = net.IP(o.Data).Equal(gatewayIP)
			}
		}
		if !dns {
			t.Fatal("DHCP advertised non-proxied DNS")
		}
	}
	b := gopacket.NewSerializeBuffer()
	gopacket.SerializeLayers(b, gopacket.SerializeOptions{FixLengths: true}, &layers.Ethernet{SrcMAC: guestMAC, DstMAC: gatewayMAC, EthernetType: layers.EthernetTypeARP}, &layers.ARP{AddrType: layers.LinkTypeEthernet, Protocol: layers.EthernetTypeIPv4, HwAddressSize: 6, ProtAddressSize: 4, Operation: 1, SourceHwAddress: guestMAC, SourceProtAddress: guestIP, DstHwAddress: make([]byte, 6), DstProtAddress: gatewayIP})
	g.frame(b.Bytes())
	p := gopacket.NewPacket(<-frames, layers.LayerTypeEthernet, gopacket.Default)
	a := p.Layer(layers.LayerTypeARP).(*layers.ARP)
	if !bytes.Equal(a.DstHwAddress, guestMAC) || !bytes.Equal(p.Layer(layers.LayerTypeEthernet).(*layers.Ethernet).DstMAC, guestMAC) || a.Operation != 2 || !net.IP(a.SourceProtAddress).Equal(gatewayIP) {
		t.Fatal("ARP gateway failed")
	}
}
func TestEndpointRequiresNumericIP(t *testing.T) {
	c := Config{Host: "proxy.example.com", Port: 1080}
	if c.validate() == nil {
		t.Fatal("hostname would leak bootstrap DNS")
	}
}
func TestIPv6AndMalformedFramesDropped(t *testing.T) {
	f, c := socksServer(t, false)
	g, err := newGateway(c, func([]byte) { t.Error("unexpected response") })
	if err != nil {
		t.Fatal(err)
	}
	defer g.close()
	for n := 0; n < 100; n++ {
		g.frame(make([]byte, n))
	}
	b := gopacket.NewSerializeBuffer()
	gopacket.SerializeLayers(b, gopacket.SerializeOptions{FixLengths: true}, &layers.Ethernet{SrcMAC: guestMAC, DstMAC: gatewayMAC, EthernetType: layers.EthernetTypeIPv6}, &layers.IPv6{Version: 6, HopLimit: 64, SrcIP: net.ParseIP("fd00::2"), DstIP: net.ParseIP("2606:4700:4700::1111"), NextHeader: layers.IPProtocolUDP}, gopacket.Payload([]byte{0, 53, 0, 53, 0, 8, 0, 0}))
	g.frame(b.Bytes())
	if f.count() != 0 {
		t.Fatal("IPv6 egress")
	}
}

func TestLargeTCPStreamIntegrity(t *testing.T) {
	_, c := socksServer(t, false)
	g, s := networkPair(t, c)
	conn, err := dialGuest(s, "93.184.216.34", 443)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(10 * time.Second))
	payload := make([]byte, 1024*1024)
	for i := range payload {
		payload[i] = byte((i*7 + i/257) % 251)
	}
	done := make(chan error, 1)
	go func() { _, err := io.Copy(conn, bytes.NewReader(payload)); done <- err }()
	got := make([]byte, len(payload))
	n, err := io.ReadFull(conn, got)
	if err != nil {
		t.Fatalf("read %d bytes: %v; %v", n, err, g.metrics())
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(payload, got) {
		for i := range got {
			if got[i] != payload[i] {
				t.Fatalf("corruption at %d: got %d want %d; metrics %v", i, got[i], payload[i], g.metrics())
			}
		}
	}
}

func TestBlockedUDPReturnsICMP(t *testing.T) {
	_, c := socksServer(t, false)
	output := make(chan []byte, 8)
	g, err := newGateway(c, func(frame []byte) { output <- append([]byte(nil), frame...) })
	if err != nil {
		t.Fatal(err)
	}
	defer g.close()
	ip := &layers.IPv4{Version: 4, IHL: 5, TTL: 64, Protocol: layers.IPProtocolUDP, SrcIP: guestIP, DstIP: net.IPv4(1, 1, 1, 1)}
	u := &layers.UDP{SrcPort: 43210, DstPort: 443}
	u.SetNetworkLayerForChecksum(ip)
	b := gopacket.NewSerializeBuffer()
	gopacket.SerializeLayers(b, gopacket.SerializeOptions{FixLengths: true, ComputeChecksums: true}, &layers.Ethernet{SrcMAC: guestMAC, DstMAC: gatewayMAC, EthernetType: layers.EthernetTypeIPv4}, ip, u, gopacket.Payload([]byte("blocked QUIC")))
	g.frame(b.Bytes())
	select {
	case frame := <-output:
		packet := gopacket.NewPacket(frame, layers.LayerTypeEthernet, gopacket.Default)
		layer := packet.Layer(layers.LayerTypeICMPv4)
		if layer == nil {
			t.Fatal("no ICMP rejection")
		}
		icmp := layer.(*layers.ICMPv4)
		if icmp.TypeCode.Type() != 3 || icmp.TypeCode.Code() != 3 {
			t.Fatalf("unexpected ICMP %v", icmp.TypeCode)
		}
	case <-time.After(time.Second):
		t.Fatal("blocked UDP was silently dropped")
	}
}
