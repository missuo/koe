#import "SPSetupWizardWindowController.h"
#import <Cocoa/Cocoa.h>

static NSString *const kConfigDir = @".koe";
static NSString *const kConfigFile = @"config.yaml";
static NSString *const kDictionaryFile = @"dictionary.txt";
static NSString *const kSystemPromptFile = @"system_prompt.txt";

// Toolbar item identifiers
static NSToolbarItemIdentifier const kToolbarASR = @"asr";
static NSToolbarItemIdentifier const kToolbarLLM = @"llm";
static NSToolbarItemIdentifier const kToolbarHotkey = @"hotkey";
static NSToolbarItemIdentifier const kToolbarDictionary = @"dictionary";
static NSToolbarItemIdentifier const kToolbarSystemPrompt = @"system_prompt";

// ─── YAML helpers (minimal, line-based) ─────────────────────────────
// We still avoid pulling in a YAML library, but the config is now nested
// enough that reads need to handle arbitrary key paths. Saves are done by
// regenerating the full config.yaml in the current v2 schema.

static NSString *configDirPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:kConfigDir];
}

static NSString *configFilePath(void) {
    return [configDirPath() stringByAppendingPathComponent:kConfigFile];
}

static NSInteger yamlIndentLevel(NSString *line) {
    NSInteger count = 0;
    while (count < (NSInteger)line.length && [line characterAtIndex:count] == ' ') {
        count += 1;
    }
    return count / 2;
}

