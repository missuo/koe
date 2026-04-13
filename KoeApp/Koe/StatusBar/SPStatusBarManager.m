#import "SPStatusBarManager.h"
#import "SPPermissionManager.h"
#import "SPAudioDeviceManager.h"
#import "SPHistoryManager.h"
#import "SPLocalization.h"
#import "koe_core.h"
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UserNotifications/UserNotifications.h>

// Icon size for menu bar (points)
static const CGFloat kIconSize = 18.0;

@interface SPStatusBarManager ()

@property (nonatomic, weak) id<SPStatusBarDelegate> delegate;
@property (nonatomic, strong) SPPermissionManager *permissionManager;
@property (nonatomic, strong) SPAudioDeviceManager *audioDeviceManager;
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenuItem *statusMenuItem;
@property (nonatomic, strong) NSMenuItem *micPermissionItem;
@property (nonatomic, strong) NSMenuItem *accessibilityPermissionItem;
@property (nonatomic, strong) NSMenuItem *inputMonitoringPermissionItem;
@property (nonatomic, strong) NSMenuItem *notificationPermissionItem;
@property (nonatomic, strong) NSMenuItem *speechRecognitionPermissionItem;
@property (nonatomic, strong) NSMenuItem *hotkeyDisplayItem;
@property (nonatomic, strong) NSMenuItem *statsCountItem;
@property (nonatomic, strong) NSMenuItem *statsTimeItem;
@property (nonatomic, strong) NSMenuItem *statsSpeedItem;
@property (nonatomic, strong) NSTimer *animationTimer;
@property (nonatomic, assign) NSInteger animationFrame;
@property (nonatomic, copy) NSString *currentState;

@end

static NSString *displayNameForKeycode(int keycode) {
    switch (keycode) {
        case 122: return @"F1";
        case 120: return @"F2";
        case 99:  return @"F3";
        case 118: return @"F4";
        case 96:  return @"F5";
        case 97:  return @"F6";
        case 98:  return @"F7";
        case 100: return @"F8";
        case 101: return @"F9";
        case 109: return @"F10";
        case 103: return @"F11";
        case 111: return @"F12";
        case 105: return @"F13";
        case 107: return @"F14";
        case 113: return @"F15";
        case 106: return @"F16";
        case 64:  return @"F17";
        case 79:  return @"F18";
        case 80:  return @"F19";
        case 90:  return @"F20";
        case 49:  return @"Space";
        case 53:  return @"Escape";
        case 48:  return @"Tab";
        case 57:  return @"CapsLock";
        case 36:  return @"Return";
        case 51:  return @"Delete";
        case 117: return @"Forward Delete";
        case 115: return @"Home";
        case 119: return @"End";
        case 116: return @"Page Up";
        case 121: return @"Page Down";
        case 123: return @"Left Arrow";
        case 124: return @"Right Arrow";
        case 125: return @"Down Arrow";
        case 126: return @"Up Arrow";
        default: break;
    }

    TISInputSourceRef inputSource = TISCopyCurrentKeyboardLayoutInputSource();
    if (inputSource) {
        CFDataRef layoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData);
        if (layoutData) {
            const UCKeyboardLayout *keyboardLayout = (const UCKeyboardLayout *)CFDataGetBytePtr(layoutData);
            if (keyboardLayout) {
                UInt32 deadKeyState = 0;
                UniChar chars[4];
                UniCharCount length = 0;
                OSStatus status = UCKeyTranslate(keyboardLayout,
                                                 (UInt16)keycode,
                                                 kUCKeyActionDisplay,
                                                 0,
                                                 LMGetKbdType(),
                                                 kUCKeyTranslateNoDeadKeysBit,
                                                 &deadKeyState,
                                                 sizeof(chars) / sizeof(chars[0]),
                                                 &length,
                                                 chars);
                if (status == noErr && length > 0) {
                    NSString *result = [[NSString stringWithCharacters:chars length:(NSUInteger)length]
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    CFRelease(inputSource);
                    if (result.length > 0) {
                        return result.uppercaseString;
                    }
                    return [NSString stringWithFormat:@"Key %d", keycode];
                }
            }
        }
        CFRelease(inputSource);
    }

    return [NSString stringWithFormat:@"Key %d", keycode];
}

static BOOL isNumericHotkeyValue(NSString *value) {
    if (value.length == 0) return NO;
    NSScanner *scanner = [NSScanner scannerWithString:value];
    int keycode = 0;
    return [scanner scanInt:&keycode] && [scanner isAtEnd];
}

