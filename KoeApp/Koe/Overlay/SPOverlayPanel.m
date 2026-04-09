#import "SPOverlayPanel.h"
#import "koe_core.h"
#import <QuartzCore/QuartzCore.h>

// ── Geometry ──────────────────────────────────────────────
static const CGFloat kMinimumPillHeight = 36.0;
static const CGFloat kDefaultBottomMargin = 10.0;
static const CGFloat kDefaultTextFontSize = 13.0;
static NSString *const kDefaultFontFamily = @"system";
static const BOOL kDefaultLimitVisibleLines = YES;
static const NSInteger kDefaultMaxVisibleLines = 3;
static const NSInteger kMinVisibleLines = 3;
static const NSInteger kMaxVisibleLines = 5;
static const CGFloat kMinTextFontSize = 12.0;
static const CGFloat kMaxTextFontSize = 28.0;
static const CGFloat kMaxBottomMargin = 180.0;
static const CGFloat kMaxWidth         = 600.0;
static const NSTimeInterval kTextScrollDuration = 0.18;

// Waveform bars
static const NSInteger kBarCount   = 5;
static const CGFloat   kBarWidth   = 3.0;
static const CGFloat   kBarSpacing = 2.0;
static const CGFloat   kBarMinH    = 3.0;
static const CGFloat   kBarMaxH    = 16.0;

// Processing dots
static const NSInteger kDotCount      = 3;
static const CGFloat   kDotBaseRadius = 2.5;
static const CGFloat   kDotSpacing    = 8.0;

// Interim text
static const CGFloat kScreenHorizontalMargin = 32.0;

// Animation
static const NSTimeInterval kAnimInterval      = 1.0 / 30.0;
static const NSTimeInterval kFadeInDuration    = 0.2;
static const NSTimeInterval kFadeOutDuration   = 0.3;
static const NSTimeInterval kResizeDuration    = 0.15;
static const NSTimeInterval kMinLingerDuration = 0.45;
static const NSTimeInterval kMaxLingerDuration = 1.2;
static const NSTimeInterval kTemplateLingerDuration = 3.0;
static const NSTimeInterval kPanelEntranceDuration = 0.22;
static const NSTimeInterval kPanelExitDuration = 0.18;
static const CGFloat kPanelEntranceLift = 10.0;
static const CGFloat kPanelExitDrop = 8.0;
static const CGFloat kBaseShadowOpacity = 0.11;
static const CGFloat kBaseShadowRadius = 4.0;
static const CGFloat kEntranceShadowOpacity = 0.17;
static const CGFloat kEntranceShadowRadius = 8.0;
static const NSTimeInterval kRippleDuration = 0.42;

static NSColor *SPOverlaySurfaceTintColor(void) {
    return [NSColor colorWithSRGBRed:0.07 green:0.065 blue:0.03 alpha:0.34];
}

static NSColor *SPOverlayShadowColor(void) {
    return [NSColor colorWithSRGBRed:0.04 green:0.035 blue:0.015 alpha:1.0];
}

static CGFloat SPOverlayClampTextFontSize(CGFloat fontSize) {
    return fmin(fmax(fontSize, kMinTextFontSize), kMaxTextFontSize);
}

static CGFloat SPOverlayClampBottomMargin(CGFloat bottomMargin) {
    return fmin(fmax(bottomMargin, 0.0), kMaxBottomMargin);
}

static NSInteger SPOverlayClampMaxVisibleLines(NSInteger maxVisibleLines) {
    return MAX(kMinVisibleLines, MIN(kMaxVisibleLines, maxVisibleLines));
}

static CGFloat SPOverlayConfigCGFloat(const char *keyPath, CGFloat fallback) {
    char *raw = sp_config_get(keyPath);
    if (!raw) return fallback;

    NSString *value = [NSString stringWithUTF8String:raw];
    sp_core_free_string(raw);
    if (value.length == 0) return fallback;

    NSScanner *scanner = [NSScanner scannerWithString:value];
    double parsedValue = 0.0;
    if (![scanner scanDouble:&parsedValue] || !scanner.isAtEnd) {
        return fallback;
    }

    return parsedValue;
}

