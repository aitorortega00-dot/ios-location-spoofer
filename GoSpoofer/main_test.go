package main

import (
	"encoding/hex"
	"net/http/httptest"
	"strings"
	"testing"

	pb "golocationspoofer/pb"
	"google.golang.org/protobuf/proto"
)

func TestDeserializeRealRequest(t *testing.T) {
	requestBytes, _ := hex.DecodeString("0001000a656e2d3030315f3030310013636f6d2e6170706c652e6c6f636174696f6e64000a32362e322e3233433535000000020000000002000000")

	arpc := ArpcDeserialize(requestBytes)
	if arpc == nil {
		t.Fatal("Failed to deserialize ARPC")
	}

	t.Logf("ARPC payload size: %d bytes", len(arpc.Payload))
	t.Logf("Version: %s", arpc.Version)
	t.Logf("Locale: %s", arpc.Locale)
	t.Logf("AppIdentifier: %s", arpc.AppIdentifier)
	t.Logf("OsVersion: %s", arpc.OsVersion)
	t.Logf("FunctionId: %d", arpc.FunctionId)

	wloc := &pb.AppleWLoc{}
	if err := proto.Unmarshal(arpc.Payload, wloc); err != nil {
		t.Fatalf("Failed to unmarshal protobuf: %v", err)
	}

	t.Logf("Number of wifi devices: %d", len(wloc.WifiDevices))

	if len(wloc.WifiDevices) == 0 {
		t.Logf("WifiDevices slice is empty or nil")
	} else {
		for i, device := range wloc.WifiDevices {
			t.Logf("Device %d: BSSID=%s", i, device.GetBssid())
		}
	}
}

func TestFullRoundTrip(t *testing.T) {
	requestBytes, _ := hex.DecodeString("0001000a656e2d3030315f3030310013636f6d2e6170706c652e6c6f636174696f6e64000a32362e322e3233433535000000020000000002000000")

	arpc := ArpcDeserialize(requestBytes)
	if arpc == nil {
		t.Fatal("Failed to deserialize ARPC")
	}

	wloc := &pb.AppleWLoc{}
	if err := proto.Unmarshal(arpc.Payload, wloc); err != nil {
		t.Fatalf("Failed to unmarshal protobuf: %v", err)
	}

	if len(wloc.WifiDevices) == 0 {
		t.Fatal("No wifi devices found")
	}

	lat := IntFromCoord(51.510420)
	lon := IntFromCoord(-3.218306)
	horizontalAccuracy := int64(39)
	verticalAccuracy := int64(1000)
	altitude := int64(530)
	unknownValue4 := int64(3)
	motionActivityType := int64(63)
	motionActivityConfidence := int64(467)

	for i, device := range wloc.WifiDevices {
		t.Logf("Spoofing BSSID: %s (index %d)", device.GetBssid(), i)
		if device.Location == nil {
			device.Location = &pb.Location{}
		}
		device.Location.Latitude = &lat
		device.Location.Longitude = &lon
		device.Location.HorizontalAccuracy = &horizontalAccuracy
		device.Location.VerticalAccuracy = &verticalAccuracy
		device.Location.Altitude = &altitude
		device.Location.UnknownValue4 = &unknownValue4
		device.Location.MotionActivityType = &motionActivityType
		device.Location.MotionActivityConfidence = &motionActivityConfidence
	}

	wloc.NumCellResults = nil
	wloc.NumWifiResults = nil
	wloc.DeviceType = nil

	initialBytes, _ := hex.DecodeString("0001000000010000")
	responseBytes, err := SerializeProto(wloc, initialBytes)
	if err != nil {
		t.Fatalf("Failed to serialize: %v", err)
	}

	t.Logf("Request had %d wifi devices", len(wloc.WifiDevices))
	t.Logf("Response bytes: %x", responseBytes)
	t.Logf("Response length: %d bytes", len(responseBytes))

	if responseBytes[0] != 0x00 || responseBytes[1] != 0x01 {
		t.Errorf("First 2 bytes should be 0x0001, got: %x", responseBytes[:2])
	}

	payloadLen := int(responseBytes[7])<<8 | int(responseBytes[8])
	t.Logf("Embedded payload length: %d bytes", payloadLen)
	t.Logf("Total response length: %d bytes", len(responseBytes))

	if payloadLen != len(responseBytes)-9 {
		t.Errorf("Payload length mismatch: embedded=%d, actual=%d", payloadLen, len(responseBytes)-9)
	}
}

func TestCoordinateEncoding(t *testing.T) {
	lat := IntFromCoord(51.510420)
	lon := IntFromCoord(-3.218306)

	t.Logf("Lat 51.510420 -> %d", lat)
	t.Logf("Lon -3.218306 -> %d", lon)

	latZigzag := encodeZigzag(lat)
	lonZigzag := encodeZigzag(lon)

	t.Logf("Lat zigzag: %d (0x%x)", latZigzag, latZigzag)
	t.Logf("Lon zigzag: %d (0x%x)", lonZigzag, lonZigzag)

	latVarint := appendVarint(make([]byte, 0), latZigzag)
	lonVarint := appendVarint(make([]byte, 0), lonZigzag)

	t.Logf("Lat varint hex: %s", hex.EncodeToString(latVarint))
	t.Logf("Lon varint hex: %s", hex.EncodeToString(lonVarint))
}

