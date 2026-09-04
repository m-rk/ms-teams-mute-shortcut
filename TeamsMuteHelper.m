#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <fcntl.h>
#import <sys/file.h>
#import <unistd.h>

typedef NS_ENUM(NSInteger, MicState) {
    MicStateUnknown = 0,
    MicStateMuted,
    MicStateUnmuted,
};

typedef struct {
    pid_t observationPID;
    AXUIElementRef micElement;
    AXUIElementRef meetingWindow;
    MicState state;
} MicContext;

typedef NS_ENUM(NSInteger, DeliveryMode) {
    DeliveryModeHID = 0,
    DeliveryModePID,
    DeliveryModeAX,
};

static BOOL gLoggingEnabled = NO;

static NSString *LogPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/Teams Mute Helper.log"];
}

static void StartLogging(void) {
    gLoggingEnabled = YES;
    [[NSData data] writeToFile:LogPath() atomically:YES];
}

static void WriteLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

static void WriteLog(NSString *format, ...) {
    if (!gLoggingEnabled) {
        return;
    }

    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSString *path = LogPath();
    NSFileManager *files = [NSFileManager defaultManager];
    if (![files fileExistsAtPath:path]) {
        [files createFileAtPath:path contents:nil attributes:nil];
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    [handle seekToEndOfFile];
    [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

static NSString *MicStateName(MicState state) {
    switch (state) {
        case MicStateMuted: return @"muted";
        case MicStateUnmuted: return @"unmuted";
        default: return @"unknown";
    }
}

static AXUIElementRef FindMicElement(AXUIElementRef root, NSInteger depth, NSInteger *visited, MicState *state) {
    if (root == NULL || depth > 90 || *visited >= 50000) {
        return NULL;
    }
    *visited += 1;

    NSArray *attributes = @[
        (__bridge NSString *)kAXTitleAttribute,
        (__bridge NSString *)kAXDescriptionAttribute,
        (__bridge NSString *)kAXHelpAttribute,
        (__bridge NSString *)kAXValueAttribute,
        (__bridge NSString *)kAXChildrenAttribute,
    ];

    CFArrayRef values = NULL;
    AXError error = AXUIElementCopyMultipleAttributeValues(
        root,
        (__bridge CFArrayRef)attributes,
        0,
        &values
    );
    if (error != kAXErrorSuccess || values == NULL) {
        return NULL;
    }

    MicState current = MicStateUnknown;
    for (CFIndex index = 0; index < 4 && index < CFArrayGetCount(values); index++) {
        CFTypeRef value = CFArrayGetValueAtIndex(values, index);
        if (value != NULL && CFGetTypeID(value) == CFStringGetTypeID()) {
            NSString *label = (__bridge NSString *)value;
            if ([label rangeOfString:@"Unmute mic" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                current = MicStateMuted;
                break;
            }
        }
    }
    if (current == MicStateUnknown) {
        for (CFIndex index = 0; index < 4 && index < CFArrayGetCount(values); index++) {
            CFTypeRef value = CFArrayGetValueAtIndex(values, index);
            if (value != NULL && CFGetTypeID(value) == CFStringGetTypeID()) {
                NSString *label = (__bridge NSString *)value;
                if ([label rangeOfString:@"Mute mic" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    current = MicStateUnmuted;
                    break;
                }
            }
        }
    }
    if (current != MicStateUnknown) {
        *state = current;
        CFRetain(root);
        CFRelease(values);
        return root;
    }

    AXUIElementRef result = NULL;
    if (CFArrayGetCount(values) > 4) {
        CFTypeRef childrenValue = CFArrayGetValueAtIndex(values, 4);
        if (childrenValue != NULL && CFGetTypeID(childrenValue) == CFArrayGetTypeID()) {
            CFArrayRef children = (CFArrayRef)childrenValue;
            CFIndex count = CFArrayGetCount(children);
            for (CFIndex index = 0; index < count; index++) {
                CFTypeRef child = CFArrayGetValueAtIndex(children, index);
                if (child != NULL && CFGetTypeID(child) == AXUIElementGetTypeID()) {
                    result = FindMicElement((AXUIElementRef)child, depth + 1, visited, state);
                    if (result != NULL) {
                        break;
                    }
                }
            }
        }
    }
    CFRelease(values);
    return result;
}

static void ReleaseMicContext(MicContext *context) {
    if (context->micElement != NULL) {
        CFRelease(context->micElement);
    }
    if (context->meetingWindow != NULL) {
        CFRelease(context->meetingWindow);
    }
    context->micElement = NULL;
    context->meetingWindow = NULL;
    context->state = MicStateUnknown;
    context->observationPID = 0;
}

static NSArray<NSRunningApplication *> *TeamsProcessCandidates(NSRunningApplication *mainTeams) {
    NSMutableArray<NSRunningApplication *> *candidates = [NSMutableArray array];
    if (mainTeams != nil) {
        [candidates addObject:mainTeams];
    }

    for (NSRunningApplication *application in [[NSWorkspace sharedWorkspace] runningApplications]) {
        if (application.processIdentifier == mainTeams.processIdentifier) {
            continue;
        }
        NSString *name = application.localizedName ?: @"";
        if ([name rangeOfString:@"Teams" options:NSCaseInsensitiveSearch].location != NSNotFound &&
            ![application.bundleIdentifier isEqualToString:@"io.github.m-rk.ms-teams-mute-helper"]) {
            [candidates addObject:application];
        }
    }
    return candidates;
}

static MicContext FindMicContext(NSRunningApplication *mainTeams) {
    MicContext context = {0, NULL, NULL, MicStateUnknown};

    for (NSRunningApplication *application in TeamsProcessCandidates(mainTeams)) {
        AXUIElementRef appElement = AXUIElementCreateApplication(application.processIdentifier);
        CFTypeRef windowsValue = NULL;
        AXError error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute, &windowsValue);
        if (error == kAXErrorSuccess && windowsValue != NULL && CFGetTypeID(windowsValue) == CFArrayGetTypeID()) {
            CFArrayRef windows = (CFArrayRef)windowsValue;
            CFIndex count = CFArrayGetCount(windows);
            for (CFIndex index = 0; index < count; index++) {
                AXUIElementRef window = (AXUIElementRef)CFArrayGetValueAtIndex(windows, index);
                NSInteger visited = 0;
                MicState state = MicStateUnknown;
                AXUIElementRef mic = FindMicElement(window, 0, &visited, &state);
                if (mic != NULL) {
                    context.observationPID = application.processIdentifier;
                    context.micElement = mic;
                    context.meetingWindow = window;
                    CFRetain(window);
                    context.state = state;
                    WriteLog(@"Found mic state=%@ observation_pid=%d nodes=%ld", MicStateName(state), application.processIdentifier, (long)visited);
                    break;
                }
            }
        }
        if (windowsValue != NULL) {
            CFRelease(windowsValue);
        }
        CFRelease(appElement);
        if (context.micElement != NULL) {
            break;
        }
    }

    return context;
}

static BOOL WaitForTeamsFrontmost(pid_t teamsPID) {
    for (NSInteger attempt = 0; attempt < 12; attempt++) {
        NSRunningApplication *frontmost = [[NSWorkspace sharedWorkspace] frontmostApplication];
        if (frontmost.processIdentifier == teamsPID) {
            return YES;
        }
        usleep(50000);
    }
    return NO;
}

static BOOL WaitForModifierRelease(void) {
    CGEventFlags modifiers = kCGEventFlagMaskCommand | kCGEventFlagMaskShift |
                             kCGEventFlagMaskControl | kCGEventFlagMaskAlternate;
    for (NSInteger attempt = 0; attempt < 100; attempt++) {
        CGEventFlags flags = CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
        if ((flags & modifiers) == 0) {
            return YES;
        }
        usleep(20000);
    }
    return NO;
}

static void PostCGKey(DeliveryMode mode, pid_t teamsPID, CGKeyCode keyCode, BOOL keyDown, CGEventFlags flags) {
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, keyCode, keyDown);
    CGEventSetFlags(event, flags);
    if (mode == DeliveryModePID) {
        CGEventPostToPid(teamsPID, event);
    } else {
        CGEventPost(kCGHIDEventTap, event);
    }
    CFRelease(event);
    usleep(15000);
}

static void SendCGShortcut(DeliveryMode mode, pid_t teamsPID) {
    CGEventFlags command = kCGEventFlagMaskCommand;
    CGEventFlags commandShift = kCGEventFlagMaskCommand | kCGEventFlagMaskShift;
    PostCGKey(mode, teamsPID, kVK_Command, YES, command);
    PostCGKey(mode, teamsPID, kVK_Shift, YES, commandShift);
    PostCGKey(mode, teamsPID, kVK_ANSI_M, YES, commandShift);
    PostCGKey(mode, teamsPID, kVK_ANSI_M, NO, commandShift);
    PostCGKey(mode, teamsPID, kVK_Shift, NO, command);
    PostCGKey(mode, teamsPID, kVK_Command, NO, 0);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static void SendAXShortcut(pid_t teamsPID) {
    AXUIElementRef application = AXUIElementCreateApplication(teamsPID);
    AXUIElementPostKeyboardEvent(application, 0, kVK_Command, YES);
    AXUIElementPostKeyboardEvent(application, 0, kVK_Shift, YES);
    AXUIElementPostKeyboardEvent(application, 'm', kVK_ANSI_M, YES);
    usleep(30000);
    AXUIElementPostKeyboardEvent(application, 'm', kVK_ANSI_M, NO);
    AXUIElementPostKeyboardEvent(application, 0, kVK_Shift, NO);
    AXUIElementPostKeyboardEvent(application, 0, kVK_Command, NO);
    CFRelease(application);
}
#pragma clang diagnostic pop

static NSString *DeliveryModeName(DeliveryMode mode) {
    switch (mode) {
        case DeliveryModeHID: return @"hid";
        case DeliveryModePID: return @"pid";
        case DeliveryModeAX: return @"ax";
    }
}

static BOOL SendAndVerify(DeliveryMode mode, NSRunningApplication *teams, MicState before) {
    WriteLog(@"Sending shortcut mode=%@", DeliveryModeName(mode));
    if (mode == DeliveryModeAX) {
        SendAXShortcut(teams.processIdentifier);
    } else {
        SendCGShortcut(mode, teams.processIdentifier);
    }

    usleep(650000);
    MicContext after = FindMicContext(teams);
    BOOL changed = before != MicStateUnknown && after.state != MicStateUnknown && after.state != before;
    WriteLog(@"Verification mode=%@ before=%@ after=%@ changed=%@",
             DeliveryModeName(mode), MicStateName(before), MicStateName(after.state), changed ? @"yes" : @"no");
    ReleaseMicContext(&after);
    return changed;
}

static int RunHelper(BOOL diagnoseOnly) {
    BOOL trusted = AXIsProcessTrusted();
    WriteLog(@"Start native helper trusted=%@ diagnose=%@", trusted ? @"yes" : @"no", diagnoseOnly ? @"yes" : @"no");
    if (!trusted) {
        WriteLog(@"Accessibility permission is not active");
        return 2;
    }

    NSRunningApplication *teams = [[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.microsoft.teams2"] firstObject];
    if (teams == nil || teams.terminated) {
        WriteLog(@"Microsoft Teams is not running");
        return 3;
    }

    MicContext before = FindMicContext(teams);
    if (diagnoseOnly) {
        BOOL foundState = before.state != MicStateUnknown;
        WriteLog(@"Diagnostic complete state=%@", MicStateName(before.state));
        ReleaseMicContext(&before);
        return foundState ? 0 : 4;
    }

    NSRunningApplication *previous = [[NSWorkspace sharedWorkspace] frontmostApplication];
    if (before.meetingWindow != NULL) {
        AXUIElementPerformAction(before.meetingWindow, kAXRaiseAction);
        AXUIElementSetAttributeValue(before.meetingWindow, kAXMainAttribute, kCFBooleanTrue);
        AXUIElementSetAttributeValue(before.meetingWindow, kAXFocusedAttribute, kCFBooleanTrue);
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    BOOL activationRequested = [teams activateWithOptions:(NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps)];
#pragma clang diagnostic pop
    BOOL frontmost = WaitForTeamsFrontmost(teams.processIdentifier);
    BOOL released = WaitForModifierRelease();
    WriteLog(@"Activation requested=%@ frontmost=%@ modifiers_released=%@",
             activationRequested ? @"yes" : @"no", frontmost ? @"yes" : @"no", released ? @"yes" : @"no");

    BOOL changed = NO;
    if (before.state == MicStateUnknown) {
        SendCGShortcut(DeliveryModeHID, teams.processIdentifier);
        WriteLog(@"Mic state was unavailable; sent one unverified HID shortcut");
    } else {
        changed = SendAndVerify(DeliveryModeHID, teams, before.state);
        if (!changed) {
            changed = SendAndVerify(DeliveryModePID, teams, before.state);
        }
        if (!changed) {
            changed = SendAndVerify(DeliveryModeAX, teams, before.state);
        }
    }

    usleep(150000);
    if (previous != nil && !previous.terminated && previous.processIdentifier != teams.processIdentifier) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [previous activateWithOptions:NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop
    }

    BOOL unverified = before.state == MicStateUnknown;
    WriteLog(@"Finished changed=%@", changed ? @"yes" : @"no");
    ReleaseMicContext(&before);
    return changed || unverified ? 0 : 5;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL diagnoseOnly = NO;
        BOOL verbose = NO;
        for (int index = 1; index < argc; index++) {
            if (strcmp(argv[index], "--diagnose") == 0) {
                diagnoseOnly = YES;
            } else if (strcmp(argv[index], "--verbose") == 0) {
                verbose = YES;
            }
        }
        if (diagnoseOnly || verbose) {
            StartLogging();
        }

        int lockFile = open("/tmp/io.github.m-rk.ms-teams-mute-helper.lock", O_CREAT | O_RDWR, 0600);
        if (lockFile < 0 || flock(lockFile, LOCK_EX | LOCK_NB) != 0) {
            WriteLog(@"Another helper instance is already running");
            return 0;
        }

        int result = RunHelper(diagnoseOnly);
        flock(lockFile, LOCK_UN);
        close(lockFile);
        return result;
    }
}
