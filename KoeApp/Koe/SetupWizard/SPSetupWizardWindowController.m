#import "SPSetupWizardWindowController.h"
#import "SPRustBridge.h"
#import <Cocoa/Cocoa.h>

static NSString *const kConfigDir = @".koe";
static NSString *const kDictionaryFile = @"dictionary.txt";
static NSString *const kSystemPromptFile = @"system_prompt.txt";

// Toolbar item identifiers
static NSToolbarItemIdentifier const kToolbarASR = @"asr";
static NSToolbarItemIdentifier const kToolbarLLM = @"llm";
static NSToolbarItemIdentifier const kToolbarHotkey = @"hotkey";
static NSToolbarItemIdentifier const kToolbarDictionary = @"dictionary";
static NSToolbarItemIdentifier const kToolbarSystemPrompt = @"system_prompt";

// ─── Config helpers (backed by sp_config_get / sp_config_set) ───────
#import "koe_core.h"

static NSString *configDirPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:kConfigDir];
}


static NSString *configGet(NSString *keyPath) {
    char *raw = sp_config_get(keyPath.UTF8String);
    if (!raw) return @"";
    NSString *result = [NSString stringWithUTF8String:raw] ?: @"";
    sp_core_free_string(raw);
    return result;
}

static BOOL configSet(NSString *keyPath, NSString *value) {
    return sp_config_set(keyPath.UTF8String, (value ?: @"").UTF8String) == 0;
}

static BOOL isNumericKeycode(NSString *value) {
    if (value.length == 0) return NO;
    NSScanner *scanner = [NSScanner scannerWithString:value];
    int intValue;
    return [scanner scanInt:&intValue] && [scanner isAtEnd];
}

static NSString *normalizedHotkeyValue(NSString *value) {
    static NSSet<NSString *> *validValues;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        validValues = [NSSet setWithArray:@[
            @"fn",
            @"left_option",
            @"right_option",
            @"left_command",
            @"right_command",
            @"left_control",
            @"right_control",
        ]];
    });
    if ([validValues containsObject:value]) return value;
    if (isNumericKeycode(value)) return value;
    return @"fn";
}

static NSString *displayNameForCustomKeycode(NSString *value) {
    int keycode = value.intValue;
    switch (keycode) {
        case 122: return @"F1 (Keycode 122)";
        case 120: return @"F2 (Keycode 120)";
        case 99:  return @"F3 (Keycode 99)";
        case 118: return @"F4 (Keycode 118)";
        case 96:  return @"F5 (Keycode 96)";
        case 97:  return @"F6 (Keycode 97)";
        case 98:  return @"F7 (Keycode 98)";
        case 100: return @"F8 (Keycode 100)";
        case 101: return @"F9 (Keycode 101)";
        case 109: return @"F10 (Keycode 109)";
        case 103: return @"F11 (Keycode 103)";
        case 111: return @"F12 (Keycode 111)";
        case 49:  return @"Space (Keycode 49)";
        case 53:  return @"Escape (Keycode 53)";
        case 48:  return @"Tab (Keycode 48)";
        case 57:  return @"CapsLock (Keycode 57)";
        default:  return [NSString stringWithFormat:@"Keycode %d", keycode];
    }
}

/// If the value is a numeric keycode, add a custom item to the popup and select it.
static void ensureCustomKeycodeInPopup(NSPopUpButton *popup, NSString *value) {
    if (!isNumericKeycode(value)) return;
    NSString *title = displayNameForCustomKeycode(value);
    [popup addItemWithTitle:title];
    [popup lastItem].representedObject = value;
    [popup selectItem:[popup lastItem]];
}

static NSString *defaultCancelKeyForTrigger(NSString *triggerKey) {
    if (isNumericKeycode(triggerKey)) return @"left_option";
    NSString *normalizedTrigger = normalizedHotkeyValue(triggerKey);
    if ([normalizedTrigger isEqualToString:@"fn"]) return @"left_option";
    if ([normalizedTrigger isEqualToString:@"left_option"]) return @"right_option";
    if ([normalizedTrigger isEqualToString:@"right_option"]) return @"left_command";
    if ([normalizedTrigger isEqualToString:@"left_command"]) return @"right_command";
    if ([normalizedTrigger isEqualToString:@"right_command"]) return @"left_control";
    if ([normalizedTrigger isEqualToString:@"left_control"]) return @"right_control";
    return @"fn";
}

// ─── Window Controller ──────────────────────────────────────────────

@interface SPSetupWizardWindowController () <NSToolbarDelegate>

// Current pane
@property (nonatomic, copy) NSString *currentPaneIdentifier;
@property (nonatomic, strong) NSView *currentPaneView;

// ASR fields
@property (nonatomic, strong) NSPopUpButton *asrProviderPopup;
@property (nonatomic, strong) NSTextField *asrAppKeyField;
@property (nonatomic, strong) NSTextField *asrAccessKeyField;
@property (nonatomic, strong) NSSecureTextField *asrAccessKeySecureField;
@property (nonatomic, strong) NSButton *asrAccessKeyToggle;
@property (nonatomic, strong) NSSecureTextField *asrQwenApiKeySecureField;
@property (nonatomic, strong) NSTextField *asrQwenApiKeyField;
@property (nonatomic, strong) NSButton *asrQwenApiKeyToggle;
@property (nonatomic, strong) NSButton *asrTestButton;
@property (nonatomic, strong) NSTextField *asrTestResultLabel;

// Local ASR model selection
@property (nonatomic, strong) NSPopUpButton *localModelPopup;
@property (nonatomic, strong) NSTextField *localModelLabel;
@property (nonatomic, strong) NSTextField *modelStatusLabel;
@property (nonatomic, strong) NSButton *modelDownloadButton;
@property (nonatomic, strong) NSButton *modelDeleteButton;
@property (nonatomic, strong) NSProgressIndicator *modelProgressBar;
@property (nonatomic, strong) NSTextField *modelProgressSizeLabel;
@property (nonatomic, strong) NSMutableSet<NSString *> *downloadingModels;
@property (nonatomic, copy) NSString *pendingVerificationPath;

// LLM fields
@property (nonatomic, strong) NSButton *llmEnabledCheckbox;
@property (nonatomic, strong) NSTextField *llmBaseUrlField;
@property (nonatomic, strong) NSTextField *llmApiKeyField;
@property (nonatomic, strong) NSSecureTextField *llmApiKeySecureField;
@property (nonatomic, strong) NSButton *llmApiKeyToggle;
@property (nonatomic, strong) NSTextField *llmModelField;
@property (nonatomic, strong) NSButton *llmTestButton;
@property (nonatomic, strong) NSTextField *llmTestResultLabel;

// LLM max token parameter
@property (nonatomic, strong) NSPopUpButton *maxTokenParamPopup;

// Hotkey
@property (nonatomic, strong) NSPopUpButton *hotkeyPopup;
@property (nonatomic, strong) NSPopUpButton *cancelHotkeyPopup;
@property (nonatomic, strong) NSButton *startSoundCheckbox;
@property (nonatomic, strong) NSButton *stopSoundCheckbox;
@property (nonatomic, strong) NSButton *errorSoundCheckbox;

// Dictionary
@property (nonatomic, strong) NSTextView *dictionaryTextView;

// System Prompt
@property (nonatomic, strong) NSTextView *systemPromptTextView;

@end

@implementation SPSetupWizardWindowController {
    dispatch_queue_t _verifyQueue;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 600, 400)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:YES];
    window.title = @"Koe Settings";
    window.toolbarStyle = NSWindowToolbarStylePreference;

    self = [super initWithWindow:window];
    if (self) {
        _verifyQueue = dispatch_queue_create("koe.model.verify", DISPATCH_QUEUE_SERIAL);
        [self setupToolbar];
    }
    return self;
}

- (void)showWindow:(id)sender {
    if (!self.currentPaneIdentifier) {
        [self switchToPane:kToolbarASR];
    }
    [self loadCurrentValues];
    [self.window center];
    [self.window makeKeyAndOrderFront:sender];
    [NSApp activateIgnoringOtherApps:YES];
}

// ─── Toolbar ────────────────────────────────────────────────────────

