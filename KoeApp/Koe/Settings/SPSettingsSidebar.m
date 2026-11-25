#import "SPSettingsSidebar.h"
#import "SPSettingsViews.h"
#import "SPTheme.h"
#import "SPLocalization.h"

#pragma mark - Row

@interface SPSidebarRow : NSView
@property(nonatomic, copy) NSString *paneIdentifier;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *symbolName;
@property(nonatomic, assign) BOOL selected;
@property(nonatomic, assign) BOOL hovered;
@property(nonatomic, copy) void (^onClick)(NSString *paneIdentifier);
@end

@implementation SPSidebarRow {
  NSImageView *_icon;
  NSTextField *_label;
  NSTrackingArea *_tracking;
}

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.wantsLayer = YES;

    _icon = [NSImageView new];
    _icon.translatesAutoresizingMaskIntoConstraints = NO;
    _icon.imageScaling = NSImageScaleProportionallyDown;
    _icon.contentTintColor = SPTheme.sidebarTitle;
    [self addSubview:_icon];

    _label = [NSTextField labelWithString:@""];
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    _label.font = SPTheme.sidebarRowFont;
    _label.textColor = SPTheme.sidebarTitle;
    [self addSubview:_label];

    // The row is the single accessibility element; its children are decorative.
    _icon.accessibilityElement = NO;
    _label.accessibilityElement = NO;

    [NSLayoutConstraint activateConstraints:@[
      [_icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                          constant:14],
      [_icon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_icon.widthAnchor constraintEqualToConstant:19],
      [_icon.heightAnchor constraintEqualToConstant:19],

      [_label.leadingAnchor constraintEqualToAnchor:_icon.trailingAnchor
                                           constant:10],
      [_label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_label.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor
                                                      constant:-10],
    ]];
  }
  return self;
}

- (void)setTitle:(NSString *)title {
  _title = [title copy];
  _label.stringValue = title ?: @"";
}

- (void)setSymbolName:(NSString *)symbolName {
  _symbolName = [symbolName copy];
  _icon.image = [NSImage imageWithSystemSymbolName:symbolName
                          accessibilityDescription:nil];
}

- (void)setSelected:(BOOL)selected {
  _selected = selected;
  [self updateBackground];
}

- (void)setHovered:(BOOL)hovered {
  _hovered = hovered;
  [self updateBackground];
}

- (void)updateBackground {
  self.layer.cornerRadius = 8.0;
  // Resolve under THIS view's appearance — a plain `.CGColor` resolves against
  // the app's appearance even while the window renders in the other one.
  [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
    if (self->_selected) {
      self.layer.backgroundColor = SPTheme.selectionBackground.CGColor;
    } else if (self->_hovered) {
      self.layer.backgroundColor = SPTheme.sidebarHover.CGColor;
    } else {
      self.layer.backgroundColor = NSColor.clearColor.CGColor;
    }
  }];
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_tracking)
    [self removeTrackingArea:_tracking];
  _tracking = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:NSTrackingMouseEnteredAndExited |
                   NSTrackingActiveInActiveApp | NSTrackingInVisibleRect
             owner:self
          userInfo:nil];
  [self addTrackingArea:_tracking];
}

- (void)mouseEntered:(NSEvent *)event { self.hovered = YES; }
- (void)mouseExited:(NSEvent *)event { self.hovered = NO; }
- (void)mouseDown:(NSEvent *)event {
  if (self.onClick)
    self.onClick(self.paneIdentifier);
}

// Route clicks on the icon/label children to the row itself.
- (NSView *)hitTest:(NSPoint)point { return [super hitTest:point] ? self : nil; }

// Expose each row as a single button (VoiceOver and UI automation).
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityButtonRole; }
- (NSString *)accessibilityLabel { return self.title; }
- (BOOL)accessibilityPerformPress {
  if (self.onClick)
    self.onClick(self.paneIdentifier);
  return YES;
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  [self updateBackground];
  _icon.contentTintColor = SPTheme.sidebarTitle;
  _label.textColor = SPTheme.sidebarTitle;
}

@end

#pragma mark - Sidebar

@implementation SPSettingsSidebarViewController {
  NSMutableArray<SPSidebarRow *> *_rows;
}

