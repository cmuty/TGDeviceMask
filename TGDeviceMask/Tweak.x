#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <rootless.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <errno.h>
#include <string.h>

static NSString *gIdentifier;
static NSString *gDisplayName;

// Preserve the two-call sysctl size-query protocol, including the terminator.
static int TGCopyMachine(void *output, size_t *outputLength) {
    if (outputLength == NULL) {
        errno = EFAULT;
        return -1;
    }
    const char *value = gIdentifier.UTF8String;
    const size_t needed = strlen(value) + 1;
    if (output == NULL) {
        *outputLength = needed;
        return 0;
    }
    const size_t capacity = *outputLength;
    const size_t count = capacity < needed ? capacity : needed;
    if (count != 0) {
        memcpy(output, value, count);
    }
    *outputLength = needed;
    if (capacity < needed) {
        errno = ENOMEM;
        return -1;
    }
    return 0;
}

static BOOL TGLoadConfiguration(void) {
    NSString *path = ROOT_PATH_NS(@"/Library/Application Support/TGDeviceMask/config.plist");
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSError *error = nil;
    id root = data == nil ? nil : [NSPropertyListSerialization
        propertyListWithData:data options:NSPropertyListImmutable format:NULL error:&error];
    if (![root isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[TGDeviceMask] Configuration missing or invalid: %@ (%@)", path, error);
        return NO;
    }
    NSDictionary *config = root;
    id enabled = config[@"Enabled"];
    if (![enabled isKindOfClass:[NSNumber class]] || ![enabled boolValue]) {
        NSLog(@"[TGDeviceMask] Disabled by configuration");
        return NO;
    }
    id identifier = config[@"ModelIdentifier"];
    id displayName = config[@"DisplayName"];
    if (![identifier isKindOfClass:[NSString class]] ||
        ![displayName isKindOfClass:[NSString class]]) {
        NSLog(@"[TGDeviceMask] ModelIdentifier and DisplayName must be strings");
        return NO;
    }
    NSString *identifierString = identifier;
    NSString *displayString = displayName;
    NSRange match = [identifierString rangeOfString:@"^iPhone[0-9]+,[0-9]+$"
        options:NSRegularExpressionSearch];
    const NSUInteger byteLength = [identifierString lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (match.location != 0 || match.length != identifierString.length ||
        identifierString.length == 0 || byteLength >= sizeof(((struct utsname *)0)->machine) ||
        displayString.length == 0 || displayString.length > 64 ||
        [displayString rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound) {
        NSLog(@"[TGDeviceMask] Invalid model value; no hooks installed");
        return NO;
    }
    gIdentifier = [identifierString copy];
    gDisplayName = [displayString copy];
    return YES;
}

%group HardwareQueries

%hookf(int, sysctlbyname, const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (name != NULL && strcmp(name, "hw.machine") == 0 && newp == NULL && newlen == 0) {
        return TGCopyMachine(oldp, oldlenp);
    }
    return %orig;
}

%hookf(int, sysctl, int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (name != NULL && namelen == 2 && name[0] == CTL_HW && name[1] == HW_MACHINE &&
        newp == NULL && newlen == 0) {
        return TGCopyMachine(oldp, oldlenp);
    }
    return %orig;
}

%hookf(int, uname, struct utsname *info) {
    int result = %orig;
    if (result == 0 && info != NULL) {
        const char *identifier = gIdentifier.UTF8String;
        memset(info->machine, 0, sizeof(info->machine));
        memcpy(info->machine, identifier, strlen(identifier));
    }
    return result;
}

%end

%group TelegramEnvironment

%hook MTApiEnvironment

// Supplying the name at initialization also keeps the API initialization hash consistent.
- (id)initWithDeviceModelName:(NSString *)name {
    (void)name;
    return %orig(gDisplayName);
}

- (NSString *)platform {
    return gIdentifier;
}

- (NSString *)platformString {
    return gDisplayName;
}

- (NSString *)deviceModel {
    return gDisplayName;
}

- (NSString *)deviceModelName {
    return gDisplayName;
}

%end
%end

%ctor {
    @autoreleasepool {
        // The loader filter and this runtime guard independently restrict the target.
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"ph.telegra.Telegraph"]) {
            return;
        }
        if (!TGLoadConfiguration()) {
            return;
        }
        Class environment = NSClassFromString(@"MTApiEnvironment");
        const SEL required[] = {
            @selector(initWithDeviceModelName:), @selector(platform),
            @selector(platformString), @selector(deviceModel), @selector(deviceModelName)
        };
        BOOL compatible = environment != Nil;
        for (size_t i = 0; compatible && i < sizeof(required) / sizeof(required[0]); ++i) {
            compatible = class_getInstanceMethod(environment, required[i]) != NULL;
        }
        if (!compatible) {
            NSLog(@"[TGDeviceMask] MTApiEnvironment interface unavailable; no hooks installed");
            return;
        }
        %init(HardwareQueries);
        %init(TelegramEnvironment, MTApiEnvironment = environment);
        NSLog(@"[TGDeviceMask] Hooks requested: %@ / %@", gIdentifier, gDisplayName);
    }
}