- (void)setupToolbar {
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"KoeSettingsToolbar"];
    toolbar.delegate = self;
    toolbar.displayMode = NSToolbarDisplayModeIconAndLabel;
    toolbar.selectedItemIdentifier = kToolbarASR;
    self.window.toolbar = toolbar;
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return @[kToolbarASR, kToolbarLLM, kToolbarHotkey, kToolbarDictionary, kToolbarSystemPrompt];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[kToolbarASR, kToolbarLLM, kToolbarHotkey, kToolbarDictionary, kToolbarSystemPrompt];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarSelectableItemIdentifiers:(NSToolbar *)toolbar {
    return @[kToolbarASR, kToolbarLLM, kToolbarHotkey, kToolbarDictionary, kToolbarSystemPrompt];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier willBeInsertedIntoToolbar:(BOOL)flag {
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
    item.target = self;
    item.action = @selector(toolbarItemClicked:);

    if ([itemIdentifier isEqualToString:kToolbarASR]) {
        item.label = @"ASR";
        item.image = [NSImage imageWithSystemSymbolName:@"mic.fill" accessibilityDescription:@"ASR"];
    } else if ([itemIdentifier isEqualToString:kToolbarLLM]) {
        item.label = @"LLM";
        item.image = [NSImage imageWithSystemSymbolName:@"cpu" accessibilityDescription:@"LLM"];
    } else if ([itemIdentifier isEqualToString:kToolbarHotkey]) {
        item.label = @"Controls";
        item.image = [NSImage imageWithSystemSymbolName:@"slider.horizontal.3" accessibilityDescription:@"Controls"];
    } else if ([itemIdentifier isEqualToString:kToolbarDictionary]) {
        item.label = @"Dictionary";
        item.image = [NSImage imageWithSystemSymbolName:@"book" accessibilityDescription:@"Dictionary"];
    } else if ([itemIdentifier isEqualToString:kToolbarSystemPrompt]) {
        item.label = @"Prompt";
        item.image = [NSImage imageWithSystemSymbolName:@"text.bubble" accessibilityDescription:@"System Prompt"];
    }

    return item;
}

- (void)toolbarItemClicked:(NSToolbarItem *)sender {
    [self switchToPane:sender.itemIdentifier];
}

// ─── Pane Switching ─────────────────────────────────────────────────

- (void)switchToPane:(NSString *)identifier {
    if ([self.currentPaneIdentifier isEqualToString:identifier]) return;
    self.currentPaneIdentifier = identifier;

    // Remove old pane
    [self.currentPaneView removeFromSuperview];

    // Build new pane
    NSView *paneView;
    if ([identifier isEqualToString:kToolbarASR]) {
        paneView = [self buildAsrPane];
    } else if ([identifier isEqualToString:kToolbarLLM]) {
        paneView = [self buildLlmPane];
    } else if ([identifier isEqualToString:kToolbarHotkey]) {
        paneView = [self buildHotkeyPane];
    } else if ([identifier isEqualToString:kToolbarDictionary]) {
        paneView = [self buildDictionaryPane];
    } else if ([identifier isEqualToString:kToolbarSystemPrompt]) {
        paneView = [self buildSystemPromptPane];
    }

    if (!paneView) return;

    self.currentPaneView = paneView;
    self.window.toolbar.selectedItemIdentifier = identifier;

    // Resize window to fit pane with animation
    NSSize paneSize = paneView.frame.size;
    NSRect windowFrame = self.window.frame;
    CGFloat contentHeight = paneSize.height;
    CGFloat titleBarHeight = windowFrame.size.height - [self.window.contentView frame].size.height;
    CGFloat newHeight = contentHeight + titleBarHeight;
    CGFloat newWidth = paneSize.width;

    NSRect newFrame = NSMakeRect(
        windowFrame.origin.x + (windowFrame.size.width - newWidth) / 2.0,
        windowFrame.origin.y + windowFrame.size.height - newHeight,
        newWidth,
        newHeight
    );

    [self.window setFrame:newFrame display:YES animate:YES];

    // Add pane to window
    paneView.frame = [self.window.contentView bounds];
    paneView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.window.contentView addSubview:paneView];

    // Reload values for this pane
    [self loadValuesForPane:identifier];
}

// ─── Build Panes ────────────────────────────────────────────────────

- (NSView *)buildAsrPane {
    CGFloat paneWidth = 600;
    CGFloat labelW = 130;
    CGFloat fieldX = labelW + 24;
    CGFloat fieldW = paneWidth - fieldX - 32;
    CGFloat rowH = 32;

    // Calculate content height
    CGFloat contentHeight = 260;
    NSView *pane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];

    CGFloat y = contentHeight - 48;

    // Description
    NSTextField *desc = [self descriptionLabel:@"Choose the ASR provider used for transcription."];
    desc.frame = NSMakeRect(24, y - 10, paneWidth - 48, 36);
    [pane addSubview:desc];
    y -= 52;

    // Provider
    [pane addSubview:[self formLabel:@"Provider" frame:NSMakeRect(16, y, labelW, 22)]];
    self.asrProviderPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX, y - 2, 160, 26) pullsDown:NO];
    [self.asrProviderPopup addItemWithTitle:@"Doubao (\u8c46\u5305)"];
    [self.asrProviderPopup itemAtIndex:0].representedObject = @"doubao";
    [self.asrProviderPopup addItemWithTitle:@"Qwen (\u963f\u91cc\u4e91)"];
    [self.asrProviderPopup itemAtIndex:1].representedObject = @"qwen";
    // Add local providers supported by this build
    NSDictionary *localProviderLabels = @{
        @"mlx": @"MLX (Apple Silicon)",
        @"sherpa-onnx": @"Sherpa-ONNX",
    };
    for (NSString *provider in [self.rustBridge supportedLocalProviders]) {
        NSString *label = localProviderLabels[provider] ?: provider;
        [self.asrProviderPopup addItemWithTitle:label];
        [self.asrProviderPopup lastItem].representedObject = provider;
    }
    [self.asrProviderPopup setTarget:self];
    [self.asrProviderPopup setAction:@selector(asrProviderChanged:)];
    [pane addSubview:self.asrProviderPopup];

    // Test button next to Provider
    self.asrTestButton = [NSButton buttonWithTitle:@"Test" target:self action:@selector(testAsrConnection:)];
    self.asrTestButton.bezelStyle = NSBezelStyleRounded;
    self.asrTestButton.frame = NSMakeRect(fieldX + 168, y - 2, 70, 28);
    [pane addSubview:self.asrTestButton];
    y -= rowH;

    // App Key (Doubao only)
    self.asrAppKeyField = [self formTextField:NSMakeRect(fieldX, y, fieldW, 22) placeholder:@"Volcengine App ID"];
    [pane addSubview:self.asrAppKeyField];
    NSTextField *appKeyLabel = [self formLabel:@"App Key" frame:NSMakeRect(16, y, labelW, 22)];
    appKeyLabel.tag = 1001;
    [pane addSubview:appKeyLabel];

    // Row 1: Model popup + Download button (Local providers, same row as App Key)
    self.localModelLabel = [self formLabel:@"Model" frame:NSMakeRect(16, y, labelW, 22)];
    self.localModelLabel.tag = 1004;
    self.localModelLabel.hidden = YES;
    [pane addSubview:self.localModelLabel];
    self.localModelPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX, y - 2, fieldW - 26, 26) pullsDown:NO];
    self.localModelPopup.hidden = YES;
    [self.localModelPopup setTarget:self];
    [self.localModelPopup setAction:@selector(localModelChanged:)];
    [pane addSubview:self.localModelPopup];

    // Download button (right of model popup, same style as eye button)
    self.modelDownloadButton = [[NSButton alloc] initWithFrame:NSMakeRect(fieldX + fieldW - 20, y + 1, 20, 20)];
    self.modelDownloadButton.image = [NSImage imageWithSystemSymbolName:@"arrow.down.circle"
                                                  accessibilityDescription:@"Download"];
    self.modelDownloadButton.bezelStyle = NSBezelStyleInline;
    self.modelDownloadButton.bordered = NO;
    self.modelDownloadButton.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.modelDownloadButton.target = self;
    self.modelDownloadButton.action = @selector(downloadSelectedModel:);
    self.modelDownloadButton.hidden = YES;
    [pane addSubview:self.modelDownloadButton];

    y -= rowH;

    // Row 2: Status + Delete button
    self.modelStatusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, y + 2, fieldW - 32, 18)];
    self.modelStatusLabel.bezeled = NO;
    self.modelStatusLabel.drawsBackground = NO;
    self.modelStatusLabel.editable = NO;
    self.modelStatusLabel.selectable = NO;
    self.modelStatusLabel.font = [NSFont systemFontOfSize:12];
    self.modelStatusLabel.hidden = YES;
    [pane addSubview:self.modelStatusLabel];

    // Delete button (right end of status row, same style as eye button)
    self.modelDeleteButton = [[NSButton alloc] initWithFrame:NSMakeRect(fieldX + fieldW - 20, y + 1, 20, 20)];
    self.modelDeleteButton.image = [NSImage imageWithSystemSymbolName:@"trash"
                                                accessibilityDescription:@"Delete"];
    self.modelDeleteButton.bezelStyle = NSBezelStyleInline;
    self.modelDeleteButton.bordered = NO;
    self.modelDeleteButton.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.modelDeleteButton.target = self;
    self.modelDeleteButton.action = @selector(deleteSelectedModel:);
    self.modelDeleteButton.hidden = YES;
    [pane addSubview:self.modelDeleteButton];

    y -= rowH;

    // Row 3: Progress bar + size label
    self.modelProgressBar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(fieldX, y + 10, fieldW - 120, 10)];
    self.modelProgressBar.controlSize = NSControlSizeMini;
    self.modelProgressBar.style = NSProgressIndicatorStyleBar;
    self.modelProgressBar.minValue = 0;
    self.modelProgressBar.maxValue = 100;
    self.modelProgressBar.indeterminate = NO;
    self.modelProgressBar.hidden = YES;
    [pane addSubview:self.modelProgressBar];

    self.modelProgressSizeLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX + fieldW - 114, y + 2, 114, 18)];
    self.modelProgressSizeLabel.bezeled = NO;
    self.modelProgressSizeLabel.drawsBackground = NO;
    self.modelProgressSizeLabel.editable = NO;
    self.modelProgressSizeLabel.selectable = NO;
    self.modelProgressSizeLabel.alignment = NSTextAlignmentRight;
    self.modelProgressSizeLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.modelProgressSizeLabel.textColor = [NSColor secondaryLabelColor];
    self.modelProgressSizeLabel.hidden = YES;
    [pane addSubview:self.modelProgressSizeLabel];

    y -= rowH;

    // Access Key (Doubao) — fixed at row 2 (same as Qwen API Key)
    CGFloat accessKeyY = contentHeight - 48 - 52 - rowH - rowH;
    CGFloat eyeW = 28;
    CGFloat secFieldW = fieldW - eyeW - 4;

    self.asrAccessKeySecureField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(fieldX, accessKeyY, secFieldW, 22)];
    self.asrAccessKeySecureField.placeholderString = @"Volcengine Access Token";
    self.asrAccessKeySecureField.font = [NSFont systemFontOfSize:13];
    [pane addSubview:self.asrAccessKeySecureField];
    self.asrAccessKeyField = [self formTextField:NSMakeRect(fieldX, accessKeyY, secFieldW, 22) placeholder:@"Volcengine Access Token"];
    self.asrAccessKeyField.hidden = YES;
    [pane addSubview:self.asrAccessKeyField];
    self.asrAccessKeyToggle = [self eyeButtonWithFrame:NSMakeRect(fieldX + secFieldW + 4, accessKeyY - 1, eyeW, 24)
                                                action:@selector(toggleAsrAccessKeyVisibility:)];
    [pane addSubview:self.asrAccessKeyToggle];
    NSTextField *accessKeyLabel = [self formLabel:@"Access Key" frame:NSMakeRect(16, accessKeyY, labelW, 22)];
    accessKeyLabel.tag = 1002;
    [pane addSubview:accessKeyLabel];

    // Qwen API Key — fixed at row 1 (same position as App Key)
    CGFloat qwenY = contentHeight - 48 - 52 - rowH;
    self.asrQwenApiKeySecureField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(fieldX, qwenY, secFieldW, 22)];
    self.asrQwenApiKeySecureField.placeholderString = @"DashScope API Key (sk-xxx)";
    self.asrQwenApiKeySecureField.font = [NSFont systemFontOfSize:13];
    self.asrQwenApiKeySecureField.hidden = YES;
    [pane addSubview:self.asrQwenApiKeySecureField];
    self.asrQwenApiKeyField = [self formTextField:NSMakeRect(fieldX, qwenY, secFieldW, 22) placeholder:@"DashScope API Key (sk-xxx)"];
    self.asrQwenApiKeyField.hidden = YES;
    [pane addSubview:self.asrQwenApiKeyField];
    self.asrQwenApiKeyToggle = [self eyeButtonWithFrame:NSMakeRect(fieldX + secFieldW + 4, qwenY - 1, eyeW, 24)
                                                action:@selector(toggleQwenApiKeyVisibility:)];
    self.asrQwenApiKeyToggle.hidden = YES;
    [pane addSubview:self.asrQwenApiKeyToggle];
    NSTextField *qwenKeyLabel = [self formLabel:@"API Key" frame:NSMakeRect(16, qwenY, labelW, 22)];
    qwenKeyLabel.tag = 1003;
    qwenKeyLabel.hidden = YES;
    [pane addSubview:qwenKeyLabel];

    // Test result label
    self.asrTestResultLabel = [NSTextField wrappingLabelWithString:@""];
    self.asrTestResultLabel.frame = NSMakeRect(fieldX, 55, fieldW, 42);
    self.asrTestResultLabel.font = [NSFont systemFontOfSize:12];
    self.asrTestResultLabel.selectable = YES;
    [pane addSubview:self.asrTestResultLabel];

    // Save / Cancel buttons
    [self addButtonsToPane:pane atY:16 width:paneWidth];

    return pane;
}