- (void)loadView {
  self.view = [[NSView alloc]
      initWithFrame:NSMakeRect(0, 0, SPTheme.sidebarWidth, 600)];
  self.view.wantsLayer = YES;
  // Clear: the sidebar shares the window gradient with the content area.
  self.view.layer.backgroundColor = SPTheme.sidebarBackground.CGColor;
  _rows = [NSMutableArray array];

  NSStackView *top = [self makeStack];
  NSStackView *bottom = [self makeStack];
  [self.view addSubview:top];
  [self.view addSubview:bottom];

  [NSLayoutConstraint activateConstraints:@[
    // 44 clears the transparent titlebar of the full-size content view.
    [top.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:44],
    [top.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor
                                      constant:8],
    [top.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor
                                       constant:-8],

    [bottom.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor
                                        constant:-12],
    [bottom.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor
                                         constant:8],
    [bottom.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor
                                          constant:-8],
  ]];

  // Grouped by what the user is configuring, in pipeline order: what turns
  // speech into text, how dictation is triggered and shown, then how the text
  // itself is shaped.
  [self addHeaderTo:top text:KoeLocalizedString(@"settings.sidebar.group.recognition")];
  [self addItemTo:top
       identifier:@"asr"
            title:KoeLocalizedString(@"settings.sidebar.asr")
           symbol:@"mic.fill"];
  [self addItemTo:top
       identifier:@"llm"
            title:KoeLocalizedString(@"settings.sidebar.llm")
           symbol:@"cpu"];

  [self addHeaderTo:top text:KoeLocalizedString(@"settings.sidebar.group.input")];
  [self addItemTo:top
       identifier:@"hotkey"
            title:KoeLocalizedString(@"settings.sidebar.controls")
           symbol:@"slider.horizontal.3"];
  [self addItemTo:top
       identifier:@"overlay"
            title:KoeLocalizedString(@"settings.sidebar.overlay")
           symbol:@"captions.bubble"];

  [self addHeaderTo:top text:KoeLocalizedString(@"settings.sidebar.group.text")];
  [self addItemTo:top
       identifier:@"dictionary"
            title:KoeLocalizedString(@"settings.sidebar.dictionary")
           symbol:@"book"];
  [self addItemTo:top
       identifier:@"system_prompt"
            title:KoeLocalizedString(@"settings.sidebar.prompt")
           symbol:@"text.bubble"];
  [self addItemTo:top
       identifier:@"templates"
            title:KoeLocalizedString(@"settings.sidebar.templates")
           symbol:@"sparkles"];

  [self addItemTo:bottom
       identifier:@"about"
            title:KoeLocalizedString(@"settings.sidebar.about")
           symbol:@"info.circle"];
}

- (NSStackView *)makeStack {
  NSStackView *stack = [NSStackView new];
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.distribution = NSStackViewDistributionFill;
  stack.spacing = 2;
  return stack;
}

- (void)addItemTo:(NSStackView *)stack
       identifier:(NSString *)identifier
            title:(NSString *)title
           symbol:(NSString *)symbol {
  SPSidebarRow *row = [[SPSidebarRow alloc] initWithFrame:NSZeroRect];
  row.translatesAutoresizingMaskIntoConstraints = NO;
  row.paneIdentifier = identifier;
  row.title = title;
  row.symbolName = symbol;
  __weak typeof(self) weakSelf = self;
  row.onClick = ^(NSString *clickedIdentifier) {
    [weakSelf selectPaneIdentifier:clickedIdentifier];
    if (weakSelf.onSelect)
      weakSelf.onSelect(clickedIdentifier);
  };
  [stack addArrangedSubview:row];
  [row.heightAnchor constraintEqualToConstant:34].active = YES;
  [row.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
  [_rows addObject:row];
}

- (void)addHeaderTo:(NSStackView *)stack text:(NSString *)text {
  NSTextField *header = [NSTextField labelWithString:text.uppercaseString];
  header.translatesAutoresizingMaskIntoConstraints = NO;
  header.font = SPTheme.captionFont;
  header.textColor = SPTheme.sidebarHeader;

  NSView *wrap = [NSView new];
  wrap.translatesAutoresizingMaskIntoConstraints = NO;
  [wrap addSubview:header];
  [NSLayoutConstraint activateConstraints:@[
    [header.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor
                                         constant:14],
    [header.topAnchor constraintEqualToAnchor:wrap.topAnchor constant:14],
    [header.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor constant:-4],
  ]];
  [stack addArrangedSubview:wrap];
  [wrap.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
}

- (void)selectPaneIdentifier:(NSString *)identifier {
  for (SPSidebarRow *row in _rows) {
    row.selected = [row.paneIdentifier isEqualToString:identifier];
  }
}

@end