static NSDictionary<NSString *, NSString *> *comboModifierDisplayNames(void) {
    static NSDictionary<NSString *, NSString *> *displayNames;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        displayNames = @{
            @"command": @"Command",
            @"option": @"Option",
            @"control": @"Control",
            @"shift": @"Shift",
            @"fn": @"Fn",
        };
    });
    return displayNames;
}

static NSArray<NSString *> *comboModifierOrder(void) {
    return @[@"command", @"option", @"control", @"shift", @"fn"];
}

static NSString *normalizedHotkeyComboValue(NSString *value) {
    if (![value containsString:@"+"]) return nil;

    NSMutableOrderedSet<NSString *> *modifiers = [NSMutableOrderedSet orderedSet];
    NSString *keyToken = nil;

    for (NSString *rawPart in [value componentsSeparatedByString:@"+"]) {
        NSString *part = [[rawPart stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
        if (part.length == 0) return nil;

        NSString *normalizedModifier = nil;
        if ([part isEqualToString:@"cmd"] || [part isEqualToString:@"command"]) {
            normalizedModifier = @"command";
        } else if ([part isEqualToString:@"alt"] || [part isEqualToString:@"option"]) {
            normalizedModifier = @"option";
        } else if ([part isEqualToString:@"ctrl"] || [part isEqualToString:@"control"]) {
            normalizedModifier = @"control";
        } else if ([part isEqualToString:@"shift"]) {
            normalizedModifier = @"shift";
        } else if ([part isEqualToString:@"fn"] || [part isEqualToString:@"function"] || [part isEqualToString:@"globe"]) {
            normalizedModifier = @"fn";
        }

        if (normalizedModifier) {
            [modifiers addObject:normalizedModifier];
            continue;
        }

        if (keyToken != nil || !isNumericHotkeyValue(part)) {
            return nil;
        }
        keyToken = [NSString stringWithFormat:@"%ld", (long)part.integerValue];
    }

    if (modifiers.count == 0 || keyToken.length == 0) return nil;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *modifier in comboModifierOrder()) {
        if ([modifiers containsObject:modifier]) {
            [parts addObject:modifier];
        }
    }
    [parts addObject:keyToken];
    return [parts componentsJoinedByString:@"+"];
}

static NSString *displayNameForHotkeyValue(NSString *value) {
    if ([value isEqualToString:@"left_option"]) {
        return @"Left Option (⌥)";
    }
    if ([value isEqualToString:@"right_option"]) {
        return @"Right Option (⌥)";
    }
    if ([value isEqualToString:@"left_command"]) {
        return @"Left Command (⌘)";
    }
    if ([value isEqualToString:@"right_command"]) {
        return @"Right Command (⌘)";
    }
    if ([value isEqualToString:@"left_control"]) {
        return @"Left Control (⌃)";
    }
    if ([value isEqualToString:@"right_control"]) {
        return @"Right Control (⌃)";
    }
    if ([value isEqualToString:@"fn"]) {
        return @"Fn (Globe)";
    }
    NSString *normalizedCombo = normalizedHotkeyComboValue(value);
    if (normalizedCombo.length > 0) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        NSArray<NSString *> *tokens = [normalizedCombo componentsSeparatedByString:@"+"];
        NSDictionary<NSString *, NSString *> *displayNames = comboModifierDisplayNames();
        for (NSInteger idx = 0; idx < (NSInteger)tokens.count; idx++) {
            NSString *token = tokens[idx];
            if (idx == (NSInteger)tokens.count - 1) {
                [parts addObject:displayNameForKeycode(token.intValue)];
            } else {
                [parts addObject:displayNames[token] ?: token.capitalizedString];
            }
        }
        return [parts componentsJoinedByString:@" + "];
    }
    if (isNumericHotkeyValue(value)) {
        int keycode = value.intValue;
        return displayNameForKeycode(keycode);
    }
    return value;
}

@implementation SPStatusBarManager

- (instancetype)initWithDelegate:(id<SPStatusBarDelegate>)delegate
               permissionManager:(SPPermissionManager *)permissionManager
              audioDeviceManager:(SPAudioDeviceManager *)audioDeviceManager {
    self = [super init];
    if (self) {
        _delegate = delegate;
        _permissionManager = permissionManager;
        _audioDeviceManager = audioDeviceManager;
        _currentState = @"idle";
        _animationFrame = 0;
        [self setupStatusBar];
    }
    return self;
}

