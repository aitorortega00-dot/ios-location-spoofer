//
//  Bridging Header for Go Location Spoofer
//  location-spoofer-tunnel
//
//  Import the CGo header for Swift access
//

#ifndef location_spoofer_tunnel_Bridging_Header_h
#define location_spoofer_tunnel_Bridging_Header_h

#include "golocationspoofer.h"

/// See LocationCachePurge.c. Jailbreak / TrollStore builds only.
int lcp_purge_as_root(char *out, int outlen);

#endif /* location_spoofer_tunnel_Bridging_Header_h */