- (NSView *)buildLlmPane {
    CGFloat paneWidth = 600;
    CGFloat labelW = 130;
    CGFloat fieldX = labelW + 24;
    CGFloat fieldW = paneWidth - fieldX - 32;
    CGFloat rowH = 32;

    CGFloat contentHeight = 540;
    NSView *pane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];

    CGFloat y = contentHeight - 48;

    // Description
    NSTextField *desc = [self descriptionLabel:@"Configure an OpenAI-compatible LLM for post-correction. When disabled, raw ASR output is used directly."];
    desc.frame = NSMakeRect(24, y - 10, paneWidth - 48, 36);
    [pane addSubview:desc];
    y -= 52;

    // Enabled toggle
    self.llmEnabledCheckbox = [NSButton checkboxWithTitle:@"Enable LLM Correction"
                                                   target:self
                                                   action:@selector(llmEnabledToggled:)];
    self.llmEnabledCheckbox.frame = NSMakeRect(fieldX, y, 300, 22);
    [pane addSubview:self.llmEnabledCheckbox];
    y -= rowH + 8;

    // Base URL
    [pane addSubview:[self formLabel:@"Base URL" frame:NSMakeRect(16, y, labelW, 22)]];
    self.llmBaseUrlField = [self formTextField:NSMakeRect(fieldX, y, fieldW, 22) placeholder:@"https://api.openai.com/v1"];
    [pane addSubview:self.llmBaseUrlField];
    y -= rowH;

    // API Key (secure by default)
    CGFloat eyeW = 28;
    CGFloat secFieldW = fieldW - eyeW - 4;
    [pane addSubview:[self formLabel:@"API Key" frame:NSMakeRect(16, y, labelW, 22)]];
    self.llmApiKeySecureField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(fieldX, y, secFieldW, 22)];
    self.llmApiKeySecureField.placeholderString = @"sk-...";
    self.llmApiKeySecureField.font = [NSFont systemFontOfSize:13];
    [pane addSubview:self.llmApiKeySecureField];
    self.llmApiKeyField = [self formTextField:NSMakeRect(fieldX, y, secFieldW, 22) placeholder:@"sk-..."];
    self.llmApiKeyField.hidden = YES;
    [pane addSubview:self.llmApiKeyField];
    self.llmApiKeyToggle = [self eyeButtonWithFrame:NSMakeRect(fieldX + secFieldW + 4, y - 1, eyeW, 24)
                                             action:@selector(toggleLlmApiKeyVisibility:)];
    [pane addSubview:self.llmApiKeyToggle];
    y -= rowH;

    // Model
    [pane addSubview:[self formLabel:@"Model" frame:NSMakeRect(16, y, labelW, 22)]];
    self.llmModelField = [self formTextField:NSMakeRect(fieldX, y, fieldW, 22) placeholder:@"gpt-5.4-nano"];
    [pane addSubview:self.llmModelField];
    y -= rowH + 4;

    // Max Token Parameter
    [pane addSubview:[self formLabel:@"Token Parameter" frame:NSMakeRect(16, y, labelW, 22)]];
    self.maxTokenParamPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX, y - 2, 240, 26) pullsDown:NO];
    [self.maxTokenParamPopup addItemsWithTitles:@[
        @"max_completion_tokens",
        @"max_tokens",
    ]];
    [self.maxTokenParamPopup itemAtIndex:0].representedObject = @"max_completion_tokens";
    [self.maxTokenParamPopup itemAtIndex:1].representedObject = @"max_tokens";
    [pane addSubview:self.maxTokenParamPopup];
    y -= 42;

    // Hint text
    NSTextField *tokenHint = [self descriptionLabel:@"GPT-4o and older models use max_tokens. GPT-5 and reasoning models (o1/o3) use max_completion_tokens."];
    tokenHint.frame = NSMakeRect(fieldX, y - 2, fieldW, 32);
    [pane addSubview:tokenHint];
    y -= 44;

    // Test button
    self.llmTestButton = [NSButton buttonWithTitle:@"Test Connection" target:self action:@selector(testLlmConnection:)];
    self.llmTestButton.bezelStyle = NSBezelStyleRounded;
    self.llmTestButton.frame = NSMakeRect(fieldX, y, 130, 28);
    [pane addSubview:self.llmTestButton];
    y -= 32;

    // Test result
    self.llmTestResultLabel = [NSTextField wrappingLabelWithString:@""];
    self.llmTestResultLabel.frame = NSMakeRect(fieldX, y - 36, fieldW, 42);
    self.llmTestResultLabel.font = [NSFont systemFontOfSize:12];
    self.llmTestResultLabel.selectable = YES;
    [pane addSubview:self.llmTestResultLabel];

    // Save / Cancel buttons
    [self addButtonsToPane:pane atY:16 width:paneWidth];

    return pane;
}

