# LocSpoofGPS (experimental)

Rootless tweak (Dopamine) that complements the MITM proxy: while spoofing is on,
location fixes that are not Wi-Fi fixes near the spoof point (GPS, cell, stale cache)
are replaced with the spoofed coordinate. Built by `.github/workflows/tweak.yml`
(artifact `tweak-deb`). Install with Sileo / Filza; remove from Sileo.
Logs: 3uTools, filter `SPOOFTWEAK`.
