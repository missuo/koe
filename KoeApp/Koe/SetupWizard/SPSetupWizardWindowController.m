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
// We parse/write the config.yaml with simple line-based logic to avoid
// pulling in a YAML library.  The config file is flat enough for this.

static NSString *configDirPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:kConfigDir];
}

static NSString *configFilePath(void) {
    return [configDirPath() stringByAppendingPathComponent:kConfigFile];
}

/// Count leading spaces in a line (each tab counts as 2 spaces).
static NSInteger yamlIndentLevel(NSString *line) {
    NSInteger indent = 0;
    for (NSUInteger i = 0; i < line.length; i++) {
        unichar ch = [line characterAtIndex:i];
        if (ch == ' ') indent++;
        else if (ch == '\t') indent += 2;
        else break;
    }
    return indent;
}

/// Read a YAML value at an arbitrary depth key path, e.g. @"asr.doubao.app_key".
/// Returns @"" if not found.
static NSString *yamlRead(NSString *yaml, NSString *keyPath) {
    NSArray<NSString *> *parts = [keyPath componentsSeparatedByString:@"."];
    if (parts.count == 0) return @"";

    NSArray<NSString *> *lines = [yaml componentsSeparatedByString:@"\n"];
    // Track which depth of the path we've matched so far
    NSInteger matchedDepth = 0;
    // The minimum indent level required for each depth
    NSInteger requiredIndent[16] = {0}; // support up to 16 levels
    requiredIndent[0] = 0;

    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0 || [trimmed hasPrefix:@"#"]) continue;

        NSInteger indent = yamlIndentLevel(line);

        // If indent is less than what the current matched section requires, we've left that section
        if (matchedDepth > 0 && indent < requiredIndent[matchedDepth - 1] + 1) {
            // Reset to how many parent sections are still valid
            while (matchedDepth > 0 && indent < requiredIndent[matchedDepth - 1] + 1) {
                matchedDepth--;
            }
        }

        // Extract key from this line
        NSRange colonRange = [trimmed rangeOfString:@":"];
        if (colonRange.location == NSNotFound) continue;

        NSString *lineKey = [[trimmed substringToIndex:colonRange.location]
                             stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        NSString *expectedKey = (matchedDepth < (NSInteger)parts.count) ? parts[matchedDepth] : nil;
        if (!expectedKey) continue;

        if ([lineKey isEqualToString:expectedKey]) {
            if (matchedDepth == (NSInteger)parts.count - 1) {
                // This is the leaf key — extract value
                NSString *value = [trimmed substringFromIndex:colonRange.location + 1];
                value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if ([value hasPrefix:@"\""]) {
                    NSRange closeQuote = [value rangeOfString:@"\"" options:0 range:NSMakeRange(1, value.length - 1)];
                    if (closeQuote.location != NSNotFound) {
                        value = [value substringToIndex:closeQuote.location + 1];
                    }
                } else {
                    NSRange commentRange = [value rangeOfString:@" #"];
                    if (commentRange.location != NSNotFound) {
                        value = [[value substringToIndex:commentRange.location]
                                 stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    }
                }
                if (value.length >= 2 && [value hasPrefix:@"\""] && [value hasSuffix:@"\""]) {
                    value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
                }
                return value;
            } else {
                // This is an intermediate section key — go deeper
                requiredIndent[matchedDepth] = indent;
                matchedDepth++;
            }
        }
    }
    return @"";
}

