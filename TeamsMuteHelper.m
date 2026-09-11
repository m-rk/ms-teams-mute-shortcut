#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <ServiceManagement/ServiceManagement.h>
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

typedef NS_ENUM(NSInteger, ShortcutRecorderTarget) {
    ShortcutRecorderTargetNone = 0,
    ShortcutRecorderTargetGlobal,
    ShortcutRecorderTargetTeams,
};

static BOOL gLoggingEnabled = NO;
static const UInt32 kDefaultHotKeyKeyCode = kVK_ANSI_A;
static const UInt32 kDefaultHotKeyModifiers = cmdKey | controlKey | shiftKey;
static const UInt32 kDefaultTeamsShortcutKeyCode = kVK_ANSI_M;
static const UInt32 kDefaultTeamsShortcutModifiers = cmdKey | shiftKey;
static NSString *const kHotKeyKeyCodePreference = @"HotKeyKeyCode";
static NSString *const kHotKeyModifiersPreference = @"HotKeyModifiers";
static NSString *const kHotKeyLabelPreference = @"HotKeyLabel";
static NSString *const kTeamsShortcutKeyCodePreference = @"TeamsShortcutKeyCode";
static NSString *const kTeamsShortcutModifiersPreference = @"TeamsShortcutModifiers";
static NSString *const kTeamsShortcutLabelPreference = @"TeamsShortcutLabel";
static NSString *const kOnboardingCompletedPreference = @"SettingsOnboardingCompleted";
static NSString *const kAutomaticUpdateChecksPreference = @"AutomaticUpdateChecks";
static NSString *const kLastUpdateCheckPreference = @"LastUpdateCheck";
static const NSTimeInterval kAutomaticUpdateCheckInterval = 24.0 * 60.0 * 60.0;

@interface TeamsMuteHelperDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate> {
    NSStatusItem *_statusItem;
    EventHotKeyRef _hotKey;
    EventHandlerRef _eventHandler;
    BOOL _hotKeyRegistered;
    BOOL _toggleInProgress;
    BOOL _settingsHotKeyMainKeyDown;
    UInt32 _hotKeyKeyCode;
    UInt32 _hotKeyModifiers;
    NSString *_hotKeyLabel;
    UInt32 _teamsShortcutKeyCode;
    UInt32 _teamsShortcutModifiers;
    NSString *_teamsShortcutLabel;
    NSMenuItem *_toggleMenuItem;
    NSMenuItem *_launchAtLoginMenuItem;
    NSMenuItem *_updateMenuItem;
    NSMenuItem *_accessibilityMenuItem;
    NSWindow *_settingsWindow;
    ShortcutRecorderTarget _recordingTarget;
    BOOL _suppressRecordedShortcutRelease;
    UInt32 _suppressRecordedShortcutKeyCode;
    id _shortcutEventMonitor;
    NSButton *_globalShortcutField;
    NSButton *_teamsShortcutField;
    NSTextField *_recordingHint;
    NSButton *_globalResetButton;
    NSButton *_teamsResetButton;
    NSButton *_testTeamsShortcutButton;
    NSButton *_automaticUpdatesCheckbox;
    NSTextField *_updateStatusLabel;
    NSButton *_checkUpdatesButton;
    NSButton *_launchAtLoginCheckbox;
    NSView *_accessibilityStatusBadge;
    NSTextField *_accessibilityStatusLabel;
    NSButton *_accessibilitySettingsButton;
    NSURL *_availableUpdateURL;
    BOOL _updateCheckInProgress;
    BOOL _automaticUpdateCheckScheduled;
}

- (void)handleGlobalHotKey;

@end

static TeamsMuteHelperDelegate *gApplicationDelegate = nil;

static BOOL IsInApplicationsFolder(void) {
    NSString *bundlePath = NSBundle.mainBundle.bundlePath.stringByStandardizingPath;
    NSArray<NSString *> *applicationFolders = NSSearchPathForDirectoriesInDomains(
        NSApplicationDirectory,
        NSUserDomainMask | NSLocalDomainMask,
        YES
    );
    for (NSString *folder in applicationFolders) {
        NSString *prefix = [folder.stringByStandardizingPath stringByAppendingString:@"/"];
        if ([bundlePath hasPrefix:prefix]) {
            return YES;
        }
    }
    return NO;
}

static NSString *CurrentVersion(void) {
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return version.length > 0 ? version : @"Unknown";
}

static BOOL VersionIsNewer(NSString *candidate, NSString *current) {
    return [candidate compare:current options:NSNumericSearch] == NSOrderedDescending;
}

static int SetLaunchAtLoginEnabled(BOOL enabled) {
    if (enabled && !IsInApplicationsFolder()) {
        fprintf(stderr, "Move Teams Mute Helper.app to an Applications folder first.\n");
        return 6;
    }

    SMAppService *service = SMAppService.mainAppService;
    if (enabled && (service.status == SMAppServiceStatusEnabled ||
                    service.status == SMAppServiceStatusRequiresApproval)) {
        return 0;
    }
    if (!enabled && service.status == SMAppServiceStatusNotRegistered) {
        return 0;
    }

    NSError *error = nil;
    BOOL changed = enabled
        ? [service registerAndReturnError:&error]
        : [service unregisterAndReturnError:&error];
    if (!changed && error != nil) {
        fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
        return 7;
    }
    return 0;
}

static BOOL LoadHotKeyPreference(UInt32 *keyCode, UInt32 *modifiers, NSString **label) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSNumber *savedKeyCode = [defaults objectForKey:kHotKeyKeyCodePreference];
    NSNumber *savedModifiers = [defaults objectForKey:kHotKeyModifiersPreference];
    NSString *savedLabel = [defaults stringForKey:kHotKeyLabelPreference];

    UInt32 allowedModifiers = cmdKey | controlKey | shiftKey | optionKey;
    UInt32 candidateModifiers = savedModifiers != nil ? savedModifiers.unsignedIntValue : 0;
    if (savedKeyCode == nil || (candidateModifiers & allowedModifiers) == 0) {
        *keyCode = kDefaultHotKeyKeyCode;
        *modifiers = kDefaultHotKeyModifiers;
        *label = @"A";
        return NO;
    }

    *keyCode = savedKeyCode.unsignedIntValue;
    *modifiers = candidateModifiers & allowedModifiers;
    *label = savedLabel.length > 0 ? savedLabel : [NSString stringWithFormat:@"Key %u", *keyCode];
    return YES;
}

static void SaveHotKeyPreference(UInt32 keyCode, UInt32 modifiers, NSString *label) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:keyCode forKey:kHotKeyKeyCodePreference];
    [defaults setInteger:modifiers forKey:kHotKeyModifiersPreference];
    [defaults setObject:label forKey:kHotKeyLabelPreference];
}

static void LoadTeamsShortcutPreference(UInt32 *keyCode, UInt32 *modifiers, NSString **label) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSNumber *savedKeyCode = [defaults objectForKey:kTeamsShortcutKeyCodePreference];
    NSNumber *savedModifiers = [defaults objectForKey:kTeamsShortcutModifiersPreference];
    NSString *savedLabel = [defaults stringForKey:kTeamsShortcutLabelPreference];
    UInt32 allowedModifiers = cmdKey | controlKey | shiftKey | optionKey;

    UInt32 candidateModifiers = savedModifiers != nil ? savedModifiers.unsignedIntValue : 0;
    if (savedKeyCode == nil || (candidateModifiers & allowedModifiers) == 0) {
        *keyCode = kDefaultTeamsShortcutKeyCode;
        *modifiers = kDefaultTeamsShortcutModifiers;
        *label = @"M";
        return;
    }

    *keyCode = savedKeyCode.unsignedIntValue;
    *modifiers = candidateModifiers & allowedModifiers;
    *label = savedLabel.length > 0 ? savedLabel : [NSString stringWithFormat:@"Key %u", *keyCode];
}

static void SaveTeamsShortcutPreference(UInt32 keyCode, UInt32 modifiers, NSString *label) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:keyCode forKey:kTeamsShortcutKeyCodePreference];
    [defaults setInteger:modifiers forKey:kTeamsShortcutModifiersPreference];
    [defaults setObject:label forKey:kTeamsShortcutLabelPreference];
}