static BOOL SPOverlayConfigBOOL(const char *keyPath, BOOL fallback) {
    char *raw = sp_config_get(keyPath);
    if (!raw) return fallback;

    NSString *value = [[[NSString stringWithUTF8String:raw] ?: @""
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    sp_core_free_string(raw);
    if (value.length == 0) return fallback;

    if ([value isEqualToString:@"1"] ||
        [value isEqualToString:@"true"] ||
        [value isEqualToString:@"yes"] ||
        [value isEqualToString:@"on"]) {
        return YES;
    }

    if ([value isEqualToString:@"0"] ||
        [value isEqualToString:@"false"] ||
        [value isEqualToString:@"no"] ||
        [value isEqualToString:@"off"]) {
        return NO;
    }

    return fallback;
}

static NSString *SPOverlayNormalizeFontFamily(NSString *fontFamily) {
    NSString *normalized = [[fontFamily ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
    if (normalized.length == 0) {
        return kDefaultFontFamily;
    }
    return normalized;
}

static BOOL SPOverlayUsesSystemFont(NSString *fontFamily) {
    return [SPOverlayNormalizeFontFamily(fontFamily) caseInsensitiveCompare:kDefaultFontFamily] == NSOrderedSame;
}

static NSString *SPOverlayConfigString(const char *keyPath, NSString *fallback) {
    char *raw = sp_config_get(keyPath);
    if (!raw) return fallback;

    NSString *value = [NSString stringWithUTF8String:raw] ?: @"";
    sp_core_free_string(raw);
    NSString *normalized = SPOverlayNormalizeFontFamily(value);
    return normalized.length > 0 ? normalized : fallback;
}

static NSFont *SPOverlayFontForFamily(NSString *fontFamily, CGFloat fontSize) {
    CGFloat clampedFontSize = SPOverlayClampTextFontSize(fontSize);
    NSString *normalized = SPOverlayNormalizeFontFamily(fontFamily);

    if (SPOverlayUsesSystemFont(normalized)) {
        return [NSFont systemFontOfSize:clampedFontSize weight:NSFontWeightMedium];
    }

    NSFont *font = [NSFont fontWithName:normalized size:clampedFontSize];
    if (font) {
        return font;
    }

    NSFontManager *fontManager = [NSFontManager sharedFontManager];
    font = [fontManager fontWithFamily:normalized traits:0 weight:5 size:clampedFontSize];
    if (font) {
        return font;
    }

    for (NSArray *member in [fontManager availableMembersOfFontFamily:normalized]) {
        if (member.count == 0) continue;
        NSString *memberName = member[0];
        font = [NSFont fontWithName:memberName size:clampedFontSize];
        if (font) {
            return font;
        }
    }

    return [NSFont systemFontOfSize:clampedFontSize weight:NSFontWeightMedium];
}

static CGFloat SPOverlayLineHeightForFont(NSFont *font) {
    if (!font) return ceil(kDefaultTextFontSize);
    NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
    return ceil([layoutManager defaultLineHeightForFont:font]);
}

static CGFloat SPOverlayHorizontalPadForFont(NSFont *font) {
    CGFloat lineHeight = SPOverlayLineHeightForFont(font);
    return ceil(MAX(14.0, MIN(22.0, lineHeight * 0.55)));
}

static CGFloat SPOverlayIconTextGapForFont(NSFont *font) {
    CGFloat lineHeight = SPOverlayLineHeightForFont(font);
    return ceil(MAX(6.0, MIN(10.0, lineHeight * 0.24)));
}

static CGFloat SPOverlayTextTopPadForFont(NSFont *font) {
    CGFloat lineHeight = SPOverlayLineHeightForFont(font);
    return ceil(MAX(12.0, MIN(18.0, lineHeight * 0.48)));
}

static CGFloat SPOverlayTextBottomPadForFont(NSFont *font) {
    CGFloat lineHeight = SPOverlayLineHeightForFont(font);
    return ceil(MAX(12.0, MIN(18.0, lineHeight * 0.44)));
}

static CGFloat SPOverlayTextTrailingPadForFont(NSFont *font) {
    CGFloat lineHeight = SPOverlayLineHeightForFont(font);
    return ceil(MAX(18.0, MIN(26.0, lineHeight * 0.72)));
}

static CGFloat SPOverlayLineLimitSlackForFont(NSFont *font) {
    CGFloat lineHeight = SPOverlayLineHeightForFont(font);
    return ceil(MAX(2.0, MIN(4.0, lineHeight * 0.12)));
}

static NSDictionary *SPOverlayTextAttributes(NSFont *font) {
    NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    paragraphStyle.lineBreakMode = NSLineBreakByWordWrapping;
    return @{
        NSFontAttributeName: font ?: [NSFont systemFontOfSize:kDefaultTextFontSize weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:1.0 alpha:0.92],
        NSParagraphStyleAttributeName: paragraphStyle,
    };
}

static CGFloat SPOverlayMeasureTextHeight(NSString *text, NSFont *font, CGFloat width) {
    CGFloat safeWidth = fmax(1.0, width);
    NSTextStorage *textStorage = [[NSTextStorage alloc] initWithAttributedString:
        [[NSAttributedString alloc] initWithString:text ?: @""
                                        attributes:SPOverlayTextAttributes(font)]];
    NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
    NSTextContainer *textContainer = [[NSTextContainer alloc] initWithContainerSize:NSMakeSize(safeWidth, CGFLOAT_MAX)];
    textContainer.lineFragmentPadding = 0.0;
    textContainer.widthTracksTextView = NO;
    [layoutManager addTextContainer:textContainer];
    [textStorage addLayoutManager:layoutManager];
    [layoutManager ensureLayoutForTextContainer:textContainer];
    return ceil([layoutManager usedRectForTextContainer:textContainer].size.height);
}

static CGFloat SPOverlayMeasureVisibleHeightForLineLimit(NSString *text, NSFont *font, CGFloat width, NSInteger maxVisibleLines) {
    CGFloat safeWidth = fmax(1.0, width);
    NSInteger clampedMaxVisibleLines = SPOverlayClampMaxVisibleLines(maxVisibleLines);
    NSDictionary *attrs = SPOverlayTextAttributes(font);
    NSTextStorage *textStorage = [[NSTextStorage alloc] initWithAttributedString:
        [[NSAttributedString alloc] initWithString:text ?: @""
                                        attributes:attrs]];
    NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
    NSTextContainer *textContainer = [[NSTextContainer alloc] initWithContainerSize:NSMakeSize(safeWidth, CGFLOAT_MAX)];
    textContainer.lineFragmentPadding = 0.0;
    textContainer.widthTracksTextView = NO;
    [layoutManager addTextContainer:textContainer];
    [textStorage addLayoutManager:layoutManager];
    [layoutManager ensureLayoutForTextContainer:textContainer];

    NSUInteger glyphCount = layoutManager.numberOfGlyphs;
    if (glyphCount == 0) {
        return SPOverlayLineHeightForFont(font);
    }

    NSUInteger glyphIndex = 0;
    NSInteger lineCount = 0;
    CGFloat visibleHeight = 0.0;
    while (glyphIndex < glyphCount) {
        NSRange lineGlyphRange = NSMakeRange(0, 0);
        NSRect lineFragmentRect = [layoutManager lineFragmentRectForGlyphAtIndex:glyphIndex
                                                                  effectiveRange:&lineGlyphRange
                                                            withoutAdditionalLayout:YES];
        lineCount += 1;
        visibleHeight = ceil(NSMaxY(lineFragmentRect));
        glyphIndex = NSMaxRange(lineGlyphRange);
        if (lineCount >= clampedMaxVisibleLines) {
            break;
        }
    }

    CGFloat totalHeight = ceil([layoutManager usedRectForTextContainer:textContainer].size.height);
    return fmin(fmax(SPOverlayLineHeightForFont(font), visibleHeight), totalHeight);
}

static BOOL SPOverlayShouldReduceMotion(void) {
    if (@available(macOS 10.15, *)) {
        return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    }
    return NO;
}

static NSRect SPOverlayPresentationStartFrame(NSRect finalFrame) {
    CGFloat insetX = fmin(10.0, floor(finalFrame.size.width * 0.018));
    CGFloat insetY = fmin(6.0, floor(finalFrame.size.height * 0.08));
    NSRect startFrame = NSInsetRect(finalFrame, insetX, insetY);
    startFrame.origin.y -= kPanelEntranceLift;
    return startFrame;
}

static NSRect SPOverlayDismissalEndFrame(NSRect currentFrame) {
    CGFloat insetX = fmin(8.0, floor(currentFrame.size.width * 0.012));
    CGFloat insetY = fmin(5.0, floor(currentFrame.size.height * 0.06));
    NSRect endFrame = NSInsetRect(currentFrame, insetX, insetY);
    endFrame.origin.y -= kPanelExitDrop;
    return endFrame;
}

// ── Animation mode ───────────────────────────────────────
typedef NS_ENUM(NSInteger, SPOverlayMode) {
    SPOverlayModeNone,
    SPOverlayModeWaveform,
    SPOverlayModeProcessing,
    SPOverlayModeSuccess,
    SPOverlayModeError,
};

// ── Key-accepting panel for template button bar ─────────
// NSPanel subclass that can become key window without activating the app.
// This allows it to receive keyboard events (number keys 1-9) while
// the user's frontmost app retains focus.

@interface SPKeyablePanel : NSPanel
@property (nonatomic, copy) void (^keyHandler)(NSInteger number);
@end

@implementation SPKeyablePanel
- (BOOL)canBecomeKeyWindow { return YES; }

- (void)keyDown:(NSEvent *)event {
    NSString *chars = event.charactersIgnoringModifiers;
    if (chars.length == 1 && self.keyHandler) {
        unichar ch = [chars characterAtIndex:0];
        if (ch >= '1' && ch <= '9') {
            self.keyHandler(ch - '0');
            return;
        }
    }
    [super keyDown:event];
}
@end

// ── Hover-aware effect view ──────────────────────────────

@interface SPHoverEffectView : NSVisualEffectView
@property (nonatomic, copy) void (^hoverChangedHandler)(BOOL hovering);
@end

@implementation SPHoverEffectView {
    NSTrackingArea *_trackingArea;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];

    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
        _trackingArea = nil;
    }

    _trackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                 options:NSTrackingMouseEnteredAndExited |
                                                         NSTrackingActiveAlways |
                                                         NSTrackingInVisibleRect
                                                   owner:self
                                                userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    if (self.hoverChangedHandler) {
        self.hoverChangedHandler(YES);
    }
}

- (void)mouseExited:(NSEvent *)event {
    if (self.hoverChangedHandler) {
        self.hoverChangedHandler(NO);
    }
}

@end

// ── Hover-aware template button ──────────────────────────

@interface SPTemplateButton : NSButton
@property (nonatomic, assign, getter=isHovering) BOOL hovering;
@property (nonatomic, assign, getter=isEmphasized) BOOL emphasized;
- (void)applyCurrentAppearance;
@end

@implementation SPTemplateButton {
    NSTrackingArea *_trackingArea;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];

    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
        _trackingArea = nil;
    }

    _trackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                 options:NSTrackingMouseEnteredAndExited |
                                                         NSTrackingActiveAlways |
                                                         NSTrackingInVisibleRect
                                                   owner:self
                                                userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    self.hovering = YES;
    [self applyCurrentAppearance];
}

- (void)mouseExited:(NSEvent *)event {
    self.hovering = NO;
    [self applyCurrentAppearance];
}

- (void)setEmphasized:(BOOL)emphasized {
    _emphasized = emphasized;
    [self applyCurrentAppearance];
}

- (void)applyCurrentAppearance {
    if (!self.layer) return;

    CGFloat backgroundAlpha = 0.1;
    CGFloat textAlpha = 0.85;
    CGFloat borderAlpha = 0.0;

    if (self.isEmphasized || self.isHovering) {
        backgroundAlpha = 0.3;
        textAlpha = 1.0;
        borderAlpha = 0.2;
    }

    self.layer.backgroundColor = [[NSColor colorWithWhite:1.0 alpha:backgroundAlpha] CGColor];
    self.layer.borderWidth = borderAlpha > 0 ? 1.0 : 0.0;
    self.layer.borderColor = [[NSColor colorWithWhite:1.0 alpha:borderAlpha] CGColor];
    self.contentTintColor = [NSColor colorWithWhite:1.0 alpha:textAlpha];
}

@end

// ── Content view ─────────────────────────────────────────

@interface SPOverlayContentView : NSView
@property (nonatomic, copy)   NSString      *statusText;
@property (nonatomic, copy)   NSString      *interimText;
@property (nonatomic, strong) NSColor       *accentColor;
@property (nonatomic, assign) SPOverlayMode  mode;
@property (nonatomic, assign) NSInteger      tick;  // animation counter
@property (nonatomic, assign) CGFloat        layoutWidth;
@property (nonatomic, assign) CGFloat        textFontSize;
@property (nonatomic, copy)   NSString      *fontFamily;
@property (nonatomic, assign) CGFloat        cornerRadius;
@property (nonatomic, assign) CGFloat        iconAreaWidth;
@property (nonatomic, assign) CGFloat        textViewportHeight;
- (void)updateTextAttributes;
- (void)refreshDisplayedTextAnimated:(BOOL)animated;
@end

@interface SPOverlayContentView ()
@property (nonatomic, strong) NSScrollView *textScrollView;
@property (nonatomic, strong) NSTextView *textView;
@end

@implementation SPOverlayContentView

- (BOOL)isFlipped { return NO; }

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self setupTextViewport];
    }
    return self;
}

- (NSFont *)contentFont {
    return SPOverlayFontForFamily(self.fontFamily, self.textFontSize > 0 ? self.textFontSize : kDefaultTextFontSize);
}