/// Set a value in the YAML string at an arbitrary depth key path.
/// If the key exists, replace it; otherwise append under the parent section(s).
static NSString *yamlWrite(NSString *yaml, NSString *keyPath, NSString *value) {
    NSArray<NSString *> *parts = [keyPath componentsSeparatedByString:@"."];
    NSString *key = parts.lastObject;

    // Quote the value if it contains special chars or is empty
    NSString *quotedValue;
    if (value.length == 0 ||
        [value rangeOfString:@" "].location != NSNotFound ||
        [value rangeOfString:@"#"].location != NSNotFound ||
        [value rangeOfString:@":"].location != NSNotFound ||
        [value rangeOfString:@"\""].location != NSNotFound ||
        [value rangeOfString:@"$"].location != NSNotFound ||
        [value rangeOfString:@"@"].location != NSNotFound ||
        [value hasPrefix:@"wss://"] || [value hasPrefix:@"https://"] || [value hasPrefix:@"http://"]) {
        quotedValue = [NSString stringWithFormat:@"\"%@\"", value];
    } else {
        quotedValue = value;
    }

    NSMutableArray<NSString *> *lines = [[yaml componentsSeparatedByString:@"\n"] mutableCopy];

    // Build indent string for the leaf key (2 spaces per depth level for sections)
    NSInteger sectionCount = (NSInteger)parts.count - 1;
    NSMutableString *indent = [NSMutableString string];
    for (NSInteger i = 0; i < sectionCount; i++) {
        [indent appendString:@"  "];
    }

    // Track section matching
    NSInteger matchedDepth = 0;
    NSInteger requiredIndent[16] = {0};
    NSInteger lastMatchedSectionLine[16] = {0}; // line index where each section was found

    for (NSInteger i = 0; i < (NSInteger)lines.count; i++) {
        NSString *line = lines[i];
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0 || [trimmed hasPrefix:@"#"]) continue;

        NSInteger lineIndent = yamlIndentLevel(line);

        // Check if we've left a matched section
        while (matchedDepth > 0 && lineIndent < requiredIndent[matchedDepth - 1] + 1) {
            matchedDepth--;
        }

        NSRange colonRange = [trimmed rangeOfString:@":"];
        if (colonRange.location == NSNotFound) continue;

        NSString *lineKey = [[trimmed substringToIndex:colonRange.location]
                             stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        if (matchedDepth < sectionCount) {
            // Still looking for parent sections
            NSString *expectedSection = parts[matchedDepth];
            if ([lineKey isEqualToString:expectedSection]) {
                requiredIndent[matchedDepth] = lineIndent;
                lastMatchedSectionLine[matchedDepth] = i;
                matchedDepth++;
            }
        } else if (matchedDepth == sectionCount) {
            // Looking for the leaf key
            if ([lineKey isEqualToString:key]) {
                // Replace this line
                NSString *newLine = [NSString stringWithFormat:@"%@%@: %@", indent, key, quotedValue];
                lines[i] = newLine;
                return [lines componentsJoinedByString:@"\n"];
            }
            // Check if we've passed the section (indent dropped to parent level or above)
        }
    }

    // Key not found — we need to insert it.
    // First, make sure all parent sections exist.
    NSInteger insertIdx = (NSInteger)lines.count;

    // Walk through parts[0..sectionCount-1] to find or create sections
    matchedDepth = 0;
    for (NSInteger i = 0; i < (NSInteger)lines.count; i++) {
        NSString *line = lines[i];
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0 || [trimmed hasPrefix:@"#"]) continue;

        NSInteger lineIndent = yamlIndentLevel(line);
        while (matchedDepth > 0 && lineIndent < requiredIndent[matchedDepth - 1] + 1) {
            matchedDepth--;
        }

        NSRange colonRange = [trimmed rangeOfString:@":"];
        if (colonRange.location == NSNotFound) continue;

        NSString *lineKey = [[trimmed substringToIndex:colonRange.location]
                             stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        if (matchedDepth < sectionCount) {
            NSString *expectedSection = parts[matchedDepth];
            if ([lineKey isEqualToString:expectedSection]) {
                requiredIndent[matchedDepth] = lineIndent;
                lastMatchedSectionLine[matchedDepth] = i;
                matchedDepth++;

                if (matchedDepth == sectionCount) {
                    // Found all parent sections — find end of deepest section to insert
                    insertIdx = i + 1;
                    while (insertIdx < (NSInteger)lines.count) {
                        NSString *nextLine = lines[insertIdx];
                        NSString *nextTrimmed = [nextLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        if (nextTrimmed.length > 0 && ![nextTrimmed hasPrefix:@"#"]) {
                            NSInteger nextIndent = yamlIndentLevel(nextLine);
                            if (nextIndent <= lineIndent) break;
                        }
                        insertIdx++;
                    }
                }
            }
        }
    }

    // Create missing parent sections
    for (NSInteger d = matchedDepth; d < sectionCount; d++) {
        NSMutableString *secIndent = [NSMutableString string];
        for (NSInteger j = 0; j < d; j++) [secIndent appendString:@"  "];
        NSString *secLine = [NSString stringWithFormat:@"%@%@:", secIndent, parts[d]];
        [lines insertObject:secLine atIndex:insertIdx];
        insertIdx++;
    }

    // Insert the leaf key
    NSString *newLine = [NSString stringWithFormat:@"%@%@: %@", indent, key, quotedValue];
    [lines insertObject:newLine atIndex:insertIdx];

    return [lines componentsJoinedByString:@"\n"];
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
    return [validValues containsObject:value] ? value : @"fn";
}

static NSString *defaultCancelKeyForTrigger(NSString *triggerKey) {
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

    // Calculate content height
    CGFloat contentHeight = 256;
    NSView *pane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];

    CGFloat y = contentHeight - 48;

    // Description
    NSTextField *desc = [self descriptionLabel:@"Choose the ASR provider used for transcription. Currently only Doubao is available."];
    desc.frame = NSMakeRect(24, y - 10, paneWidth - 48, 36);
    [pane addSubview:desc];
    y -= 52;

    // Provider
    [pane addSubview:[self formLabel:@"Provider" frame:NSMakeRect(16, y, labelW, 22)]];
    self.asrProviderPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX, y - 2, 220, 26) pullsDown:NO];
    [self.asrProviderPopup addItemWithTitle:@"Doubao (\u8c46\u5305)"];
    [self.asrProviderPopup itemAtIndex:0].representedObject = @"doubao";
    [pane addSubview:self.asrProviderPopup];
    y -= rowH;

    // App Key
    [pane addSubview:[self formLabel:@"App Key" frame:NSMakeRect(16, y, labelW, 22)]];
    self.asrAppKeyField = [self formTextField:NSMakeRect(fieldX, y, fieldW, 22) placeholder:@"Volcengine App ID"];
    [pane addSubview:self.asrAppKeyField];
    y -= rowH;

    // Access Key (secure by default)
    CGFloat eyeW = 28;
    CGFloat secFieldW = fieldW - eyeW - 4;
    [pane addSubview:[self formLabel:@"Access Key" frame:NSMakeRect(16, y, labelW, 22)]];
    self.asrAccessKeySecureField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(fieldX, y, secFieldW, 22)];
    self.asrAccessKeySecureField.placeholderString = @"Volcengine Access Token";
    self.asrAccessKeySecureField.font = [NSFont systemFontOfSize:13];
    [pane addSubview:self.asrAccessKeySecureField];
    self.asrAccessKeyField = [self formTextField:NSMakeRect(fieldX, y, secFieldW, 22) placeholder:@"Volcengine Access Token"];
    self.asrAccessKeyField.hidden = YES;
    [pane addSubview:self.asrAccessKeyField];
    self.asrAccessKeyToggle = [self eyeButtonWithFrame:NSMakeRect(fieldX + secFieldW + 4, y - 1, eyeW, 24)
                                                action:@selector(toggleAsrAccessKeyVisibility:)];
    [pane addSubview:self.asrAccessKeyToggle];
    y -= rowH + 16;

    // Save / Cancel buttons
    [self addButtonsToPane:pane atY:y width:paneWidth];

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
    NSString *configPath = configFilePath();
    NSString *yaml = [NSString stringWithContentsOfFile:configPath encoding:NSUTF8StringEncoding error:nil] ?: @"";

    if ([identifier isEqualToString:kToolbarASR]) {
        NSString *provider = yamlRead(yaml, @"asr.provider");
        if (provider.length == 0) provider = @"doubao";
        for (NSInteger i = 0; i < self.asrProviderPopup.numberOfItems; i++) {
            if ([[self.asrProviderPopup itemAtIndex:i].representedObject isEqualToString:provider]) {
                [self.asrProviderPopup selectItemAtIndex:i];
                break;
            }
        }
        self.asrAppKeyField.stringValue = yamlRead(yaml, @"asr.doubao.app_key");
        NSString *accessKey = yamlRead(yaml, @"asr.doubao.access_key");
        self.asrAccessKeySecureField.stringValue = accessKey;
        self.asrAccessKeyField.stringValue = accessKey;
        // Reset to hidden state
        self.asrAccessKeySecureField.hidden = NO;
        self.asrAccessKeyField.hidden = YES;
        self.asrAccessKeyToggle.image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:@"Show"];
        self.asrAccessKeyToggle.tag = 0;
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
        NSString *triggerKey = normalizedHotkeyValue(yamlRead(yaml, @"hotkey.trigger_key"));
        NSString *cancelKey = normalizedHotkeyValue(yamlRead(yaml, @"hotkey.cancel_key"));
        if (cancelKey.length == 0 || [cancelKey isEqualToString:triggerKey]) {
            cancelKey = defaultCancelKeyForTrigger(triggerKey);
        }
        for (NSInteger i = 0; i < self.hotkeyPopup.numberOfItems; i++) {
            if ([[self.hotkeyPopup itemAtIndex:i].representedObject isEqualToString:triggerKey]) {
                [self.hotkeyPopup selectItemAtIndex:i];
                break;
            }
        }
        for (NSInteger i = 0; i < self.cancelHotkeyPopup.numberOfItems; i++) {
            if ([[self.cancelHotkeyPopup itemAtIndex:i].representedObject isEqualToString:cancelKey]) {
                [self.cancelHotkeyPopup selectItemAtIndex:i];
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

    // Read existing config.yaml (preserve structure)
    NSString *configPath = configFilePath();
    NSString *yaml = [NSString stringWithContentsOfFile:configPath encoding:NSUTF8StringEncoding error:nil] ?: @"";

    // Update ASR fields (always save — fields may be nil if pane not visited, check first)
    if (self.asrAppKeyField) {
        NSString *selectedProvider = self.asrProviderPopup.selectedItem.representedObject ?: @"doubao";
        yaml = yamlWrite(yaml, @"asr.provider", selectedProvider);
        yaml = yamlWrite(yaml, @"asr.doubao.app_key", self.asrAppKeyField.stringValue);
        NSString *accessKey = self.asrAccessKeyToggle.tag == 1 ? self.asrAccessKeyField.stringValue : self.asrAccessKeySecureField.stringValue;
        yaml = yamlWrite(yaml, @"asr.doubao.access_key", accessKey);
    }

    // Update LLM fields
    if (self.llmEnabledCheckbox) {
        NSString *enabledStr = (self.llmEnabledCheckbox.state == NSControlStateValueOn) ? @"true" : @"false";
        yaml = yamlWrite(yaml, @"llm.enabled", enabledStr);
        yaml = yamlWrite(yaml, @"llm.base_url", self.llmBaseUrlField.stringValue);
        NSString *llmApiKey = self.llmApiKeyToggle.tag == 1 ? self.llmApiKeyField.stringValue : self.llmApiKeySecureField.stringValue;
        yaml = yamlWrite(yaml, @"llm.api_key", llmApiKey);
        yaml = yamlWrite(yaml, @"llm.model", self.llmModelField.stringValue);
        NSString *selectedTokenParam = self.maxTokenParamPopup.selectedItem.representedObject ?: @"max_completion_tokens";
        yaml = yamlWrite(yaml, @"llm.max_token_parameter", selectedTokenParam);
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
        yaml = yamlWrite(yaml, @"hotkey.trigger_key", selectedTriggerHotkey);
        yaml = yamlWrite(yaml, @"hotkey.cancel_key", selectedCancelHotkey);
    }
    if (self.startSoundCheckbox) {
        NSString *startSound = (self.startSoundCheckbox.state == NSControlStateValueOn) ? @"true" : @"false";
        NSString *stopSound = (self.stopSoundCheckbox.state == NSControlStateValueOn) ? @"true" : @"false";
        NSString *errorSound = (self.errorSoundCheckbox.state == NSControlStateValueOn) ? @"true" : @"false";
        yaml = yamlWrite(yaml, @"feedback.start_sound", startSound);
        yaml = yamlWrite(yaml, @"feedback.stop_sound", stopSound);
        yaml = yamlWrite(yaml, @"feedback.error_sound", errorSound);
    }

    // Write config.yaml
    NSError *error = nil;
    [yaml writeToFile:configPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
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
