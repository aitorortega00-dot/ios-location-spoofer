package main

import (
	"math"
	"sync"
	"testing"

	pb "golocationspoofer/pb"
	"google.golang.org/protobuf/proto"
)

// La coordenada cambiada en caliente debe ser la que se lee despues.
func TestApplyCoordsHotUpdate(t *testing.T) {
	setSpoofCoords(41.6523, -4.7245, true)
	if !applyCoords(41.6524, -4.7244, true) {
		t.Fatal("applyCoords rejected a valid coordinate")
	}
	lat, lon, enabled := getSpoofCoords()
	if lat != 41.6524 || lon != -4.7244 || !enabled {
		t.Fatalf("got (%v, %v, %v), want (41.6524, -4.7244, true)", lat, lon, enabled)
	}
}

// Las coordenadas invalidas se ignoran y no pisan la actual.
func TestApplyCoordsRejectsInvalid(t *testing.T) {
	setSpoofCoords(41.0, -4.0, true)
	for _, c := range [][2]float64{{91, 0}, {-91, 0}, {0, 181}, {0, -181}, {math.NaN(), 0}} {
		if applyCoords(c[0], c[1], true) {
			t.Errorf("applyCoords accepted invalid %v", c)
		}
	}
	lat, lon, _ := getSpoofCoords()
	if lat != 41.0 || lon != -4.0 {
		t.Fatalf("invalid input overwrote coords: (%v, %v)", lat, lon)
	}
}

// Desactivar (modo transparente) siempre se acepta.
func TestApplyCoordsDisable(t *testing.T) {
	if !applyCoords(0, 0, false) {
		t.Fatal("disable rejected")
	}
	if _, _, enabled := getSpoofCoords(); enabled {
		t.Fatal("still enabled after disable")
	}
}

// Tras un cambio en caliente, la reescritura del protobuf usa la coordenada nueva.
func TestRewriteUsesHotUpdatedCoords(t *testing.T) {
	applyCoords(40.4168, -3.7038, true)
	applyCoords(40.41689, -3.70371, true) // ~10 m al NE

	req := &pb.AppleWLoc{WifiDevices: []*pb.WifiDevice{{Bssid: "aa:bb:cc:dd:ee:ff"}}}
	payload, _ := proto.Marshal(req)

	curLat, curLon, _ := getSpoofCoords()
	out, n := rewriteAppleWLocCoords(payload, IntFromCoord(curLat), IntFromCoord(curLon))
	if n == 0 {
		t.Fatal("no fields modified")
	}
	got := &pb.AppleWLoc{}
	if err := proto.Unmarshal(out, got); err != nil {
		t.Fatal(err)
	}
	loc := got.WifiDevices[0].GetLocation()
	if loc.GetLatitude() != IntFromCoord(40.41689) || loc.GetLongitude() != IntFromCoord(-3.70371) {
		t.Fatalf("rewrite used (%d, %d), want new coords", loc.GetLatitude(), loc.GetLongitude())
	}
}

// Lecturas y escrituras concurrentes (go test -race) y lecturas siempre coherentes.
func TestCoordsConcurrentAccess(t *testing.T) {
	setSpoofCoords(-1, -1, true) // estado inicial con lat == lon
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(2)
		go func(i int) {
			defer wg.Done()
			v := float64(i)
			applyCoords(v, v, true)
		}(i)
		go func() {
			defer wg.Done()
			lat, lon, _ := getSpoofCoords()
			if lat != lon {
				t.Errorf("torn read: lat=%v lon=%v", lat, lon)
			}
		}()
	}
	wg.Wait()
}
