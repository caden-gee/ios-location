package main

import (
	"bytes"
	"encoding/binary"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	pb "golocationspoofer/pb"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"
)

func i64(v int64) *int64   { return &v }
func i32(v int32) *int32   { return &v }
func str(v string) *string { return &v }

// sampleWLoc mimics what locationd sends: BSSIDs, mostly without locations,
// plus request metadata that must survive the rewrite.
func sampleWLoc() *pb.AppleWLoc {
	return &pb.AppleWLoc{
		WifiDevices: []*pb.WifiDevice{
			{Bssid: "aa:bb:cc:dd:ee:ff"},
			{Bssid: "11:22:33:44:55:66", Location: &pb.Location{
				Latitude:           i64(100),
				Longitude:          i64(-200),
				HorizontalAccuracy: i64(39),
				Altitude:           i64(530),
			}},
		},
		NumWifiResults: i32(-1),
		AppBundleId:    str("com.apple.locationd"),
	}
}

func sampleArpc(t *testing.T, payload []byte) *ArpcRequest {
	t.Helper()
	return &ArpcRequest{
		Version:       "1",
		Locale:        "en-001_001",
		AppIdentifier: "com.apple.locationd",
		OsVersion:     "26.2.23C55",
		FunctionId:    1,
		Payload:       payload,
	}
}

func TestArpcRoundTrip(t *testing.T) {
	payload, err := proto.Marshal(sampleWLoc())
	if err != nil {
		t.Fatal(err)
	}
	want := sampleArpc(t, payload)
	want.FunctionId = 0x01020304

	raw, err := ArpcSerialize(want)
	if err != nil {
		t.Fatal(err)
	}
	got, err := ArpcDeserialize(raw)
	if err != nil {
		t.Fatalf("ArpcDeserialize: %v", err)
	}
	if got.Version != want.Version || got.Locale != want.Locale ||
		got.AppIdentifier != want.AppIdentifier || got.OsVersion != want.OsVersion ||
		got.FunctionId != want.FunctionId || !bytes.Equal(got.Payload, want.Payload) {
		t.Fatalf("round trip mismatch:\n got %+v\nwant %+v", got, want)
	}
}

func TestArpcDeserializeRejectsTruncatedInput(t *testing.T) {
	raw, err := ArpcSerialize(sampleArpc(t, []byte{1, 2, 3, 4, 5}))
	if err != nil {
		t.Fatal(err)
	}
	for n := 0; n < len(raw); n++ {
		if _, err := ArpcDeserialize(raw[:n]); err == nil {
			t.Errorf("ArpcDeserialize accepted %d/%d bytes", n, len(raw))
		}
	}
}

func TestIntFromCoord(t *testing.T) {
	for _, c := range []struct {
		in   float64
		want int64
	}{
		{51.510420, 5151042000},
		{-3.218306, -321830600},
		{0, 0},
	} {
		if got := IntFromCoord(c.in); got != c.want {
			t.Errorf("IntFromCoord(%v) = %d, want %d", c.in, got, c.want)
		}
	}
}

func TestRewriteAppleWLocCoords(t *testing.T) {
	in := sampleWLoc()
	payload, err := proto.Marshal(in)
	if err != nil {
		t.Fatal(err)
	}
	lat, lon := IntFromCoord(51.510420), IntFromCoord(-3.218306)

	out, modified := rewriteAppleWLocCoords(payload, lat, lon)
	if modified != 4 {
		t.Errorf("modified = %d, want 4 (2 injected + 2 replaced)", modified)
	}

	got := &pb.AppleWLoc{}
	if err := proto.Unmarshal(out, got); err != nil {
		t.Fatalf("rewritten payload does not parse: %v", err)
	}
	if len(got.WifiDevices) != len(in.WifiDevices) {
		t.Fatalf("wifi device count = %d, want %d", len(got.WifiDevices), len(in.WifiDevices))
	}
	for i, d := range got.WifiDevices {
		if d.Bssid != in.WifiDevices[i].Bssid {
			t.Errorf("device %d bssid = %q, want %q", i, d.Bssid, in.WifiDevices[i].Bssid)
		}
		if d.GetLocation().GetLatitude() != lat || d.GetLocation().GetLongitude() != lon {
			t.Errorf("device %d location = (%d, %d), want (%d, %d)", i,
				d.GetLocation().GetLatitude(), d.GetLocation().GetLongitude(), lat, lon)
		}
	}
	// Non-coordinate fields are preserved byte-for-byte.
	if loc := got.WifiDevices[1].Location; loc.GetHorizontalAccuracy() != 39 || loc.GetAltitude() != 530 {
		t.Errorf("location extras not preserved: %+v", loc)
	}
	if got.GetNumWifiResults() != -1 || got.GetAppBundleId() != "com.apple.locationd" {
		t.Errorf("top-level fields not preserved: %+v", got)
	}
}

