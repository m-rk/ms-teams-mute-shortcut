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

@interface TeamsMuteHelperDelegate : NSObject <NSApplicationDelegate> {
    NSStatusItem *_statusItem;
    EventHotKeyRef _hotKey;
    EventHandlerRef _eventHandler;
    BOOL _hotKeyRegistered;
    BOOL _toggleInProgress;
}

- (void)handleGlobalHotKey;

@end

static TeamsMuteHelperDelegate *gApplicationDelegate = nil;

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

static void PostGlobalHotKeyForTesting(void) {
    CGEventFlags command = kCGEventFlagMaskCommand;
    CGEventFlags commandControl = command | kCGEventFlagMaskControl;
    CGEventFlags modifiers = commandControl | kCGEventFlagMaskShift;
    PostCGKey(DeliveryModeHID, 0, kVK_Command, YES, command);
    PostCGKey(DeliveryModeHID, 0, kVK_Control, YES, commandControl);
    PostCGKey(DeliveryModeHID, 0, kVK_Shift, YES, modifiers);
    PostCGKey(DeliveryModeHID, 0, kVK_ANSI_A, YES, modifiers);
    PostCGKey(DeliveryModeHID, 0, kVK_ANSI_A, NO, modifiers);
    PostCGKey(DeliveryModeHID, 0, kVK_Shift, NO, commandControl);
    PostCGKey(DeliveryModeHID, 0, kVK_Control, NO, command);
    PostCGKey(DeliveryModeHID, 0, kVK_Command, NO, 0);
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

    WriteLog(@"Posting Control-Shift-Command-A for listener testing; before=%@", MicStateName(before.state));
    PostGlobalHotKeyForTesting();

    BOOL changed = NO;
    for (NSInteger attempt = 0; attempt < 20 && !changed; attempt++) {
        usleep(200000);
        MicContext after = FindMicContext(teams);
        changed = after.state != MicStateUnknown && after.state != before.state;
        ReleaseMicContext(&after);
    }

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

- (void)showReadyStatus {
    NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"AppIcon" ofType:@"icns"];
    NSImage *image = iconPath == nil ? nil : [[NSImage alloc] initWithContentsOfFile:iconPath];
    if (image == nil) {
        [self setStatusSymbol:@"mic.slash" description:@"Teams Mute Helper — Control-Shift-Command-A"];
        return;
    }

    image.size = NSMakeSize(18, 18);
    image.template = NO;
    _statusItem.button.image = image;
    _statusItem.button.toolTip = @"Teams Mute Helper — Control-Shift-Command-A";
}

- (void)showIdleStatus {
    if (!_hotKeyRegistered) {
        [self setStatusSymbol:@"exclamationmark.triangle"
                  description:@"Control-Shift-Command-A is already in use"];
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
    [self requestToggle];
}

- (void)toggleFromMenu:(id)sender {
    (void)sender;
    [self requestToggle];
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

- (BOOL)registerGlobalHotKey {
    EventTypeSpec eventType = {kEventClassKeyboard, kEventHotKeyPressed};
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

    EventHotKeyID hotKeyID = {'TMHM', 1};
    OSStatus hotKeyStatus = RegisterEventHotKey(
        kVK_ANSI_A,
        cmdKey | controlKey | shiftKey,
        hotKeyID,
        GetApplicationEventTarget(),
        0,
        &_hotKey
    );
    if (hotKeyStatus != noErr) {
        WriteLog(@"Could not register hotkey status=%d", (int)hotKeyStatus);
        RemoveEventHandler(_eventHandler);
        _eventHandler = NULL;
        return NO;
    }
    return YES;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    [self showReadyStatus];

    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *toggleItem = [[NSMenuItem alloc] initWithTitle:@"Toggle Teams Mute (⌃⇧⌘A)"
                                                        action:@selector(toggleFromMenu:)
                                                 keyEquivalent:@""];
    toggleItem.target = self;
    [menu addItem:toggleItem];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *accessibilityItem = [[NSMenuItem alloc] initWithTitle:@"Open Accessibility Settings…"
                                                               action:@selector(openAccessibilitySettings:)
                                                        keyEquivalent:@""];
    accessibilityItem.target = self;
    [menu addItem:accessibilityItem];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit Until Next Login"
                                                      action:@selector(quitHelper:)
                                               keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];
    _statusItem.menu = menu;

    NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
    BOOL trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    _hotKeyRegistered = [self registerGlobalHotKey];
    WriteLog(@"Listener started trusted=%@ hotkey_registered=%@",
             trusted ? @"yes" : @"no", _hotKeyRegistered ? @"yes" : @"no");
    [self showIdleStatus];
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
        for (int index = 1; index < argc; index++) {
            if (strcmp(argv[index], "--diagnose") == 0) {
                diagnoseOnly = YES;
            } else if (strcmp(argv[index], "--verbose") == 0) {
                verbose = YES;
            } else if (strcmp(argv[index], "--listen") == 0) {
                listen = YES;
            } else if (strcmp(argv[index], "--test-hotkey") == 0) {
                testHotKey = YES;
            }
        }
        if (diagnoseOnly || verbose) {
            StartLogging();
        }

        if (testHotKey) {
            return TestGlobalHotKey();
        }

        if (listen) {
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