static NSString *yamlUnquoteScalar(NSString *value) {
    if (value.length < 2) {
        return value ?: @"";
    }

    unichar first = [value characterAtIndex:0];
    unichar last = [value characterAtIndex:value.length - 1];
    if (first == '"' && last == '"') {
        NSString *inner = [value substringWithRange:NSMakeRange(1, value.length - 2)];
        inner = [inner stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"];
        inner = [inner stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\""];
        inner = [inner stringByReplacingOccurrencesOfString:@"\\\\" withString:@"\\"];
        return inner;
    }

    if (first == '\'' && last == '\'') {
        NSString *inner = [value substringWithRange:NSMakeRange(1, value.length - 2)];
        return [inner stringByReplacingOccurrencesOfString:@"''" withString:@"'"];
    }

    return value;
}

/// Read a nested YAML scalar value. `keyPath` e.g. @"asr.openai.api_key".
static NSString *yamlRead(NSString *yaml, NSString *keyPath) {
    NSArray<NSString *> *lines = [yaml componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString *> *pathStack = [NSMutableArray array];

    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0 || [trimmed hasPrefix:@"#"]) continue;

        NSInteger depth = yamlIndentLevel(line);
        while ((NSInteger)pathStack.count > depth) {
            [pathStack removeLastObject];
        }

        if ([trimmed hasSuffix:@":"] && [trimmed rangeOfString:@": "].location == NSNotFound) {
            NSString *section = [[trimmed substringToIndex:trimmed.length - 1]
                                 stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            [pathStack addObject:section];
            continue;
        }

        NSRange colon = [trimmed rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;

        NSString *key = [[trimmed substringToIndex:colon.location]
                         stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *value = [trimmed substringFromIndex:colon.location + 1];
        value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        NSMutableArray<NSString *> *fullPath = [pathStack mutableCopy];
        [fullPath addObject:key];
        if ([[fullPath componentsJoinedByString:@"."] isEqualToString:keyPath]) {
            value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([value hasPrefix:@"\""] || [value hasPrefix:@"'"]) {
                NSString *quote = [value substringToIndex:1];
                NSRange closeQuote = [value rangeOfString:quote options:NSBackwardsSearch];
                if (closeQuote.location != NSNotFound && closeQuote.location > 0) {
                    value = [value substringToIndex:closeQuote.location + 1];
                }
            } else {
                NSRange commentRange = [value rangeOfString:@" #"];
                if (commentRange.location != NSNotFound) {
                    value = [[value substringToIndex:commentRange.location]
                             stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                }
            }
            return yamlUnquoteScalar(value ?: @"");
        }
    }
    return @"";
}

static NSString *yamlValueOrDefault(NSString *yaml, NSString *keyPath, NSString *fallback) {
    NSString *value = yamlRead(yaml, keyPath);
    return value.length > 0 ? value : fallback;
}

static NSString *yamlQuotedString(NSString *value) {
    NSString *safe = value ?: @"";
    safe = [safe stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    safe = [safe stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    safe = [safe stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    return [NSString stringWithFormat:@"\"%@\"", safe];
}

// ─── Window Controller ──────────────────────────────────────────────

@interface SPSetupWizardWindowController () <NSToolbarDelegate>

// Current pane
@property (nonatomic, copy) NSString *currentPaneIdentifier;
@property (nonatomic, strong) NSView *currentPaneView;

// ASR fields
@property (nonatomic, strong) NSPopUpButton *asrProviderPopup;
@property (nonatomic, strong) NSTextField *asrDescriptionLabel;
@property (nonatomic, strong) NSTextField *asrAppKeyField;
@property (nonatomic, strong) NSTextField *asrAccessKeyField;
@property (nonatomic, strong) NSSecureTextField *asrAccessKeySecureField;
@property (nonatomic, strong) NSButton *asrAccessKeyToggle;
@property (nonatomic, strong) NSTextField *asrOpenAIBaseUrlField;
@property (nonatomic, strong) NSTextField *asrOpenAIApiKeyField;
@property (nonatomic, strong) NSSecureTextField *asrOpenAIApiKeySecureField;
@property (nonatomic, strong) NSButton *asrOpenAIApiKeyToggle;
@property (nonatomic, strong) NSPopUpButton *asrOpenAIModelPopup;
@property (nonatomic, strong) NSTextField *asrQwenBaseUrlField;
@property (nonatomic, strong) NSTextField *asrQwenApiKeyField;
@property (nonatomic, strong) NSSecureTextField *asrQwenApiKeySecureField;
@property (nonatomic, strong) NSButton *asrQwenApiKeyToggle;
@property (nonatomic, strong) NSPopUpButton *asrQwenModelPopup;
@property (nonatomic, strong) NSArray<NSView *> *asrDoubaoViews;
@property (nonatomic, strong) NSArray<NSView *> *asrOpenAIViews;
@property (nonatomic, strong) NSArray<NSView *> *asrQwenViews;

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
@property (nonatomic, strong) NSButton *startSoundCheckbox;
@property (nonatomic, strong) NSButton *stopSoundCheckbox;
@property (nonatomic, strong) NSButton *errorSoundCheckbox;

// Dictionary
@property (nonatomic, strong) NSTextView *dictionaryTextView;

// System Prompt
@property (nonatomic, strong) NSTextView *systemPromptTextView;

@end

@implementation SPSetupWizardWindowController

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
        [self setupToolbar];
        [self switchToPane:kToolbarASR];
        [self loadCurrentValues];
    }
    return self;
}

- (void)showWindow:(id)sender {
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

    CGFloat contentHeight = 380;
    NSView *pane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];

    CGFloat y = contentHeight - 48;

    self.asrDescriptionLabel = [self descriptionLabel:@""];
    self.asrDescriptionLabel.frame = NSMakeRect(24, y - 10, paneWidth - 48, 36);
    [pane addSubview:self.asrDescriptionLabel];
    y -= 52;

    [pane addSubview:[self formLabel:@"Provider" frame:NSMakeRect(16, y, labelW, 22)]];
    self.asrProviderPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX, y - 2, 220, 26) pullsDown:NO];
    [self.asrProviderPopup addItemsWithTitles:@[@"Doubao", @"OpenAI", @"Qwen"]];
    [self.asrProviderPopup itemAtIndex:0].representedObject = @"doubao";
    [self.asrProviderPopup itemAtIndex:1].representedObject = @"openai";
    [self.asrProviderPopup itemAtIndex:2].representedObject = @"qwen";
    self.asrProviderPopup.target = self;
    self.asrProviderPopup.action = @selector(asrProviderChanged:);
    [pane addSubview:self.asrProviderPopup];
    y -= rowH;

    CGFloat providerRow1Y = y;
    CGFloat providerRow2Y = y - rowH;
    CGFloat providerRow3Y = y - rowH * 2;

    NSTextField *doubaoAppKeyLabel = [self formLabel:@"App Key" frame:NSMakeRect(16, providerRow1Y, labelW, 22)];
    [pane addSubview:doubaoAppKeyLabel];
    self.asrAppKeyField = [self formTextField:NSMakeRect(fieldX, providerRow1Y, fieldW, 22) placeholder:@"Volcengine App ID"];
    [pane addSubview:self.asrAppKeyField];

    CGFloat eyeW = 28;
    CGFloat secFieldW = fieldW - eyeW - 4;
    NSTextField *doubaoAccessKeyLabel = [self formLabel:@"Access Key" frame:NSMakeRect(16, providerRow2Y, labelW, 22)];
    [pane addSubview:doubaoAccessKeyLabel];
    self.asrAccessKeySecureField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(fieldX, providerRow2Y, secFieldW, 22)];
    self.asrAccessKeySecureField.placeholderString = @"Volcengine Access Token";
    self.asrAccessKeySecureField.font = [NSFont systemFontOfSize:13];
    [pane addSubview:self.asrAccessKeySecureField];
    self.asrAccessKeyField = [self formTextField:NSMakeRect(fieldX, providerRow2Y, secFieldW, 22) placeholder:@"Volcengine Access Token"];
    self.asrAccessKeyField.hidden = YES;
    [pane addSubview:self.asrAccessKeyField];
    self.asrAccessKeyToggle = [self eyeButtonWithFrame:NSMakeRect(fieldX + secFieldW + 4, providerRow2Y - 1, eyeW, 24)
                                                action:@selector(toggleAsrAccessKeyVisibility:)];
    [pane addSubview:self.asrAccessKeyToggle];

    NSTextField *openaiBaseUrlLabel = [self formLabel:@"Base URL" frame:NSMakeRect(16, providerRow1Y, labelW, 22)];
    [pane addSubview:openaiBaseUrlLabel];
    self.asrOpenAIBaseUrlField = [self formTextField:NSMakeRect(fieldX, providerRow1Y, fieldW, 22) placeholder:@"https://api.openai.com/v1"];
    [pane addSubview:self.asrOpenAIBaseUrlField];

    NSTextField *openaiApiKeyLabel = [self formLabel:@"API Key" frame:NSMakeRect(16, providerRow2Y, labelW, 22)];
    [pane addSubview:openaiApiKeyLabel];
    self.asrOpenAIApiKeySecureField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(fieldX, providerRow2Y, secFieldW, 22)];
    self.asrOpenAIApiKeySecureField.placeholderString = @"sk-...";
    self.asrOpenAIApiKeySecureField.font = [NSFont systemFontOfSize:13];
    [pane addSubview:self.asrOpenAIApiKeySecureField];
    self.asrOpenAIApiKeyField = [self formTextField:NSMakeRect(fieldX, providerRow2Y, secFieldW, 22) placeholder:@"sk-..."];
    self.asrOpenAIApiKeyField.hidden = YES;
    [pane addSubview:self.asrOpenAIApiKeyField];
    self.asrOpenAIApiKeyToggle = [self eyeButtonWithFrame:NSMakeRect(fieldX + secFieldW + 4, providerRow2Y - 1, eyeW, 24)
                                                   action:@selector(toggleAsrOpenAIApiKeyVisibility:)];
    [pane addSubview:self.asrOpenAIApiKeyToggle];

    NSTextField *openaiModelLabel = [self formLabel:@"Model" frame:NSMakeRect(16, providerRow3Y, labelW, 22)];
    [pane addSubview:openaiModelLabel];
    self.asrOpenAIModelPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX, providerRow3Y - 2, 240, 26) pullsDown:NO];
    [self.asrOpenAIModelPopup addItemsWithTitles:@[
        @"gpt-4o-transcribe",
        @"gpt-4o-mini-transcribe",
    ]];
    [self.asrOpenAIModelPopup itemAtIndex:0].representedObject = @"gpt-4o-transcribe";
    [self.asrOpenAIModelPopup itemAtIndex:1].representedObject = @"gpt-4o-mini-transcribe";
    [self.asrOpenAIModelPopup selectItemAtIndex:0];
    [pane addSubview:self.asrOpenAIModelPopup];

    NSTextField *qwenBaseUrlLabel = [self formLabel:@"Base URL" frame:NSMakeRect(16, providerRow1Y, labelW, 22)];
    [pane addSubview:qwenBaseUrlLabel];
    self.asrQwenBaseUrlField = [self formTextField:NSMakeRect(fieldX, providerRow1Y, fieldW, 22) placeholder:@"wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime"];
    [pane addSubview:self.asrQwenBaseUrlField];

    NSTextField *qwenApiKeyLabel = [self formLabel:@"API Key" frame:NSMakeRect(16, providerRow2Y, labelW, 22)];
    [pane addSubview:qwenApiKeyLabel];
    self.asrQwenApiKeySecureField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(fieldX, providerRow2Y, secFieldW, 22)];
    self.asrQwenApiKeySecureField.placeholderString = @"sk-...";
    self.asrQwenApiKeySecureField.font = [NSFont systemFontOfSize:13];
    [pane addSubview:self.asrQwenApiKeySecureField];
    self.asrQwenApiKeyField = [self formTextField:NSMakeRect(fieldX, providerRow2Y, secFieldW, 22) placeholder:@"sk-..."];
    self.asrQwenApiKeyField.hidden = YES;
    [pane addSubview:self.asrQwenApiKeyField];
    self.asrQwenApiKeyToggle = [self eyeButtonWithFrame:NSMakeRect(fieldX + secFieldW + 4, providerRow2Y - 1, eyeW, 24)
                                                 action:@selector(toggleAsrQwenApiKeyVisibility:)];
    [pane addSubview:self.asrQwenApiKeyToggle];

    NSTextField *qwenModelLabel = [self formLabel:@"Model" frame:NSMakeRect(16, providerRow3Y, labelW, 22)];
    [pane addSubview:qwenModelLabel];
    self.asrQwenModelPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX, providerRow3Y - 2, 260, 26) pullsDown:NO];
    [self.asrQwenModelPopup addItemsWithTitles:@[
        @"qwen3-asr-flash-realtime",
    ]];
    [self.asrQwenModelPopup itemAtIndex:0].representedObject = @"qwen3-asr-flash-realtime";
    [self.asrQwenModelPopup selectItemAtIndex:0];
    [pane addSubview:self.asrQwenModelPopup];
    y = providerRow3Y - rowH - 16;

    self.asrDoubaoViews = @[
        doubaoAppKeyLabel,
        self.asrAppKeyField,
        doubaoAccessKeyLabel,
        self.asrAccessKeySecureField,
        self.asrAccessKeyField,
        self.asrAccessKeyToggle,
    ];
    self.asrOpenAIViews = @[
        openaiBaseUrlLabel,
        self.asrOpenAIBaseUrlField,
        openaiApiKeyLabel,
        self.asrOpenAIApiKeySecureField,
        self.asrOpenAIApiKeyField,
        self.asrOpenAIApiKeyToggle,
        openaiModelLabel,
        self.asrOpenAIModelPopup,
    ];
    self.asrQwenViews = @[
        qwenBaseUrlLabel,
        self.asrQwenBaseUrlField,
        qwenApiKeyLabel,
        self.asrQwenApiKeySecureField,
        self.asrQwenApiKeyField,
        self.asrQwenApiKeyToggle,
        qwenModelLabel,
        self.asrQwenModelPopup,
    ];

    [self addButtonsToPane:pane atY:y width:paneWidth];
    [self updateAsrProviderControls];

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
    y -= 36;

    // Hint text
    NSTextField *tokenHint = [self descriptionLabel:@"GPT-4o and older models use max_tokens. GPT-5 and reasoning models (o1/o3) use max_completion_tokens."];
    tokenHint.frame = NSMakeRect(fieldX, y, fieldW, 32);
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

    CGFloat contentHeight = 320;
    NSView *pane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];

    CGFloat y = contentHeight - 48;

    // Description
    NSTextField *desc = [self descriptionLabel:@"Choose which key triggers voice input. Hold to record or double-press to toggle."];
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
    ]];
    [self.hotkeyPopup itemAtIndex:0].representedObject = @"fn";
    [self.hotkeyPopup itemAtIndex:1].representedObject = @"left_option";
    [self.hotkeyPopup itemAtIndex:2].representedObject = @"right_option";
    [self.hotkeyPopup itemAtIndex:3].representedObject = @"left_command";
    [self.hotkeyPopup itemAtIndex:4].representedObject = @"right_command";
    [pane addSubview:self.hotkeyPopup];
    y -= rowH + 16;

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
    feedbackHint.frame = NSMakeRect(fieldX, y - 6, paneWidth - fieldX - 32, 32);
    [pane addSubview:feedbackHint];
    y -= 44;

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