static NSString *HotKeyDisplayString(UInt32 modifiers, NSString *label) {
    NSMutableString *display = [NSMutableString string];
    if ((modifiers & controlKey) != 0) {
        [display appendString:@"⌃"];
    }
    if ((modifiers & optionKey) != 0) {
        [display appendString:@"⌥"];
    }
    if ((modifiers & shiftKey) != 0) {
        [display appendString:@"⇧"];
    }
    if ((modifiers & cmdKey) != 0) {
        [display appendString:@"⌘"];
    }
    [display appendString:label];
    return display;
}

static UInt32 CarbonModifiersFromEvent(NSEventModifierFlags flags) {
    UInt32 modifiers = 0;
    if ((flags & NSEventModifierFlagCommand) != 0) {
        modifiers |= cmdKey;
    }
    if ((flags & NSEventModifierFlagControl) != 0) {
        modifiers |= controlKey;
    }
    if ((flags & NSEventModifierFlagShift) != 0) {
        modifiers |= shiftKey;
    }
    if ((flags & NSEventModifierFlagOption) != 0) {
        modifiers |= optionKey;
    }
    return modifiers;
}

static NSString *KeyLabelFromEvent(NSEvent *event) {
    NSString *characters = event.charactersIgnoringModifiers;
    if (characters.length == 0) {
        return [NSString stringWithFormat:@"Key %hu", event.keyCode];
    }

    unichar character = [characters characterAtIndex:0];
    switch (character) {
        case NSUpArrowFunctionKey: return @"↑";
        case NSDownArrowFunctionKey: return @"↓";
        case NSLeftArrowFunctionKey: return @"←";
        case NSRightArrowFunctionKey: return @"→";
        case NSHomeFunctionKey: return @"Home";
        case NSEndFunctionKey: return @"End";
        case NSPageUpFunctionKey: return @"Page Up";
        case NSPageDownFunctionKey: return @"Page Down";
        case NSDeleteFunctionKey: return @"⌫";
        case NSDeleteCharFunctionKey: return @"⌦";
        case NSF1FunctionKey: return @"F1";
        case NSF2FunctionKey: return @"F2";
        case NSF3FunctionKey: return @"F3";
        case NSF4FunctionKey: return @"F4";
        case NSF5FunctionKey: return @"F5";
        case NSF6FunctionKey: return @"F6";
        case NSF7FunctionKey: return @"F7";
        case NSF8FunctionKey: return @"F8";
        case NSF9FunctionKey: return @"F9";
        case NSF10FunctionKey: return @"F10";
        case NSF11FunctionKey: return @"F11";
        case NSF12FunctionKey: return @"F12";
        case '\r': return @"↩";
        case '\t': return @"⇥";
        case ' ': return @"Space";
        default: return characters.uppercaseString;
    }
}

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
    for (NSInteger attempt = 0; attempt < 50; attempt++) {
        NSRunningApplication *frontmost = [[NSWorkspace sharedWorkspace] frontmostApplication];
        if (frontmost.processIdentifier == teamsPID) {
            return YES;
        }
        usleep(10000);
    }
    return NO;
}