- (void)setupTextViewport {
    self.textScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.textScrollView.drawsBackground = NO;
    self.textScrollView.borderType = NSNoBorder;
    self.textScrollView.hasVerticalScroller = NO;
    self.textScrollView.hasHorizontalScroller = NO;
    self.textScrollView.autohidesScrollers = YES;
    self.textScrollView.scrollerStyle = NSScrollerStyleOverlay;
    self.textScrollView.verticalScrollElasticity = NSScrollElasticityNone;
    self.textScrollView.horizontalScrollElasticity = NSScrollElasticityNone;
    self.textScrollView.wantsLayer = YES;

    NSTextView *textView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    textView.drawsBackground = NO;
    textView.editable = NO;
    textView.selectable = NO;
    textView.richText = NO;
    textView.importsGraphics = NO;
    textView.usesFontPanel = NO;
    textView.usesFindPanel = NO;
    textView.textContainerInset = NSZeroSize;
    textView.textContainer.lineFragmentPadding = 0.0;
    textView.verticallyResizable = YES;
    textView.horizontallyResizable = NO;
    textView.autoresizingMask = NSViewWidthSizable;
    textView.textContainer.widthTracksTextView = YES;
    textView.textContainer.containerSize = NSMakeSize(1.0, CGFLOAT_MAX);

    self.textView = textView;
    self.textScrollView.documentView = textView;
    [self addSubview:self.textScrollView];
}

- (NSString *)displayText {
    return (self.interimText.length > 0) ? self.interimText : self.statusText;
}

- (void)setLayoutWidth:(CGFloat)layoutWidth {
    _layoutWidth = layoutWidth;
    [self setNeedsLayout:YES];
}

- (void)setIconAreaWidth:(CGFloat)iconAreaWidth {
    _iconAreaWidth = iconAreaWidth;
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

- (void)setTextViewportHeight:(CGFloat)textViewportHeight {
    _textViewportHeight = textViewportHeight;
    [self setNeedsLayout:YES];
}

- (void)setTextFontSize:(CGFloat)textFontSize {
    _textFontSize = textFontSize;
    [self updateTextAttributes];
    [self setNeedsDisplay:YES];
}

- (void)setFontFamily:(NSString *)fontFamily {
    _fontFamily = [fontFamily copy];
    [self updateTextAttributes];
    [self setNeedsDisplay:YES];
}

- (NSRect)textViewportFrame {
    NSFont *font = [self contentFont];
    CGFloat effectiveWidth = self.layoutWidth > 0 ? self.layoutWidth : NSWidth(self.bounds);
    CGFloat topPad = SPOverlayTextTopPadForFont(font);
    CGFloat bottomPad = SPOverlayTextBottomPadForFont(font);
    CGFloat horizontalPad = SPOverlayHorizontalPadForFont(font);
    CGFloat iconGap = SPOverlayIconTextGapForFont(font);
    CGFloat trailingPad = SPOverlayTextTrailingPadForFont(font);
    CGFloat effectiveViewportHeight = self.textViewportHeight > 0
        ? self.textViewportHeight
        : fmax(1.0, NSHeight(self.bounds) - topPad - bottomPad);
    CGFloat textX = horizontalPad + (self.iconAreaWidth > 0 ? self.iconAreaWidth : 28.0) + iconGap;
    CGFloat textWidth = fmax(1.0, effectiveWidth - textX - trailingPad);
    return NSMakeRect(textX, bottomPad, textWidth, effectiveViewportHeight);
}

- (void)layout {
    [super layout];
    [self updateTextLayout];
}

- (void)updateTextLayout {
    if (!self.textScrollView || !self.textView) return;

    NSRect textFrame = [self textViewportFrame];
    self.textScrollView.frame = textFrame;
    self.textView.frame = NSMakeRect(0, 0, textFrame.size.width, MAX(textFrame.size.height, self.textView.frame.size.height));
    self.textView.textContainer.containerSize = NSMakeSize(textFrame.size.width, CGFLOAT_MAX);
}

- (void)updateTextAttributes {
    NSDictionary *attrs = SPOverlayTextAttributes([self contentFont]);
    if (self.textView.string.length > 0) {
        [self.textView.textStorage setAttributedString:[[NSAttributedString alloc] initWithString:self.textView.string attributes:attrs]];
    } else {
        self.textView.typingAttributes = attrs;
    }
}

- (void)refreshDisplayedTextAnimated:(BOOL)animated {
    NSString *displayText = [self displayText] ?: @"";
    NSDictionary *attrs = SPOverlayTextAttributes([self contentFont]);
    NSClipView *clipView = self.textScrollView.contentView;
    CGFloat oldOffsetY = clipView.bounds.origin.y;

    [self.textView.textStorage setAttributedString:[[NSAttributedString alloc] initWithString:displayText attributes:attrs]];
    [self updateTextLayout];

    [self.textView.layoutManager ensureLayoutForTextContainer:self.textView.textContainer];
    CGFloat contentHeight = ceil([self.textView.layoutManager usedRectForTextContainer:self.textView.textContainer].size.height);
    CGFloat viewportHeight = NSHeight(self.textScrollView.frame);
    CGFloat documentHeight = MAX(viewportHeight, contentHeight);
    self.textView.frame = NSMakeRect(0, 0, NSWidth(self.textScrollView.frame), documentHeight);

    CGFloat targetOffsetY = MAX(0.0, documentHeight - viewportHeight);
    NSPoint targetPoint = NSMakePoint(0.0, targetOffsetY);
    if (animated && targetOffsetY > oldOffsetY + 0.5) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = kTextScrollDuration;
            ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            [[clipView animator] setBoundsOrigin:targetPoint];
        } completionHandler:^{
            [self.textScrollView reflectScrolledClipView:clipView];
        }];
    } else {
        [clipView setBoundsOrigin:targetPoint];
        [self.textScrollView reflectScrolledClipView:clipView];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    CGFloat iconAreaWidth = self.iconAreaWidth > 0 ? self.iconAreaWidth : 28.0;
    CGFloat horizontalPad = SPOverlayHorizontalPadForFont([self contentFont]);

    // ── Dark tint (minimum contrast for white text on any background) ──
    [SPOverlaySurfaceTintColor() setFill];
    [NSBezierPath fillRect:bounds];

    // ── Left icon area ──
    CGFloat iconCenterX = horizontalPad + iconAreaWidth / 2.0;
    CGFloat centerY = NSMidY(bounds);

    switch (self.mode) {
        case SPOverlayModeWaveform:
            [self drawWaveformAtX:iconCenterX centerY:centerY];
            break;
        case SPOverlayModeProcessing:
            [self drawDotsAtX:iconCenterX centerY:centerY];
            break;
        case SPOverlayModeSuccess:
            [self drawCheckmarkAtX:iconCenterX centerY:centerY];
            break;
        case SPOverlayModeError:
            [self drawCrossAtX:iconCenterX centerY:centerY];
            break;
        default:
            break;
    }
}

#pragma mark - Waveform (recording)

- (void)drawWaveformAtX:(CGFloat)centerX centerY:(CGFloat)centerY {
    NSColor *color = self.accentColor ?: [NSColor whiteColor];
    CGFloat totalW = kBarCount * kBarWidth + (kBarCount - 1) * kBarSpacing;
    CGFloat startX = centerX - totalW / 2.0;

    for (NSInteger i = 0; i < kBarCount; i++) {
        double phase = (double)(self.tick) * 0.12 + (double)i * 1.1;
        CGFloat t = (CGFloat)(0.5 + 0.5 * sin(phase));
        CGFloat h = kBarMinH + t * (kBarMaxH - kBarMinH);
        CGFloat alpha = 0.55 + 0.45 * t;

        [[color colorWithAlphaComponent:alpha] setFill];

        CGFloat x = startX + i * (kBarWidth + kBarSpacing);
        CGFloat y = centerY - h / 2.0;
        NSBezierPath *bar = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, y, kBarWidth, h)
                                                             xRadius:kBarWidth / 2.0
                                                             yRadius:kBarWidth / 2.0];
        [bar fill];
    }
}

#pragma mark - Processing dots

- (void)drawDotsAtX:(CGFloat)centerX centerY:(CGFloat)centerY {
    NSColor *color = self.accentColor ?: [NSColor whiteColor];
    CGFloat totalW = (kDotCount - 1) * kDotSpacing;
    CGFloat startX = centerX - totalW / 2.0;

    for (NSInteger i = 0; i < kDotCount; i++) {
        double phase = (double)(self.tick) * 0.15 - (double)i * 0.9;
        CGFloat bounce = (CGFloat)fmax(0.0, sin(phase));
        CGFloat r = kDotBaseRadius + bounce * 1.5;
        CGFloat alpha = 0.35 + 0.65 * bounce;
        CGFloat offsetY = bounce * 3.0;

        [[color colorWithAlphaComponent:alpha] setFill];
        CGFloat x = startX + i * kDotSpacing;
        NSRect dotRect = NSMakeRect(x - r, centerY - r + offsetY, r * 2, r * 2);
        [[NSBezierPath bezierPathWithOvalInRect:dotRect] fill];
    }
}