- (void)toggleAsrOpenAIApiKeyVisibility:(NSButton *)sender {
    if (sender.tag == 0) {
        self.asrOpenAIApiKeyField.stringValue = self.asrOpenAIApiKeySecureField.stringValue;
        self.asrOpenAIApiKeySecureField.hidden = YES;
        self.asrOpenAIApiKeyField.hidden = NO;
        sender.image = [NSImage imageWithSystemSymbolName:@"eye" accessibilityDescription:@"Hide"];
        sender.tag = 1;
    } else {
        self.asrOpenAIApiKeySecureField.stringValue = self.asrOpenAIApiKeyField.stringValue;
        self.asrOpenAIApiKeyField.hidden = YES;
        self.asrOpenAIApiKeySecureField.hidden = NO;
        sender.image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:@"Show"];
        sender.tag = 0;
    }
}

- (void)toggleAsrQwenApiKeyVisibility:(NSButton *)sender {
    if (sender.tag == 0) {
        self.asrQwenApiKeyField.stringValue = self.asrQwenApiKeySecureField.stringValue;
        self.asrQwenApiKeySecureField.hidden = YES;
        self.asrQwenApiKeyField.hidden = NO;
        sender.image = [NSImage imageWithSystemSymbolName:@"eye" accessibilityDescription:@"Hide"];
        sender.tag = 1;
    } else {
        self.asrQwenApiKeySecureField.stringValue = self.asrQwenApiKeyField.stringValue;
        self.asrQwenApiKeyField.hidden = YES;
        self.asrQwenApiKeySecureField.hidden = NO;
        sender.image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:@"Show"];
        sender.tag = 0;
    }
}