static BOOL WaitForModifierRelease(void) {
    CGEventFlags modifiers = kCGEventFlagMaskCommand | kCGEventFlagMaskShift |
                             kCGEventFlagMaskControl | kCGEventFlagMaskAlternate;
    for (NSInteger attempt = 0; attempt < 400; attempt++) {
        CGEventFlags flags = CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
        if ((flags & modifiers) == 0) {
            return YES;
        }
        usleep(5000);
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
    usleep(1000);
}

static void SendCGShortcut(DeliveryMode mode, pid_t teamsPID, UInt32 keyCode, UInt32 modifiers) {
    CGEventFlags flags = 0;
    if ((modifiers & cmdKey) != 0) {
        flags |= kCGEventFlagMaskCommand;
        PostCGKey(mode, teamsPID, kVK_Command, YES, flags);
    }
    if ((modifiers & controlKey) != 0) {
        flags |= kCGEventFlagMaskControl;
        PostCGKey(mode, teamsPID, kVK_Control, YES, flags);
    }
    if ((modifiers & optionKey) != 0) {
        flags |= kCGEventFlagMaskAlternate;
        PostCGKey(mode, teamsPID, kVK_Option, YES, flags);
    }
    if ((modifiers & shiftKey) != 0) {
        flags |= kCGEventFlagMaskShift;
        PostCGKey(mode, teamsPID, kVK_Shift, YES, flags);
    }

    PostCGKey(mode, teamsPID, (CGKeyCode)keyCode, YES, flags);
    PostCGKey(mode, teamsPID, (CGKeyCode)keyCode, NO, flags);

    if ((modifiers & shiftKey) != 0) {
        flags &= ~kCGEventFlagMaskShift;
        PostCGKey(mode, teamsPID, kVK_Shift, NO, flags);
    }
    if ((modifiers & optionKey) != 0) {
        flags &= ~kCGEventFlagMaskAlternate;
        PostCGKey(mode, teamsPID, kVK_Option, NO, flags);
    }
    if ((modifiers & controlKey) != 0) {
        flags &= ~kCGEventFlagMaskControl;
        PostCGKey(mode, teamsPID, kVK_Control, NO, flags);
    }
    if ((modifiers & cmdKey) != 0) {
        PostCGKey(mode, teamsPID, kVK_Command, NO, 0);
    }
}

static void PostGlobalHotKeyForTesting(UInt32 keyCode, UInt32 carbonModifiers) {
    CGEventFlags flags = 0;
    if ((carbonModifiers & cmdKey) != 0) {
        flags |= kCGEventFlagMaskCommand;
        PostCGKey(DeliveryModeHID, 0, kVK_Command, YES, flags);
    }
    if ((carbonModifiers & controlKey) != 0) {
        flags |= kCGEventFlagMaskControl;
        PostCGKey(DeliveryModeHID, 0, kVK_Control, YES, flags);
    }
    if ((carbonModifiers & optionKey) != 0) {
        flags |= kCGEventFlagMaskAlternate;
        PostCGKey(DeliveryModeHID, 0, kVK_Option, YES, flags);
    }
    if ((carbonModifiers & shiftKey) != 0) {
        flags |= kCGEventFlagMaskShift;
        PostCGKey(DeliveryModeHID, 0, kVK_Shift, YES, flags);
    }

    PostCGKey(DeliveryModeHID, 0, (CGKeyCode)keyCode, YES, flags);
    PostCGKey(DeliveryModeHID, 0, (CGKeyCode)keyCode, NO, flags);

    if ((carbonModifiers & shiftKey) != 0) {
        flags &= ~kCGEventFlagMaskShift;
        PostCGKey(DeliveryModeHID, 0, kVK_Shift, NO, flags);
    }
    if ((carbonModifiers & optionKey) != 0) {
        flags &= ~kCGEventFlagMaskAlternate;
        PostCGKey(DeliveryModeHID, 0, kVK_Option, NO, flags);
    }
    if ((carbonModifiers & controlKey) != 0) {
        flags &= ~kCGEventFlagMaskControl;
        PostCGKey(DeliveryModeHID, 0, kVK_Control, NO, flags);
    }
    if ((carbonModifiers & cmdKey) != 0) {
        PostCGKey(DeliveryModeHID, 0, kVK_Command, NO, 0);
    }
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static void SendAXShortcut(pid_t teamsPID, UInt32 keyCode, UInt32 modifiers) {
    AXUIElementRef application = AXUIElementCreateApplication(teamsPID);
    if ((modifiers & cmdKey) != 0) {
        AXUIElementPostKeyboardEvent(application, 0, kVK_Command, YES);
    }
    if ((modifiers & controlKey) != 0) {
        AXUIElementPostKeyboardEvent(application, 0, kVK_Control, YES);
    }
    if ((modifiers & optionKey) != 0) {
        AXUIElementPostKeyboardEvent(application, 0, kVK_Option, YES);
    }
    if ((modifiers & shiftKey) != 0) {
        AXUIElementPostKeyboardEvent(application, 0, kVK_Shift, YES);
    }
    AXUIElementPostKeyboardEvent(application, 0, (CGKeyCode)keyCode, YES);
    usleep(30000);
    AXUIElementPostKeyboardEvent(application, 0, (CGKeyCode)keyCode, NO);
    if ((modifiers & shiftKey) != 0) {
        AXUIElementPostKeyboardEvent(application, 0, kVK_Shift, NO);
    }
    if ((modifiers & optionKey) != 0) {
        AXUIElementPostKeyboardEvent(application, 0, kVK_Option, NO);
    }
    if ((modifiers & controlKey) != 0) {
        AXUIElementPostKeyboardEvent(application, 0, kVK_Control, NO);
    }
    if ((modifiers & cmdKey) != 0) {
        AXUIElementPostKeyboardEvent(application, 0, kVK_Command, NO);
    }
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

static BOOL WaitForMicStateChange(NSRunningApplication *teams, MicState before, NSTimeInterval timeout) {
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    do {
        NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - started;
        usleep(elapsed < 0.10 ? 5000 : 20000);
        MicContext after = FindMicContext(teams);
        BOOL changed = before != MicStateUnknown && after.state != MicStateUnknown && after.state != before;
        if (changed) {
            WriteLog(@"Observed mic change before=%@ after=%@ latency_ms=%.0f",
                     MicStateName(before), MicStateName(after.state),
                     (CFAbsoluteTimeGetCurrent() - started) * 1000.0);
            ReleaseMicContext(&after);
            return YES;
        }
        ReleaseMicContext(&after);
    } while (CFAbsoluteTimeGetCurrent() - started < timeout);
    return NO;
}

static BOOL SendAndVerify(DeliveryMode mode,
                          NSRunningApplication *teams,
                          MicState before,
                          UInt32 keyCode,
                          UInt32 modifiers) {
    WriteLog(@"Sending shortcut mode=%@", DeliveryModeName(mode));
    if (mode == DeliveryModeAX) {
        SendAXShortcut(teams.processIdentifier, keyCode, modifiers);
    } else {
        SendCGShortcut(mode, teams.processIdentifier, keyCode, modifiers);
    }

    BOOL changed = WaitForMicStateChange(teams, before, 0.65);
    WriteLog(@"Verification mode=%@ before=%@ changed=%@",
             DeliveryModeName(mode), MicStateName(before), changed ? @"yes" : @"no");
    return changed;
}

static int RunHelper(BOOL diagnoseOnly, BOOL reportUnverified) {
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

    UInt32 teamsShortcutKeyCode = 0;
    UInt32 teamsShortcutModifiers = 0;
    NSString *teamsShortcutLabel = nil;
    LoadTeamsShortcutPreference(&teamsShortcutKeyCode, &teamsShortcutModifiers, &teamsShortcutLabel);
    WriteLog(@"Using Teams shortcut %@",
             HotKeyDisplayString(teamsShortcutModifiers, teamsShortcutLabel));

    MicContext before = FindMicContext(teams);
    if (!diagnoseOnly && reportUnverified && before.state == MicStateUnknown) {
        ReleaseMicContext(&before);
        usleep(50000);
        before = FindMicContext(teams);
    }
    if (diagnoseOnly) {
        BOOL foundState = before.state != MicStateUnknown;
        WriteLog(@"Diagnostic complete state=%@", MicStateName(before.state));
        ReleaseMicContext(&before);
        return foundState ? 0 : 4;
    }
    BOOL changed = NO;
    BOOL unverified = before.state == MicStateUnknown;
    if (before.state == MicStateUnknown) {
        SendCGShortcut(DeliveryModePID,
                       teams.processIdentifier,
                       teamsShortcutKeyCode,
                       teamsShortcutModifiers);
        WriteLog(@"Mic state was unavailable; sent one unverified process-targeted shortcut");
    } else {
        changed = SendAndVerify(DeliveryModePID,
                                teams,
                                before.state,
                                teamsShortcutKeyCode,
                                teamsShortcutModifiers);
        if (!changed) {
            changed = SendAndVerify(DeliveryModeAX,
                                    teams,
                                    before.state,
                                    teamsShortcutKeyCode,
                                    teamsShortcutModifiers);
        }
    }

    NSRunningApplication *previous = nil;
    BOOL activatedTeams = NO;
    if (!unverified && !changed) {
        BOOL released = WaitForModifierRelease();
        WriteLog(@"Fallback modifiers released=%@", released ? @"yes" : @"no");
        previous = [[NSWorkspace sharedWorkspace] frontmostApplication];
        if (before.meetingWindow != NULL) {
            AXUIElementPerformAction(before.meetingWindow, kAXRaiseAction);
            AXUIElementSetAttributeValue(before.meetingWindow, kAXMainAttribute, kCFBooleanTrue);
            AXUIElementSetAttributeValue(before.meetingWindow, kAXFocusedAttribute, kCFBooleanTrue);
        }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        BOOL activationRequested = [teams activateWithOptions:(NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps)];
#pragma clang diagnostic pop
        activatedTeams = YES;
        BOOL frontmost = WaitForTeamsFrontmost(teams.processIdentifier);
        WriteLog(@"Fallback activation requested=%@ frontmost=%@",
                 activationRequested ? @"yes" : @"no", frontmost ? @"yes" : @"no");

        changed = SendAndVerify(DeliveryModeHID,
                                teams,
                                before.state,
                                teamsShortcutKeyCode,
                                teamsShortcutModifiers);
        if (!changed) {
            changed = SendAndVerify(DeliveryModePID,
                                    teams,
                                    before.state,
                                    teamsShortcutKeyCode,
                                    teamsShortcutModifiers);
        }
        if (!changed) {
            changed = SendAndVerify(DeliveryModeAX,
                                    teams,
                                    before.state,
                                    teamsShortcutKeyCode,
                                    teamsShortcutModifiers);
        }
    }

    if (activatedTeams && previous != nil && !previous.terminated &&
        previous.processIdentifier != teams.processIdentifier) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [previous activateWithOptions:NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop
    }

    WriteLog(@"Finished changed=%@ focus_fallback=%@",
             changed ? @"yes" : @"no", activatedTeams ? @"yes" : @"no");
    ReleaseMicContext(&before);
    if (changed) {
        return 0;
    }
    if (unverified) {
        return reportUnverified ? 6 : 0;
    }
    return 5;
}

static int TestGlobalHotKey(void) {
    if (!AXIsProcessTrusted()) {
        WriteLog(@"Accessibility permission is required to test the global hotkey");
        return 2;
    }

    NSRunningApplication *teams = [[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.microsoft.teams2"] firstObject];
    if (teams == nil || teams.terminated) {
        WriteLog(@"Microsoft Teams is not running");
        return 3;
    }

    MicContext before = FindMicContext(teams);
    if (before.state == MicStateUnknown) {
        WriteLog(@"No active Teams meeting was found");
        ReleaseMicContext(&before);
        return 4;
    }

    UInt32 keyCode = 0;
    UInt32 modifiers = 0;
    NSString *label = nil;
    LoadHotKeyPreference(&keyCode, &modifiers, &label);
    WriteLog(@"Posting %@ for listener testing; before=%@",
             HotKeyDisplayString(modifiers, label), MicStateName(before.state));
    PostGlobalHotKeyForTesting(keyCode, modifiers);

    BOOL changed = WaitForMicStateChange(teams, before.state, 4.0);

    WriteLog(@"Global hotkey test changed=%@", changed ? @"yes" : @"no");
    ReleaseMicContext(&before);
    return changed ? 0 : 5;
}

static int RunLockedHelper(BOOL diagnoseOnly, BOOL reportUnverified) {
    int lockFile = open("/tmp/io.github.m-rk.ms-teams-mute-helper.lock", O_CREAT | O_RDWR, 0600);
    if (lockFile < 0 || flock(lockFile, LOCK_EX | LOCK_NB) != 0) {
        WriteLog(@"Another helper instance is already running");
        if (lockFile >= 0) {
            close(lockFile);
        }
        return 0;
    }

    int result = RunHelper(diagnoseOnly, reportUnverified);
    flock(lockFile, LOCK_UN);
    close(lockFile);
    return result;
}

static OSStatus HandleHotKeyEvent(EventHandlerCallRef nextHandler, EventRef event, void *context) {
    (void)nextHandler;
    (void)event;
    TeamsMuteHelperDelegate *delegate = (__bridge TeamsMuteHelperDelegate *)context;
    [delegate handleGlobalHotKey];
    return noErr;
}

static NSTextField *SettingsLabel(NSString *text, NSRect frame) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.frame = frame;
    return label;
}

static NSButton *SettingsButton(NSString *title, id target, SEL action, NSRect frame) {
    NSButton *button = [NSButton buttonWithTitle:title target:target action:action];
    button.frame = frame;
    button.bezelStyle = NSBezelStyleRounded;
    return button;
}

static NSButton *ShortcutButton(id target, SEL action, NSRect frame) {
    NSButton *button = SettingsButton(@"", target, action, frame);
    button.font = [NSFont monospacedSystemFontOfSize:17 weight:NSFontWeightSemibold];
    return button;
}

@implementation TeamsMuteHelperDelegate

- (void)setStatusSymbol:(NSString *)symbolName description:(NSString *)description {
    NSImage *image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:description];
    image.template = YES;
    _statusItem.button.image = image;
    _statusItem.button.toolTip = description;
}

- (NSString *)shortcutDisplayString {
    return HotKeyDisplayString(_hotKeyModifiers, _hotKeyLabel);
}

- (void)updateShortcutMenu {
    _toggleMenuItem.title = [NSString stringWithFormat:@"Toggle Teams Mute (%@)", [self shortcutDisplayString]];
}

- (void)showReadyStatus {
    NSString *description = [NSString stringWithFormat:@"Teams Mute Helper %@ — %@",
                              CurrentVersion(), [self shortcutDisplayString]];
    NSString *imagePath = [[NSBundle mainBundle] pathForResource:@"MenuBarIcon" ofType:@"png"];
    NSImage *image = imagePath != nil ? [[NSImage alloc] initWithContentsOfFile:imagePath] : nil;
    if (image == nil) {
        [self setStatusSymbol:@"mic.slash" description:description];
        return;
    }

    image.size = NSMakeSize(18, 18);
    image.template = YES;
    _statusItem.button.image = image;
    _statusItem.button.toolTip = description;
}

- (void)showIdleStatus {
    if (!_hotKeyRegistered) {
        [self setStatusSymbol:@"exclamationmark.triangle"
                  description:[NSString stringWithFormat:@"%@ is already in use", [self shortcutDisplayString]]];
    } else if (!AXIsProcessTrusted()) {
        [self setStatusSymbol:@"exclamationmark.triangle"
                  description:@"Teams Mute Helper needs Accessibility access"];
    } else {
        [self showReadyStatus];
    }
}

- (void)showResult:(int)result {
    if (result == 0 || result == 6) {
        [self showIdleStatus];
        return;
    }

    NSString *description = @"Teams Mute Helper could not toggle mute";
    if (result == 2) {
        description = @"Teams Mute Helper needs Accessibility access";
    } else if (result == 3) {
        description = @"Microsoft Teams is not running";
    } else if (result == 4) {
        description = @"No active Teams meeting was found";
    }
    [self setStatusSymbol:@"exclamationmark.triangle" description:description];

    if (result == 2) {
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!self->_toggleInProgress) {
            [self showIdleStatus];
        }
    });
}

- (void)requestToggleForSettingsTest:(BOOL)settingsTest {
    if (_toggleInProgress) {
        WriteLog(@"Ignored overlapping hotkey press");
        return;
    }

    BOOL showSettingsFeedback = settingsTest || _settingsWindow.visible;
    _toggleInProgress = YES;
    if (showSettingsFeedback) {
        _recordingHint.stringValue = @"Testing in the current Teams meeting…";
        _recordingHint.textColor = NSColor.secondaryLabelColor;
        _testTeamsShortcutButton.enabled = NO;
    }
    [self setStatusSymbol:@"mic.badge.plus" description:@"Toggling Teams mute…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int result = RunLockedHelper(NO, showSettingsFeedback);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_toggleInProgress = NO;
            [self showResult:result];
            if (showSettingsFeedback) {
                NSString *message = @"The shortcut was sent, but the mic state did not change.";
                NSColor *color = NSColor.systemRedColor;
                if (result == 0) {
                    message = @"Worked — the Teams mic state changed.";
                    color = NSColor.systemGreenColor;
                } else if (result == 2) {
                    message = @"Accessibility access is required before this can be tested.";
                } else if (result == 3) {
                    message = @"Microsoft Teams is not running.";
                } else if (result == 4) {
                    message = @"No active Teams meeting was found.";
                } else if (result == 6) {
                    message = @"Shortcut sent — check Teams to confirm.";
                    color = NSColor.secondaryLabelColor;
                }
                self->_recordingHint.stringValue = message;
                self->_recordingHint.textColor = color;
                self->_testTeamsShortcutButton.enabled = YES;
            }
        });
    });
}