- (void)setupStatusBar {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];

    [self applyIdleIcon];

    // Build menu
    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;
    menu.autoenablesItems = NO;

    // Status display with version info
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *version = info[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = info[@"CFBundleVersion"] ?: @"?";
    NSString *statusTitle = [NSString stringWithFormat:KoeLocalizedString(@"statusBar.status.ready"), version, build];
    self.statusMenuItem = [[NSMenuItem alloc] initWithTitle:statusTitle
                                                    action:nil
                                             keyEquivalent:@""];
    self.statusMenuItem.enabled = NO;
    [menu addItem:self.statusMenuItem];

    self.hotkeyDisplayItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:KoeLocalizedString(@"statusBar.shortcut.format"), @"Fn"]
                                                        action:nil
                                                 keyEquivalent:@""];
    self.hotkeyDisplayItem.enabled = NO;
    [menu addItem:self.hotkeyDisplayItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Statistics section
    NSMenuItem *statsHeader = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    statsHeader.view = [self headerViewWithTitle:KoeLocalizedString(@"statusBar.section.statistics")];
    [menu addItem:statsHeader];

    self.statsCountItem = [[NSMenuItem alloc] initWithTitle:@"  ..."
                                                    action:nil
                                             keyEquivalent:@""];
    self.statsCountItem.enabled = NO;
    [menu addItem:self.statsCountItem];

    self.statsTimeItem = [[NSMenuItem alloc] initWithTitle:@"  ..."
                                                   action:nil
                                            keyEquivalent:@""];
    self.statsTimeItem.enabled = NO;
    [menu addItem:self.statsTimeItem];

    self.statsSpeedItem = [[NSMenuItem alloc] initWithTitle:@"  ..."
                                                    action:nil
                                             keyEquivalent:@""];
    self.statsSpeedItem.enabled = NO;
    [menu addItem:self.statsSpeedItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Permissions section
    NSMenuItem *permHeader = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    permHeader.view = [self headerViewWithTitle:KoeLocalizedString(@"statusBar.section.permissions")];
    [menu addItem:permHeader];

    self.micPermissionItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:KoeLocalizedString(@"statusBar.permission.microphone"), KoeLocalizedString(@"statusBar.permission.checking")]
                                                       action:@selector(openMicrophoneSettings)
                                                keyEquivalent:@""];
    self.micPermissionItem.target = self;
    self.micPermissionItem.enabled = NO;
    [menu addItem:self.micPermissionItem];

    self.accessibilityPermissionItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:KoeLocalizedString(@"statusBar.permission.accessibility"), KoeLocalizedString(@"statusBar.permission.checking")]
                                                                 action:@selector(requestAccessibilityPermission)
                                                          keyEquivalent:@""];
    self.accessibilityPermissionItem.target = self;
    self.accessibilityPermissionItem.enabled = NO;
    [menu addItem:self.accessibilityPermissionItem];

    self.inputMonitoringPermissionItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:KoeLocalizedString(@"statusBar.permission.inputMonitoring"), KoeLocalizedString(@"statusBar.permission.checking")]
                                                                   action:@selector(openInputMonitoringSettings)
                                                            keyEquivalent:@""];
    self.inputMonitoringPermissionItem.target = self;
    self.inputMonitoringPermissionItem.enabled = NO;
    [menu addItem:self.inputMonitoringPermissionItem];

    self.notificationPermissionItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:KoeLocalizedString(@"statusBar.permission.notifications"), KoeLocalizedString(@"statusBar.permission.checking")]
                                                                action:@selector(requestNotificationPermission)
                                                         keyEquivalent:@""];
    self.notificationPermissionItem.target = self;
    self.notificationPermissionItem.enabled = NO;
    [menu addItem:self.notificationPermissionItem];

    self.speechRecognitionPermissionItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:KoeLocalizedString(@"statusBar.permission.speechRecognition"), KoeLocalizedString(@"statusBar.permission.checking")]
                                                                     action:nil
                                                              keyEquivalent:@""];
    self.speechRecognitionPermissionItem.enabled = NO;
    self.speechRecognitionPermissionItem.hidden = YES;
    [menu addItem:self.speechRecognitionPermissionItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Microphone selection submenu
    NSMenuItem *microphoneItem = [[NSMenuItem alloc] initWithTitle:KoeLocalizedString(@"statusBar.menu.microphone")
                                                           action:nil
                                                    keyEquivalent:@""];
    NSMenu *micSubmenu = [[NSMenu alloc] initWithTitle:KoeLocalizedString(@"statusBar.menu.microphone")];
    microphoneItem.submenu = micSubmenu;
    [menu addItem:microphoneItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *setupWizard = [[NSMenuItem alloc] initWithTitle:KoeLocalizedString(@"statusBar.menu.setupWizard")
                                                        action:@selector(openSetupWizard:)
                                                 keyEquivalent:@","];
    setupWizard.target = self;
    [menu addItem:setupWizard];

    NSMenuItem *openConfig = [[NSMenuItem alloc] initWithTitle:KoeLocalizedString(@"statusBar.menu.openConfig")
                                                       action:@selector(openConfigFolder:)
                                                keyEquivalent:@""];
    openConfig.target = self;
    [menu addItem:openConfig];

    NSMenuItem *checkForUpdates = [[NSMenuItem alloc] initWithTitle:KoeLocalizedString(@"statusBar.menu.checkUpdates")
                                                             action:@selector(checkForUpdates:)
                                                      keyEquivalent:@""];
    checkForUpdates.target = self;
    [menu addItem:checkForUpdates];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *loginItem = [[NSMenuItem alloc] initWithTitle:KoeLocalizedString(@"statusBar.menu.launchAtLogin")
                                                      action:@selector(toggleLaunchAtLogin:)
                                               keyEquivalent:@""];
    loginItem.target = self;
    if (@available(macOS 13.0, *)) {
        loginItem.state = (SMAppService.mainAppService.status == SMAppServiceStatusEnabled)
                          ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [menu addItem:loginItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:KoeLocalizedString(@"statusBar.menu.quit")
                                                 action:@selector(quitApp:)
                                          keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];

    self.statusItem.menu = menu;
}

#pragma mark - NSMenuDelegate

- (void)menuWillOpen:(NSMenu *)menu {
    [self refreshHotkeyDisplay];
    [self refreshPermissionStatus];
    [self refreshStats];
    [self refreshMicrophoneSubmenu:menu];
    if ([self.delegate respondsToSelector:@selector(statusBarMenuDidOpen)]) {
        [self.delegate statusBarMenuDidOpen];
    }
}

- (void)menuDidClose:(NSMenu *)menu {
    if ([self.delegate respondsToSelector:@selector(statusBarMenuDidClose)]) {
        [self.delegate statusBarMenuDidClose];
    }
}

- (void)refreshPermissionStatus {
    BOOL mic = [self.permissionManager isMicrophoneGranted];
    BOOL accessibility = [self.permissionManager isAccessibilityGranted];
    BOOL inputMonitoring = [self.permissionManager isInputMonitoringGranted];

    NSString *granted = KoeLocalizedString(@"statusBar.permission.granted");
    NSString *notGranted = KoeLocalizedString(@"statusBar.permission.notGranted");

    self.micPermissionItem.title = [NSString stringWithFormat:KoeLocalizedString(@"statusBar.permission.microphone"),
                                    mic ? granted : notGranted];
    self.micPermissionItem.enabled = !mic;
    self.accessibilityPermissionItem.title = [NSString stringWithFormat:KoeLocalizedString(@"statusBar.permission.accessibility"),
                                              accessibility ? granted : notGranted];
    self.accessibilityPermissionItem.enabled = !accessibility;
    self.inputMonitoringPermissionItem.title = [NSString stringWithFormat:KoeLocalizedString(@"statusBar.permission.inputMonitoring"),
                                                inputMonitoring ? granted : notGranted];
    self.inputMonitoringPermissionItem.enabled = !inputMonitoring;

    [self.permissionManager checkNotificationPermissionWithCompletion:^(BOOL notifGranted) {
        self.notificationPermissionItem.title = [NSString stringWithFormat:KoeLocalizedString(@"statusBar.permission.notifications"),
                                                  notifGranted ? granted : notGranted];
        self.notificationPermissionItem.enabled = !notifGranted;
    }];

    // Speech Recognition — only visible when apple-speech provider is configured
    char *rawProvider = sp_config_get("asr.provider");
    BOOL isAppleSpeech = rawProvider && strcmp(rawProvider, "apple-speech") == 0;
    if (rawProvider) sp_core_free_string(rawProvider);
    self.speechRecognitionPermissionItem.hidden = !isAppleSpeech;
    if (isAppleSpeech) {
        BOOL speechGranted = [self.permissionManager isSpeechRecognitionGranted];
        self.speechRecognitionPermissionItem.title = [NSString stringWithFormat:KoeLocalizedString(@"statusBar.permission.speechRecognition"),
                                                       speechGranted ? granted : notGranted];
    }
}

- (void)openMicrophoneSettings {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]];
}

