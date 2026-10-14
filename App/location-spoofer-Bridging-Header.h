//
//  location-spoofer-Bridging-Header.h
//  Exposes the C helpers of the app target to Swift.
//

#ifndef location_spoofer_Bridging_Header_h
#define location_spoofer_Bridging_Header_h

/// See LocationCachePurge.c. Jailbreak / TrollStore builds only.
int lcp_purge_as_root(char *out, int outlen);

#endif