- (NSView *)buildHotkeyPane {
    CGFloat paneWidth = 600;
    CGFloat labelW = 130;
    CGFloat fieldX = labelW + 24;
    CGFloat rowH = 32;

    CGFloat contentHeight = 360;
    NSView *pane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];

    CGFloat y = contentHeight - 48;

    // Description
    NSTextField *desc = [self descriptionLabel:@"Choose a trigger key for voice input and a separate cancel key to abort the current session."];
    desc.frame = NSMakeRect(24, y - 10, paneWidth - 48, 36);
    [pane addSubview:desc];
    y -= 52;

    // Trigger Key
    [pane addSubview:[self formLabel:@"Trigger Key" frame:NSMakeRect(16, y, labelW, 22)]];

    self.hotkeyPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX, y - 2, 220, 26) pullsDown:NO];
    [self.hotkeyPopup addItemsWithTitles:@[
        @"Fn (Globe)",
        @"Left Option (\u2325)",
        @"Right Option (\u2325)",
        @"Left Command (\u2318)",
        @"Right Command (\u2318)",
        @"Left Control (\u2303)",
        @"Right Control (\u2303)",
    ]];
    [self.hotkeyPopup itemAtIndex:0].representedObject = @"fn";
    [self.hotkeyPopup itemAtIndex:1].representedObject = @"left_option";
    [self.hotkeyPopup itemAtIndex:2].representedObject = @"right_option";
    [self.hotkeyPopup itemAtIndex:3].representedObject = @"left_command";
    [self.hotkeyPopup itemAtIndex:4].representedObject = @"right_command";
    [self.hotkeyPopup itemAtIndex:5].representedObject = @"left_control";
    [self.hotkeyPopup itemAtIndex:6].representedObject = @"right_control";
    [pane addSubview:self.hotkeyPopup];
    y -= rowH + 16;

    // Cancel Key
    [pane addSubview:[self formLabel:@"Cancel Key" frame:NSMakeRect(16, y, labelW, 22)]];

    self.cancelHotkeyPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX, y - 2, 220, 26) pullsDown:NO];
    [self.cancelHotkeyPopup addItemsWithTitles:@[
        @"Fn (Globe)",
        @"Left Option (\u2325)",
        @"Right Option (\u2325)",
        @"Left Command (\u2318)",
        @"Right Command (\u2318)",
        @"Left Control (\u2303)",
        @"Right Control (\u2303)",
    ]];
    [self.cancelHotkeyPopup itemAtIndex:0].representedObject = @"fn";
    [self.cancelHotkeyPopup itemAtIndex:1].representedObject = @"left_option";
    [self.cancelHotkeyPopup itemAtIndex:2].representedObject = @"right_option";
    [self.cancelHotkeyPopup itemAtIndex:3].representedObject = @"left_command";
    [self.cancelHotkeyPopup itemAtIndex:4].representedObject = @"right_command";
    [self.cancelHotkeyPopup itemAtIndex:5].representedObject = @"left_control";
    [self.cancelHotkeyPopup itemAtIndex:6].representedObject = @"right_control";
    [pane addSubview:self.cancelHotkeyPopup];
    y -= rowH + 8;

    NSTextField *hotkeyHint = [self descriptionLabel:@"Trigger Key and Cancel Key must be different."];
    hotkeyHint.frame = NSMakeRect(fieldX, y + 2, paneWidth - fieldX - 32, 24);
    [pane addSubview:hotkeyHint];
    y -= 30;

    // Feedback sounds
    [pane addSubview:[self formLabel:@"Feedback Sounds" frame:NSMakeRect(16, y, labelW, 22)]];

    self.startSoundCheckbox = [NSButton checkboxWithTitle:@"Play a sound when recording starts"
                                                   target:nil
                                                   action:nil];
    self.startSoundCheckbox.frame = NSMakeRect(fieldX, y - 4, 300, 22);
    [pane addSubview:self.startSoundCheckbox];
    y -= 28;

    self.stopSoundCheckbox = [NSButton checkboxWithTitle:@"Play a sound when recording stops"
                                                  target:nil
                                                  action:nil];
    self.stopSoundCheckbox.frame = NSMakeRect(fieldX, y - 4, 300, 22);
    [pane addSubview:self.stopSoundCheckbox];
    y -= 28;

    self.errorSoundCheckbox = [NSButton checkboxWithTitle:@"Play a sound when an error occurs"
                                                   target:nil
                                                   action:nil];
    self.errorSoundCheckbox.frame = NSMakeRect(fieldX, y - 4, 300, 22);
    [pane addSubview:self.errorSoundCheckbox];
    y -= 32;

    NSTextField *feedbackHint = [self descriptionLabel:@"These toggle the built-in cue sounds for start, stop, and error events."];
    feedbackHint.frame = NSMakeRect(fieldX, y - 2, paneWidth - fieldX - 32, 24);
    [pane addSubview:feedbackHint];
    y -= 34;

    // Save / Cancel buttons
    [self addButtonsToPane:pane atY:y width:paneWidth];

    return pane;
}

- (NSView *)buildDictionaryPane {
    CGFloat paneWidth = 600;
    CGFloat contentHeight = 440;
    NSView *pane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];

    CGFloat y = contentHeight - 48;

    // Description
    NSTextField *desc = [self descriptionLabel:@"User dictionary \u2014 one term per line. These terms are prioritized during LLM correction. Lines starting with # are comments."];
    desc.frame = NSMakeRect(24, y - 10, paneWidth - 48, 36);
    [pane addSubview:desc];
    y -= 44;

    // Text editor
    CGFloat editorHeight = y - 56;
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(24, 56, paneWidth - 48, editorHeight)];
    scrollView.hasVerticalScroller = YES;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.borderType = NSBezelBorder;

    self.dictionaryTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth - 54, editorHeight)];
    self.dictionaryTextView.minSize = NSMakeSize(0, editorHeight);
    self.dictionaryTextView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    self.dictionaryTextView.verticallyResizable = YES;
    self.dictionaryTextView.horizontallyResizable = NO;
    self.dictionaryTextView.autoresizingMask = NSViewWidthSizable;
    self.dictionaryTextView.textContainer.containerSize = NSMakeSize(paneWidth - 54, FLT_MAX);
    self.dictionaryTextView.textContainer.widthTracksTextView = YES;
    self.dictionaryTextView.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.dictionaryTextView.allowsUndo = YES;

    scrollView.documentView = self.dictionaryTextView;
    [pane addSubview:scrollView];

    // Save / Cancel buttons
    [self addButtonsToPane:pane atY:16 width:paneWidth];

    return pane;
}

- (NSView *)buildSystemPromptPane {
    CGFloat paneWidth = 600;
    CGFloat contentHeight = 440;
    NSView *pane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];

    CGFloat y = contentHeight - 48;

    // Description
    NSTextField *desc = [self descriptionLabel:@"System prompt sent to the LLM for text correction. Edit to customize behavior."];
    desc.frame = NSMakeRect(24, y - 10, paneWidth - 48, 36);
    [pane addSubview:desc];
    y -= 44;

    // Text editor
    CGFloat editorHeight = y - 56;
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(24, 56, paneWidth - 48, editorHeight)];
    scrollView.hasVerticalScroller = YES;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.borderType = NSBezelBorder;

    self.systemPromptTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth - 54, editorHeight)];
    self.systemPromptTextView.minSize = NSMakeSize(0, editorHeight);
    self.systemPromptTextView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    self.systemPromptTextView.verticallyResizable = YES;
    self.systemPromptTextView.horizontallyResizable = NO;
    self.systemPromptTextView.autoresizingMask = NSViewWidthSizable;
    self.systemPromptTextView.textContainer.containerSize = NSMakeSize(paneWidth - 54, FLT_MAX);
    self.systemPromptTextView.textContainer.widthTracksTextView = YES;
    self.systemPromptTextView.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.systemPromptTextView.allowsUndo = YES;

    scrollView.documentView = self.systemPromptTextView;
    [pane addSubview:scrollView];

    // Save / Cancel buttons
    [self addButtonsToPane:pane atY:16 width:paneWidth];

    return pane;
}

// ─── Shared button bar ──────────────────────────────────────────────

- (void)addButtonsToPane:(NSView *)pane atY:(CGFloat)y width:(CGFloat)paneWidth {
    NSButton *saveButton = [NSButton buttonWithTitle:@"Save" target:self action:@selector(saveConfig:)];
    saveButton.bezelStyle = NSBezelStyleRounded;
    saveButton.keyEquivalent = @"\r";
    saveButton.frame = NSMakeRect(paneWidth - 32 - 80, y, 80, 28);
    [pane addSubview:saveButton];

    NSButton *cancelButton = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancelSetup:)];
    cancelButton.bezelStyle = NSBezelStyleRounded;
    cancelButton.keyEquivalent = @"\033";
    cancelButton.frame = NSMakeRect(paneWidth - 32 - 80 - 88, y, 80, 28);
    [pane addSubview:cancelButton];
}

// ─── UI Helpers ─────────────────────────────────────────────────────

- (NSTextField *)formLabel:(NSString *)title frame:(NSRect)frame {
    NSTextField *label = [NSTextField labelWithString:title];
    label.frame = frame;
    label.alignment = NSTextAlignmentRight;
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    label.textColor = [NSColor labelColor];
    return label;
}

- (NSTextField *)formTextField:(NSRect)frame placeholder:(NSString *)placeholder {
    NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
    field.placeholderString = placeholder;
    field.font = [NSFont systemFontOfSize:13];
    field.lineBreakMode = NSLineBreakByTruncatingTail;
    field.usesSingleLineMode = YES;
    return field;
}

- (NSTextField *)descriptionLabel:(NSString *)text {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:12];
    label.textColor = [NSColor secondaryLabelColor];
    return label;
}

- (NSButton *)eyeButtonWithFrame:(NSRect)frame action:(SEL)action {
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    button.bezelStyle = NSBezelStyleInline;
    button.bordered = NO;
    button.image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:@"Show"];
    button.imageScaling = NSImageScaleProportionallyUpOrDown;
    button.target = self;
    button.action = action;
    button.tag = 0; // 0 = hidden, 1 = visible
    return button;
}

