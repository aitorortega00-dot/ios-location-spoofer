TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LocSpoofGPS
LocSpoofGPS_FILES = Tweak.x
LocSpoofGPS_CFLAGS = -fobjc-arc
LocSpoofGPS_FRAMEWORKS = Foundation CoreLocation

include $(THEOS_MAKE_PATH)/tweak.mk