func TestFieldPresence(t *testing.T) {
	wloc := &pb.AppleWLoc{
		WifiDevices: []*pb.WifiDevice{
			{
				Bssid: "aa:bb:cc:dd:ee:ff",
				Location: &pb.Location{
					Latitude:  p64(5151042000),
					Longitude: p64(-321830600),
				},
			},
		},
	}

	wloc.NumCellResults = nil
	wloc.NumWifiResults = nil
	wloc.DeviceType = nil

	protoBytes, _ := proto.Marshal(wloc)
	t.Logf("With nil fields: %d bytes", len(protoBytes))
	t.Logf("Hex: %x", protoBytes)

	wloc3 := &pb.AppleWLoc{
		WifiDevices: []*pb.WifiDevice{
			{
				Bssid: "aa:bb:cc:dd:ee:ff",
				Location: &pb.Location{
					Latitude:  p64(5151042000),
					Longitude: p64(-321830600),
				},
			},
		},
	}

	protoBytes3, _ := proto.Marshal(wloc3)
	t.Logf("Without setting fields: %d bytes", len(protoBytes3))
	t.Logf("Hex: %x", protoBytes3)
}

func TestCellTowerSpoof(t *testing.T) {
	lat := IntFromCoord(40.4168)
	lon := IntFromCoord(-3.7038)
	mcc, mnc := uint32(214), uint32(7)
	req := &pb.AppleWLoc{
		WifiDevices:      []*pb.WifiDevice{{Bssid: "aa:bb:cc:dd:ee:ff"}},
		CellTowerRequest: &pb.CellTower{Mcc: mcc, Mnc: mnc, CellId: 12345, TacId: 678},
	}
	payload, err := proto.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	out, modified := rewriteAppleWLocCoords(payload, lat, lon)
	if modified == 0 {
		t.Fatal("nothing modified")
	}
	resp := &pb.AppleWLoc{}
	if err := proto.Unmarshal(out, resp); err != nil {
		t.Fatalf("rewritten payload does not parse: %v", err)
	}
	if len(resp.CellTowerResponse) != 1 {
		t.Fatalf("want 1 cell tower response, got %d", len(resp.CellTowerResponse))
	}
	ct := resp.CellTowerResponse[0]
	if ct.CellId != 12345 || ct.Mcc != mcc || ct.Location.GetLatitude() != lat || ct.Location.GetLongitude() != lon || ct.Location.GetHorizontalAccuracy() != cellAccuracy {
		t.Fatalf("bad cell tower: %+v loc=%+v", ct, ct.Location)
	}
	if resp.WifiDevices[0].Location.GetLatitude() != lat || resp.WifiDevices[0].Location.GetHorizontalAccuracy() != 30 {
		t.Fatalf("wifi not spoofed: %+v", resp.WifiDevices[0].Location)
	}
	if resp.CellTowerRequest == nil || resp.CellTowerRequest.CellId != 12345 {
		t.Fatal("cell tower request not kept")
	}

	// A response-style entry (tag 22) with a real location gets overwritten.
	real := &pb.AppleWLoc{CellTowerResponse: []*pb.CellTower{{CellId: 1, Location: &pb.Location{Latitude: proto.Int64(1), Longitude: proto.Int64(2), HorizontalAccuracy: proto.Int64(500)}}}}
	payload, _ = proto.Marshal(real)
	out, _ = rewriteAppleWLocCoords(payload, lat, lon)
	resp = &pb.AppleWLoc{}
	if err := proto.Unmarshal(out, resp); err != nil {
		t.Fatal(err)
	}
	l := resp.CellTowerResponse[0].Location
	if l.GetLatitude() != lat || l.GetLongitude() != lon || l.GetHorizontalAccuracy() != 500 {
		t.Fatalf("existing cell location not rewritten: %+v", l)
	}
}

func TestShieldBlocksWhenSpoofOff(t *testing.T) {
	setSpoof(0, 0, false)
	req := httptest.NewRequest("POST", "https://gs-loc.apple.com/clls/wloc", strings.NewReader("x"))
	_, resp := handleLocationRequest(req)
	if resp == nil || resp.StatusCode != 503 {
		t.Fatalf("expected blocked 503 response, got %+v", resp)
	}
	// Garbage while spoofing is on is blocked too (never forwarded to Apple).
	setSpoof(40.4, -3.7, true)
	req = httptest.NewRequest("POST", "https://gs-loc.apple.com/clls/wloc", strings.NewReader("garbage"))
	_, resp = handleLocationRequest(req)
	if resp == nil || resp.StatusCode != 503 {
		t.Fatalf("expected blocked 503 for unparsable body, got %+v", resp)
	}
	setSpoof(0, 0, false)
}