- (void)requestToggle {
    [self requestToggleForSettingsTest:NO];
}

- (void)handleGlobalHotKey {
    if (_suppressRecordedShortcutRelease) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            self->_suppressRecordedShortcutRelease = NO;
        });
        return;
    }
    if (_recordingTarget != ShortcutRecorderTargetNone) {
        [self completeShortcutRecordingWithKeyCode:_hotKeyKeyCode
                                         modifiers:_hotKeyModifiers
                                             label:_hotKeyLabel];
        return;
    }
    [self requestToggle];
}

- (void)toggleFromMenu:(id)sender {
    (void)sender;
    [self requestToggle];
}

- (void)testTeamsShortcut:(id)sender {
    (void)sender;
    [self requestToggleForSettingsTest:YES];
}

- (void)showShortcutConflictForDisplay:(NSString *)display {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"That shortcut is already in use";
    alert.informativeText = [NSString stringWithFormat:@"%@ is registered by another app. Your previous shortcut is still active.", display];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (BOOL)replaceHotKeyWithKeyCode:(UInt32)keyCode modifiers:(UInt32)modifiers {
    if (_hotKeyRegistered && _hotKeyKeyCode == keyCode && _hotKeyModifiers == modifiers) {
        return YES;
    }

    UInt32 previousKeyCode = _hotKeyKeyCode;
    UInt32 previousModifiers = _hotKeyModifiers;
    BOOL hadPreviousHotKey = _hotKey != NULL;
    if (_hotKey != NULL) {
        UnregisterEventHotKey(_hotKey);
        _hotKey = NULL;
    }

    EventHotKeyID hotKeyID = {'TMHM', 1};
    EventHotKeyRef replacement = NULL;
    OSStatus status = RegisterEventHotKey(
        keyCode,
        modifiers,
        hotKeyID,
        GetApplicationEventTarget(),
        0,
        &replacement
    );
    if (status == noErr) {
        _hotKey = replacement;
        _hotKeyRegistered = YES;
        WriteLog(@"Registered hotkey key_code=%u modifiers=%u", keyCode, modifiers);
        return YES;
    }

    WriteLog(@"Could not register hotkey key_code=%u modifiers=%u status=%d", keyCode, modifiers, (int)status);
    _hotKeyRegistered = NO;
    if (hadPreviousHotKey) {
        OSStatus restoreStatus = RegisterEventHotKey(
            previousKeyCode,
            previousModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &_hotKey
        );
        _hotKeyRegistered = restoreStatus == noErr;
        WriteLog(@"Restored previous hotkey status=%d", (int)restoreStatus);
    }
    return NO;
}

- (NSString *)teamsShortcutDisplayString {
    return HotKeyDisplayString(_teamsShortcutModifiers, _teamsShortcutLabel);
}

- (void)setShortcutControlsIdleWithHint:(NSString *)hint {
    _recordingTarget = ShortcutRecorderTargetNone;
    _globalShortcutField.title = [self shortcutDisplayString];
    _teamsShortcutField.title = [self teamsShortcutDisplayString];
    _globalShortcutField.enabled = YES;
    _teamsShortcutField.enabled = YES;
    _globalResetButton.enabled = YES;
    _teamsResetButton.enabled = YES;
    _testTeamsShortcutButton.enabled = !_toggleInProgress;
    _automaticUpdatesCheckbox.enabled = YES;
    _checkUpdatesButton.enabled = !_updateCheckInProgress;
    _launchAtLoginCheckbox.enabled = YES;
    _accessibilitySettingsButton.enabled = YES;
    _recordingHint.stringValue = hint ?: @"Join a Teams meeting to test your shortcuts.";
    _recordingHint.textColor = NSColor.secondaryLabelColor;
}

- (void)beginShortcutRecordingForTarget:(ShortcutRecorderTarget)target {
    if (!_settingsWindow.visible || _recordingTarget != ShortcutRecorderTargetNone) {
        return;
    }

    _settingsHotKeyMainKeyDown = NO;
    _recordingTarget = target;
    NSButton *field = target == ShortcutRecorderTargetGlobal
        ? _globalShortcutField
        : _teamsShortcutField;
    field.title = @"Press shortcut…";
    _globalShortcutField.enabled = NO;
    _teamsShortcutField.enabled = NO;
    _globalResetButton.enabled = NO;
    _teamsResetButton.enabled = NO;
    _testTeamsShortcutButton.enabled = NO;
    _automaticUpdatesCheckbox.enabled = NO;
    _checkUpdatesButton.enabled = NO;
    _launchAtLoginCheckbox.enabled = NO;
    _accessibilitySettingsButton.enabled = NO;
    _recordingHint.stringValue = @"Use Control, Option, Shift, or Command. Press Escape to cancel.";
}

- (void)beginGlobalShortcutRecording:(id)sender {
    (void)sender;
    [self beginShortcutRecordingForTarget:ShortcutRecorderTargetGlobal];
}

- (void)beginTeamsShortcutRecording:(id)sender {
    (void)sender;
    [self beginShortcutRecordingForTarget:ShortcutRecorderTargetTeams];
}

- (void)cancelShortcutRecording {
    if (_recordingTarget == ShortcutRecorderTargetNone) {
        return;
    }
    [self setShortcutControlsIdleWithHint:@"Recording cancelled."];
}

- (void)completeShortcutRecordingWithKeyCode:(UInt32)keyCode
                                    modifiers:(UInt32)modifiers
                                        label:(NSString *)label {
    ShortcutRecorderTarget target = _recordingTarget;
    if (target == ShortcutRecorderTargetNone) {
        return;
    }

    _suppressRecordedShortcutRelease = YES;
    _suppressRecordedShortcutKeyCode = keyCode;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        self->_suppressRecordedShortcutRelease = NO;
    });

    if (target == ShortcutRecorderTargetGlobal) {
        NSString *display = HotKeyDisplayString(modifiers, label);
        if (![self replaceHotKeyWithKeyCode:keyCode modifiers:modifiers]) {
            [self setShortcutControlsIdleWithHint:@"The previous global shortcut is still active."];
            [self showShortcutConflictForDisplay:display];
            [self showIdleStatus];
            return;
        }
        _hotKeyKeyCode = keyCode;
        _hotKeyModifiers = modifiers;
        _hotKeyLabel = label;
        SaveHotKeyPreference(keyCode, modifiers, label);
        [self updateShortcutMenu];
        [self showIdleStatus];
    } else {
        _teamsShortcutKeyCode = keyCode;
        _teamsShortcutModifiers = modifiers;
        _teamsShortcutLabel = label;
        SaveTeamsShortcutPreference(keyCode, modifiers, label);
        _recordingHint.stringValue = @"Use Test to confirm this matches Teams.";
        _recordingHint.textColor = NSColor.secondaryLabelColor;
    }

    [self setShortcutControlsIdleWithHint:@"Shortcut saved."];
}