#pragma mark - Checkmark (pasting)

- (void)drawCheckmarkAtX:(CGFloat)centerX centerY:(CGFloat)centerY {
    NSColor *color = self.accentColor ?: [NSColor whiteColor];

    CGFloat progress = fmin(1.0, (CGFloat)self.tick / 12.0);

    NSPoint p0 = NSMakePoint(centerX - 6, centerY + 1);
    NSPoint p1 = NSMakePoint(centerX - 1.5, centerY - 4);
    NSPoint p2 = NSMakePoint(centerX + 7, centerY + 5);

    NSBezierPath *path = [NSBezierPath bezierPath];
    path.lineWidth = 2.0;
    path.lineCapStyle = NSLineCapStyleRound;
    path.lineJoinStyle = NSLineJoinStyleRound;

    if (progress <= 0.4) {
        CGFloat t = progress / 0.4;
        NSPoint end = NSMakePoint(p0.x + (p1.x - p0.x) * t, p0.y + (p1.y - p0.y) * t);
        [path moveToPoint:p0];
        [path lineToPoint:end];
    } else {
        CGFloat t = (progress - 0.4) / 0.6;
        NSPoint end = NSMakePoint(p1.x + (p2.x - p1.x) * t, p1.y + (p2.y - p1.y) * t);
        [path moveToPoint:p0];
        [path lineToPoint:p1];
        [path lineToPoint:end];
    }

    [[color colorWithAlphaComponent:0.95] setStroke];
    [path stroke];
}

#pragma mark - Cross (error)

- (void)drawCrossAtX:(CGFloat)centerX centerY:(CGFloat)centerY {
    NSColor *color = self.accentColor ?: [NSColor redColor];
    CGFloat arm = 5.0;

    NSBezierPath *path = [NSBezierPath bezierPath];
    path.lineWidth = 2.0;
    path.lineCapStyle = NSLineCapStyleRound;

    [path moveToPoint:NSMakePoint(centerX - arm, centerY - arm)];
    [path lineToPoint:NSMakePoint(centerX + arm, centerY + arm)];
    [path moveToPoint:NSMakePoint(centerX + arm, centerY - arm)];
    [path lineToPoint:NSMakePoint(centerX - arm, centerY + arm)];

    [[color colorWithAlphaComponent:0.95] setStroke];
    [path stroke];
}

@end

// ── Main overlay controller ──────────────────────────────

@interface SPOverlayPanel ()

@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) SPHoverEffectView *effectView;
@property (nonatomic, strong) SPOverlayContentView *contentView;
@property (nonatomic, strong) NSTimer *animationTimer;
@property (nonatomic, strong) NSTimer *lingerTimer;
@property (nonatomic, copy)   NSString *currentState;
@property (nonatomic, assign) CGFloat sessionMaxWidth;
@property (nonatomic, assign) CGFloat sessionMaxHeight;
@property (nonatomic, strong) NSArray<NSDictionary *> *templateButtons;
@property (nonatomic, strong) NSArray<NSNumber *> *templateShortcutNumbers;
@property (nonatomic, assign) BOOL showingTemplates;
@property (nonatomic, strong) SPKeyablePanel *buttonBarPanel;
@property (nonatomic, strong) NSMutableArray<NSButton *> *templateButtonViews;
@property (nonatomic, assign) BOOL mainPanelHovered;
@property (nonatomic, assign) BOOL templateBarHovered;
@property (nonatomic, assign) NSTimeInterval remainingLingerDuration;
@property (nonatomic, strong) NSDate *lingerDeadline;
@property (nonatomic, assign) CGFloat textFontSize;
@property (nonatomic, assign) CGFloat bottomMargin;
@property (nonatomic, copy) NSString *fontFamily;
@property (nonatomic, assign) CGFloat configuredTextFontSize;
@property (nonatomic, assign) CGFloat configuredBottomMargin;
@property (nonatomic, copy) NSString *configuredFontFamily;
@property (nonatomic, assign) BOOL limitVisibleLinesEnabled;
@property (nonatomic, assign) NSInteger maxVisibleLines;
@property (nonatomic, assign) BOOL configuredLimitVisibleLinesEnabled;
@property (nonatomic, assign) NSInteger configuredMaxVisibleLines;
@property (nonatomic, assign, getter=isPreviewActive) BOOL previewActive;
@property (nonatomic, strong) CAShapeLayer *recordingRippleLayer;

@end

@implementation SPOverlayPanel

- (instancetype)init {
    self = [super init];
    if (self) {
        _currentState = @"idle";
        _textFontSize = kDefaultTextFontSize;
        _bottomMargin = kDefaultBottomMargin;
        _fontFamily = kDefaultFontFamily;
        _configuredTextFontSize = kDefaultTextFontSize;
        _configuredBottomMargin = kDefaultBottomMargin;
        _configuredFontFamily = kDefaultFontFamily;
        _limitVisibleLinesEnabled = kDefaultLimitVisibleLines;
        _maxVisibleLines = kDefaultMaxVisibleLines;
        _configuredLimitVisibleLinesEnabled = kDefaultLimitVisibleLines;
        _configuredMaxVisibleLines = kDefaultMaxVisibleLines;
        [self setupPanel];
        [self reloadAppearanceFromConfig];
    }
    return self;
}

- (NSFont *)contentFont {
    return SPOverlayFontForFamily(self.fontFamily, self.textFontSize);
}

- (CGFloat)basePillHeight {
    NSFont *font = [self contentFont];
    CGFloat lineHeight = SPOverlayLineHeightForFont(font);
    return fmax(kMinimumPillHeight, lineHeight + SPOverlayTextTopPadForFont(font) + SPOverlayTextBottomPadForFont(font));
}

- (CGFloat)overlayCornerRadius {
    return floor(fmin(24.0, [self basePillHeight] / 2.0));
}

- (CGFloat)iconAreaWidth {
    return fmax(28.0, floor([self basePillHeight] * 0.78));
}

- (CGFloat)textVerticalPadding {
    NSFont *font = [self contentFont];
    return SPOverlayTextTopPadForFont(font) + SPOverlayTextBottomPadForFont(font);
}

- (void)updateContentAppearance {
    self.contentView.textFontSize = self.textFontSize;
    self.contentView.fontFamily = self.fontFamily;
    self.contentView.cornerRadius = [self overlayCornerRadius];
    self.contentView.iconAreaWidth = [self iconAreaWidth];
    self.contentView.layer.cornerRadius = [self overlayCornerRadius];
    self.contentView.layer.masksToBounds = YES;
    [self.contentView updateTextAttributes];
    [self.contentView setNeedsLayout:YES];
}

- (void)clearRecordingRippleIfNeeded {
    [self.recordingRippleLayer removeAllAnimations];
    [self.recordingRippleLayer removeFromSuperlayer];
    self.recordingRippleLayer = nil;
}

- (void)resetMotionPresentationState {
    [self.contentView.layer removeAnimationForKey:@"overlayContentEntrance"];
    [self.contentView.layer removeAnimationForKey:@"overlayContentExit"];
    [self.effectView.layer removeAnimationForKey:@"overlayShadowEntrance"];
    [self.effectView.layer removeAnimationForKey:@"overlayShadowExit"];
    self.contentView.layer.transform = CATransform3DIdentity;
    self.contentView.layer.opacity = 1.0;
    self.effectView.layer.shadowOpacity = kBaseShadowOpacity;
    self.effectView.layer.shadowRadius = kBaseShadowRadius;
}

- (void)animateContentLayerFromTransform:(CATransform3D)fromTransform
                             toTransform:(CATransform3D)toTransform
                             fromOpacity:(CGFloat)fromOpacity
                               toOpacity:(CGFloat)toOpacity
                                duration:(CFTimeInterval)duration
                               animation:(NSString *)animationKey {
    if (!self.contentView.layer) return;

    [self.contentView.layer removeAnimationForKey:animationKey];
    self.contentView.layer.transform = toTransform;
    self.contentView.layer.opacity = toOpacity;

    CABasicAnimation *transformAnimation = [CABasicAnimation animationWithKeyPath:@"transform"];
    transformAnimation.fromValue = [NSValue valueWithCATransform3D:fromTransform];
    transformAnimation.toValue = [NSValue valueWithCATransform3D:toTransform];

    CABasicAnimation *opacityAnimation = [CABasicAnimation animationWithKeyPath:@"opacity"];
    opacityAnimation.fromValue = @(fromOpacity);
    opacityAnimation.toValue = @(toOpacity);

    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[transformAnimation, opacityAnimation];
    group.duration = duration;
    group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [self.contentView.layer addAnimation:group forKey:animationKey];
}