- (void)asrProviderChanged:(id)sender {
    [self updateAsrProviderControls];
}

- (void)updateAsrProviderControls {
    NSString *provider = self.asrProviderPopup.selectedItem.representedObject ?: @"doubao";
    BOOL isOpenAI = [provider isEqualToString:@"openai"];
    BOOL isQwen = [provider isEqualToString:@"qwen"];

    for (NSView *view in self.asrDoubaoViews) {
        view.hidden = isOpenAI || isQwen;
    }
    for (NSView *view in self.asrOpenAIViews) {
        view.hidden = !isOpenAI;
    }
    for (NSView *view in self.asrQwenViews) {
        view.hidden = !isQwen;
    }

    if (isOpenAI) {
        self.asrDescriptionLabel.stringValue = @"Configure OpenAI Realtime transcription. This provider uses gpt-4o-transcribe or gpt-4o-mini-transcribe over WebSocket.";
    } else if (isQwen) {
        self.asrDescriptionLabel.stringValue = @"Configure Qwen-ASR-Realtime from Alibaba Cloud Model Studio. This provider uses a realtime WebSocket session with manual commit mode.";
    } else {
        self.asrDescriptionLabel.stringValue = @"Configure the Doubao Streaming ASR service. You need credentials from the Volcengine console.";
    }
}