- (void)restoreDefaultGlobalShortcut:(id)sender {
    (void)sender;
    if (![self replaceHotKeyWithKeyCode:kDefaultHotKeyKeyCode modifiers:kDefaultHotKeyModifiers]) {
        [self showShortcutConflictForDisplay:HotKeyDisplayString(kDefaultHotKeyModifiers, @"A")];
        return;
    }
    _hotKeyKeyCode = kDefaultHotKeyKeyCode;
    _hotKeyModifiers = kDefaultHotKeyModifiers;
    _hotKeyLabel = @"A";
    SaveHotKeyPreference(_hotKeyKeyCode, _hotKeyModifiers, _hotKeyLabel);
    [self updateShortcutMenu];
    [self setShortcutControlsIdleWithHint:@"Global shortcut restored to its default."];
    [self showIdleStatus];
}

- (void)restoreDefaultTeamsShortcut:(id)sender {
    (void)sender;
    _teamsShortcutKeyCode = kDefaultTeamsShortcutKeyCode;
    _teamsShortcutModifiers = kDefaultTeamsShortcutModifiers;
    _teamsShortcutLabel = @"M";
    SaveTeamsShortcutPreference(_teamsShortcutKeyCode, _teamsShortcutModifiers, _teamsShortcutLabel);
    _recordingHint.stringValue = @"Use Test to confirm this matches Teams.";
    _recordingHint.textColor = NSColor.secondaryLabelColor;
    [self setShortcutControlsIdleWithHint:@"Teams shortcut restored to its default."];
}

- (void)installShortcutEventMonitor {
    if (_shortcutEventMonitor != nil) {
        return;
    }
    NSEventMask shortcutMask = NSEventMaskKeyDown | NSEventMaskKeyUp;
    _shortcutEventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:shortcutMask
                                                                   handler:^NSEvent *(NSEvent *event) {
        if (self->_recordingTarget == ShortcutRecorderTargetNone) {
            if (event.type == NSEventTypeKeyUp && self->_suppressRecordedShortcutRelease &&
                event.keyCode == self->_suppressRecordedShortcutKeyCode) {
                self->_settingsHotKeyMainKeyDown = NO;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    self->_suppressRecordedShortcutRelease = NO;
                });
                return nil;
            }
            UInt32 modifiers = CarbonModifiersFromEvent(event.modifierFlags);
            if (event.type == NSEventTypeKeyDown && event.keyCode == self->_hotKeyKeyCode &&
                modifiers == self->_hotKeyModifiers) {
                if (!event.isARepeat) {
                    self->_settingsHotKeyMainKeyDown = YES;
                }
                return nil;
            }
            if (event.type == NSEventTypeKeyUp && event.keyCode == self->_hotKeyKeyCode &&
                self->_settingsHotKeyMainKeyDown) {
                self->_settingsHotKeyMainKeyDown = NO;
                [self handleGlobalHotKey];
                return nil;
            }
            return event;
        }
        if (event.type != NSEventTypeKeyDown) {
            return nil;
        }
        if (event.isARepeat) {
            return nil;
        }

        UInt32 modifiers = CarbonModifiersFromEvent(event.modifierFlags);
        if (modifiers == 0) {
            if (event.keyCode == kVK_Escape) {
                [self cancelShortcutRecording];
                return nil;
            }
            NSBeep();
            self->_recordingHint.stringValue = @"Include at least one modifier key.";
            return nil;
        }

        [self completeShortcutRecordingWithKeyCode:event.keyCode
                                         modifiers:modifiers
                                             label:KeyLabelFromEvent(event)];
        return nil;
    }];
}

- (void)refreshUpdateControls {
    if (_checkUpdatesButton == nil) {
        return;
    }
    if (_updateCheckInProgress) {
        _updateStatusLabel.stringValue = @"Checking GitHub for the latest release…";
        _checkUpdatesButton.title = @"Checking…";
        _checkUpdatesButton.enabled = NO;
        return;
    }

    _checkUpdatesButton.enabled = YES;
    if (_availableUpdateURL != nil) {
        _checkUpdatesButton.title = @"View Update…";
        return;
    }

    _checkUpdatesButton.title = @"Check for Updates…";
    NSDate *lastCheck = [[NSUserDefaults standardUserDefaults] objectForKey:kLastUpdateCheckPreference];
    if (lastCheck != nil) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateStyle = NSDateFormatterMediumStyle;
        formatter.timeStyle = NSDateFormatterShortStyle;
        _updateStatusLabel.stringValue = [NSString stringWithFormat:@"Last checked %@.",
                                          [formatter stringFromDate:lastCheck]];
    } else {
        _updateStatusLabel.stringValue = @"Updates have not been checked yet.";
    }
}

