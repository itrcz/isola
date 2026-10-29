package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"net"
	"os"
	"os/exec"
	"syscall"
	"testing"
	"time"

	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
)

// Opt-in acceptance check with Apple's actual SNTP client. Loopback only;
// no clock-setting flags, public time servers, or changes to system settings.
func TestSystemSNTPClient(t *testing.T) {
	if os.Getenv("ISOLA_SYSTEM_SNTP_TEST") != "1" {
		t.Skip("opt-in macOS client check")
	}
	socket, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 123})
	if err != nil {
		if errors.Is(err, syscall.EACCES) || errors.Is(err, syscall.EADDRINUSE) {
			t.Skip("Apple SNTP requires exclusive access to reserved loopback UDP port 123")
		}
		t.Fatal(err)
	}
	defer socket.Close()
	socket.SetDeadline(time.Now().Add(5 * time.Second))
	done := make(chan error, 1)
	go func() {
		buffer := make([]byte, 1024)
		n, client, err := socket.ReadFromUDP(buffer)
		if err == nil {
			now := time.Now()
			_, err = socket.WriteToUDP(timeReply(buffer[:n], now, now), client)
		}
		done <- err
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, "/usr/bin/sntp", "-t", "3", "127.0.0.1").CombinedOutput()
	if err != nil {
		t.Fatalf("Apple SNTP rejected host-clock reply: %v %s", err, output)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	t.Logf("Apple SNTP accepted the local reply: %s", output)
}

func TestTimePacket(t *testing.T) {
	received := time.Date(2026, 10, 20, 12, 0, 0, 250000000, time.UTC)
	sent := received.Add(time.Millisecond)
	for _, version := range []byte{3, 4} {
		request := make([]byte, 48)
		request[0], request[2] = version<<3|3, 6
		putNTPTime(request[40:48], received.Add(-24*time.Hour))
		reply := timeReply(request, received, sent)
		if len(reply) != 48 || reply[0] != version<<3|4 || reply[1] != 1 ||
			string(reply[12:16]) != "LOCL" || !bytes.Equal(reply[24:32], request[40:48]) {
			t.Fatal("invalid server header or originate timestamp")
		}
		if binary.BigEndian.Uint32(reply[32:36]) != uint32(received.Unix()+2208988800) ||
			binary.BigEndian.Uint32(reply[36:40]) != 1<<30 {
			t.Fatal("incorrect seconds or fractional timestamp")
		}
		if bytes.Compare(reply[40:48], reply[32:40]) <= 0 {
			t.Fatal("transmit timestamp did not advance")
		}
	}
	buf := make([]byte, 8)
	putNTPTime(buf, time.Unix(2085978496, 0)) // first second of NTP era 1
	if binary.BigEndian.Uint32(buf[:4]) != 0 {
		t.Fatal("NTP era rollover")
	}
}

func TestTimeRejectsMalformedAndControlPackets(t *testing.T) {
	for _, n := range []int{0, 47, 49, 68, 512} {
		if timeReply(make([]byte, n), time.Now(), time.Now()) != nil {
			t.Fatal("accepted malformed/extension packet")
		}
	}
	for version := byte(0); version < 8; version++ {
		for mode := byte(0); mode < 8; mode++ {
			q := make([]byte, 48)
			q[0] = version<<3 | mode
			if (timeReply(q, time.Now(), time.Now()) != nil) != ((version == 3 || version == 4) && mode == 3) {
				t.Fatalf("unexpected version %d mode %d", version, mode)
			}
		}
	}
}

func TestGuestTimeWorksWithDeadProxyWithoutEgress(t *testing.T) {
	f, config := socksServer(t, false)
	f.listener.Close()
	g, s := networkPair(t, config)
	for _, ip := range []net.IP{gatewayIP, net.IPv4(17, 253, 14, 253)} {
		conn, err := gonet.DialUDP(s, nil, &tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFrom4Slice(ip.To4()), Port: 123}, ipv4.ProtocolNumber)
		if err != nil {
			t.Fatal(err)
		}
		conn.SetDeadline(time.Now().Add(time.Second))
		request := make([]byte, 48)
		request[0] = 0x23
		putNTPTime(request[40:48], time.Now().Add(-48*time.Hour))
		for i := 0; i < 2; i++ {
			before := uint32(time.Now().Unix() + 2208988800)
			conn.Write(request)
			reply := make([]byte, 512)
			n, err := conn.Read(reply)
			if err != nil || n != 48 {
				t.Fatalf("no local NTP response: %d %v", n, err)
			}
			after := uint32(time.Now().Unix() + 2208988800)
			got := binary.BigEndian.Uint32(reply[40:44])
			if got < before || got > after || !bytes.Equal(reply[24:32], request[40:48]) {
				t.Fatal("response does not contain current host time")
			}
		}
		conn.Close()
	}
	if f.count() != 0 || g.tcpDials.Load() != 0 || g.dnsQueries.Load() != 0 {
		t.Fatal("NTP attempted upstream traffic")
	}
}
