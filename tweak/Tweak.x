//
//  LocSpoofGPS — companion tweak of Location Spoofer (experimental, "option A").
//
//  The app spoofs Wi-Fi positions with its MITM proxy, but the GPS receiver keeps
//  working (even in airplane mode) and near a window its fixes pull the position
//  back home. This tweak runs inside every process that uses CoreLocation and,
//  while spoofing is on, replaces every fix that is NOT a Wi-Fi fix close to the
//  spoof point (GPS, cell, Wi-Fi from a stale cache far away) with the spoofed
//  coordinate. Wi-Fi fixes near the spoof point (the proxy's answers) pass through
//  untouched, so the MITM keeps doing the real work.
//
//  State comes from the app through notifyd (see App/TweakBridge.swift).
//  If the state is missing (app never ran since boot, spoof off) nothing changes.
//
//  Logs: os_log lines starting with "SPOOFTWEAK" (3uTools filter SPOOFTWEAK).
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <notify.h>
#import <objc/runtime.h>
#import <os/log.h>

#define LS_ENABLED "dev.duti.location-spoofer.tweak.enabled"
#define LS_LAT     "dev.duti.location-spoofer.tweak.lat"
#define LS_LON     "dev.duti.location-spoofer.tweak.lon"

// Private CLLocationType values (CoreLocation): 1 GPS, 4 Wi-Fi, 6 cell, ...
static const int kLSTypeWifi = 4;
// Wi-Fi fixes farther than this from the spoof point come from a stale cache.
static const double kLSMaxWifiDistance = 500.0;
// Accuracy reported on replaced fixes (similar to a Wi-Fi fix).
static const double kLSReplacedAccuracy = 35.0;

@interface CLLocation (LSPrivate)
- (int)type;
@end

static int gTokEnabled = -1, gTokLat = -1, gTokLon = -1;
static unsigned long gLogCount = 0;

static BOOL LSGetSpoof(CLLocationCoordinate2D *out) {
    if (gTokEnabled < 0 || gTokLat < 0 || gTokLon < 0) return NO;
    uint64_t en = 0, la = 0, lo = 0;
    if (notify_get_state(gTokEnabled, &en) != NOTIFY_STATUS_OK || en != 1) return NO;
    if (notify_get_state(gTokLat, &la) != NOTIFY_STATUS_OK) return NO;
    if (notify_get_state(gTokLon, &lo) != NOTIFY_STATUS_OK) return NO;
    double lat, lon;
    memcpy(&lat, &la, sizeof(lat));
    memcpy(&lon, &lo, sizeof(lon));
    if (!(lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180) || (lat == 0 && lon == 0)) return NO;
    out->latitude = lat;
    out->longitude = lon;
    return YES;
}

static CLLocation *LSFix(CLLocation *loc) {
    if (!loc || loc.horizontalAccuracy < 0) return loc;   // invalid fix: leave it alone
    CLLocationCoordinate2D s;
    if (!LSGetSpoof(&s)) return loc;

    int type = [loc respondsToSelector:@selector(type)] ? [loc type] : -1;
    CLLocation *target = [[CLLocation alloc] initWithLatitude:s.latitude longitude:s.longitude];
    double dist = [loc distanceFromLocation:target];
    BOOL keep = (type == kLSTypeWifi && dist <= kLSMaxWifiDistance);

    unsigned long n = ++gLogCount;
    if (n <= 30 || n % 25 == 0) {
        os_log(OS_LOG_DEFAULT, "SPOOFTWEAK %{public}s type=%d acc=%.0f dist=%.0f -> %{public}s (#%lu)",
               getprogname(), type, loc.horizontalAccuracy, dist, keep ? "keep" : "REPLACE", n);
    }
    if (keep) return loc;

    return [[CLLocation alloc] initWithCoordinate:s
                                         altitude:loc.altitude
                               horizontalAccuracy:kLSReplacedAccuracy
                                 verticalAccuracy:loc.verticalAccuracy
                                           course:-1
                                            speed:-1
                                        timestamp:loc.timestamp];
}

// ---------------------------------------------------------------------------
// Delegate proxy: sits between CLLocationManager and the app's delegate and
// rewrites the locations of locationManager:didUpdateLocations:.
// ---------------------------------------------------------------------------

@interface LSDelegateProxy : NSProxy
@property (nonatomic, weak) id target;
- (instancetype)initWithTarget:(id)target;
@end

@implementation LSDelegateProxy
- (instancetype)initWithTarget:(id)target {
    _target = target;
    return self;
}
- (BOOL)respondsToSelector:(SEL)sel {
    return [self.target respondsToSelector:sel];
}
- (BOOL)conformsToProtocol:(Protocol *)protocol {
    return [self.target conformsToProtocol:protocol];
}
- (id)forwardingTargetForSelector:(SEL)sel {
    return self.target;
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSMethodSignature *sig = [self.target methodSignatureForSelector:sel];
    return sig ?: [NSMethodSignature signatureWithObjCTypes:"v@:"];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    id t = self.target;
    if (t) [invocation invokeWithTarget:t];
}
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    id t = self.target;
    if (![t respondsToSelector:_cmd]) return;
    NSMutableArray *fixed = [NSMutableArray arrayWithCapacity:locations.count];
    for (CLLocation *l in locations) {
        CLLocation *f = LSFix(l);
        if (f) [fixed addObject:f];
    }
    [t locationManager:manager didUpdateLocations:fixed];
}
@end

static char kLSProxyKey;

static BOOL LSIsProxy(id obj) {
    return obj && object_getClass(obj) == [LSDelegateProxy class];
}

%hook CLLocationManager

- (void)setDelegate:(id)delegate {
    if (!delegate || LSIsProxy(delegate)) {
        %orig;
        return;
    }
    LSDelegateProxy *proxy = [[LSDelegateProxy alloc] initWithTarget:delegate];
    // The manager holds its delegate weakly: keep the proxy alive with the manager.
    objc_setAssociatedObject(self, &kLSProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(proxy);
}

- (CLLocation *)location {
    return LSFix(%orig);
}

%end

%ctor {
    const char *proc = getprogname();
    if (proc && strcmp(proc, "locationd") == 0) return;   // never touch the daemon itself
    notify_register_check(LS_ENABLED, &gTokEnabled);
    notify_register_check(LS_LAT, &gTokLat);
    notify_register_check(LS_LON, &gTokLon);
    %init;
    os_log(OS_LOG_DEFAULT, "SPOOFTWEAK loaded in %{public}s", proc ? proc : "?");
}