- (void)refreshSettingsStatus {
    if (_settingsWindow == nil) {
        return;
    }
    [self setShortcutControlsIdleWithHint:nil];
    [self syncLaunchAtLoginMenuItem];
    BOOL trusted = AXIsProcessTrusted();
    _accessibilityStatusLabel.stringValue = trusted
        ? @"Accessibility granted"
        : @"Accessibility required";
    _accessibilityStatusLabel.textColor = NSColor.labelColor;
    NSColor *badgeColor = trusted
        ? [NSColor.systemGreenColor colorWithAlphaComponent:0.20]
        : [NSColor.systemOrangeColor colorWithAlphaComponent:0.22];
    _accessibilityStatusBadge.layer.backgroundColor = badgeColor.CGColor;
    [self refreshUpdateControls];
}

- (void)buildSettingsWindow {
    NSRect frame = NSMakeRect(0, 0, 580, 560);
    NSPanel *settingsPanel = [[NSPanel alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled |
                             NSWindowStyleMaskClosable |
                             NSWindowStyleMaskNonactivatingPanel)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    settingsPanel.floatingPanel = YES;
    settingsPanel.hidesOnDeactivate = NO;
    settingsPanel.becomesKeyOnlyIfNeeded = NO;
    _settingsWindow = settingsPanel;
    _settingsWindow.releasedWhenClosed = NO;
    _settingsWindow.delegate = self;
    [_settingsWindow standardWindowButton:NSWindowMiniaturizeButton].hidden = YES;
    [_settingsWindow standardWindowButton:NSWindowZoomButton].hidden = YES;

    NSView *content = _settingsWindow.contentView;
    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(26, 456, 72, 72)];
    icon.image = NSApp.applicationIconImage;
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    [content addSubview:icon];

    NSTextField *title = SettingsLabel(@"Teams Mute Helper", NSMakeRect(116, 497, 430, 32));
    title.font = [NSFont systemFontOfSize:24 weight:NSFontWeightSemibold];
    [content addSubview:title];

    NSTextField *version = SettingsLabel([NSString stringWithFormat:@"Version %@", CurrentVersion()],
                                         NSMakeRect(117, 471, 420, 22));
    version.textColor = NSColor.secondaryLabelColor;
    [content addSubview:version];

    NSTextField *summary = SettingsLabel(@"Mute or unmute Microsoft Teams from anywhere with one global shortcut.",
                                         NSMakeRect(116, 432, 430, 34));
    summary.textColor = NSColor.secondaryLabelColor;
    summary.maximumNumberOfLines = 2;
    summary.usesSingleLineMode = NO;
    summary.lineBreakMode = NSLineBreakByWordWrapping;
    [content addSubview:summary];

    NSTextField *shortcutsTitle = SettingsLabel(@"Shortcuts", NSMakeRect(30, 397, 500, 22));
    shortcutsTitle.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    [content addSubview:shortcutsTitle];
    NSBox *shortcuts = [[NSBox alloc] initWithFrame:NSMakeRect(20, 253, 540, 136)];
    shortcuts.titlePosition = NSNoTitle;
    [content addSubview:shortcuts];
    [shortcuts addSubview:SettingsLabel(@"Global shortcut", NSMakeRect(20, 88, 120, 24))];
    _globalShortcutField = ShortcutButton(self,
                                          @selector(beginGlobalShortcutRecording:),
                                          NSMakeRect(150, 84, 190, 32));
    [shortcuts addSubview:_globalShortcutField];
    _globalResetButton = SettingsButton(@"Reset", self,
                                         @selector(restoreDefaultGlobalShortcut:),
                                         NSMakeRect(350, 84, 72, 32));
    [shortcuts addSubview:_globalResetButton];

    [shortcuts addSubview:SettingsLabel(@"Teams shortcut", NSMakeRect(20, 47, 120, 24))];
    _teamsShortcutField = ShortcutButton(self,
                                         @selector(beginTeamsShortcutRecording:),
                                         NSMakeRect(150, 43, 190, 32));
    [shortcuts addSubview:_teamsShortcutField];
    _teamsResetButton = SettingsButton(@"Reset", self,
                                        @selector(restoreDefaultTeamsShortcut:),
                                        NSMakeRect(350, 43, 72, 32));
    [shortcuts addSubview:_teamsResetButton];
    _testTeamsShortcutButton = SettingsButton(@"Test", self,
                                               @selector(testTeamsShortcut:),
                                               NSMakeRect(432, 43, 72, 32));
    [shortcuts addSubview:_testTeamsShortcutButton];

    _recordingHint = SettingsLabel(@"", NSMakeRect(20, 12, 500, 20));
    _recordingHint.textColor = NSColor.secondaryLabelColor;
    [shortcuts addSubview:_recordingHint];

    NSTextField *updatesTitle = SettingsLabel(@"Updates", NSMakeRect(30, 219, 500, 22));
    updatesTitle.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    [content addSubview:updatesTitle];
    NSBox *updates = [[NSBox alloc] initWithFrame:NSMakeRect(20, 116, 540, 95)];
    updates.titlePosition = NSNoTitle;
    [content addSubview:updates];
    _automaticUpdatesCheckbox = [NSButton checkboxWithTitle:@"Check automatically once a day"
                                                     target:self
                                                     action:@selector(automaticUpdateSettingChanged:)];
    _automaticUpdatesCheckbox.frame = NSMakeRect(20, 48, 300, 24);
    [updates addSubview:_automaticUpdatesCheckbox];
    _checkUpdatesButton = SettingsButton(@"Check for Updates…", self,
                                          @selector(checkForUpdates:),
                                          NSMakeRect(350, 43, 170, 32));
    [updates addSubview:_checkUpdatesButton];
    _updateStatusLabel = SettingsLabel(@"", NSMakeRect(20, 14, 500, 22));
    _updateStatusLabel.textColor = NSColor.secondaryLabelColor;
    [updates addSubview:_updateStatusLabel];

    NSTextField *startupTitle = SettingsLabel(@"Startup and Permissions", NSMakeRect(30, 83, 500, 22));
    startupTitle.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    [content addSubview:startupTitle];
    NSBox *startup = [[NSBox alloc] initWithFrame:NSMakeRect(20, 14, 540, 61)];
    startup.titlePosition = NSNoTitle;
    [content addSubview:startup];
    _launchAtLoginCheckbox = [NSButton checkboxWithTitle:@"Launch at Login"
                                                  target:self
                                                  action:@selector(toggleLaunchAtLogin:)];
    _launchAtLoginCheckbox.frame = NSMakeRect(20, 19, 140, 24);
    [startup addSubview:_launchAtLoginCheckbox];
    _accessibilityStatusBadge = [[NSView alloc] initWithFrame:NSMakeRect(170, 18, 190, 24)];
    _accessibilityStatusBadge.wantsLayer = YES;
    _accessibilityStatusBadge.layer.cornerRadius = 6.0;
    [startup addSubview:_accessibilityStatusBadge];
    _accessibilityStatusLabel = SettingsLabel(@"", NSZeroRect);
    _accessibilityStatusLabel.alignment = NSTextAlignmentCenter;
    _accessibilityStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_accessibilityStatusBadge addSubview:_accessibilityStatusLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_accessibilityStatusLabel.centerXAnchor constraintEqualToAnchor:_accessibilityStatusBadge.centerXAnchor],
        [_accessibilityStatusLabel.centerYAnchor constraintEqualToAnchor:_accessibilityStatusBadge.centerYAnchor],
        [_accessibilityStatusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_accessibilityStatusBadge.leadingAnchor
                                                                             constant:8.0],
        [_accessibilityStatusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_accessibilityStatusBadge.trailingAnchor
                                                                              constant:-8.0],
    ]];
    _accessibilitySettingsButton = SettingsButton(@"Open Settings…", self,
                                                   @selector(openAccessibilitySettings:),
                                                   NSMakeRect(370, 14, 150, 32));
    [startup addSubview:_accessibilitySettingsButton];
}