- (void)animateShadowFromOpacity:(CGFloat)fromOpacity
                       toOpacity:(CGFloat)toOpacity
                      fromRadius:(CGFloat)fromRadius
                        toRadius:(CGFloat)toRadius
                        duration:(CFTimeInterval)duration
                       animation:(NSString *)animationKey {
    if (!self.effectView.layer) return;

    [self.effectView.layer removeAnimationForKey:animationKey];
    self.effectView.layer.shadowOpacity = toOpacity;
    self.effectView.layer.shadowRadius = toRadius;

    CABasicAnimation *opacityAnimation = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
    opacityAnimation.fromValue = @(fromOpacity);
    opacityAnimation.toValue = @(toOpacity);

    CABasicAnimation *radiusAnimation = [CABasicAnimation animationWithKeyPath:@"shadowRadius"];
    radiusAnimation.fromValue = @(fromRadius);
    radiusAnimation.toValue = @(toRadius);

    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[opacityAnimation, radiusAnimation];
    group.duration = duration;
    group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [self.effectView.layer addAnimation:group forKey:animationKey];
}

- (void)playRecordingRippleIfNeeded {
    if (SPOverlayShouldReduceMotion()) return;
    if (![self.currentState hasPrefix:@"recording"]) return;
    if (!self.contentView.layer) return;

    [self clearRecordingRippleIfNeeded];

    CGFloat maxRadius = fmax(22.0, [self basePillHeight] * 0.72);
    CGFloat baseRadius = maxRadius * 0.34;
    CGFloat centerX = SPOverlayHorizontalPadForFont([self contentFont]) + [self iconAreaWidth] / 2.0;
    CGFloat centerY = NSMidY(self.contentView.bounds);

    CAShapeLayer *ringLayer = [CAShapeLayer layer];
    ringLayer.bounds = CGRectMake(0, 0, maxRadius * 2.0, maxRadius * 2.0);
    ringLayer.position = CGPointMake(centerX, centerY);
    CGPathRef ringPath = CGPathCreateWithEllipseInRect(CGRectInset(ringLayer.bounds, 1.0, 1.0), NULL);
    ringLayer.path = ringPath;
    CGPathRelease(ringPath);
    ringLayer.fillColor = NSColor.clearColor.CGColor;
    ringLayer.strokeColor = [NSColor colorWithWhite:1.0 alpha:0.20].CGColor;
    ringLayer.lineWidth = 1.3;
    ringLayer.opacity = 0.0;
    self.recordingRippleLayer = ringLayer;
    [self.contentView.layer addSublayer:ringLayer];

    CABasicAnimation *scaleAnimation = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    scaleAnimation.fromValue = @(baseRadius / maxRadius);
    scaleAnimation.toValue = @1.0;

    CAKeyframeAnimation *opacityAnimation = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    opacityAnimation.values = @[@0.0, @0.22, @0.0];
    opacityAnimation.keyTimes = @[@0.0, @0.3, @1.0];

    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[scaleAnimation, opacityAnimation];
    group.duration = kRippleDuration;
    group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    group.removedOnCompletion = YES;
    [ringLayer addAnimation:group forKey:@"recordingRipple"];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kRippleDuration + 0.05) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.recordingRippleLayer == ringLayer) {
            [self clearRecordingRippleIfNeeded];
        } else {
            [ringLayer removeFromSuperlayer];
        }
    });
}

- (NSString *)currentDisplayText {
    return (self.contentView.interimText.length > 0) ? self.contentView.interimText : self.contentView.statusText;
}

- (BOOL)shouldUseScrollingTranscriptLayout {
    return self.limitVisibleLinesEnabled && self.contentView.interimText.length > 0;
}

- (NSInteger)visibleLineLimitForCurrentState {
    return SPOverlayClampMaxVisibleLines(self.maxVisibleLines);
}

- (void)applyAppearanceWithFontSize:(CGFloat)fontSize
                         fontFamily:(NSString *)fontFamily
                       bottomMargin:(CGFloat)bottomMargin
                  limitVisibleLines:(BOOL)limitVisibleLines
                    maxVisibleLines:(NSInteger)maxVisibleLines
                resetSessionMetrics:(BOOL)resetMetrics {
    self.textFontSize = SPOverlayClampTextFontSize(fontSize);
    self.bottomMargin = SPOverlayClampBottomMargin(bottomMargin);
    self.fontFamily = SPOverlayNormalizeFontFamily(fontFamily);
    self.limitVisibleLinesEnabled = limitVisibleLines;
    self.maxVisibleLines = SPOverlayClampMaxVisibleLines(maxVisibleLines);
    [self updateContentAppearance];
    if (resetMetrics) {
        self.sessionMaxWidth = 0;
        self.sessionMaxHeight = 0;
    }
}

- (void)restoreConfiguredAppearanceIfNeeded {
    if (!self.isPreviewActive) return;
    self.previewActive = NO;
    [self applyAppearanceWithFontSize:self.configuredTextFontSize
                           fontFamily:self.configuredFontFamily
                         bottomMargin:self.configuredBottomMargin
                   limitVisibleLines:self.configuredLimitVisibleLinesEnabled
                     maxVisibleLines:self.configuredMaxVisibleLines
                  resetSessionMetrics:YES];
}

- (void)updateMainPanelMaskForHeight:(CGFloat)height {
    if (!self.effectView) return;

    CGFloat cornerRadius = [self overlayCornerRadius];
    CGFloat maskHeight = fmax(height, [self basePillHeight]);
    NSImage *mask = [NSImage imageWithSize:NSMakeSize(cornerRadius * 2 + 1, maskHeight)
                                   flipped:NO
                            drawingHandler:^BOOL(NSRect dstRect) {
        [[NSColor blackColor] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:dstRect
                                         xRadius:cornerRadius
                                         yRadius:cornerRadius] fill];
        return YES;
    }];
    mask.capInsets = NSEdgeInsetsMake(cornerRadius, cornerRadius, cornerRadius, cornerRadius);
    mask.resizingMode = NSImageResizingModeStretch;
    self.effectView.maskImage = mask;
}

- (void)repositionTemplateBarAnimated:(BOOL)animated {
    if (!self.buttonBarPanel) return;

    NSRect pillFrame = self.panel.frame;
    NSRect barFrame = self.buttonBarPanel.frame;
    NSRect newFrame = NSMakeRect(NSMidX(pillFrame) - barFrame.size.width / 2.0,
                                 NSMaxY(pillFrame) + 6.0,
                                 barFrame.size.width,
                                 barFrame.size.height);
    if (animated) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = kResizeDuration;
            [[self.buttonBarPanel animator] setFrame:newFrame display:YES];
        }];
    } else {
        [self.buttonBarPanel setFrame:newFrame display:YES];
    }
}

- (void)setupPanel {
    NSRect rect = NSMakeRect(0, 0, 180, [self basePillHeight]);

    NSPanel *panel = [[NSPanel alloc] initWithContentRect:rect
                                                 styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                   backing:NSBackingStoreBuffered
                                                     defer:YES];
    panel.level = NSStatusWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorStationary |
                               NSWindowCollectionBehaviorFullScreenAuxiliary;
    panel.backgroundColor = [NSColor clearColor];
    panel.opaque = NO;
    panel.hasShadow = NO;
    panel.ignoresMouseEvents = YES;
    panel.hidesOnDeactivate = NO;
    panel.alphaValue = 0.0;

    // Visual effect background (HUD material for contrast on any desktop)
    SPHoverEffectView *effectView = [[SPHoverEffectView alloc] initWithFrame:rect];
    effectView.material     = NSVisualEffectMaterialHUDWindow;
    effectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    effectView.state        = NSVisualEffectStateActive;
    effectView.appearance   = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    effectView.wantsLayer   = YES;
    effectView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    __weak typeof(self) weakSelf = self;
    effectView.hoverChangedHandler = ^(BOOL hovering) {
        [weakSelf setMainPanelHovered:hovering];
    };

    // Light glow shadow (visible on dark backgrounds)
    effectView.layer.shadowColor   = SPOverlayShadowColor().CGColor;
    effectView.layer.shadowOpacity = kBaseShadowOpacity;
    effectView.layer.shadowRadius  = kBaseShadowRadius;
    effectView.layer.shadowOffset  = CGSizeMake(0, -1.0);

    panel.contentView = effectView;
    self.effectView = effectView;

    // Content drawn on top of the effect view
    self.contentView = [[SPOverlayContentView alloc] initWithFrame:rect];
    self.contentView.wantsLayer = YES;
    self.contentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [effectView addSubview:self.contentView];
    [self updateContentAppearance];
    [self updateMainPanelMaskForHeight:rect.size.height];

    self.panel = panel;
}

- (void)setMainPanelInteractive:(BOOL)interactive {
    self.panel.ignoresMouseEvents = !interactive;
}

- (BOOL)isHoveringOverlay {
    return self.mainPanelHovered || self.templateBarHovered;
}

- (void)clearLingerTimer {
    [self.lingerTimer invalidate];
    self.lingerTimer = nil;
    self.lingerDeadline = nil;
    self.remainingLingerDuration = 0;
}