- (void)requestAccessibilityPermission {
    [self.permissionManager requestAccessibilityPermission];
}

- (void)openInputMonitoringSettings {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]];
}

- (void)requestNotificationPermission {
    [self.permissionManager requestNotificationPermission];
}

- (void)refreshStats {
    SPHistoryStats *stats = [[SPHistoryManager sharedManager] aggregateStats];

    // Count display
    NSMutableArray *parts = [NSMutableArray array];
    if (stats.totalCharCount > 0) {
        [parts addObject:[NSString stringWithFormat:KoeLocalizedString(@"statusBar.stats.chars"), (long)stats.totalCharCount]];
    }
    if (stats.totalWordCount > 0) {
        [parts addObject:[NSString stringWithFormat:KoeLocalizedString(@"statusBar.stats.words"), (long)stats.totalWordCount]];
    }
    if (parts.count > 0) {
        self.statsCountItem.title = [NSString stringWithFormat:KoeLocalizedString(@"statusBar.stats.total"),
                                     [parts componentsJoinedByString:@" / "]];
    } else {
        self.statsCountItem.title = KoeLocalizedString(@"statusBar.stats.totalNone");
    }

    // Time + session count
    NSInteger totalSec = stats.totalDurationMs / 1000;
    NSInteger min = totalSec / 60;
    NSInteger sec = totalSec % 60;
    if (stats.sessionCount > 0) {
        self.statsTimeItem.title = [NSString stringWithFormat:KoeLocalizedString(@"statusBar.stats.time"),
                                    (long)min, (long)sec, (long)stats.sessionCount];
    } else {
        self.statsTimeItem.title = KoeLocalizedString(@"statusBar.stats.timeNone");
    }

    // Typing speed
    if (stats.totalDurationMs > 0 && (stats.totalCharCount + stats.totalWordCount) > 0) {
        double minutes = (double)stats.totalDurationMs / 60000.0;
        if (stats.totalCharCount > stats.totalWordCount) {
            double speed = (double)stats.totalCharCount / minutes;
            self.statsSpeedItem.title = [NSString stringWithFormat:KoeLocalizedString(@"statusBar.stats.speedChars"), speed];
        } else {
            double speed = (double)stats.totalWordCount / minutes;
            self.statsSpeedItem.title = [NSString stringWithFormat:KoeLocalizedString(@"statusBar.stats.speedWords"), speed];
        }
    } else {
        self.statsSpeedItem.title = KoeLocalizedString(@"statusBar.stats.speedNone");
    }
}