func TestRewritePreservesUnknownFields(t *testing.T) {
	payload, err := proto.Marshal(sampleWLoc())
	if err != nil {
		t.Fatal(err)
	}
	payload = protowire.AppendTag(payload, 99, protowire.VarintType)
	payload = protowire.AppendVarint(payload, 12345)

	out, _ := rewriteAppleWLocCoords(payload, 1, 2)
	got := &pb.AppleWLoc{}
	if err := proto.Unmarshal(out, got); err != nil {
		t.Fatal(err)
	}
	if want := payload[len(payload)-4:]; !bytes.Equal(got.ProtoReflect().GetUnknown(), want) {
		t.Errorf("unknown fields = %x, want %x", got.ProtoReflect().GetUnknown(), want)
	}
}

func TestRewriteMalformedPayloadPassesThrough(t *testing.T) {
	bad := []byte{0x12, 0x7f, 0x00} // field 2, LEN 127, but only 1 byte follows
	out, _ := rewriteAppleWLocCoords(bad, 1, 2)
	if !bytes.Equal(out, bad) {
		t.Errorf("malformed payload was modified: %x", out)
	}
}

func TestBuildWlocResponse(t *testing.T) {
	payload := []byte{0xde, 0xad, 0xbe, 0xef}
	got, err := buildWlocResponse(payload)
	if err != nil {
		t.Fatal(err)
	}
	want := append(append([]byte{}, wlocResponseHeader...), 0x00, 0x04, 0xde, 0xad, 0xbe, 0xef)
	if !bytes.Equal(got, want) {
		t.Errorf("got %x, want %x", got, want)
	}

	if _, err := buildWlocResponse(make([]byte, 1<<16)); err == nil {
		t.Error("oversized payload accepted; length field would overflow")
	}
}

func newWlocRequest(body []byte) *http.Request {
	return httptest.NewRequest(http.MethodPost, "https://gs-loc.apple.com/clls/wloc", bytes.NewReader(body))
}

func TestHandleLocationRequestSpoofs(t *testing.T) {
	setSpoofConfig(51.510420, -3.218306, true)
	t.Cleanup(func() { setSpoofConfig(0, 0, false) })

	payload, err := proto.Marshal(sampleWLoc())
	if err != nil {
		t.Fatal(err)
	}
	body, err := ArpcSerialize(sampleArpc(t, payload))
	if err != nil {
		t.Fatal(err)
	}

	_, resp := handleLocationRequest(newWlocRequest(body))
	if resp == nil {
		t.Fatal("expected a spoofed response, got pass-through")
	}
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasPrefix(raw, wlocResponseHeader) {
		t.Fatalf("response missing header: %x", raw)
	}
	n := int(binary.BigEndian.Uint16(raw[len(wlocResponseHeader):]))
	rest := raw[len(wlocResponseHeader)+2:]
	if n != len(rest) {
		t.Fatalf("embedded length %d != actual %d", n, len(rest))
	}
	got := &pb.AppleWLoc{}
	if err := proto.Unmarshal(rest, got); err != nil {
		t.Fatal(err)
	}
	for i, d := range got.WifiDevices {
		if d.GetLocation().GetLatitude() != 5151042000 || d.GetLocation().GetLongitude() != -321830600 {
			t.Errorf("device %d not spoofed: %+v", i, d.GetLocation())
		}
	}
}

func TestHandleLocationRequestPassThroughKeepsBody(t *testing.T) {
	body := []byte("definitely not arpc")
	req, resp := handleLocationRequest(newWlocRequest(body))
	if resp != nil {
		t.Fatal("expected pass-through for unparseable body")
	}
	forwarded, err := io.ReadAll(req.Body)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(forwarded, body) {
		t.Errorf("forwarded body = %q, want %q", forwarded, body)
	}
	if req.ContentLength != int64(len(body)) {
		t.Errorf("ContentLength = %d, want %d", req.ContentLength, len(body))
	}
}