- (void)updateLingerTimerForHoverState {
    if (self.showingTemplates == NO && self.currentState != nil &&
        ([self.currentState isEqualToString:@"idle"] || [self.currentState isEqualToString:@"completed"])) {
        return;
    }

    if ([self isHoveringOverlay]) {
        if (self.lingerTimer && self.lingerDeadline) {
            self.remainingLingerDuration = fmax(0.1, [self.lingerDeadline timeIntervalSinceNow]);
            [self.lingerTimer invalidate];
            self.lingerTimer = nil;
            self.lingerDeadline = nil;
        }
        return;
    }

    if (!self.lingerTimer && self.remainingLingerDuration > 0) {
        [self scheduleDismissAfter:self.remainingLingerDuration];
    }
}

- (void)setMainPanelHovered:(BOOL)mainPanelHovered {
    _mainPanelHovered = mainPanelHovered;
    [self updateLingerTimerForHoverState];
}

- (void)setTemplateBarHovered:(BOOL)templateBarHovered {
    _templateBarHovered = templateBarHovered;
    [self updateLingerTimerForHoverState];
}

- (void)dismissToIdle {
    [self clearLingerTimer];
    self.sessionMaxWidth = 0;
    self.sessionMaxHeight = 0;
    self.currentState = @"idle";
    [self hide];
}

- (void)scheduleDismissAfter:(NSTimeInterval)duration {
    [self.lingerTimer invalidate];
    self.lingerTimer = nil;

    self.remainingLingerDuration = duration;
    self.lingerDeadline = [NSDate dateWithTimeIntervalSinceNow:duration];

    __weak typeof(self) weakSelf = self;
    self.lingerTimer = [NSTimer scheduledTimerWithTimeInterval:duration
                                                       repeats:NO
                                                         block:^(NSTimer *timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.lingerTimer = nil;
        strongSelf.lingerDeadline = nil;
        strongSelf.remainingLingerDuration = 0;
        [strongSelf dismissToIdle];
    }];
}

#pragma mark - Public

- (void)updateState:(NSString *)state {
    BOOL isPreviewState = [state hasSuffix:@"_preview"];
    if (self.isPreviewActive && !isPreviewState) {
        [self restoreConfiguredAppearanceIfNeeded];
    }

    // Cancel any pending linger dismiss from a previous session
    [self clearLingerTimer];
    [self setMainPanelInteractive:NO];
    self.mainPanelHovered = NO;
    self.templateBarHovered = NO;

    self.currentState = state;
    [self stopAnimation];

    // Only clear display text when starting a new recording session
    if ([state hasPrefix:@"recording"]) {
        self.contentView.interimText = nil;
    }

    if ([state isEqualToString:@"idle"] || [state isEqualToString:@"completed"]) {
        self.sessionMaxWidth = 0;
        self.sessionMaxHeight = 0;
        [self hide];
        return;
    }

    NSString *text;
    NSColor *accent;
    SPOverlayMode mode;

    if ([state hasPrefix:@"recording"]) {
        self.sessionMaxWidth = 0;
        self.sessionMaxHeight = 0;
        text   = @"Listening…";
        accent = [NSColor colorWithRed:1.0 green:0.32 blue:0.32 alpha:1.0];
        mode   = SPOverlayModeWaveform;
    } else if ([state hasPrefix:@"connecting_asr"]) {
        text   = @"Connecting…";
        accent = [NSColor colorWithRed:1.0 green:0.78 blue:0.28 alpha:1.0];
        mode   = SPOverlayModeProcessing;
    } else if ([state hasPrefix:@"finalizing_asr"]) {
        text   = @"Recognizing…";
        accent = [NSColor colorWithRed:0.35 green:0.78 blue:1.0 alpha:1.0];
        mode   = SPOverlayModeProcessing;
    } else if ([state isEqualToString:@"correcting"]) {
        text   = @"Thinking…";
        accent = [NSColor colorWithRed:0.55 green:0.6 blue:1.0 alpha:1.0];
        mode   = SPOverlayModeProcessing;
    } else if ([state hasPrefix:@"preparing_paste"] || [state isEqualToString:@"pasting"]) {
        text   = @"Pasting…";
        accent = [NSColor colorWithRed:0.3 green:0.85 blue:0.45 alpha:1.0];
        mode   = SPOverlayModeSuccess;
    } else if ([state isEqualToString:@"error"] || [state isEqualToString:@"failed"]) {
        text   = @"Error";
        accent = [NSColor colorWithRed:1.0 green:0.32 blue:0.32 alpha:1.0];
        mode   = SPOverlayModeError;
    } else {
        text   = @"Working…";
        accent = [NSColor colorWithRed:0.35 green:0.78 blue:1.0 alpha:1.0];
        mode   = SPOverlayModeProcessing;
    }

    self.contentView.statusText  = text;
    self.contentView.accentColor = accent;
    self.contentView.mode        = mode;
    self.contentView.tick        = 0;
    [self resizeAndCenterAnimated:NO];
    [self.contentView setNeedsDisplay:YES];
    [self show];
    [self startAnimation];
}

- (void)updateInterimText:(NSString *)text {
    if (![self.currentState hasPrefix:@"recording"]) return;
    self.contentView.interimText = text;
    [self resizeAndCenterAnimated:YES];
    [self.contentView setNeedsDisplay:YES];
}

- (void)updateDisplayText:(NSString *)text {
    self.contentView.interimText = text;
    [self setMainPanelInteractive:YES];
    [self resizeAndCenterAnimated:YES];
    [self.contentView setNeedsDisplay:YES];
}

- (void)reloadAppearanceFromConfig {
    NSString *configuredFontFamily = SPOverlayConfigString("overlay.font_family", kDefaultFontFamily);
    CGFloat configuredFontSize = SPOverlayConfigCGFloat("overlay.font_size", kDefaultTextFontSize);
    CGFloat configuredBottomMargin = SPOverlayConfigCGFloat("overlay.bottom_margin", kDefaultBottomMargin);
    BOOL configuredLimitVisibleLinesEnabled = SPOverlayConfigBOOL("overlay.limit_visible_lines", kDefaultLimitVisibleLines);
    NSInteger configuredMaxVisibleLines = SPOverlayClampMaxVisibleLines(lround(SPOverlayConfigCGFloat("overlay.max_visible_lines", kDefaultMaxVisibleLines)));

    self.configuredFontFamily = SPOverlayNormalizeFontFamily(configuredFontFamily);
    self.configuredTextFontSize = SPOverlayClampTextFontSize(configuredFontSize);
    self.configuredBottomMargin = SPOverlayClampBottomMargin(configuredBottomMargin);
    self.configuredLimitVisibleLinesEnabled = configuredLimitVisibleLinesEnabled;
    self.configuredMaxVisibleLines = configuredMaxVisibleLines;

    if (!self.isPreviewActive) {
        [self applyAppearanceWithFontSize:self.configuredTextFontSize
                               fontFamily:self.configuredFontFamily
                             bottomMargin:self.configuredBottomMargin
                       limitVisibleLines:self.configuredLimitVisibleLinesEnabled
                         maxVisibleLines:self.configuredMaxVisibleLines
                      resetSessionMetrics:YES];
        [self resizeAndCenterAnimated:NO];
        [self.contentView setNeedsDisplay:YES];
        [self repositionTemplateBarAnimated:NO];
    }
}

- (void)showPreviewWithText:(NSString *)text
                   fontSize:(CGFloat)fontSize
                 fontFamily:(NSString *)fontFamily
               bottomMargin:(CGFloat)bottomMargin
          limitVisibleLines:(BOOL)limitVisibleLines
            maxVisibleLines:(NSInteger)maxVisibleLines {
    if (!self.isPreviewActive &&
        self.currentState.length > 0 &&
        ![self.currentState isEqualToString:@"idle"] &&
        ![self.currentState isEqualToString:@"completed"]) {
        return;
    }

    self.previewActive = YES;
    [self hideTemplateButtons];
    [self applyAppearanceWithFontSize:fontSize
                           fontFamily:fontFamily
                         bottomMargin:bottomMargin
                   limitVisibleLines:limitVisibleLines
                     maxVisibleLines:maxVisibleLines
                  resetSessionMetrics:YES];
    [self updateState:@"recording_preview"];
    [self updateInterimText:text ?: @""];
}

- (void)hidePreview {
    if (!self.isPreviewActive) return;

    [self clearLingerTimer];
    [self hideTemplateButtons];
    [self setMainPanelInteractive:NO];
    self.mainPanelHovered = NO;
    self.templateBarHovered = NO;
    self.contentView.interimText = nil;
    [self restoreConfiguredAppearanceIfNeeded];
    self.currentState = @"idle";
    [self hide];
}

- (void)lingerAndDismiss {
    [self clearLingerTimer];
    [self setMainPanelInteractive:YES];

    // Keep the confirmation short by default, but allow hover to pin it.
    NSString *displayText = self.contentView.interimText ?: self.contentView.statusText ?: @"";
    NSUInteger charCount = displayText.length;
    NSTimeInterval linger = fmin(fmax(charCount * 0.015, kMinLingerDuration), kMaxLingerDuration);
    self.remainingLingerDuration = linger;
    if (![self isHoveringOverlay]) {
        [self scheduleDismissAfter:linger];
    }
}