- (void)toggleAsrAccessKeyVisibility:(NSButton *)sender {
    if (sender.tag == 0) {
        // Show plain text
        self.asrAccessKeyField.stringValue = self.asrAccessKeySecureField.stringValue;
        self.asrAccessKeySecureField.hidden = YES;
        self.asrAccessKeyField.hidden = NO;
        sender.image = [NSImage imageWithSystemSymbolName:@"eye" accessibilityDescription:@"Hide"];
        sender.tag = 1;
    } else {
        // Show secure
        self.asrAccessKeySecureField.stringValue = self.asrAccessKeyField.stringValue;
        self.asrAccessKeyField.hidden = YES;
        self.asrAccessKeySecureField.hidden = NO;
        sender.image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:@"Show"];
        sender.tag = 0;
    }
}

- (void)toggleQwenApiKeyVisibility:(NSButton *)sender {
    if (sender.tag == 0) {
        // Show plain text
        self.asrQwenApiKeyField.stringValue = self.asrQwenApiKeySecureField.stringValue;
        self.asrQwenApiKeySecureField.hidden = YES;
        self.asrQwenApiKeyField.hidden = NO;
        sender.image = [NSImage imageWithSystemSymbolName:@"eye" accessibilityDescription:@"Hide"];
        sender.tag = 1;
    } else {
        // Show secure
        self.asrQwenApiKeySecureField.stringValue = self.asrQwenApiKeyField.stringValue;
        self.asrQwenApiKeyField.hidden = YES;
        self.asrQwenApiKeySecureField.hidden = NO;
        sender.image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:@"Show"];
        sender.tag = 0;
    }
}

- (void)asrProviderChanged:(NSPopUpButton *)sender {
    NSString *selectedProvider = sender.selectedItem.representedObject ?: @"doubao";
    BOOL isDoubao = [selectedProvider isEqualToString:@"doubao"];
    BOOL isQwen = [selectedProvider isEqualToString:@"qwen"];
    BOOL isLocal = !isDoubao && !isQwen;

    // Show/hide Doubao fields
    for (NSView *view in self.currentPaneView.subviews) {
        if (view.tag == 1001 || view.tag == 1002) { // App Key and Access Key labels
            view.hidden = !isDoubao;
        }
    }
    self.asrAppKeyField.hidden = !isDoubao;
    self.asrAccessKeyField.hidden = YES; // Always start hidden (secure mode)
    self.asrAccessKeySecureField.hidden = !isDoubao;
    self.asrAccessKeyToggle.hidden = !isDoubao;

    // Show/hide Qwen fields
    for (NSView *view in self.currentPaneView.subviews) {
        if (view.tag == 1003) { // Qwen API Key label
            view.hidden = !isQwen;
        }
    }
    self.asrQwenApiKeyField.hidden = YES; // Always start hidden (secure mode)
    self.asrQwenApiKeySecureField.hidden = !isQwen;
    self.asrQwenApiKeyToggle.hidden = !isQwen;

    // Show/hide local model popup, status, and download button
    self.localModelPopup.hidden = !isLocal;
    self.modelStatusLabel.hidden = !isLocal;
    if (!isLocal) {
        self.modelDownloadButton.hidden = YES;
        self.modelDeleteButton.hidden = YES;
        self.modelProgressBar.hidden = YES;
        self.modelProgressSizeLabel.hidden = YES;
    } else {
        self.modelDownloadButton.hidden = NO;
        self.modelDeleteButton.hidden = NO;
    }
    for (NSView *view in self.currentPaneView.subviews) {
        if (view.tag == 1004) { // Model label
            view.hidden = !isLocal;
        }
    }
    if (isLocal) {
        [self populateLocalModelPopup:selectedProvider];
        [self updateModelStatusLabel];
    }

    // Hide test button for local providers (no remote connection to test)
    self.asrTestButton.hidden = isLocal;
    self.asrTestResultLabel.hidden = isLocal;

    // Clear test result when switching provider
    self.asrTestResultLabel.stringValue = @"";
    self.asrTestButton.enabled = YES;
}

- (void)localModelChanged:(id)sender {
    [self updateModelStatusLabel];
}

- (void)updateModelStatusLabel {
    NSString *modelPath = self.localModelPopup.selectedItem.representedObject;
    if (!modelPath) {
        self.modelStatusLabel.stringValue = @"";
        self.modelDownloadButton.enabled = NO;
        self.modelDeleteButton.enabled = NO;
        self.modelProgressBar.hidden = YES;
        self.modelProgressSizeLabel.hidden = YES;
        return;
    }

    // If selected model is currently downloading, show progress UI
    if ([self.downloadingModels containsObject:modelPath]) {
        self.modelStatusLabel.stringValue = @"Downloading";
        self.modelStatusLabel.textColor = [NSColor secondaryLabelColor];
        self.modelDownloadButton.image = [NSImage imageWithSystemSymbolName:@"stop.circle"
                                                     accessibilityDescription:@"Stop"];
        self.modelDownloadButton.enabled = YES;
        self.modelDeleteButton.enabled = NO;
        self.modelProgressBar.hidden = NO;
        self.modelProgressSizeLabel.hidden = NO;
        return;
    }

    // 1. Cache-only lookup (~1ms)
    NSInteger cachedStatus = [self.rustBridge modelStatus:modelPath mode:SPModelVerifyCacheOnly];
    if (cachedStatus == 2) {
        [self applyModelStatus:cachedStatus];
        return;
    }

    // 2. Cache miss or incomplete — show "Verifying…" and dispatch async
    [self applyModelStatus:(cachedStatus > 0 ? cachedStatus : 1) verifying:YES];
    self.pendingVerificationPath = modelPath;

    dispatch_async(_verifyQueue, ^{
        NSInteger verified = [self.rustBridge modelStatus:modelPath mode:SPModelVerifyNormal];
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.pendingVerificationPath isEqualToString:modelPath]) {
                self.pendingVerificationPath = nil;
                [self applyModelStatus:verified];
            }
        });
    });
}

- (void)applyModelStatus:(NSInteger)status {
    [self applyModelStatus:status verifying:NO];
}

- (void)applyModelStatus:(NSInteger)status verifying:(BOOL)verifying {
    self.modelProgressBar.hidden = YES;
    self.modelProgressSizeLabel.hidden = YES;
    self.modelDownloadButton.image = [NSImage imageWithSystemSymbolName:@"arrow.down.circle"
                                                 accessibilityDescription:@"Download"];
    switch (status) {
        case 2:
            self.modelStatusLabel.stringValue = verifying ? @"● Verifying…" : @"● Installed";
            self.modelStatusLabel.textColor = verifying ? [NSColor secondaryLabelColor] : [NSColor systemGreenColor];
            self.modelDownloadButton.enabled = NO;
            self.modelDeleteButton.enabled = YES;
            break;
        case 1:
            self.modelStatusLabel.stringValue = verifying ? @"◐ Verifying…" : @"◐ Incomplete";
            self.modelStatusLabel.textColor = verifying ? [NSColor secondaryLabelColor] : [NSColor systemOrangeColor];
            self.modelDownloadButton.enabled = YES;
            self.modelDeleteButton.enabled = YES;
            break;
        default:
            self.modelStatusLabel.stringValue = @"○ Not installed";
            self.modelStatusLabel.textColor = [NSColor secondaryLabelColor];
            self.modelDownloadButton.enabled = YES;
            self.modelDeleteButton.enabled = NO;
            break;
    }
}

- (void)downloadSelectedModel:(id)sender {
    NSString *modelPath = self.localModelPopup.selectedItem.representedObject;
    if (!modelPath) return;

    // If this model is downloading, cancel it
    if ([self.downloadingModels containsObject:modelPath]) {
        [self.rustBridge cancelDownload:modelPath];
        return;
    }

    if (!self.downloadingModels) {
        self.downloadingModels = [NSMutableSet new];
    }
    [self.downloadingModels addObject:modelPath];

    // Switch to stop icon and show progress bar
    self.modelDownloadButton.image = [NSImage imageWithSystemSymbolName:@"stop.circle"
                                                 accessibilityDescription:@"Stop"];
    self.modelDownloadButton.hidden = NO;
    self.modelStatusLabel.stringValue = @"Downloading...";
    self.modelStatusLabel.textColor = [NSColor secondaryLabelColor];
    self.modelProgressBar.hidden = NO;
    self.modelProgressBar.doubleValue = 0;
    self.modelProgressSizeLabel.hidden = NO;
    self.modelProgressSizeLabel.stringValue = @"";

    // Get total size from scan_models data
    __block uint64_t totalBytesAllFiles = 0;
    for (NSDictionary *m in [self.rustBridge scanModels]) {
        if ([m[@"path"] isEqualToString:modelPath]) {
            totalBytesAllFiles = [m[@"total_size"] unsignedLongLongValue];
            break;
        }
    }
    __block NSMutableDictionary<NSNumber *, NSNumber *> *fileDownloaded = [NSMutableDictionary new];

    __weak typeof(self) weakSelf = self;
    [self.rustBridge downloadModel:modelPath
        progress:^(NSUInteger fileIndex, NSUInteger fileCount,
                   uint64_t downloaded, uint64_t total, NSString *filename) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;

            // Only update UI if this model is still selected
            NSString *selected = strongSelf.localModelPopup.selectedItem.representedObject;
            if (![modelPath isEqualToString:selected]) return;

            fileDownloaded[@(fileIndex)] = @(downloaded);

            uint64_t totalDownloaded = 0;
            for (NSNumber *v in fileDownloaded.allValues) totalDownloaded += v.unsignedLongLongValue;

            double pct = (totalBytesAllFiles > 0)
                ? (double)totalDownloaded / (double)totalBytesAllFiles * 100.0 : 0;
            strongSelf.modelProgressBar.doubleValue = pct;
            strongSelf.modelStatusLabel.stringValue = @"Downloading";
            strongSelf.modelProgressSizeLabel.stringValue =
                [NSString stringWithFormat:@"%.1f / %.1f MB",
                    (double)totalDownloaded / 1048576.0,
                    (double)totalBytesAllFiles / 1048576.0];
        }
        completion:^(BOOL success, NSString *message) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.downloadingModels removeObject:modelPath];
            [strongSelf updateModelStatusLabel];
        }];
}