- (void)refreshHotkeyDisplay {
    char *t = sp_config_resolved_trigger_key();
    NSString *triggerKey = t ? @(t) : @"fn";
    sp_core_free_string(t);

    self.hotkeyDisplayItem.title = [NSString stringWithFormat:KoeLocalizedString(@"statusBar.shortcut.format"),
                                    displayNameForHotkeyValue(triggerKey)];
}

#pragma mark - Microphone Selection

- (void)refreshMicrophoneSubmenu:(NSMenu *)menu {
    // Find the Microphone menu item by tag instead of title (title is localized)
    NSMenuItem *micItem = nil;
    for (NSMenuItem *item in menu.itemArray) {
        if (item.submenu && [item.submenu.title isEqualToString:KoeLocalizedString(@"statusBar.menu.microphone")]) {
            micItem = item;
            break;
        }
    }
    if (!micItem) return;

    NSMenu *submenu = micItem.submenu;
    [submenu removeAllItems];

    NSString *selectedUID = self.audioDeviceManager.selectedDeviceUID;
    NSArray<SPAudioInputDevice *> *devices = [self.audioDeviceManager availableInputDevices];

    // Check if selected device is currently available
    BOOL selectedFound = NO;
    if (selectedUID) {
        for (SPAudioInputDevice *device in devices) {
            if ([device.uid isEqualToString:selectedUID]) {
                selectedFound = YES;
                break;
            }
        }
    }

    // "System Default" option
    NSMenuItem *defaultItem = [[NSMenuItem alloc] initWithTitle:KoeLocalizedString(@"statusBar.menu.systemDefault")
                                                        action:@selector(selectAudioDevice:)
                                                 keyEquivalent:@""];
    defaultItem.target = self;
    defaultItem.representedObject = nil;
    defaultItem.state = (selectedUID == nil) ? NSControlStateValueOn : NSControlStateValueOff;
    [submenu addItem:defaultItem];

    if (devices.count > 0) {
        [submenu addItem:[NSMenuItem separatorItem]];
    }

    // Available input devices
    // NOTE: Only device.name is shown. If the user has multiple devices with identical
    // names (e.g. two identical USB mics), they cannot be distinguished visually.
    // A future improvement could append a disambiguator (manufacturer, UID suffix, etc.).
    for (SPAudioInputDevice *device in devices) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:device.name
                                                      action:@selector(selectAudioDevice:)
                                               keyEquivalent:@""];
        item.target = self;
        item.representedObject = device.uid;
        item.state = [device.uid isEqualToString:selectedUID] ? NSControlStateValueOn : NSControlStateValueOff;
        [submenu addItem:item];
    }

    // Show disconnected but still-selected device as a greyed-out item
    if (selectedUID && !selectedFound) {
        NSString *deviceName = self.audioDeviceManager.selectedDeviceName ?: selectedUID;
        [submenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *unavailableItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:KoeLocalizedString(@"statusBar.menu.unavailable"), deviceName]
                                                                action:nil
                                                         keyEquivalent:@""];
        unavailableItem.state = NSControlStateValueOn;
        unavailableItem.enabled = NO;
        [submenu addItem:unavailableItem];
    }
}

