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

static BOOL gLoggingEnabled = NO;
static const UInt32 kDefaultHotKeyKeyCode = kVK_ANSI_A;
static const UInt32 kDefaultHotKeyModifiers = cmdKey | controlKey | shiftKey;
static NSString *const kHotKeyKeyCodePreference = @"HotKeyKeyCode";
static NSString *const kHotKeyModifiersPreference = @"HotKeyModifiers";
static NSString *const kHotKeyLabelPreference = @"HotKeyLabel";
static NSString *const kShortcutPromptShownPreference = @"ShortcutPromptShown";

@interface TeamsMuteHelperDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate> {
    NSStatusItem *_statusItem;
    EventHotKeyRef _hotKey;
    EventHandlerRef _eventHandler;
    BOOL _hotKeyRegistered;
    BOOL _toggleInProgress;
    UInt32 _hotKeyKeyCode;
    UInt32 _hotKeyModifiers;
    NSString *_hotKeyLabel;
    NSMenuItem *_toggleMenuItem;
    NSMenuItem *_launchAtLoginMenuItem;
    BOOL _shortcutDialogOpen;
    BOOL _recordingShortcut;
    UInt32 _recordingKeyCode;
    UInt32 _recordingModifiers;
    NSString *_recordingLabel;
    NSTextField *_recordingField;
    NSTextField *_recordingHint;
    NSButton *_recordingButton;
    NSButton *_shortcutSaveButton;
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

static BOOL SendAndVerify(DeliveryMode mode, NSRunningApplication *teams, MicState before) {
    WriteLog(@"Sending shortcut mode=%@", DeliveryModeName(mode));
    if (mode == DeliveryModeAX) {
        SendAXShortcut(teams.processIdentifier);
    } else {
        SendCGShortcut(mode, teams.processIdentifier);
    }

    BOOL changed = WaitForMicStateChange(teams, before, 0.65);
    WriteLog(@"Verification mode=%@ before=%@ changed=%@",
             DeliveryModeName(mode), MicStateName(before), changed ? @"yes" : @"no");
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

    BOOL changed = NO;
    BOOL unverified = before.state == MicStateUnknown;
    if (before.state == MicStateUnknown) {
        SendCGShortcut(DeliveryModePID, teams.processIdentifier);
        WriteLog(@"Mic state was unavailable; sent one unverified process-targeted shortcut");
    } else {
        changed = SendAndVerify(DeliveryModePID, teams, before.state);
        if (!changed) {
            changed = SendAndVerify(DeliveryModeAX, teams, before.state);
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

        changed = SendAndVerify(DeliveryModeHID, teams, before.state);
        if (!changed) {
            changed = SendAndVerify(DeliveryModePID, teams, before.state);
        }
        if (!changed) {
            changed = SendAndVerify(DeliveryModeAX, teams, before.state);
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
    return changed || unverified ? 0 : 5;
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

static int RunLockedHelper(BOOL diagnoseOnly) {
    int lockFile = open("/tmp/io.github.m-rk.ms-teams-mute-helper.lock", O_CREAT | O_RDWR, 0600);
    if (lockFile < 0 || flock(lockFile, LOCK_EX | LOCK_NB) != 0) {
        WriteLog(@"Another helper instance is already running");
        if (lockFile >= 0) {
            close(lockFile);
        }
        return 0;
    }

    int result = RunHelper(diagnoseOnly);
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
    NSString *description = [NSString stringWithFormat:@"Teams Mute Helper — %@", [self shortcutDisplayString]];
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
    if (result == 0) {
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

- (void)requestToggle {
    if (_toggleInProgress) {
        WriteLog(@"Ignored overlapping hotkey press");
        return;
    }

    _toggleInProgress = YES;
    [self setStatusSymbol:@"mic.badge.plus" description:@"Toggling Teams mute…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int result = RunLockedHelper(NO);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_toggleInProgress = NO;
            [self showResult:result];
        });
    });
}

- (void)handleGlobalHotKey {
    if (_shortcutDialogOpen) {
        if (_recordingShortcut) {
            [self completeShortcutRecordingWithKeyCode:_hotKeyKeyCode
                                            modifiers:_hotKeyModifiers
                                                label:_hotKeyLabel];
        }
        return;
    }
    [self requestToggle];
}

- (void)toggleFromMenu:(id)sender {
    (void)sender;
    [self requestToggle];
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

- (void)beginShortcutRecording:(id)sender {
    (void)sender;
    if (!_shortcutDialogOpen || _recordingShortcut) {
        return;
    }

    _recordingShortcut = YES;
    _recordingField.stringValue = @"Press shortcut now…";
    _recordingHint.stringValue = @"Use Control, Option, Shift, or Command";
    _recordingButton.title = @"Listening…";
    _recordingButton.enabled = NO;
    _shortcutSaveButton.enabled = NO;
}

- (void)cancelShortcutRecording {
    _recordingShortcut = NO;
    _recordingField.stringValue = HotKeyDisplayString(_recordingModifiers, _recordingLabel);
    _recordingHint.stringValue = @"Recording cancelled";
    _recordingButton.title = @"Record New Shortcut";
    _recordingButton.enabled = YES;
    _shortcutSaveButton.enabled = YES;
}

- (void)completeShortcutRecordingWithKeyCode:(UInt32)keyCode
                                   modifiers:(UInt32)modifiers
                                       label:(NSString *)label {
    if (!_recordingShortcut) {
        return;
    }

    _recordingKeyCode = keyCode;
    _recordingModifiers = modifiers;
    _recordingLabel = label;
    _recordingShortcut = NO;
    _recordingField.stringValue = HotKeyDisplayString(modifiers, label);
    _recordingHint.stringValue = @"Ready to save";
    _recordingButton.title = @"Record Again";
    _recordingButton.enabled = YES;
    _shortcutSaveButton.enabled = YES;
}

- (void)presentShortcutRecorderForFirstLaunch:(BOOL)firstLaunch {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = firstLaunch
        ? @"Choose Your Mute Shortcut"
        : @"Toggle Teams Mute global keyboard shortcut";
    alert.informativeText = firstLaunch
        ? @"Control-Shift-Command-A is ready to use. Keep it, or click Record a Different Shortcut when you're ready."
        : @"Your current global shortcut is shown below. Click Record New Shortcut when you're ready to change it. Teams still receives Shift-Command-M.";

    NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, 116)];
    NSTextField *recording = [NSTextField labelWithString:[self shortcutDisplayString]];
    recording.frame = NSMakeRect(0, 67, 360, 36);
    recording.alignment = NSTextAlignmentCenter;
    recording.font = [NSFont monospacedSystemFontOfSize:24 weight:NSFontWeightSemibold];
    [accessory addSubview:recording];

    NSButton *recordButton = [NSButton buttonWithTitle:firstLaunch
                                                       ? @"Record a Different Shortcut"
                                                       : @"Record New Shortcut"
                                               target:self
                                               action:@selector(beginShortcutRecording:)];
    recordButton.frame = NSMakeRect(75, 31, 210, 30);
    recordButton.bezelStyle = NSBezelStyleRounded;
    [accessory addSubview:recordButton];

    NSTextField *hint = [NSTextField labelWithString:@"Nothing is recorded until you click the button"];
    hint.frame = NSMakeRect(0, 4, 360, 18);
    hint.alignment = NSTextAlignmentCenter;
    hint.textColor = NSColor.secondaryLabelColor;
    [accessory addSubview:hint];
    alert.accessoryView = accessory;

    NSButton *saveButton = [alert addButtonWithTitle:firstLaunch ? @"Use Shortcut" : @"Save"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:@"Restore Default"];

    _shortcutDialogOpen = YES;
    _recordingShortcut = NO;
    _recordingKeyCode = _hotKeyKeyCode;
    _recordingModifiers = _hotKeyModifiers;
    _recordingLabel = _hotKeyLabel;
    _recordingField = recording;
    _recordingHint = hint;
    _recordingButton = recordButton;
    _shortcutSaveButton = saveButton;
    id monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                       handler:^NSEvent *(NSEvent *event) {
        if (!self->_recordingShortcut) {
            return event;
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
            hint.stringValue = @"Include at least one modifier key";
            return nil;
        }

        [self completeShortcutRecordingWithKeyCode:event.keyCode
                                         modifiers:modifiers
                                             label:KeyLabelFromEvent(event)];
        return nil;
    }];

    NSModalResponse response = [alert runModal];
    [NSEvent removeMonitor:monitor];
    UInt32 candidateKeyCode = _recordingKeyCode;
    UInt32 candidateModifiers = _recordingModifiers;
    NSString *candidateLabel = _recordingLabel;
    _shortcutDialogOpen = NO;
    _recordingShortcut = NO;
    _recordingField = nil;
    _recordingHint = nil;
    _recordingButton = nil;
    _shortcutSaveButton = nil;

    if (response == NSAlertSecondButtonReturn) {
        return;
    }
    if (response == NSAlertThirdButtonReturn) {
        candidateKeyCode = kDefaultHotKeyKeyCode;
        candidateModifiers = kDefaultHotKeyModifiers;
        candidateLabel = @"A";
    }

    NSString *candidateDisplay = HotKeyDisplayString(candidateModifiers, candidateLabel);
    if (![self replaceHotKeyWithKeyCode:candidateKeyCode modifiers:candidateModifiers]) {
        [self showShortcutConflictForDisplay:candidateDisplay];
        [self showIdleStatus];
        return;
    }

    _hotKeyKeyCode = candidateKeyCode;
    _hotKeyModifiers = candidateModifiers;
    _hotKeyLabel = candidateLabel;
    SaveHotKeyPreference(_hotKeyKeyCode, _hotKeyModifiers, _hotKeyLabel);
    [self updateShortcutMenu];
    [self showIdleStatus];
}

- (void)configureShortcut:(id)sender {
    (void)sender;
    [self presentShortcutRecorderForFirstLaunch:NO];
}

- (void)syncLaunchAtLoginMenuItem {
    SMAppServiceStatus status = SMAppService.mainAppService.status;
    _launchAtLoginMenuItem.state = status == SMAppServiceStatusEnabled
        ? NSControlStateValueOn
        : status == SMAppServiceStatusRequiresApproval
            ? NSControlStateValueMixed
            : NSControlStateValueOff;
    _launchAtLoginMenuItem.title = status == SMAppServiceStatusRequiresApproval
        ? @"Launch at Login (Approval Required)…"
        : @"Launch at Login";
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
    BOOL hasSavedShortcut = LoadHotKeyPreference(&_hotKeyKeyCode, &_hotKeyModifiers, &savedLabel);
    _hotKeyLabel = savedLabel;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL shouldPromptForShortcut = !hasSavedShortcut && ![defaults boolForKey:kShortcutPromptShownPreference];

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

    NSMenuItem *shortcutItem = [[NSMenuItem alloc] initWithTitle:@"Keyboard Shortcut…"
                                                          action:@selector(configureShortcut:)
                                                   keyEquivalent:@""];
    shortcutItem.target = self;
    [menu addItem:shortcutItem];

    _launchAtLoginMenuItem = [[NSMenuItem alloc] initWithTitle:@"Launch at Login"
                                                        action:@selector(toggleLaunchAtLogin:)
                                                 keyEquivalent:@""];
    _launchAtLoginMenuItem.target = self;
    [menu addItem:_launchAtLoginMenuItem];

    NSMenuItem *accessibilityItem = [[NSMenuItem alloc] initWithTitle:@"Open Accessibility Settings…"
                                                               action:@selector(openAccessibilitySettings:)
                                                        keyEquivalent:@""];
    accessibilityItem.target = self;
    [menu addItem:accessibilityItem];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit Teams Mute Helper"
                                                      action:@selector(quitHelper:)
                                               keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];
    _statusItem.menu = menu;

    BOOL trusted = AXIsProcessTrusted();
    if (!shouldPromptForShortcut) {
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

    if (shouldPromptForShortcut) {
        dispatch_async(dispatch_get_main_queue(), ^{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [[NSRunningApplication currentApplication] activateWithOptions:NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop
            [self presentShortcutRecorderForFirstLaunch:YES];
            [defaults setBool:YES forKey:kShortcutPromptShownPreference];

            NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
            AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
            [self showIdleStatus];
        });
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

        return RunLockedHelper(diagnoseOnly);
    }
}