- (NSArray<NSNumber *> *)resolvedShortcutNumbersForTemplates:(NSArray<NSDictionary *> *)templates {
    NSMutableArray<NSNumber *> *resolved = [NSMutableArray arrayWithCapacity:templates.count];
    NSMutableSet<NSNumber *> *used = [NSMutableSet set];

    for (NSDictionary *tmpl in templates) {
        NSNumber *shortcut = [tmpl[@"shortcut"] isKindOfClass:[NSNumber class]] ? tmpl[@"shortcut"] : nil;
        NSInteger value = shortcut.integerValue;
        if (shortcut && value >= 1 && value <= 9 && ![used containsObject:shortcut]) {
            [resolved addObject:@(value)];
            [used addObject:@(value)];
        } else {
            [resolved addObject:@0];
        }
    }

    NSInteger nextShortcut = 1;
    for (NSUInteger i = 0; i < resolved.count; i++) {
        if (resolved[i].integerValue > 0) continue;
        while (nextShortcut <= 9 && [used containsObject:@(nextShortcut)]) {
            nextShortcut += 1;
        }
        if (nextShortcut > 9) break;
        resolved[i] = @(nextShortcut);
        [used addObject:@(nextShortcut)];
    }

    return resolved;
}

- (void)showTemplateButtons:(NSArray<NSDictionary *> *)templates {
    if (templates.count == 0) return;
    self.templateButtons = templates;
    self.templateShortcutNumbers = [self resolvedShortcutNumbersForTemplates:templates];
    self.showingTemplates = YES;
    self.templateBarHovered = NO;
    [self setMainPanelInteractive:YES];

    // Remove old button bar
    [self.buttonBarPanel orderOut:nil];
    self.buttonBarPanel = nil;
    self.templateButtonViews = nil;

    // Calculate button sizes using only the template label.
    CGFloat btnH = 26;
    CGFloat btnSpacing = 8;
    CGFloat barPad = 6;
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
    };

    CGFloat totalW = 0;
    NSMutableArray<NSNumber *> *widths = [NSMutableArray array];
    for (NSUInteger i = 0; i < templates.count; i++) {
        NSDictionary *tmpl = templates[i];
        NSString *label = tmpl[@"name"] ?: @"";
        CGFloat w = [label sizeWithAttributes:attrs].width + 24;
        w = fmax(w, 60); // minimum button width
        [widths addObject:@(w)];
        totalW += w;
    }
    totalW += (templates.count - 1) * btnSpacing + 2 * barPad;
    CGFloat barH = btnH + 2 * barPad;

    // Create button bar panel (SPKeyablePanel to receive keyboard events)
    SPKeyablePanel *bar = [[SPKeyablePanel alloc] initWithContentRect:NSMakeRect(0, 0, totalW, barH)
                                                            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                              backing:NSBackingStoreBuffered
                                                                defer:YES];
    bar.level = NSStatusWindowLevel;
    bar.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                             NSWindowCollectionBehaviorStationary |
                             NSWindowCollectionBehaviorFullScreenAuxiliary;
    bar.backgroundColor = [NSColor clearColor];
    bar.opaque = NO;
    bar.hasShadow = NO;
    bar.ignoresMouseEvents = NO;
    bar.hidesOnDeactivate = NO;

    // Background with vibrancy
    SPHoverEffectView *bgView = [[SPHoverEffectView alloc] initWithFrame:NSMakeRect(0, 0, totalW, barH)];
    bgView.material = NSVisualEffectMaterialHUDWindow;
    bgView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    bgView.state = NSVisualEffectStateActive;
    bgView.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    bgView.wantsLayer = YES;
    __weak typeof(self) weakSelf = self;
    bgView.hoverChangedHandler = ^(BOOL hovering) {
        [weakSelf setTemplateBarHovered:hovering];
    };

    // Pill shape mask for button bar
    CGFloat cornerR = barH / 2.0;
    NSImage *mask = [NSImage imageWithSize:NSMakeSize(cornerR * 2 + 1, barH)
                                   flipped:NO
                            drawingHandler:^BOOL(NSRect dstRect) {
        [[NSColor blackColor] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:dstRect xRadius:cornerR yRadius:cornerR] fill];
        return YES;
    }];
    mask.capInsets = NSEdgeInsetsMake(cornerR, cornerR, cornerR, cornerR);
    mask.resizingMode = NSImageResizingModeStretch;
    bgView.maskImage = mask;

    // Glow shadow (match main pill)
    bgView.layer.shadowColor = SPOverlayShadowColor().CGColor;
    bgView.layer.shadowOpacity = kBaseShadowOpacity;
    bgView.layer.shadowRadius = kBaseShadowRadius;
    bgView.layer.shadowOffset = CGSizeMake(0, -1.0);

    bar.contentView = bgView;

    // Dark tint overlay (match main pill contrast)
    NSView *tintView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, totalW, barH)];
    tintView.wantsLayer = YES;
    tintView.layer.backgroundColor = SPOverlaySurfaceTintColor().CGColor;
    tintView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [bgView addSubview:tintView];

    // Add buttons (borderless, plain text style)
    self.templateButtonViews = [NSMutableArray array];
    CGFloat x = barPad;
    for (NSUInteger i = 0; i < templates.count; i++) {
        NSDictionary *tmpl = templates[i];
        NSString *label = tmpl[@"name"] ?: @"";
        CGFloat w = [widths[i] floatValue];

        SPTemplateButton *btn = [[SPTemplateButton alloc] initWithFrame:NSMakeRect(x, barPad, w, btnH)];
        btn.title = label;
        btn.bordered = NO;
        btn.focusRingType = NSFocusRingTypeNone;
        btn.wantsLayer = YES;
        btn.layer.cornerRadius = btnH / 2.0;
        btn.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        btn.tag = (NSInteger)i;
        btn.target = self;
        btn.action = @selector(templateButtonClicked:);
        [btn applyCurrentAppearance];
        [bgView addSubview:btn];
        [self.templateButtonViews addObject:btn];

        x += w + btnSpacing;
    }

    // Position above the main pill with 6pt gap
    NSRect pillFrame = self.panel.frame;
    CGFloat barX = NSMidX(pillFrame) - totalW / 2.0;
    CGFloat barY = NSMaxY(pillFrame) + 6;
    [bar setFrame:NSMakeRect(barX, barY, totalW, barH) display:YES];

    // Fade in
    bar.alphaValue = 0.0;
    [bar orderFrontRegardless];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.2;
        bar.animator.alphaValue = 1.0;
    }];

    self.buttonBarPanel = bar;

    // Set up keyboard handler for future consumers that choose to focus the bar explicitly.
    bar.keyHandler = ^(NSInteger number) {
        [weakSelf handleNumberKey:number];
    };

    // Keep the template bar around a bit longer, and pause auto-dismiss while hovered.
    [self clearLingerTimer];
    self.remainingLingerDuration = kTemplateLingerDuration;
    if (![self isHoveringOverlay]) {
        [self scheduleDismissAfter:kTemplateLingerDuration];
    }
}

- (void)templateButtonClicked:(NSButton *)sender {
    NSInteger index = sender.tag;
    [self highlightButtonAtIndex:index thenDismiss:YES];
}

- (void)hideTemplateButtons {
    self.showingTemplates = NO;
    self.templateButtons = nil;
    self.templateShortcutNumbers = nil;
    self.templateButtonViews = nil;
    self.templateBarHovered = NO;
    if (self.buttonBarPanel) {
        NSPanel *barToHide = self.buttonBarPanel;
        self.buttonBarPanel = nil;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.2;
            barToHide.animator.alphaValue = 0.0;
        } completionHandler:^{
            [barToHide orderOut:nil];
        }];
    }
}

- (BOOL)handleNumberKey:(NSInteger)number {
    if (!self.showingTemplates || !self.templateButtons) return NO;
    for (NSUInteger i = 0; i < self.templateButtons.count; i++) {
        NSInteger shortcut = i < self.templateShortcutNumbers.count ? self.templateShortcutNumbers[i].integerValue : 0;
        if (shortcut == number) {
            [self highlightButtonAtIndex:(NSInteger)i thenDismiss:YES];
            return YES;
        }
    }
    return NO;
}

/// Smoothly highlight a button, then trigger the delegate.
- (void)highlightButtonAtIndex:(NSInteger)index thenDismiss:(BOOL)dismiss {
    if (index < 0 || index >= (NSInteger)self.templateButtonViews.count) return;

    NSButton *btn = self.templateButtonViews[index];
    NSDictionary *templateData = index < (NSInteger)self.templateButtons.count ? self.templateButtons[index] : nil;
    NSNumber *sourceIndex = [templateData[@"source_index"] isKindOfClass:[NSNumber class]] ? templateData[@"source_index"] : nil;
    NSInteger templateIndex = sourceIndex != nil ? sourceIndex.integerValue : index;

    // Dim all other buttons, brighten selected one
    for (NSButton *b in self.templateButtonViews) {
        b.alphaValue = (b == btn) ? 1.0 : 0.3;
    }
    for (NSButton *button in self.templateButtonViews) {
        if ([button isKindOfClass:[SPTemplateButton class]]) {
            ((SPTemplateButton *)button).emphasized = (button == btn);
        }
    }

    // Brief hold then dismiss
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self hideTemplateButtons];
        [self.delegate overlayPanel:self didSelectTemplateAtIndex:templateIndex];
    });
}