- (void)selectAudioDevice:(NSMenuItem *)sender {
    NSString *uid = sender.representedObject;
    NSString *name = uid ? sender.title : nil;
    [self.audioDeviceManager selectDevice:uid name:name];
    NSLog(@"[Koe] Audio device selected: %@", uid ?: @"System Default");

    if ([self.delegate respondsToSelector:@selector(statusBarDidSelectAudioDeviceWithUID:)]) {
        [self.delegate statusBarDidSelectAudioDeviceWithUID:uid];
    }
}

#pragma mark - Helpers

- (NSView *)headerViewWithTitle:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont boldSystemFontOfSize:[NSFont systemFontSize]];
    label.textColor = [NSColor labelColor];
    [label sizeToFit];

    // Match standard menu item padding
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, label.frame.size.height + 4)];
    label.frame = NSMakeRect(20, 2, label.frame.size.width, label.frame.size.height);
    [container addSubview:label];
    return container;
}

#pragma mark - Custom Icon Drawing

/// Create a template image drawn with the given block. Template images auto-adapt to dark/light mode.
- (NSImage *)templateImageWithDrawing:(void (^)(NSSize size))drawBlock {
    NSSize size = NSMakeSize(kIconSize, kIconSize);
    NSImage *image = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect rect) {
        drawBlock(size);
        return YES;
    }];
    image.template = YES;
    return image;
}

/// Idle: five static waveform bars — a calm, resting audio visualizer matching recording style
- (void)applyIdleIcon {
    NSImage *icon = [self templateImageWithDrawing:^(NSSize size) {
        CGFloat barWidth = 2.0;
        CGFloat spacing = 2.5;
        CGFloat centerX = size.width / 2.0;
        CGFloat centerY = size.height / 2.0;

        // Heights for 5 bars — symmetric resting state (short, medium, tall, medium, short)
        CGFloat heights[] = {4.0, 7.0, 11.0, 7.0, 4.0};
        NSInteger barCount = 5;
        CGFloat totalWidth = barCount * barWidth + (barCount - 1) * spacing;
        CGFloat startX = centerX - totalWidth / 2.0;

        [[NSColor blackColor] setFill];
        for (NSInteger i = 0; i < barCount; i++) {
            CGFloat x = startX + i * (barWidth + spacing);
            CGFloat h = heights[i];
            CGFloat y = centerY - h / 2.0;
            NSBezierPath *bar = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, y, barWidth, h)
                                                               xRadius:barWidth / 2.0
                                                               yRadius:barWidth / 2.0];
            [bar fill];
        }
    }];
    self.statusItem.button.image = icon;
}

