#import "SPStatusBarManager.h"
#import "SPPermissionManager.h"
#import "SPAudioDeviceManager.h"
#import "SPHistoryManager.h"
#import <Cocoa/Cocoa.h>
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
@property (nonatomic, strong) NSMenuItem *hotkeyDisplayItem;
@property (nonatomic, strong) NSMenuItem *statsCountItem;
@property (nonatomic, strong) NSMenuItem *statsTimeItem;
@property (nonatomic, strong) NSMenuItem *statsSpeedItem;
@property (nonatomic, strong) NSTimer *animationTimer;
@property (nonatomic, assign) NSInteger animationFrame;
@property (nonatomic, copy) NSString *currentState;

@end

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
    return @"Fn (Globe)";
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
    NSString *statusTitle = [NSString stringWithFormat:@"Ready — v%@ (%@)", version, build];
    self.statusMenuItem = [[NSMenuItem alloc] initWithTitle:statusTitle
                                                    action:nil
                                             keyEquivalent:@""];
    self.statusMenuItem.enabled = NO;
    [menu addItem:self.statusMenuItem];

    self.hotkeyDisplayItem = [[NSMenuItem alloc] initWithTitle:@"Hotkeys: Fn / Left Option"
                                                        action:nil
                                                 keyEquivalent:@""];
    self.hotkeyDisplayItem.enabled = NO;
    [menu addItem:self.hotkeyDisplayItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Statistics section
    NSMenuItem *statsHeader = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    statsHeader.view = [self headerViewWithTitle:@"Statistics"];
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
    permHeader.view = [self headerViewWithTitle:@"Permissions"];
    [menu addItem:permHeader];

    self.micPermissionItem = [[NSMenuItem alloc] initWithTitle:@"  Microphone: Checking..."
                                                       action:nil
                                                keyEquivalent:@""];
    self.micPermissionItem.enabled = NO;
    [menu addItem:self.micPermissionItem];

    self.accessibilityPermissionItem = [[NSMenuItem alloc] initWithTitle:@"  Accessibility: Checking..."
                                                                 action:nil
                                                          keyEquivalent:@""];
    self.accessibilityPermissionItem.enabled = NO;
    [menu addItem:self.accessibilityPermissionItem];

    self.inputMonitoringPermissionItem = [[NSMenuItem alloc] initWithTitle:@"  Input Monitoring: Checking..."
                                                                   action:nil
                                                            keyEquivalent:@""];
    self.inputMonitoringPermissionItem.enabled = NO;
    [menu addItem:self.inputMonitoringPermissionItem];

    self.notificationPermissionItem = [[NSMenuItem alloc] initWithTitle:@"  Notifications: Checking..."
                                                                action:nil
                                                         keyEquivalent:@""];
    self.notificationPermissionItem.enabled = NO;
    [menu addItem:self.notificationPermissionItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Microphone selection submenu
    NSMenuItem *microphoneItem = [[NSMenuItem alloc] initWithTitle:@"Microphone"
                                                           action:nil
                                                    keyEquivalent:@""];
    NSMenu *micSubmenu = [[NSMenu alloc] initWithTitle:@"Microphone"];
    microphoneItem.submenu = micSubmenu;
    [menu addItem:microphoneItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *setupWizard = [[NSMenuItem alloc] initWithTitle:@"Setup Wizard..."
                                                        action:@selector(openSetupWizard:)
                                                 keyEquivalent:@","];
    setupWizard.target = self;
    [menu addItem:setupWizard];

    NSMenuItem *openConfig = [[NSMenuItem alloc] initWithTitle:@"Open Config Folder..."
                                                       action:@selector(openConfigFolder:)
                                                keyEquivalent:@""];
    openConfig.target = self;
    [menu addItem:openConfig];

    NSMenuItem *checkForUpdates = [[NSMenuItem alloc] initWithTitle:@"Check for Updates..."
                                                             action:@selector(checkForUpdates:)
                                                      keyEquivalent:@""];
    checkForUpdates.target = self;
    [menu addItem:checkForUpdates];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *loginItem = [[NSMenuItem alloc] initWithTitle:@"Launch at Login"
                                                      action:@selector(toggleLaunchAtLogin:)
                                               keyEquivalent:@""];
    loginItem.target = self;
    if (@available(macOS 13.0, *)) {
        loginItem.state = (SMAppService.mainAppService.status == SMAppServiceStatusEnabled)
                          ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [menu addItem:loginItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit Koe"
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

    self.micPermissionItem.title = [NSString stringWithFormat:@"  Microphone: %@",
                                    mic ? @"Granted" : @"Not Granted"];
    self.accessibilityPermissionItem.title = [NSString stringWithFormat:@"  Accessibility: %@",
                                              accessibility ? @"Granted" : @"Not Granted"];
    self.inputMonitoringPermissionItem.title = [NSString stringWithFormat:@"  Input Monitoring: %@",
                                                inputMonitoring ? @"Granted" : @"Not Granted"];

    [self.permissionManager checkNotificationPermissionWithCompletion:^(BOOL granted) {
        self.notificationPermissionItem.title = [NSString stringWithFormat:@"  Notifications: %@",
                                                  granted ? @"Granted" : @"Not Granted"];
    }];
}

- (void)refreshStats {
    SPHistoryStats *stats = [[SPHistoryManager sharedManager] aggregateStats];

    // Count display
    NSMutableArray *parts = [NSMutableArray array];
    if (stats.totalCharCount > 0) {
        [parts addObject:[NSString stringWithFormat:@"%ld chars", (long)stats.totalCharCount]];
    }
    if (stats.totalWordCount > 0) {
        [parts addObject:[NSString stringWithFormat:@"%ld words", (long)stats.totalWordCount]];
    }
    if (parts.count > 0) {
        self.statsCountItem.title = [NSString stringWithFormat:@"  Total: %@",
                                     [parts componentsJoinedByString:@" / "]];
    } else {
        self.statsCountItem.title = @"  Total: No data yet";
    }

    // Time + session count
    NSInteger totalSec = stats.totalDurationMs / 1000;
    NSInteger min = totalSec / 60;
    NSInteger sec = totalSec % 60;
    if (stats.sessionCount > 0) {
        self.statsTimeItem.title = [NSString stringWithFormat:@"  Time: %ld min %ld sec | %ld sessions",
                                    (long)min, (long)sec, (long)stats.sessionCount];
    } else {
        self.statsTimeItem.title = @"  Time: --";
    }

    // Typing speed
    if (stats.totalDurationMs > 0 && (stats.totalCharCount + stats.totalWordCount) > 0) {
        double minutes = (double)stats.totalDurationMs / 60000.0;
        if (stats.totalCharCount > stats.totalWordCount) {
            // Primarily Chinese
            double speed = (double)stats.totalCharCount / minutes;
            self.statsSpeedItem.title = [NSString stringWithFormat:@"  Speed: %.0f chars/min", speed];
        } else {
            // Primarily English
            double speed = (double)stats.totalWordCount / minutes;
            self.statsSpeedItem.title = [NSString stringWithFormat:@"  Speed: %.0f words/min", speed];
        }
    } else {
        self.statsSpeedItem.title = @"  Speed: --";
    }
}

- (void)refreshHotkeyDisplay {
    NSString *configPath = [NSHomeDirectory() stringByAppendingPathComponent:@".koe/config.yaml"];
    NSString *yaml = [NSString stringWithContentsOfFile:configPath encoding:NSUTF8StringEncoding error:nil];

    NSString *triggerKey = @"fn";
    NSString *cancelKey = @"left_option";
    if (yaml) {
        NSArray<NSString *> *lines = [yaml componentsSeparatedByString:@"\n"];
        for (NSString *line in lines) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([trimmed hasPrefix:@"trigger_key:"]) {
                NSString *value = [trimmed substringFromIndex:@"trigger_key:".length];
                value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                // Strip quotes
                if (value.length >= 2 && [value hasPrefix:@"\""] && [value hasSuffix:@"\""]) {
                    value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
                }
                // Strip inline comment for unquoted values
                NSRange commentRange = [value rangeOfString:@" #"];
                if (commentRange.location != NSNotFound) {
                    value = [[value substringToIndex:commentRange.location]
                             stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                }
                if (value.length > 0) triggerKey = value;
            } else if ([trimmed hasPrefix:@"cancel_key:"]) {
                NSString *value = [trimmed substringFromIndex:@"cancel_key:".length];
                value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (value.length >= 2 && [value hasPrefix:@"\""] && [value hasSuffix:@"\""]) {
                    value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
                }
                NSRange commentRange = [value rangeOfString:@" #"];
                if (commentRange.location != NSNotFound) {
                    value = [[value substringToIndex:commentRange.location]
                             stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                }
                if (value.length > 0) cancelKey = value;
            }
        }
    }

    if ([triggerKey isEqualToString:cancelKey]) {
        cancelKey = [triggerKey isEqualToString:@"fn"] ? @"left_option" : @"fn";
    }

    self.hotkeyDisplayItem.title = [NSString stringWithFormat:@"Hotkeys: %@ / %@",
                                    displayNameForHotkeyValue(triggerKey),
                                    displayNameForHotkeyValue(cancelKey)];
}

#pragma mark - Microphone Selection

- (void)refreshMicrophoneSubmenu:(NSMenu *)menu {
    // Find the Microphone menu item
    NSInteger micIndex = [menu indexOfItemWithTitle:@"Microphone"];
    if (micIndex == -1) return;

    NSMenu *submenu = [menu itemAtIndex:micIndex].submenu;
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
    NSMenuItem *defaultItem = [[NSMenuItem alloc] initWithTitle:@"System Default"
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
        NSMenuItem *unavailableItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%@ (Unavailable)", deviceName]
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
        self.statusMenuItem.title = [NSString stringWithFormat:@"Ready — v%@ (%@)", ver, bld];
        [self applyIdleIcon];

    } else if ([state hasPrefix:@"recording"]) {
        self.statusMenuItem.title = @"Listening...";
        [self startRecordingAnimation];

    } else if ([state isEqualToString:@"connecting_asr"]) {
        self.statusMenuItem.title = @"Connecting...";
        [self startProcessingAnimation];

    } else if ([state isEqualToString:@"finalizing_asr"]) {
        self.statusMenuItem.title = @"Recognizing...";
        [self startProcessingAnimation];

    } else if ([state isEqualToString:@"correcting"]) {
        self.statusMenuItem.title = @"Thinking...";
        [self startProcessingAnimation];

    } else if ([state hasPrefix:@"preparing_paste"] || [state isEqualToString:@"pasting"]) {
        self.statusMenuItem.title = @"Pasting...";
        [self applyPasteIcon];

    } else if ([state isEqualToString:@"error"] || [state isEqualToString:@"failed"]) {
        self.statusMenuItem.title = @"Error";
        [self applyErrorIcon];

    } else {
        self.statusMenuItem.title = @"Working...";
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