#pragma mark - Layout

- (void)resizeAndCenterAnimated:(BOOL)animated {
    NSFont *font = [self contentFont];
    NSDictionary *attrs = @{
        NSFontAttributeName: font,
    };
    NSString *displayText = [self currentDisplayText];
    NSAttributedString *str = [[NSAttributedString alloc] initWithString:displayText ?: @"" attributes:attrs];

    CGFloat horizontalPad = SPOverlayHorizontalPadForFont(font);
    CGFloat iconGap = SPOverlayIconTextGapForFont(font);
    CGFloat trailingPad = SPOverlayTextTrailingPadForFont(font);
    CGFloat iconSpace = horizontalPad + [self iconAreaWidth] + iconGap;

    // 1. Determine natural single-line width
    CGFloat naturalW = [str size].width;
    CGFloat desiredW = iconSpace + naturalW + trailingPad;

    // 2. Clamp to screen/max limits
    NSScreen *screen = [NSScreen mainScreen];
    NSRect visible = screen.visibleFrame;
    CGFloat absoluteMaxW = fmin(kMaxWidth, visible.size.width - 2 * kScreenHorizontalMargin);

    CGFloat pillW = desiredW;
    CGFloat pillH = [self basePillHeight];
    CGFloat lineHeight = SPOverlayLineHeightForFont(font);
    CGFloat textViewportHeight = lineHeight;
    BOOL usesScrollingTranscriptLayout = [self shouldUseScrollingTranscriptLayout];
    BOOL shouldStabilizeWidth = animated && self.sessionMaxWidth > 0;
    BOOL shouldStabilizeHeight = animated && usesScrollingTranscriptLayout && self.sessionMaxHeight > 0;

    if (displayText.length > 0) {
        pillW = fmin(MAX(desiredW, iconSpace + 120.0), absoluteMaxW);

        // Keep width monotonic during a live session first, then measure height
        // using that final width so we don't preserve a stale tall layout.
        if (shouldStabilizeWidth) {
            pillW = fmax(pillW, self.sessionMaxWidth);
        }

        CGFloat textMaxW = fmax(1.0, pillW - iconSpace - trailingPad);
        CGFloat measuredTextHeight = SPOverlayMeasureTextHeight(displayText, font, textMaxW);

        if (usesScrollingTranscriptLayout) {
            CGFloat maxVisibleTextHeight = SPOverlayMeasureVisibleHeightForLineLimit(displayText,
                                                                                    font,
                                                                                    textMaxW,
                                                                                    [self visibleLineLimitForCurrentState]) + SPOverlayLineLimitSlackForFont(font);
            textViewportHeight = fmin(fmax(lineHeight, measuredTextHeight), maxVisibleTextHeight);
        } else {
            textViewportHeight = fmax(lineHeight, measuredTextHeight);
        }

        pillH = fmax([self basePillHeight], ceil(textViewportHeight) + [self textVerticalPadding]);
    }

    // 3. Stabilization: only keep height monotonic when line limiting is enabled.
    if (shouldStabilizeHeight) {
        pillH = fmax(pillH, self.sessionMaxHeight);
    }
    
    if (animated) {
        self.sessionMaxWidth = pillW;
        self.sessionMaxHeight = usesScrollingTranscriptLayout ? pillH : 0;
    }

    // 4. Update internal layout width to prevent wrapping mid-animation
    self.contentView.layoutWidth = pillW;
    self.contentView.textViewportHeight = textViewportHeight;
    [self updateMainPanelMaskForHeight:pillH];
    [self.contentView refreshDisplayedTextAnimated:animated];

    // 5. Final Frame
    CGFloat x = NSMidX(visible) - pillW / 2.0;
    CGFloat y = NSMinY(visible) + self.bottomMargin;
    NSRect newFrame = NSMakeRect(x, y, pillW, pillH);

    if (animated) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = kResizeDuration;
            ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            [[self.panel animator] setFrame:newFrame display:YES];
        }];
        [self repositionTemplateBarAnimated:YES];
    } else {
        [self.panel setFrame:newFrame display:YES];
        [self repositionTemplateBarAnimated:NO];
    }
}

#pragma mark - Show / Hide

- (void)show {
    BOOL wasVisible = self.panel.isVisible && self.panel.alphaValue > 0.01;
    [self resetMotionPresentationState];
    [self.panel orderFrontRegardless];

    if (wasVisible || SPOverlayShouldReduceMotion()) {
        if (!wasVisible) {
            self.panel.alphaValue = 0.0;
        }
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = SPOverlayShouldReduceMotion() ? kFadeInDuration : 0.12;
            ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            self.panel.animator.alphaValue = 1.0;
        }];
        return;
    }

    NSRect finalFrame = self.panel.frame;
    NSRect startFrame = SPOverlayPresentationStartFrame(finalFrame);
    [self.panel setFrame:startFrame display:YES];
    self.panel.alphaValue = 0.0;

    CATransform3D startTransform = CATransform3DMakeScale(0.982, 0.982, 1.0);
    startTransform = CATransform3DTranslate(startTransform, 0.0, -6.0, 0.0);
    [self animateContentLayerFromTransform:startTransform
                               toTransform:CATransform3DIdentity
                               fromOpacity:0.94
                                 toOpacity:1.0
                                  duration:kPanelEntranceDuration
                                 animation:@"overlayContentEntrance"];
    [self animateShadowFromOpacity:0.05
                         toOpacity:kEntranceShadowOpacity
                        fromRadius:2.0
                          toRadius:kEntranceShadowRadius
                          duration:kPanelEntranceDuration
                         animation:@"overlayShadowEntrance"];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kPanelEntranceDuration * 0.55) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self.panel.isVisible || self.panel.alphaValue <= 0.0) return;
        [self animateShadowFromOpacity:kEntranceShadowOpacity
                             toOpacity:kBaseShadowOpacity
                            fromRadius:kEntranceShadowRadius
                              toRadius:kBaseShadowRadius
                              duration:0.18
                             animation:@"overlayShadowEntranceSettle"];
    });

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = kPanelEntranceDuration;
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [[self.panel animator] setFrame:finalFrame display:YES];
        self.panel.animator.alphaValue = 1.0;
    }];
    [self playRecordingRippleIfNeeded];
}

- (void)hide {
    [self hideTemplateButtons];
    [self stopAnimation];
    [self setMainPanelInteractive:NO];

    if (!self.panel.isVisible || self.panel.alphaValue <= 0.01) {
        [self.panel orderOut:nil];
        return;
    }

    [self clearRecordingRippleIfNeeded];

    NSRect currentFrame = self.panel.frame;
    BOOL reduceMotion = SPOverlayShouldReduceMotion();
    NSRect endFrame = reduceMotion ? currentFrame : SPOverlayDismissalEndFrame(currentFrame);

    if (!reduceMotion) {
        CATransform3D endTransform = CATransform3DMakeScale(0.992, 0.992, 1.0);
        endTransform = CATransform3DTranslate(endTransform, 0.0, -4.0, 0.0);
        [self animateContentLayerFromTransform:CATransform3DIdentity
                                   toTransform:endTransform
                                   fromOpacity:1.0
                                     toOpacity:0.96
                                      duration:kPanelExitDuration
                                     animation:@"overlayContentExit"];
        [self animateShadowFromOpacity:kBaseShadowOpacity
                             toOpacity:0.04
                            fromRadius:kBaseShadowRadius
                              toRadius:2.0
                              duration:kPanelExitDuration
                             animation:@"overlayShadowExit"];
    }

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = reduceMotion ? kFadeOutDuration : kPanelExitDuration;
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [[self.panel animator] setFrame:endFrame display:YES];
        self.panel.animator.alphaValue = 0.0;
    } completionHandler:^{
        [self resetMotionPresentationState];
        if ([self.currentState isEqualToString:@"idle"] || [self.currentState isEqualToString:@"completed"]) {
            [self.panel orderOut:nil];
        }
    }];
}

#pragma mark - Animation Timer

- (void)startAnimation {
    self.contentView.tick = 0;
    self.animationTimer = [NSTimer scheduledTimerWithTimeInterval:kAnimInterval
                                                         repeats:YES
                                                           block:^(NSTimer *timer) {
        self.contentView.tick++;
        [self.contentView setNeedsDisplay:YES];
    }];
}

- (void)stopAnimation {
    [self.animationTimer invalidate];
    self.animationTimer = nil;
}

- (void)dealloc {
    [self stopAnimation];
}

@end