/// Recording: animated waveform bars with varying heights — voice activity
- (void)applyRecordingIconWithFrame:(NSInteger)frame {
    // 5 bars, heights shift each frame to create a wave animation
    NSImage *icon = [self templateImageWithDrawing:^(NSSize size) {
        CGFloat barWidth = 2.0;
        CGFloat spacing = 2.5;
        CGFloat centerX = size.width / 2.0;
        CGFloat centerY = size.height / 2.0;
        NSInteger barCount = 5;

        CGFloat totalWidth = barCount * barWidth + (barCount - 1) * spacing;
        CGFloat startX = centerX - totalWidth / 2.0;

        [[NSColor blackColor] setFill];
        for (NSInteger i = 0; i < barCount; i++) {
            // Sine wave pattern that shifts with frame
            double phase = (double)(i + frame) * 0.8;
            CGFloat h = 4.0 + 9.0 * fabs(sin(phase));
            CGFloat x = startX + i * (barWidth + spacing);
            CGFloat y = centerY - h / 2.0;
            NSBezierPath *bar = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, y, barWidth, h)
                                                               xRadius:barWidth / 2.0
                                                               yRadius:barWidth / 2.0];
            [bar fill];
        }
    }];
    self.statusItem.button.image = icon;
}

/// Processing: pulsing dot pattern (thinking/working)
- (void)applyProcessingIconWithFrame:(NSInteger)frame {
    NSImage *icon = [self templateImageWithDrawing:^(NSSize size) {
        CGFloat centerY = size.height / 2.0;
        CGFloat centerX = size.width / 2.0;
        CGFloat dotSpacing = 5.0;
        NSInteger dotCount = 3;
        CGFloat totalWidth = (dotCount - 1) * dotSpacing;
        CGFloat startX = centerX - totalWidth / 2.0;

        for (NSInteger i = 0; i < dotCount; i++) {
            // Cascade: each dot pulses in sequence
            double phase = (double)(frame - i) * 0.7;
            CGFloat radius = 1.5 + 1.5 * fmax(0, sin(phase));
            CGFloat alpha = 0.4 + 0.6 * fmax(0, sin(phase));
            CGFloat x = startX + i * dotSpacing;

            [[NSColor colorWithWhite:0 alpha:alpha] setFill];
            NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:
                NSMakeRect(x - radius, centerY - radius, radius * 2, radius * 2)];
            [dot fill];
        }
    }];
    self.statusItem.button.image = icon;
}

/// Error: X mark
- (void)applyErrorIcon {
    NSImage *icon = [self templateImageWithDrawing:^(NSSize size) {
        CGFloat centerX = size.width / 2.0;
        CGFloat centerY = size.height / 2.0;
        CGFloat arm = 4.0;

        NSBezierPath *path = [NSBezierPath bezierPath];
        path.lineWidth = 2.0;
        path.lineCapStyle = NSLineCapStyleRound;

        [path moveToPoint:NSMakePoint(centerX - arm, centerY - arm)];
        [path lineToPoint:NSMakePoint(centerX + arm, centerY + arm)];
        [path moveToPoint:NSMakePoint(centerX + arm, centerY - arm)];
        [path lineToPoint:NSMakePoint(centerX - arm, centerY + arm)];

        [[NSColor blackColor] setStroke];
        [path stroke];
    }];
    self.statusItem.button.image = icon;
}

/// Pasting: checkmark
- (void)applyPasteIcon {
    NSImage *icon = [self templateImageWithDrawing:^(NSSize size) {
        CGFloat centerX = size.width / 2.0;
        CGFloat centerY = size.height / 2.0;

        NSBezierPath *path = [NSBezierPath bezierPath];
        path.lineWidth = 2.0;
        path.lineCapStyle = NSLineCapStyleRound;
        path.lineJoinStyle = NSLineJoinStyleRound;

        // Checkmark
        [path moveToPoint:NSMakePoint(centerX - 4, centerY)];
        [path lineToPoint:NSMakePoint(centerX - 1, centerY - 3.5)];
        [path lineToPoint:NSMakePoint(centerX + 5, centerY + 4)];

        [[NSColor blackColor] setStroke];
        [path stroke];
    }];
    self.statusItem.button.image = icon;
}

#pragma mark - State Updates