// ─── Load / Save ────────────────────────────────────────────────────

- (void)loadCurrentValues {
    [self loadValuesForPane:self.currentPaneIdentifier];
}

- (void)loadValuesForPane:(NSString *)identifier {
    NSString *dir = configDirPath();
    NSString *configPath = configFilePath();
    NSString *yaml = [NSString stringWithContentsOfFile:configPath encoding:NSUTF8StringEncoding error:nil] ?: @"";

    if ([identifier isEqualToString:kToolbarASR]) {
        NSString *provider = yamlValueOrDefault(yaml, @"asr.provider", @"doubao");
        for (NSInteger i = 0; i < self.asrProviderPopup.numberOfItems; i++) {
            if ([[self.asrProviderPopup itemAtIndex:i].representedObject isEqualToString:provider]) {
                [self.asrProviderPopup selectItemAtIndex:i];
                break;
            }
        }

        self.asrAppKeyField.stringValue = yamlValueOrDefault(yaml, @"asr.doubao.app_key", yamlRead(yaml, @"asr.app_key"));
        NSString *accessKey = yamlValueOrDefault(yaml, @"asr.doubao.access_key", yamlRead(yaml, @"asr.access_key"));
        self.asrAccessKeySecureField.stringValue = accessKey;
        self.asrAccessKeyField.stringValue = accessKey;
        self.asrAccessKeySecureField.hidden = NO;
        self.asrAccessKeyField.hidden = YES;
        self.asrAccessKeyToggle.image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:@"Show"];
        self.asrAccessKeyToggle.tag = 0;

        self.asrOpenAIBaseUrlField.stringValue = yamlValueOrDefault(yaml, @"asr.openai.base_url", @"https://api.openai.com/v1");
        NSString *openaiApiKey = yamlRead(yaml, @"asr.openai.api_key");
        self.asrOpenAIApiKeySecureField.stringValue = openaiApiKey;
        self.asrOpenAIApiKeyField.stringValue = openaiApiKey;
        self.asrOpenAIApiKeySecureField.hidden = NO;
        self.asrOpenAIApiKeyField.hidden = YES;
        self.asrOpenAIApiKeyToggle.image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:@"Show"];
        self.asrOpenAIApiKeyToggle.tag = 0;

        NSString *asrModel = yamlValueOrDefault(yaml, @"asr.openai.model", @"gpt-4o-transcribe");
        for (NSInteger i = 0; i < self.asrOpenAIModelPopup.numberOfItems; i++) {
            if ([[self.asrOpenAIModelPopup itemAtIndex:i].representedObject isEqualToString:asrModel]) {
                [self.asrOpenAIModelPopup selectItemAtIndex:i];
                break;
            }
        }

        self.asrQwenBaseUrlField.stringValue = yamlValueOrDefault(yaml, @"asr.qwen.base_url", @"wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime");
        NSString *qwenApiKey = yamlRead(yaml, @"asr.qwen.api_key");
        self.asrQwenApiKeySecureField.stringValue = qwenApiKey;
        self.asrQwenApiKeyField.stringValue = qwenApiKey;
        self.asrQwenApiKeySecureField.hidden = NO;
        self.asrQwenApiKeyField.hidden = YES;
        self.asrQwenApiKeyToggle.image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:@"Show"];
        self.asrQwenApiKeyToggle.tag = 0;

        NSString *qwenModel = yamlValueOrDefault(yaml, @"asr.qwen.model", @"qwen3-asr-flash-realtime");
        for (NSInteger i = 0; i < self.asrQwenModelPopup.numberOfItems; i++) {
            if ([[self.asrQwenModelPopup itemAtIndex:i].representedObject isEqualToString:qwenModel]) {
                [self.asrQwenModelPopup selectItemAtIndex:i];
                break;
            }
        }

        [self updateAsrProviderControls];
    } else if ([identifier isEqualToString:kToolbarLLM]) {
        NSString *enabled = yamlRead(yaml, @"llm.enabled");
        self.llmEnabledCheckbox.state = ([enabled isEqualToString:@"false"]) ? NSControlStateValueOff : NSControlStateValueOn;
        NSString *baseUrl = yamlRead(yaml, @"llm.base_url");
        self.llmBaseUrlField.stringValue = baseUrl.length > 0 ? baseUrl : @"https://api.openai.com/v1";
        NSString *apiKey = yamlRead(yaml, @"llm.api_key");
        self.llmApiKeySecureField.stringValue = apiKey;
        self.llmApiKeyField.stringValue = apiKey;
        self.llmApiKeySecureField.hidden = NO;
        self.llmApiKeyField.hidden = YES;
        self.llmApiKeyToggle.image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:@"Show"];
        self.llmApiKeyToggle.tag = 0;
        NSString *model = yamlRead(yaml, @"llm.model");
        self.llmModelField.stringValue = model.length > 0 ? model : @"gpt-5.4-nano";
        // Max token parameter
        NSString *maxTokenParam = yamlRead(yaml, @"llm.max_token_parameter");
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
        NSString *triggerKey = yamlRead(yaml, @"hotkey.trigger_key");
        if (triggerKey.length == 0) triggerKey = @"fn";
        for (NSInteger i = 0; i < self.hotkeyPopup.numberOfItems; i++) {
            if ([[self.hotkeyPopup itemAtIndex:i].representedObject isEqualToString:triggerKey]) {
                [self.hotkeyPopup selectItemAtIndex:i];
                break;
            }
        }

        NSString *startSound = yamlRead(yaml, @"feedback.start_sound");
        NSString *stopSound = yamlRead(yaml, @"feedback.stop_sound");
        NSString *errorSound = yamlRead(yaml, @"feedback.error_sound");
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
    NSString *dir = configDirPath();

    // Ensure directory exists
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    // Read existing config.yaml so we can preserve fields not exposed in the UI.
    NSString *configPath = configFilePath();
    NSString *yaml = [NSString stringWithContentsOfFile:configPath encoding:NSUTF8StringEncoding error:nil] ?: @"";

    NSString *asrProvider = yamlValueOrDefault(yaml, @"asr.provider", @"doubao");
    NSString *asrConnectTimeout = yamlValueOrDefault(yaml, @"asr.connect_timeout_ms", @"3000");
    NSString *asrFinalWaitTimeout = yamlValueOrDefault(yaml, @"asr.final_wait_timeout_ms", @"5000");

    NSString *doubaoUrl = yamlValueOrDefault(yaml, @"asr.doubao.url",
                                             yamlValueOrDefault(yaml, @"asr.url",
                                                                @"wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"));
    NSString *doubaoAppKey = yamlValueOrDefault(yaml, @"asr.doubao.app_key", yamlRead(yaml, @"asr.app_key"));
    NSString *doubaoAccessKey = yamlValueOrDefault(yaml, @"asr.doubao.access_key", yamlRead(yaml, @"asr.access_key"));
    NSString *doubaoResourceId = yamlValueOrDefault(yaml, @"asr.doubao.resource_id",
                                                    yamlValueOrDefault(yaml, @"asr.resource_id", @"volc.seedasr.sauc.duration"));
    NSString *doubaoEnableDdc = yamlValueOrDefault(yaml, @"asr.doubao.enable_ddc",
                                                   yamlValueOrDefault(yaml, @"asr.enable_ddc", @"true"));
    NSString *doubaoEnableItn = yamlValueOrDefault(yaml, @"asr.doubao.enable_itn",
                                                   yamlValueOrDefault(yaml, @"asr.enable_itn", @"true"));
    NSString *doubaoEnablePunc = yamlValueOrDefault(yaml, @"asr.doubao.enable_punc",
                                                    yamlValueOrDefault(yaml, @"asr.enable_punc", @"true"));
    NSString *doubaoEnableNonstream = yamlValueOrDefault(yaml, @"asr.doubao.enable_nonstream",
                                                         yamlValueOrDefault(yaml, @"asr.enable_nonstream", @"true"));

    NSString *openaiBaseUrl = yamlValueOrDefault(yaml, @"asr.openai.base_url", @"https://api.openai.com/v1");
    NSString *openaiApiKey = yamlRead(yaml, @"asr.openai.api_key");
    NSString *openaiModel = yamlValueOrDefault(yaml, @"asr.openai.model", @"gpt-4o-transcribe");
    NSString *openaiLanguage = yamlRead(yaml, @"asr.openai.language");
    NSString *openaiPrompt = yamlRead(yaml, @"asr.openai.prompt");
    NSString *qwenBaseUrl = yamlValueOrDefault(yaml, @"asr.qwen.base_url", @"wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime");
    NSString *qwenApiKey = yamlRead(yaml, @"asr.qwen.api_key");
    NSString *qwenModel = yamlValueOrDefault(yaml, @"asr.qwen.model", @"qwen3-asr-flash-realtime");
    NSString *qwenLanguage = yamlRead(yaml, @"asr.qwen.language");

    NSString *llmEnabled = yamlValueOrDefault(yaml, @"llm.enabled", @"true");
    NSString *llmBaseUrl = yamlValueOrDefault(yaml, @"llm.base_url", @"https://api.openai.com/v1");
    NSString *llmApiKey = yamlRead(yaml, @"llm.api_key");
    NSString *llmModel = yamlValueOrDefault(yaml, @"llm.model", @"gpt-5.4-nano");
    NSString *llmTemperature = yamlValueOrDefault(yaml, @"llm.temperature", @"0");
    NSString *llmTopP = yamlValueOrDefault(yaml, @"llm.top_p", @"1");
    NSString *llmTimeout = yamlValueOrDefault(yaml, @"llm.timeout_ms", @"8000");
    NSString *llmMaxOutputTokens = yamlValueOrDefault(yaml, @"llm.max_output_tokens", @"1024");
    NSString *llmMaxTokenParameter = yamlValueOrDefault(yaml, @"llm.max_token_parameter", @"max_completion_tokens");
    NSString *llmDictionaryMaxCandidates = yamlValueOrDefault(yaml, @"llm.dictionary_max_candidates", @"0");
    NSString *llmSystemPromptPath = yamlValueOrDefault(yaml, @"llm.system_prompt_path", @"system_prompt.txt");
    NSString *llmUserPromptPath = yamlValueOrDefault(yaml, @"llm.user_prompt_path", @"user_prompt.txt");

    NSString *feedbackStartSound = yamlValueOrDefault(yaml, @"feedback.start_sound", @"false");
    NSString *feedbackStopSound = yamlValueOrDefault(yaml, @"feedback.stop_sound", @"false");
    NSString *feedbackErrorSound = yamlValueOrDefault(yaml, @"feedback.error_sound", @"false");

    NSString *dictionaryPath = yamlValueOrDefault(yaml, @"dictionary.path", @"dictionary.txt");
    NSString *hotkeyTrigger = yamlValueOrDefault(yaml, @"hotkey.trigger_key", @"fn");

    if (self.asrProviderPopup) {
        asrProvider = self.asrProviderPopup.selectedItem.representedObject ?: @"doubao";
    }
    if (self.asrAppKeyField) {
        doubaoAppKey = self.asrAppKeyField.stringValue ?: @"";
        doubaoAccessKey = (self.asrAccessKeyToggle.tag == 1 ? self.asrAccessKeyField.stringValue : self.asrAccessKeySecureField.stringValue) ?: @"";
        openaiBaseUrl = self.asrOpenAIBaseUrlField.stringValue.length > 0 ? self.asrOpenAIBaseUrlField.stringValue : @"https://api.openai.com/v1";
        openaiApiKey = (self.asrOpenAIApiKeyToggle.tag == 1 ? self.asrOpenAIApiKeyField.stringValue : self.asrOpenAIApiKeySecureField.stringValue) ?: @"";
        openaiModel = self.asrOpenAIModelPopup.selectedItem.representedObject ?: @"gpt-4o-transcribe";
        qwenBaseUrl = self.asrQwenBaseUrlField.stringValue.length > 0 ? self.asrQwenBaseUrlField.stringValue : @"wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime";
        qwenApiKey = (self.asrQwenApiKeyToggle.tag == 1 ? self.asrQwenApiKeyField.stringValue : self.asrQwenApiKeySecureField.stringValue) ?: @"";
        qwenModel = self.asrQwenModelPopup.selectedItem.representedObject ?: @"qwen3-asr-flash-realtime";
    }
    if (self.llmEnabledCheckbox) {
        llmEnabled = (self.llmEnabledCheckbox.state == NSControlStateValueOn) ? @"true" : @"false";
        llmBaseUrl = self.llmBaseUrlField.stringValue.length > 0 ? self.llmBaseUrlField.stringValue : @"https://api.openai.com/v1";
        llmApiKey = (self.llmApiKeyToggle.tag == 1 ? self.llmApiKeyField.stringValue : self.llmApiKeySecureField.stringValue) ?: @"";
        llmModel = self.llmModelField.stringValue.length > 0 ? self.llmModelField.stringValue : @"gpt-5.4-nano";
        llmMaxTokenParameter = self.maxTokenParamPopup.selectedItem.representedObject ?: @"max_completion_tokens";
    }
    if (self.hotkeyPopup) {
        hotkeyTrigger = self.hotkeyPopup.selectedItem.representedObject ?: @"fn";
    }
    if (self.startSoundCheckbox) {
        feedbackStartSound = (self.startSoundCheckbox.state == NSControlStateValueOn) ? @"true" : @"false";
        feedbackStopSound = (self.stopSoundCheckbox.state == NSControlStateValueOn) ? @"true" : @"false";
        feedbackErrorSound = (self.errorSoundCheckbox.state == NSControlStateValueOn) ? @"true" : @"false";
    }

    NSMutableString *newYaml = [NSMutableString string];
    [newYaml appendString:@"version: 2\n\n"];
    [newYaml appendString:@"asr:\n"];
    [newYaml appendFormat:@"  provider: %@\n", yamlQuotedString(asrProvider)];
    [newYaml appendFormat:@"  connect_timeout_ms: %@\n", asrConnectTimeout];
    [newYaml appendFormat:@"  final_wait_timeout_ms: %@\n", asrFinalWaitTimeout];
    [newYaml appendString:@"\n"];
    [newYaml appendString:@"  doubao:\n"];
    [newYaml appendFormat:@"    url: %@\n", yamlQuotedString(doubaoUrl)];
    [newYaml appendFormat:@"    app_key: %@\n", yamlQuotedString(doubaoAppKey)];
    [newYaml appendFormat:@"    access_key: %@\n", yamlQuotedString(doubaoAccessKey)];
    [newYaml appendFormat:@"    resource_id: %@\n", yamlQuotedString(doubaoResourceId)];
    [newYaml appendFormat:@"    enable_ddc: %@\n", doubaoEnableDdc];
    [newYaml appendFormat:@"    enable_itn: %@\n", doubaoEnableItn];
    [newYaml appendFormat:@"    enable_punc: %@\n", doubaoEnablePunc];
    [newYaml appendFormat:@"    enable_nonstream: %@\n", doubaoEnableNonstream];
    [newYaml appendString:@"\n"];
    [newYaml appendString:@"  openai:\n"];
    [newYaml appendFormat:@"    base_url: %@\n", yamlQuotedString(openaiBaseUrl)];
    [newYaml appendFormat:@"    api_key: %@\n", yamlQuotedString(openaiApiKey)];
    [newYaml appendFormat:@"    model: %@\n", yamlQuotedString(openaiModel)];
    [newYaml appendFormat:@"    language: %@\n", yamlQuotedString(openaiLanguage)];
    [newYaml appendFormat:@"    prompt: %@\n", yamlQuotedString(openaiPrompt)];
    [newYaml appendString:@"\n"];
    [newYaml appendString:@"  qwen:\n"];
    [newYaml appendFormat:@"    base_url: %@\n", yamlQuotedString(qwenBaseUrl)];
    [newYaml appendFormat:@"    api_key: %@\n", yamlQuotedString(qwenApiKey)];
    [newYaml appendFormat:@"    model: %@\n", yamlQuotedString(qwenModel)];
    [newYaml appendFormat:@"    language: %@\n", yamlQuotedString(qwenLanguage)];
    [newYaml appendString:@"\n"];
    [newYaml appendString:@"llm:\n"];
    [newYaml appendFormat:@"  enabled: %@\n", llmEnabled];
    [newYaml appendFormat:@"  base_url: %@\n", yamlQuotedString(llmBaseUrl)];
    [newYaml appendFormat:@"  api_key: %@\n", yamlQuotedString(llmApiKey)];
    [newYaml appendFormat:@"  model: %@\n", yamlQuotedString(llmModel)];
    [newYaml appendFormat:@"  temperature: %@\n", llmTemperature];
    [newYaml appendFormat:@"  top_p: %@\n", llmTopP];
    [newYaml appendFormat:@"  timeout_ms: %@\n", llmTimeout];
    [newYaml appendFormat:@"  max_output_tokens: %@\n", llmMaxOutputTokens];
    [newYaml appendFormat:@"  max_token_parameter: %@\n", yamlQuotedString(llmMaxTokenParameter)];
    [newYaml appendFormat:@"  dictionary_max_candidates: %@\n", llmDictionaryMaxCandidates];
    [newYaml appendFormat:@"  system_prompt_path: %@\n", yamlQuotedString(llmSystemPromptPath)];
    [newYaml appendFormat:@"  user_prompt_path: %@\n", yamlQuotedString(llmUserPromptPath)];
    [newYaml appendString:@"\n"];
    [newYaml appendString:@"feedback:\n"];
    [newYaml appendFormat:@"  start_sound: %@\n", feedbackStartSound];
    [newYaml appendFormat:@"  stop_sound: %@\n", feedbackStopSound];
    [newYaml appendFormat:@"  error_sound: %@\n", feedbackErrorSound];
    [newYaml appendString:@"\n"];
    [newYaml appendString:@"dictionary:\n"];
    [newYaml appendFormat:@"  path: %@\n", yamlQuotedString(dictionaryPath)];
    [newYaml appendString:@"\n"];
    [newYaml appendString:@"hotkey:\n"];
    [newYaml appendFormat:@"  trigger_key: %@\n", yamlQuotedString(hotkeyTrigger)];

    NSError *error = nil;
    [newYaml writeToFile:configPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (error) {
        NSLog(@"[Koe] Failed to write config.yaml: %@", error.localizedDescription);
        [self showAlert:@"Failed to save config.yaml" info:error.localizedDescription];
        return;
    }

    // Write dictionary.txt
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
    NSDictionary *body = @{
        @"model": model,
        @"messages": @[@{@"role": @"user", @"content": @"Hi"}],
        tokenParam: @(10),
    };
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

- (void)showAlert:(NSString *)message info:(NSString *)info {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = info ?: @"";
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

@end