- (void)showSettingsWindowForOnboarding:(BOOL)onboarding {
    if (_settingsWindow == nil) {
        [self buildSettingsWindow];
    }
    _settingsWindow.title = onboarding ? @"Welcome to Teams Mute Helper" : @"Teams Mute Helper Settings";

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSNumber *automaticSetting = [defaults objectForKey:kAutomaticUpdateChecksPreference];
    if (automaticSetting == nil) {
        [defaults setBool:YES forKey:kAutomaticUpdateChecksPreference];
        automaticSetting = @YES;
    }
    if (onboarding) {
        [defaults setBool:YES forKey:kOnboardingCompletedPreference];
    }
    _automaticUpdatesCheckbox.state = automaticSetting.boolValue
        ? NSControlStateValueOn
        : NSControlStateValueOff;
    [self refreshSettingsStatus];
    [self installShortcutEventMonitor];

    [_settingsWindow center];
    [_settingsWindow orderFrontRegardless];
    [self scheduleAutomaticUpdateCheck];
}

- (void)showSettings:(id)sender {
    (void)sender;
    [self showSettingsWindowForOnboarding:NO];
}

- (void)automaticUpdateSettingChanged:(id)sender {
    (void)sender;
    BOOL automatic = _automaticUpdatesCheckbox.state == NSControlStateValueOn;
    [[NSUserDefaults standardUserDefaults] setBool:automatic
                                            forKey:kAutomaticUpdateChecksPreference];
    if (automatic) {
        [self scheduleAutomaticUpdateCheck];
    }
}

- (void)checkForUpdates:(id)sender {
    (void)sender;
    if (_availableUpdateURL != nil) {
        [[NSWorkspace sharedWorkspace] openURL:_availableUpdateURL];
        return;
    }
    [self performUpdateCheckUserInitiated:YES];
}

- (void)checkForUpdatesFromMenu:(id)sender {
    (void)sender;
    if (_availableUpdateURL != nil) {
        [[NSWorkspace sharedWorkspace] openURL:_availableUpdateURL];
        return;
    }
    [self showSettingsWindowForOnboarding:NO];
    [self performUpdateCheckUserInitiated:YES];
}

- (void)performUpdateCheckUserInitiated:(BOOL)userInitiated {
    (void)userInitiated;
    if (_updateCheckInProgress) {
        return;
    }
    _updateCheckInProgress = YES;
    [self refreshUpdateControls];

    NSURL *url = [NSURL URLWithString:@"https://api.github.com/repos/m-rk/ms-teams-mute-shortcut/releases/latest"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Teams-Mute-Helper" forHTTPHeaderField:@"User-Agent"];
    request.timeoutInterval = 15.0;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *candidateVersion = nil;
        NSURL *releaseURL = nil;
        NSString *failure = nil;
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (error != nil) {
            failure = error.localizedDescription;
        } else if (![http isKindOfClass:NSHTTPURLResponse.class] || http.statusCode != 200) {
            failure = @"GitHub did not return a release.";
        } else {
            NSError *jsonError = nil;
            NSDictionary *release = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (![release isKindOfClass:NSDictionary.class] || jsonError != nil) {
                failure = @"The release response could not be read.";
            } else {
                NSString *tag = release[@"tag_name"];
                NSString *page = release[@"html_url"];
                if ([tag hasPrefix:@"v"] || [tag hasPrefix:@"V"]) {
                    tag = [tag substringFromIndex:1];
                }
                if (tag.length == 0 || page.length == 0) {
                    failure = @"The latest release did not include version information.";
                } else {
                    candidateVersion = tag;
                    releaseURL = [NSURL URLWithString:page];
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self->_updateCheckInProgress = NO;
            [[NSUserDefaults standardUserDefaults] setObject:[NSDate date]
                                                       forKey:kLastUpdateCheckPreference];
            if (failure != nil) {
                self->_updateStatusLabel.stringValue = [NSString stringWithFormat:@"Couldn’t check for updates: %@", failure];
                self->_updateStatusLabel.textColor = NSColor.systemRedColor;
            } else if (VersionIsNewer(candidateVersion, CurrentVersion())) {
                self->_availableUpdateURL = releaseURL;
                self->_updateStatusLabel.stringValue = [NSString stringWithFormat:@"Version %@ is available.", candidateVersion];
                self->_updateStatusLabel.textColor = NSColor.systemBlueColor;
                self->_updateMenuItem.title = [NSString stringWithFormat:@"Update Available: %@…", candidateVersion];
            } else {
                self->_availableUpdateURL = nil;
                self->_updateStatusLabel.stringValue = [NSString stringWithFormat:@"Teams Mute Helper %@ is up to date.", CurrentVersion()];
                self->_updateStatusLabel.textColor = NSColor.secondaryLabelColor;
                self->_updateMenuItem.title = @"Check for Updates…";
            }
            self->_checkUpdatesButton.enabled = YES;
            self->_checkUpdatesButton.title = self->_availableUpdateURL != nil
                ? @"View Update…"
                : @"Check for Updates…";
            [self scheduleAutomaticUpdateCheck];
        });
    }];
    [task resume];
}

- (void)scheduleAutomaticUpdateCheck {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (_automaticUpdateCheckScheduled ||
        ![defaults boolForKey:kOnboardingCompletedPreference] ||
        ![defaults boolForKey:kAutomaticUpdateChecksPreference]) {
        return;
    }

    NSDate *lastCheck = [defaults objectForKey:kLastUpdateCheckPreference];
    NSTimeInterval elapsed = lastCheck == nil ? kAutomaticUpdateCheckInterval : -lastCheck.timeIntervalSinceNow;
    NSTimeInterval delay = lastCheck == nil ? 2.0 : MAX(2.0, kAutomaticUpdateCheckInterval - elapsed);
    _automaticUpdateCheckScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self->_automaticUpdateCheckScheduled = NO;
        NSUserDefaults *currentDefaults = [NSUserDefaults standardUserDefaults];
        if ([currentDefaults boolForKey:kAutomaticUpdateChecksPreference]) {
            [self performUpdateCheckUserInitiated:NO];
        }
    });
}

- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object != _settingsWindow) {
        return;
    }
    _settingsHotKeyMainKeyDown = NO;
    [self cancelShortcutRecording];
    if (_shortcutEventMonitor != nil) {
        [NSEvent removeMonitor:_shortcutEventMonitor];
        _shortcutEventMonitor = nil;
    }
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    if (notification.object == _settingsWindow && _recordingTarget == ShortcutRecorderTargetNone) {
        [self refreshSettingsStatus];
    }
}

- (void)syncLaunchAtLoginMenuItem {
    SMAppServiceStatus status = SMAppService.mainAppService.status;
    NSControlStateValue state = status == SMAppServiceStatusEnabled
        ? NSControlStateValueOn
        : status == SMAppServiceStatusRequiresApproval
            ? NSControlStateValueMixed
            : NSControlStateValueOff;
    _launchAtLoginMenuItem.state = state;
    _launchAtLoginMenuItem.title = status == SMAppServiceStatusRequiresApproval
        ? @"Launch at Login (Approval Required)…"
        : @"Launch at Login";
    _launchAtLoginMenuItem.hidden = status == SMAppServiceStatusEnabled;
    _launchAtLoginCheckbox.state = state;
    _launchAtLoginCheckbox.title = @"Launch at Login";
}

- (void)registerLaunchAtLoginIfNeeded {
    if (!IsInApplicationsFolder()) {
        WriteLog(@"Skipped login item registration outside Applications folder");
        [self syncLaunchAtLoginMenuItem];
        return;
    }

    SMAppService *service = SMAppService.mainAppService;
    if (service.status == SMAppServiceStatusEnabled ||
        service.status == SMAppServiceStatusRequiresApproval) {
        [self syncLaunchAtLoginMenuItem];
        return;
    }

    NSError *error = nil;
    BOOL registered = [service registerAndReturnError:&error];
    WriteLog(@"Native login item registered=%@ error=%@",
             registered ? @"yes" : @"no", error.localizedDescription ?: @"none");
    [self syncLaunchAtLoginMenuItem];
}

