#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <rootless.h>
#import <dispatch/dispatch.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>

static NSString *gIdentifier;
static NSString *gDisplayName;
static NSString *gLogPath;
static NSUInteger gLogBytes;

// Use the application's writable container so diagnostics survive sandbox restrictions.
static void TGLog(NSString *message) {
    NSLog(@"[TGDeviceMask] %@", message);
    if (gLogPath == nil) {
        return;
    }
    @synchronized (gLogPath) {
        NSData *line = [[NSString stringWithFormat:@"%@ %@\n", [NSDate date], message]
            dataUsingEncoding:NSUTF8StringEncoding];
        if (gLogBytes + line.length > 16384) {
            return;
        }
        FILE *file = fopen(gLogPath.fileSystemRepresentation, "ab");
        if (file != NULL) {
            gLogBytes += fwrite(line.bytes, 1, line.length, file);
            fclose(file);
        }
    }
}

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
        TGLog([NSString stringWithFormat:@"Configuration missing or invalid: %@ (%@)", path, error]);
        return NO;
    }
    NSDictionary *config = root;
    id enabled = config[@"Enabled"];
    if (![enabled isKindOfClass:[NSNumber class]] || ![enabled boolValue]) {
        TGLog(@"Disabled by configuration");
        return NO;
    }
    id identifier = config[@"ModelIdentifier"];
    id displayName = config[@"DisplayName"];
    if (![identifier isKindOfClass:[NSString class]] ||
        ![displayName isKindOfClass:[NSString class]]) {
        TGLog(@"ModelIdentifier and DisplayName must be strings");
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
        TGLog(@"Invalid model value; no hooks installed");
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

%group TelegramInitializer

%hook MTApiEnvironment

// Supplying the name at initialization also keeps the API initialization hash consistent.
- (id)initWithDeviceModelName:(NSString *)name {
    (void)name;
    id result = %orig(gDisplayName);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        TGLog([NSString stringWithFormat:@"Model initializer intercepted; supplied %@", gDisplayName]);
    });
    return result;
}

%end
%end

%group TelegramPlatform
%hook MTApiEnvironment

- (NSString *)platform {
    return gIdentifier;
}

%end
%end

%group TelegramPlatformString
%hook MTApiEnvironment

- (NSString *)platformString {
    return gDisplayName;
}

%end
%end

%group TelegramModel
%hook MTApiEnvironment

- (NSString *)deviceModel {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        TGLog([NSString stringWithFormat:@"deviceModel getter intercepted; returning %@", gDisplayName]);
    });
    return gDisplayName;
}

%end
%end

%group TelegramModelName
%hook MTApiEnvironment

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
        gLogPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"TGDeviceMask-diagnostics.txt"];
        NSError *logError = nil;
        if (![@"TGDeviceMask 1.0.1\n" writeToFile:gLogPath atomically:YES
            encoding:NSUTF8StringEncoding error:&logError]) {
            NSLog(@"[TGDeviceMask] Cannot create diagnostic file: %@", logError);
        }
        TGLog([NSString stringWithFormat:@"Loaded into Telegram %@ (%@)",
            [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
            [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]]);
        if (!TGLoadConfiguration()) {
            return;
        }
        // Hardware queries do not depend on Telegram's private Objective-C interface.
        %init(HardwareQueries);
        struct utsname info;
        if (uname(&info) == 0) {
            TGLog([NSString stringWithFormat:@"uname self-check: %s", info.machine]);
        }
        char machine[256] = {0};
        size_t machineLength = sizeof(machine);
        if (sysctlbyname("hw.machine", machine, &machineLength, NULL, 0) == 0) {
            TGLog([NSString stringWithFormat:@"sysctlbyname self-check: %s", machine]);
        }
        Class environment = NSClassFromString(@"MTApiEnvironment");
        if (environment == Nil) {
            TGLog(@"MTApiEnvironment not found at load; only hardware hooks requested");
            return;
        }
        const SEL selectors[] = {
            @selector(initWithDeviceModelName:), @selector(platform), @selector(platformString),
            @selector(deviceModel), @selector(deviceModelName)
        };
        for (size_t i = 0; i < sizeof(selectors) / sizeof(selectors[0]); ++i) {
            TGLog([NSString stringWithFormat:@"Method %@: %@", NSStringFromSelector(selectors[i]),
                class_getInstanceMethod(environment, selectors[i]) != NULL ? @"present" : @"missing"]);
        }
        // A missing optional method must not disable unrelated hooks.
        if (class_getInstanceMethod(environment, @selector(initWithDeviceModelName:)) != NULL) {
            %init(TelegramInitializer, MTApiEnvironment = environment);
        }
        if (class_getInstanceMethod(environment, @selector(platform)) != NULL) {
            %init(TelegramPlatform, MTApiEnvironment = environment);
        }
        if (class_getInstanceMethod(environment, @selector(platformString)) != NULL) {
            %init(TelegramPlatformString, MTApiEnvironment = environment);
        }
        if (class_getInstanceMethod(environment, @selector(deviceModel)) != NULL) {
            %init(TelegramModel, MTApiEnvironment = environment);
        }
        if (class_getInstanceMethod(environment, @selector(deviceModelName)) != NULL) {
            %init(TelegramModelName, MTApiEnvironment = environment);
        }
        TGLog([NSString stringWithFormat:@"Hook setup finished: %@ / %@", gIdentifier, gDisplayName]);
    }
}