- (void)deleteSelectedModel:(id)sender {
    NSString *modelPath = self.localModelPopup.selectedItem.representedObject;
    if (!modelPath) return;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Remove Model Files?";
    alert.informativeText = @"Downloaded model files will be deleted. The model can be re-downloaded later.";
    [alert addButtonWithTitle:@"Remove"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.alertStyle = NSAlertStyleWarning;

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [self.rustBridge removeModelFiles:modelPath];
        [self updateModelStatusLabel];
    }
}

- (void)populateLocalModelPopup:(NSString *)provider {
    [self.localModelPopup removeAllItems];

    NSArray<NSDictionary *> *models = [self.rustBridge scanModels];
    for (NSDictionary *model in models) {
        if (![model[@"provider"] isEqualToString:provider]) continue;

        NSString *path = model[@"path"];
        NSString *title = model[@"description"] ?: path;

        [self.localModelPopup addItemWithTitle:title];
        [self.localModelPopup lastItem].representedObject = path;
    }

    if (self.localModelPopup.numberOfItems == 0) {
        [self.localModelPopup addItemWithTitle:@"No models found"];
        self.localModelPopup.enabled = NO;
    } else {
        self.localModelPopup.enabled = YES;
    }
}

- (void)toggleLlmApiKeyVisibility:(NSButton *)sender {
    if (sender.tag == 0) {
        self.llmApiKeyField.stringValue = self.llmApiKeySecureField.stringValue;
        self.llmApiKeySecureField.hidden = YES;
        self.llmApiKeyField.hidden = NO;
        sender.image = [NSImage imageWithSystemSymbolName:@"eye" accessibilityDescription:@"Hide"];
        sender.tag = 1;
    } else {
        self.llmApiKeySecureField.stringValue = self.llmApiKeyField.stringValue;
        self.llmApiKeyField.hidden = YES;
        self.llmApiKeySecureField.hidden = NO;
        sender.image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:@"Show"];
        sender.tag = 0;
    }
}

// ─── Load / Save ────────────────────────────────────────────────────

- (void)loadCurrentValues {
    [self loadValuesForPane:self.currentPaneIdentifier];
}