- (void)toggleLaunchAtLogin:(id)sender {
    (void)sender;
    SMAppService *service = SMAppService.mainAppService;
    if (service.status == SMAppServiceStatusRequiresApproval) {
        [SMAppService openSystemSettingsLoginItems];
        return;
    }

    if (service.status != SMAppServiceStatusEnabled && !IsInApplicationsFolder()) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleInformational;
        alert.messageText = @"Move Teams Mute Helper to Applications";
        alert.informativeText = @"Launch at Login can be enabled after the app is moved to your Applications folder.";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        return;
    }

    NSError *error = nil;
    BOOL changed = service.status == SMAppServiceStatusEnabled
        ? [service unregisterAndReturnError:&error]
        : [service registerAndReturnError:&error];
    WriteLog(@"Native login item changed=%@ status=%ld error=%@",
             changed ? @"yes" : @"no", (long)service.status,
             error.localizedDescription ?: @"none");
    [self syncLaunchAtLoginMenuItem];
    if (!changed && error != nil) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = @"Couldn’t change Launch at Login";
        alert.informativeText = error.localizedDescription;
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    }
}

- (void)menuWillOpen:(NSMenu *)menu {
    (void)menu;
    [self syncLaunchAtLoginMenuItem];
    _accessibilityMenuItem.hidden = AXIsProcessTrusted();
    if (!_toggleInProgress) {
        [self showIdleStatus];
    }
}

- (void)openAccessibilitySettings:(id)sender {
    (void)sender;
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)quitHelper:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

- (BOOL)installHotKeyHandler {
    EventTypeSpec eventType = {kEventClassKeyboard, kEventHotKeyReleased};
    OSStatus handlerStatus = InstallApplicationEventHandler(
        HandleHotKeyEvent,
        1,
        &eventType,
        (__bridge void *)self,
        &_eventHandler
    );
    if (handlerStatus != noErr) {
        WriteLog(@"Could not install hotkey handler status=%d", (int)handlerStatus);
        return NO;
    }

    return YES;
}

- (void)registerConfiguredHotKeyWithRetryDelay:(NSTimeInterval)retryDelay {
    _hotKeyRegistered = [self replaceHotKeyWithKeyCode:_hotKeyKeyCode modifiers:_hotKeyModifiers];
    [self showIdleStatus];
    if (_hotKeyRegistered) {
        return;
    }

    NSTimeInterval nextDelay = MIN(retryDelay * 2.0, 5.0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(retryDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self registerConfiguredHotKeyWithRetryDelay:nextDelay];
    });
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSString *savedLabel = nil;
    LoadHotKeyPreference(&_hotKeyKeyCode, &_hotKeyModifiers, &savedLabel);
    _hotKeyLabel = savedLabel;
    NSString *savedTeamsLabel = nil;
    LoadTeamsShortcutPreference(&_teamsShortcutKeyCode,
                                &_teamsShortcutModifiers,
                                &savedTeamsLabel);
    _teamsShortcutLabel = savedTeamsLabel;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL shouldShowOnboarding = ![defaults boolForKey:kOnboardingCompletedPreference];

    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:26];
    [self showReadyStatus];

    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;
    _toggleMenuItem = [[NSMenuItem alloc] initWithTitle:@""
                                                action:@selector(toggleFromMenu:)
                                         keyEquivalent:@""];
    _toggleMenuItem.target = self;
    [self updateShortcutMenu];
    [menu addItem:_toggleMenuItem];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *settingsItem = [[NSMenuItem alloc] initWithTitle:@"Settings…"
                                                          action:@selector(showSettings:)
                                                   keyEquivalent:@""];
    settingsItem.target = self;
    [menu addItem:settingsItem];

    _updateMenuItem = [[NSMenuItem alloc] initWithTitle:@"Check for Updates…"
                                                 action:@selector(checkForUpdatesFromMenu:)
                                          keyEquivalent:@""];
    _updateMenuItem.target = self;
    [menu addItem:_updateMenuItem];
    [menu addItem:[NSMenuItem separatorItem]];

    _launchAtLoginMenuItem = [[NSMenuItem alloc] initWithTitle:@"Launch at Login"
                                                        action:@selector(toggleLaunchAtLogin:)
                                                 keyEquivalent:@""];
    _launchAtLoginMenuItem.target = self;
    [menu addItem:_launchAtLoginMenuItem];

    _accessibilityMenuItem = [[NSMenuItem alloc] initWithTitle:@"Open Accessibility Settings…"
                                                        action:@selector(openAccessibilitySettings:)
                                                 keyEquivalent:@""];
    _accessibilityMenuItem.target = self;
    _accessibilityMenuItem.hidden = AXIsProcessTrusted();
    [menu addItem:_accessibilityMenuItem];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *versionItem = [[NSMenuItem alloc]
        initWithTitle:[NSString stringWithFormat:@"Version %@", CurrentVersion()]
               action:nil
        keyEquivalent:@""];
    versionItem.enabled = NO;
    [menu addItem:versionItem];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit Teams Mute Helper"
                                                      action:@selector(quitHelper:)
                                               keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];
    _statusItem.menu = menu;

    BOOL trusted = AXIsProcessTrusted();
    if (!shouldShowOnboarding) {
        NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
        trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    }
    BOOL handlerInstalled = [self installHotKeyHandler];
    _hotKeyRegistered = NO;
    if (handlerInstalled) {
        [self registerConfiguredHotKeyWithRetryDelay:0.25];
    }
    [self registerLaunchAtLoginIfNeeded];
    WriteLog(@"Listener started trusted=%@ hotkey_registered=%@",
             trusted ? @"yes" : @"no", _hotKeyRegistered ? @"yes" : @"no");
    [self showIdleStatus];

    if (shouldShowOnboarding) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showSettingsWindowForOnboarding:YES];
        });
    } else {
        [self scheduleAutomaticUpdateCheck];
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    if (_hotKey != NULL) {
        UnregisterEventHotKey(_hotKey);
    }
    if (_eventHandler != NULL) {
        RemoveEventHandler(_eventHandler);
    }
    if (_shortcutEventMonitor != nil) {
        [NSEvent removeMonitor:_shortcutEventMonitor];
    }
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL diagnoseOnly = NO;
        BOOL verbose = NO;
        BOOL listen = NO;
        BOOL testHotKey = NO;
        BOOL toggleOnce = NO;
        BOOL registerLoginItem = NO;
        BOOL unregisterLoginItem = NO;
        for (int index = 1; index < argc; index++) {
            if (strcmp(argv[index], "--diagnose") == 0) {
                diagnoseOnly = YES;
            } else if (strcmp(argv[index], "--verbose") == 0) {
                verbose = YES;
            } else if (strcmp(argv[index], "--listen") == 0) {
                listen = YES;
            } else if (strcmp(argv[index], "--test-hotkey") == 0) {
                testHotKey = YES;
            } else if (strcmp(argv[index], "--toggle") == 0) {
                toggleOnce = YES;
            } else if (strcmp(argv[index], "--register-login-item") == 0) {
                registerLoginItem = YES;
            } else if (strcmp(argv[index], "--unregister-login-item") == 0) {
                unregisterLoginItem = YES;
            }
        }
        if (diagnoseOnly || verbose) {
            StartLogging();
        }

        if (testHotKey) {
            return TestGlobalHotKey();
        }
        if (registerLoginItem || unregisterLoginItem) {
            return SetLaunchAtLoginEnabled(registerLoginItem);
        }

        BOOL runListener = listen || (!diagnoseOnly && !verbose && !testHotKey && !toggleOnce &&
                                      !registerLoginItem && !unregisterLoginItem);
        if (runListener) {
            NSApplication *application = [NSApplication sharedApplication];
            TeamsMuteHelperDelegate *delegate = [[TeamsMuteHelperDelegate alloc] init];
            gApplicationDelegate = delegate;
            application.delegate = delegate;
            [application run];
            return 0;
        }

        return RunLockedHelper(diagnoseOnly, NO);
    }
}