- (void)updateState:(NSString *)state {
    self.currentState = state;
    [self stopAnimation];

    if ([state isEqualToString:@"idle"] || [state isEqualToString:@"completed"]) {
        NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
        NSString *ver = info[@"CFBundleShortVersionString"] ?: @"?";
        NSString *bld = info[@"CFBundleVersion"] ?: @"?";
        self.statusMenuItem.title = [NSString stringWithFormat:KoeLocalizedString(@"statusBar.status.ready"), ver, bld];
        [self applyIdleIcon];

    } else if ([state hasPrefix:@"recording"]) {
        self.statusMenuItem.title = KoeLocalizedString(@"statusBar.status.listening");
        [self startRecordingAnimation];

    } else if ([state isEqualToString:@"connecting_asr"]) {
        self.statusMenuItem.title = KoeLocalizedString(@"statusBar.status.connecting");
        [self startProcessingAnimation];

    } else if ([state isEqualToString:@"finalizing_asr"]) {
        self.statusMenuItem.title = KoeLocalizedString(@"statusBar.status.recognizing");
        [self startProcessingAnimation];

    } else if ([state isEqualToString:@"correcting"]) {
        self.statusMenuItem.title = KoeLocalizedString(@"statusBar.status.thinking");
        [self startProcessingAnimation];

    } else if ([state hasPrefix:@"preparing_paste"] || [state isEqualToString:@"pasting"]) {
        self.statusMenuItem.title = KoeLocalizedString(@"statusBar.status.pasting");
        [self applyPasteIcon];

    } else if ([state isEqualToString:@"error"] || [state isEqualToString:@"failed"]) {
        self.statusMenuItem.title = KoeLocalizedString(@"statusBar.status.error");
        [self applyErrorIcon];

    } else {
        self.statusMenuItem.title = KoeLocalizedString(@"statusBar.status.working");
        [self startProcessingAnimation];
    }
}

#pragma mark - Animations

- (void)startRecordingAnimation {
    self.animationFrame = 0;
    [self applyRecordingIconWithFrame:0];
    self.animationTimer = [NSTimer scheduledTimerWithTimeInterval:0.15
                                                         repeats:YES
                                                           block:^(NSTimer *timer) {
        self.animationFrame++;
        [self applyRecordingIconWithFrame:self.animationFrame];
    }];
}

- (void)startProcessingAnimation {
    self.animationFrame = 0;
    [self applyProcessingIconWithFrame:0];
    self.animationTimer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                         repeats:YES
                                                           block:^(NSTimer *timer) {
        self.animationFrame++;
        [self applyProcessingIconWithFrame:self.animationFrame];
    }];
}

- (void)stopAnimation {
    [self.animationTimer invalidate];
    self.animationTimer = nil;
    self.animationFrame = 0;
}

#pragma mark - Actions

- (void)openSetupWizard:(id)sender {
    if ([self.delegate respondsToSelector:@selector(statusBarDidSelectSetupWizard)]) {
        [self.delegate statusBarDidSelectSetupWizard];
    }
}

- (void)openConfigFolder:(id)sender {
    NSString *path = [NSString stringWithFormat:@"%@/.koe", NSHomeDirectory()];
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
}

- (void)reloadConfig:(id)sender {
    if ([self.delegate respondsToSelector:@selector(statusBarDidSelectReloadConfig)]) {
        [self.delegate statusBarDidSelectReloadConfig];
    }
}

- (void)checkForUpdates:(id)sender {
    if ([self.delegate respondsToSelector:@selector(statusBarDidSelectCheckForUpdates)]) {
        [self.delegate statusBarDidSelectCheckForUpdates];
    }
}

- (void)toggleLaunchAtLogin:(NSMenuItem *)sender {
    if (@available(macOS 13.0, *)) {
        SMAppService *service = SMAppService.mainAppService;
        NSError *error = nil;
        if (service.status == SMAppServiceStatusEnabled) {
            [service unregisterAndReturnError:&error];
            sender.state = NSControlStateValueOff;
        } else {
            [service registerAndReturnError:&error];
            sender.state = NSControlStateValueOn;
        }
        if (error) {
            NSLog(@"[Koe] Launch at login toggle failed: %@", error.localizedDescription);
        }
    }
}

- (void)quitApp:(id)sender {
    if ([self.delegate respondsToSelector:@selector(statusBarDidSelectQuit)]) {
        [self.delegate statusBarDidSelectQuit];
    } else {
        [NSApp terminate:nil];
    }
}

- (void)dealloc {
    [self stopAnimation];
}

@end