- (void)loadValuesForPane:(NSString *)identifier {
    NSString *dir = configDirPath();

    if ([identifier isEqualToString:kToolbarASR]) {
        NSString *provider = configGet(@"asr.provider");
        if (provider.length == 0) provider = @"doubao";
        for (NSInteger i = 0; i < self.asrProviderPopup.numberOfItems; i++) {
            if ([[self.asrProviderPopup itemAtIndex:i].representedObject isEqualToString:provider]) {
                [self.asrProviderPopup selectItemAtIndex:i];
                break;
            }
        }
        // Load Doubao fields
        self.asrAppKeyField.stringValue = configGet(@"asr.doubao.app_key");
        NSString *accessKey = configGet(@"asr.doubao.access_key");
        self.asrAccessKeySecureField.stringValue = accessKey;
        self.asrAccessKeyField.stringValue = accessKey;
        // Load Qwen fields
        NSString *qwenApiKey = configGet(@"asr.qwen.api_key");
        self.asrQwenApiKeySecureField.stringValue = qwenApiKey;
        self.asrQwenApiKeyField.stringValue = qwenApiKey;
        // Reset visibility based on selected provider
        [self asrProviderChanged:self.asrProviderPopup];
        // Select current local model if applicable
        NSString *currentModel = nil;
        if ([provider isEqualToString:@"mlx"]) {
            currentModel = configGet(@"asr.mlx.model");
        } else if ([provider isEqualToString:@"sherpa-onnx"]) {
            currentModel = configGet(@"asr.sherpa-onnx.model");
        }
        if (currentModel.length > 0) {
            for (NSInteger i = 0; i < self.localModelPopup.numberOfItems; i++) {
                if ([[self.localModelPopup itemAtIndex:i].representedObject isEqualToString:currentModel]) {
                    [self.localModelPopup selectItemAtIndex:i];
                    break;
                }
            }
            [self updateModelStatusLabel];
        }
        // Clear test result when loading
        self.asrTestResultLabel.stringValue = @"";
        self.asrTestButton.enabled = YES;
    } else if ([identifier isEqualToString:kToolbarLLM]) {
        NSString *enabled = configGet(@"llm.enabled");
        self.llmEnabledCheckbox.state = ([enabled isEqualToString:@"false"]) ? NSControlStateValueOff : NSControlStateValueOn;
        NSString *baseUrl = configGet(@"llm.base_url");
        self.llmBaseUrlField.stringValue = baseUrl.length > 0 ? baseUrl : @"https://api.openai.com/v1";
        NSString *apiKey = configGet(@"llm.api_key");
        self.llmApiKeySecureField.stringValue = apiKey;
        self.llmApiKeyField.stringValue = apiKey;
        self.llmApiKeySecureField.hidden = NO;
        self.llmApiKeyField.hidden = YES;
        self.llmApiKeyToggle.image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:@"Show"];
        self.llmApiKeyToggle.tag = 0;
        NSString *model = configGet(@"llm.model");
        self.llmModelField.stringValue = model.length > 0 ? model : @"gpt-5.4-nano";
        // Max token parameter
        NSString *maxTokenParam = configGet(@"llm.max_token_parameter");
        if (maxTokenParam.length == 0) maxTokenParam = @"max_completion_tokens";
        for (NSInteger i = 0; i < self.maxTokenParamPopup.numberOfItems; i++) {
            if ([[self.maxTokenParamPopup itemAtIndex:i].representedObject isEqualToString:maxTokenParam]) {
                [self.maxTokenParamPopup selectItemAtIndex:i];
                break;
            }
        }
        self.llmTestResultLabel.stringValue = @"";
        [self updateLlmFieldsEnabled];
    } else if ([identifier isEqualToString:kToolbarHotkey]) {
        NSString *triggerKeyRaw = configGet(@"hotkey.trigger_key");
        NSString *cancelKeyRaw = configGet(@"hotkey.cancel_key");

        NSString *triggerKey = normalizedHotkeyValue(triggerKeyRaw);
        NSString *cancelKey = normalizedHotkeyValue(cancelKeyRaw);

        // Reset cancel key to default if it's empty or matches trigger key
        if (cancelKey.length == 0 || [cancelKey isEqualToString:triggerKey]) {
            cancelKey = defaultCancelKeyForTrigger(triggerKey);
        }

        if (isNumericKeycode(triggerKey)) {
            ensureCustomKeycodeInPopup(self.hotkeyPopup, triggerKey);
        } else {
            for (NSInteger i = 0; i < self.hotkeyPopup.numberOfItems; i++) {
                if ([[self.hotkeyPopup itemAtIndex:i].representedObject isEqualToString:triggerKey]) {
                    [self.hotkeyPopup selectItemAtIndex:i];
                    break;
                }
            }
        }
        if (isNumericKeycode(cancelKey)) {
            ensureCustomKeycodeInPopup(self.cancelHotkeyPopup, cancelKey);
        } else {
            for (NSInteger i = 0; i < self.cancelHotkeyPopup.numberOfItems; i++) {
                if ([[self.cancelHotkeyPopup itemAtIndex:i].representedObject isEqualToString:cancelKey]) {
                    [self.cancelHotkeyPopup selectItemAtIndex:i];
                    break;
                }
            }
        }

        NSString *startSound = configGet(@"feedback.start_sound");
        NSString *stopSound = configGet(@"feedback.stop_sound");
        NSString *errorSound = configGet(@"feedback.error_sound");
        self.startSoundCheckbox.state = [startSound isEqualToString:@"true"] ? NSControlStateValueOn : NSControlStateValueOff;
        self.stopSoundCheckbox.state = [stopSound isEqualToString:@"true"] ? NSControlStateValueOn : NSControlStateValueOff;
        self.errorSoundCheckbox.state = [errorSound isEqualToString:@"true"] ? NSControlStateValueOn : NSControlStateValueOff;
    } else if ([identifier isEqualToString:kToolbarDictionary]) {
        NSString *dictPath = [dir stringByAppendingPathComponent:kDictionaryFile];
        NSString *dictContent = [NSString stringWithContentsOfFile:dictPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
        [self.dictionaryTextView setString:dictContent];
    } else if ([identifier isEqualToString:kToolbarSystemPrompt]) {
        NSString *promptPath = [dir stringByAppendingPathComponent:kSystemPromptFile];
        NSString *promptContent = [NSString stringWithContentsOfFile:promptPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
        [self.systemPromptTextView setString:promptContent];
    }
}

- (void)saveConfig:(id)sender {
    // Warn if a local provider is selected but the model is not installed
    if (self.asrProviderPopup) {
        NSString *provider = self.asrProviderPopup.selectedItem.representedObject ?: @"doubao";
        BOOL isLocal = ![provider isEqualToString:@"doubao"] && ![provider isEqualToString:@"qwen"];
        if (isLocal) {
            NSString *modelPath = self.localModelPopup.selectedItem.representedObject;
            if (modelPath) {
                NSInteger status = [self.rustBridge modelStatus:modelPath mode:SPModelVerifyCacheOnly];
                if (status != 2) { // not installed
                    NSAlert *alert = [[NSAlert alloc] init];
                    alert.messageText = @"Model Not Installed";
                    alert.informativeText = @"The selected model has not been downloaded yet. ASR will not work until the model is installed.";
                    [alert addButtonWithTitle:@"Save Anyway"];
                    [alert addButtonWithTitle:@"Cancel"];
                    alert.alertStyle = NSAlertStyleWarning;
                    if ([alert runModal] != NSAlertFirstButtonReturn) {
                        return;
                    }
                }
            }
        }
    }

    NSString *dir = configDirPath();

    // Ensure directory exists
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    // Track whether any config write fails
    BOOL saveOk = YES;

    // Update ASR fields (always save — fields may be nil if pane not visited, check first)
    if (self.asrAppKeyField) {
        NSString *selectedProvider = self.asrProviderPopup.selectedItem.representedObject ?: @"doubao";
        saveOk &= configSet(@"asr.provider", selectedProvider);
        // Save Doubao fields
        saveOk &= configSet(@"asr.doubao.app_key", self.asrAppKeyField.stringValue);
        NSString *accessKey = self.asrAccessKeyToggle.tag == 1 ? self.asrAccessKeyField.stringValue : self.asrAccessKeySecureField.stringValue;
        saveOk &= configSet(@"asr.doubao.access_key", accessKey);
        // Save Qwen fields
        NSString *qwenApiKey = self.asrQwenApiKeyToggle.tag == 1 ? self.asrQwenApiKeyField.stringValue : self.asrQwenApiKeySecureField.stringValue;
        saveOk &= configSet(@"asr.qwen.api_key", qwenApiKey);
        // Save local model selection
        if ([selectedProvider isEqualToString:@"mlx"]) {
            NSString *modelPath = self.localModelPopup.selectedItem.representedObject;
            if (modelPath) saveOk &= configSet(@"asr.mlx.model", modelPath);
        } else if ([selectedProvider isEqualToString:@"sherpa-onnx"]) {
            NSString *modelPath = self.localModelPopup.selectedItem.representedObject;
            if (modelPath) saveOk &= configSet(@"asr.sherpa-onnx.model", modelPath);
        }
    }

    // Update LLM fields
    if (self.llmEnabledCheckbox) {
        NSString *enabledStr = (self.llmEnabledCheckbox.state == NSControlStateValueOn) ? @"true" : @"false";
        saveOk &= configSet(@"llm.enabled", enabledStr);
        saveOk &= configSet(@"llm.base_url", self.llmBaseUrlField.stringValue);
        NSString *llmApiKey = self.llmApiKeyToggle.tag == 1 ? self.llmApiKeyField.stringValue : self.llmApiKeySecureField.stringValue;
        saveOk &= configSet(@"llm.api_key", llmApiKey);
        saveOk &= configSet(@"llm.model", self.llmModelField.stringValue);
        NSString *selectedTokenParam = self.maxTokenParamPopup.selectedItem.representedObject ?: @"max_completion_tokens";
        saveOk &= configSet(@"llm.max_token_parameter", selectedTokenParam);
    }

    // Update hotkey
    if (self.hotkeyPopup) {
        NSString *selectedTriggerHotkey = self.hotkeyPopup.selectedItem.representedObject ?: @"fn";
        NSString *selectedCancelHotkey = self.cancelHotkeyPopup.selectedItem.representedObject ?: defaultCancelKeyForTrigger(selectedTriggerHotkey);
        if ([selectedTriggerHotkey isEqualToString:selectedCancelHotkey]) {
            [self showAlert:@"Trigger and Cancel keys must be different"
                       info:@"Choose two different keys for starting and cancelling voice input."];
            return;
        }
        saveOk &= configSet(@"hotkey.trigger_key", selectedTriggerHotkey);
        saveOk &= configSet(@"hotkey.cancel_key", selectedCancelHotkey);
    }
    if (self.startSoundCheckbox) {
        NSString *startSound = (self.startSoundCheckbox.state == NSControlStateValueOn) ? @"true" : @"false";
        NSString *stopSound = (self.stopSoundCheckbox.state == NSControlStateValueOn) ? @"true" : @"false";
        NSString *errorSound = (self.errorSoundCheckbox.state == NSControlStateValueOn) ? @"true" : @"false";
        saveOk &= configSet(@"feedback.start_sound", startSound);
        saveOk &= configSet(@"feedback.stop_sound", stopSound);
        saveOk &= configSet(@"feedback.error_sound", errorSound);
    }

    if (!saveOk) {
        [self showAlert:@"Some settings failed to save"
                   info:@"Check that ~/.koe/config.yaml is writable and try again."];
    }

    // Write dictionary.txt
    NSError *error = nil;
    if (self.dictionaryTextView) {
        NSString *dictPath = [dir stringByAppendingPathComponent:kDictionaryFile];
        [self.dictionaryTextView.string writeToFile:dictPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (error) {
            NSLog(@"[Koe] Failed to write dictionary.txt: %@", error.localizedDescription);
            [self showAlert:@"Failed to save dictionary.txt" info:error.localizedDescription];
            return;
        }
    }

    // Write system_prompt.txt
    if (self.systemPromptTextView) {
        NSString *promptPath = [dir stringByAppendingPathComponent:kSystemPromptFile];
        [self.systemPromptTextView.string writeToFile:promptPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (error) {
            NSLog(@"[Koe] Failed to write system_prompt.txt: %@", error.localizedDescription);
            [self showAlert:@"Failed to save system_prompt.txt" info:error.localizedDescription];
            return;
        }
    }

    NSLog(@"[Koe] Settings saved");

    // Notify delegate to reload
    if ([self.delegate respondsToSelector:@selector(setupWizardDidSaveConfig)]) {
        [self.delegate setupWizardDidSaveConfig];
    }

    [self.window close];
}

- (void)cancelSetup:(id)sender {
    [self.window close];
}

- (void)llmEnabledToggled:(id)sender {
    [self updateLlmFieldsEnabled];
}

- (void)updateLlmFieldsEnabled {
    BOOL enabled = (self.llmEnabledCheckbox.state == NSControlStateValueOn);
    self.llmBaseUrlField.enabled = enabled;
    self.llmApiKeyField.enabled = enabled;
    self.llmModelField.enabled = enabled;
    self.maxTokenParamPopup.enabled = enabled;
    self.llmTestButton.enabled = enabled;
}

- (void)testLlmConnection:(id)sender {
    NSString *baseUrl = self.llmBaseUrlField.stringValue;
    NSString *apiKey = self.llmApiKeyToggle.tag == 1 ? self.llmApiKeyField.stringValue : self.llmApiKeySecureField.stringValue;
    NSString *model = self.llmModelField.stringValue;

    if (baseUrl.length == 0 || apiKey.length == 0 || model.length == 0) {
        self.llmTestResultLabel.stringValue = @"Please fill in all fields first.";
        self.llmTestResultLabel.textColor = [NSColor systemOrangeColor];
        return;
    }

    self.llmTestButton.enabled = NO;
    self.llmTestResultLabel.stringValue = @"Testing...";
    self.llmTestResultLabel.textColor = [NSColor secondaryLabelColor];

    NSString *endpoint = [baseUrl stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    endpoint = [endpoint stringByAppendingString:@"/chat/completions"];
    NSURL *url = [NSURL URLWithString:endpoint];
    if (!url) {
        self.llmTestResultLabel.stringValue = @"Invalid Base URL.";
        self.llmTestResultLabel.textColor = [NSColor systemRedColor];
        self.llmTestButton.enabled = YES;
        return;
    }

    NSString *tokenParam = self.maxTokenParamPopup.selectedItem.representedObject ?: @"max_completion_tokens";
    NSMutableDictionary *body = [@{
        @"model": model,
        @"messages": @[@{@"role": @"user", @"content": @"Hi"}],
        tokenParam: @(10),
    } mutableCopy];
    // Match runtime behavior: send reasoning_effort when using max_completion_tokens
    if ([tokenParam isEqualToString:@"max_completion_tokens"]) {
        body[@"reasoning_effort"] = @"none";
    }
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = jsonData;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    request.timeoutInterval = 15;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.llmTestButton.enabled = (self.llmEnabledCheckbox.state == NSControlStateValueOn);

            if (error) {
                self.llmTestResultLabel.stringValue = error.localizedDescription;
                self.llmTestResultLabel.textColor = [NSColor systemRedColor];
                return;
            }

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if (httpResponse.statusCode >= 200 && httpResponse.statusCode < 300) {
                self.llmTestResultLabel.stringValue = @"Connection successful!";
                self.llmTestResultLabel.textColor = [NSColor systemGreenColor];
            } else {
                NSString *errMsg = nil;
                if (data) {
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if ([json isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *errObj = json[@"error"];
                        if ([errObj isKindOfClass:[NSDictionary class]]) {
                            errMsg = errObj[@"message"];
                        }
                    }
                }
                NSString *bodyStr = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
                self.llmTestResultLabel.stringValue = [NSString stringWithFormat:@"HTTP %ld: %@",
                    (long)httpResponse.statusCode,
                    errMsg ?: bodyStr ?: @"Unknown error"];
                self.llmTestResultLabel.textColor = [NSColor systemRedColor];
            }
        });
    }];
    [task resume];
}

// ─── ASR Test Connection ────────────────────────────────────────────

- (void)testAsrConnection:(id)sender {
    NSString *provider = self.asrProviderPopup.selectedItem.representedObject ?: @"doubao";
    if ([provider isEqualToString:@"doubao"]) {
        [self testDoubaoConnection];
    } else if ([provider isEqualToString:@"qwen"]) {
        [self testQwenConnection];
    }
}

- (void)testDoubaoConnection {
    // Get current key values (account for plain/secure toggle state)
    NSString *appKey = self.asrAppKeyField.stringValue;
    NSString *accessKey = self.asrAccessKeyToggle.tag == 1 ? self.asrAccessKeyField.stringValue : self.asrAccessKeySecureField.stringValue;

    if (appKey.length == 0 || accessKey.length == 0) {
        self.asrTestResultLabel.stringValue = @"请先填写 App Key 和 Access Key";
        self.asrTestResultLabel.textColor = [NSColor systemOrangeColor];
        return;
    }

    self.asrTestButton.enabled = NO;
    self.asrTestResultLabel.stringValue = @"测试中...";
    self.asrTestResultLabel.textColor = [NSColor secondaryLabelColor];

    // Create WebSocket connection test
    NSURL *url = [NSURL URLWithString:@"wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 5;

    // Set Doubao auth headers
    [request setValue:appKey forHTTPHeaderField:@"X-Api-App-Key"];
    [request setValue:accessKey forHTTPHeaderField:@"X-Api-Access-Key"];
    [request setValue:@"volc.seedasr.sauc.duration" forHTTPHeaderField:@"X-Api-Resource-Id"];
    [request setValue:[[NSUUID UUID] UUIDString] forHTTPHeaderField:@"X-Api-Connect-Id"];

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 5;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSURLSessionWebSocketTask *wsTask = [session webSocketTaskWithRequest:request];

    __weak typeof(self) weakSelf = self;
    __block BOOL hasCompleted = NO;

    // Try to receive a message (Doubao may not send one immediately)
    [wsTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (hasCompleted) return;
            hasCompleted = YES;

            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            [wsTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
            strongSelf.asrTestButton.enabled = YES;

            if (error) {
                NSString *errorMsg = error.localizedDescription;

                // Check userInfo for HTTP status code
                NSHTTPURLResponse *response = error.userInfo[@"NSURLSessionDownloadTaskResumeData"];
                NSInteger statusCode = 0;
                if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                    statusCode = response.statusCode;
                }

                if ([errorMsg containsString:@"401"] || [errorMsg containsString:@"403"] ||
                    [error.localizedFailureReason containsString:@"401"] || statusCode == 401) {
                    strongSelf.asrTestResultLabel.stringValue = @"认证失败：请检查 App Key 和 Access Key 是否正确";
                } else if ([errorMsg containsString:@"time"] || error.code == NSURLErrorTimedOut) {
                    strongSelf.asrTestResultLabel.stringValue = @"连接超时：请检查网络连接";
                } else if ([errorMsg containsString:@"bad response"] ||
                           [errorMsg containsString:@"Bad response"] ||
                           statusCode == 400 || statusCode == 403) {
                    // HTTP error during WebSocket handshake (e.g. 400 Bad Request)
                    strongSelf.asrTestResultLabel.stringValue = @"认证失败：请检查 App Key 和 Access Key 是否正确";
                } else if ([errorMsg containsString:@"unable"] ||
                           [errorMsg containsString:@"Unable"] ||
                           [errorMsg containsString:@"Cannot connect"] ||
                           [errorMsg containsString:@"Network"]) {
                    strongSelf.asrTestResultLabel.stringValue = @"网络连接失败：请检查网络设置";
                } else {
                    strongSelf.asrTestResultLabel.stringValue = @"连接失败：请检查配置信息是否正确";
                }
                strongSelf.asrTestResultLabel.textColor = [NSColor systemRedColor];
                return;
            }

            strongSelf.asrTestResultLabel.stringValue = @"连接成功";
            strongSelf.asrTestResultLabel.textColor = [NSColor systemGreenColor];
        });
    }];

    [wsTask resume];

    // Doubao may not send a message immediately; treat no error within 2s as success
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (hasCompleted) return;
        hasCompleted = YES;

        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        [wsTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];

        if (!strongSelf.asrTestButton.enabled) {
            strongSelf.asrTestButton.enabled = YES;
            strongSelf.asrTestResultLabel.stringValue = @"连接成功";
            strongSelf.asrTestResultLabel.textColor = [NSColor systemGreenColor];
        }
    });

    // Fallback timeout
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (hasCompleted) return;
        hasCompleted = YES;

        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        [wsTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
        strongSelf.asrTestButton.enabled = YES;
        strongSelf.asrTestResultLabel.stringValue = @"连接超时：请检查网络连接";
        strongSelf.asrTestResultLabel.textColor = [NSColor systemRedColor];
    });
}

- (void)testQwenConnection {
    // Get current key value (account for plain/secure toggle state)
    NSString *apiKey = self.asrQwenApiKeyToggle.tag == 1 ? self.asrQwenApiKeyField.stringValue : self.asrQwenApiKeySecureField.stringValue;

    if (apiKey.length == 0) {
        self.asrTestResultLabel.stringValue = @"请先填写 API Key";
        self.asrTestResultLabel.textColor = [NSColor systemOrangeColor];
        return;
    }

    self.asrTestButton.enabled = NO;
    self.asrTestResultLabel.stringValue = @"测试中...";
    self.asrTestResultLabel.textColor = [NSColor secondaryLabelColor];

    // Create WebSocket connection test
    NSURL *url = [NSURL URLWithString:@"wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 10;

    // Set Qwen DashScope auth header
    [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];

    NSURLSessionConfiguration *config2 = [NSURLSessionConfiguration defaultSessionConfiguration];
    config2.timeoutIntervalForRequest = 10;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config2];
    NSURLSessionWebSocketTask *wsTask = [session webSocketTaskWithRequest:request];

    __weak typeof(self) weakSelf = self;
    __weak NSURLSessionWebSocketTask *weakWsTask = wsTask;

    // Qwen DashScope returns a session.created message on connect
    [wsTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            [weakWsTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];

            strongSelf.asrTestButton.enabled = YES;

            if (error) {
                NSString *errorMsg = error.localizedDescription;
                NSInteger statusCode = 0;

                // Try to extract HTTP status code from error
                if (error.userInfo[@"_kCFStreamErrorDomainKey"]) {
                    NSNumber *code = error.userInfo[@"_kCFStreamErrorDomainKey"];
                    if (code) statusCode = code.integerValue;
                }

                if ([errorMsg containsString:@"401"] || [errorMsg containsString:@"403"] ||
                    statusCode == 401) {
                    strongSelf.asrTestResultLabel.stringValue = @"认证失败：请检查 API Key 是否正确";
                } else if ([errorMsg containsString:@"time"] || error.code == NSURLErrorTimedOut) {
                    strongSelf.asrTestResultLabel.stringValue = @"连接超时：请检查网络连接";
                } else if ([errorMsg containsString:@"bad response"] ||
                           [errorMsg containsString:@"Bad response"]) {
                    // HTTP error during WebSocket handshake
                    strongSelf.asrTestResultLabel.stringValue = @"认证失败：请检查 API Key 是否正确";
                } else if ([errorMsg containsString:@"unable"] ||
                           [errorMsg containsString:@"Unable"] ||
                           [errorMsg containsString:@"Cannot connect"]) {
                    strongSelf.asrTestResultLabel.stringValue = @"网络连接失败：请检查网络设置";
                } else {
                    strongSelf.asrTestResultLabel.stringValue = @"连接失败：请检查配置信息是否正确";
                }
                strongSelf.asrTestResultLabel.textColor = [NSColor systemRedColor];
                return;
            }

            if (message) {
                strongSelf.asrTestResultLabel.stringValue = @"连接成功";
                strongSelf.asrTestResultLabel.textColor = [NSColor systemGreenColor];
            } else {
                strongSelf.asrTestResultLabel.stringValue = @"连接失败：未收到服务器响应";
                strongSelf.asrTestResultLabel.textColor = [NSColor systemRedColor];
            }
        });
    }];

    [wsTask resume];

    // Timeout handler
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.asrTestButton.enabled) return;

        [wsTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
        strongSelf.asrTestButton.enabled = YES;
        strongSelf.asrTestResultLabel.stringValue = @"连接超时：请检查网络连接";
        strongSelf.asrTestResultLabel.textColor = [NSColor systemRedColor];
    });
}

- (void)showAlert:(NSString *)message info:(NSString *)info {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = info ?: @"";
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

@end
