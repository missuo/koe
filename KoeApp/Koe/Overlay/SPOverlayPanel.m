#import "SPOverlayPanel.h"
#import <QuartzCore/QuartzCore.h>

// ── Geometry ──────────────────────────────────────────────
static const CGFloat kPillHeight       = 36.0;
static const CGFloat kPillCornerRadius = 18.0;
static const CGFloat kBottomMargin     = 10.0;
static const CGFloat kHorizontalPad    = 14.0;
static const CGFloat kIconAreaWidth    = 28.0;
static const CGFloat kIconTextGap      = 6.0;
static const CGFloat kMaxWidth         = 600.0;
static const CGFloat kMaxHeight        = 300.0;

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

// ── Animation mode ───────────────────────────────────────
typedef NS_ENUM(NSInteger, SPOverlayMode) {
    SPOverlayModeNone,
    SPOverlayModeWaveform,
    SPOverlayModeProcessing,
    SPOverlayModeSuccess,
    SPOverlayModeError,
};

// ── Content view ─────────────────────────────────────────

@interface SPOverlayContentView : NSView
@property (nonatomic, copy)   NSString      *statusText;
@property (nonatomic, copy)   NSString      *interimText;
@property (nonatomic, strong) NSColor       *accentColor;
@property (nonatomic, assign) SPOverlayMode  mode;
@property (nonatomic, assign) NSInteger      tick;  // animation counter
@property (nonatomic, assign) CGFloat        layoutWidth;
@end

@implementation SPOverlayContentView

- (BOOL)isFlipped { return NO; }

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;

    // ── Dark tint (minimum contrast for white text on any background) ──
    [[NSColor colorWithWhite:0.0 alpha:0.35] setFill];
    [NSBezierPath fillRect:bounds];

    // ── Border (edge definition on dark backgrounds) ──
    NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5)
                                                            xRadius:kPillCornerRadius
                                                            yRadius:kPillCornerRadius];
    [[NSColor colorWithWhite:1.0 alpha:0.20] setStroke];
    border.lineWidth = 0.5;
    [border stroke];

    // ── Left icon area ──
    CGFloat iconCenterX = kHorizontalPad + kIconAreaWidth / 2.0;
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

    // ── Text ──
    NSString *displayText = (self.interimText.length > 0) ? self.interimText : self.statusText;
    if (displayText.length > 0) {
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:13.0 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: [NSColor colorWithWhite:1.0 alpha:0.92],
        };
        NSAttributedString *str = [[NSAttributedString alloc] initWithString:displayText
                                                                  attributes:attrs];
        CGFloat textX = kHorizontalPad + kIconAreaWidth + kIconTextGap;
        // Use layoutWidth to avoid wrapping into animated/intermediate bounds
        CGFloat textMaxW = fmax(1.0, self.layoutWidth - textX - kHorizontalPad);
        NSRect textRect = [str boundingRectWithSize:NSMakeSize(textMaxW, CGFLOAT_MAX)
                                            options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine];
        CGFloat textY = (bounds.size.height - textRect.size.height) / 2.0;
        [str drawWithRect:NSMakeRect(textX, textY, textMaxW, textRect.size.height)
                  options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine];
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
@property (nonatomic, strong) NSVisualEffectView *effectView;
@property (nonatomic, strong) SPOverlayContentView *contentView;
@property (nonatomic, strong) NSTimer *animationTimer;
@property (nonatomic, strong) NSTimer *lingerTimer;
@property (nonatomic, copy)   NSString *currentState;
@property (nonatomic, assign) CGFloat sessionMaxWidth;
@property (nonatomic, assign) CGFloat sessionMaxHeight;
@property (nonatomic, strong) NSArray<NSDictionary *> *templateButtons;
@property (nonatomic, assign) BOOL showingTemplates;
@property (nonatomic, strong) NSPanel *buttonBarPanel;
@property (nonatomic, strong) NSMutableArray<NSButton *> *templateButtonViews;

@end

@implementation SPOverlayPanel

- (instancetype)init {
    self = [super init];
    if (self) {
        _currentState = @"idle";
        [self setupPanel];
    }
    return self;
}

- (void)setupPanel {
    NSRect rect = NSMakeRect(0, 0, 180, kPillHeight);

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
    NSVisualEffectView *effectView = [[NSVisualEffectView alloc] initWithFrame:rect];
    effectView.material     = NSVisualEffectMaterialHUDWindow;
    effectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    effectView.state        = NSVisualEffectStateActive;
    effectView.appearance   = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    effectView.wantsLayer   = YES;
    effectView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // Pill shape via maskImage (Apple-recommended for shaping NSVisualEffectView)
    CGFloat diameter = kPillCornerRadius * 2;
    NSImage *mask = [NSImage imageWithSize:NSMakeSize(diameter + 1, kPillHeight)
                                   flipped:NO
                            drawingHandler:^BOOL(NSRect dstRect) {
        [[NSColor blackColor] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:dstRect
                                         xRadius:kPillCornerRadius
                                         yRadius:kPillCornerRadius] fill];
        return YES;
    }];
    mask.capInsets     = NSEdgeInsetsMake(kPillCornerRadius, kPillCornerRadius,
                                          kPillCornerRadius, kPillCornerRadius);
    mask.resizingMode  = NSImageResizingModeStretch;
    effectView.maskImage = mask;

    // Light glow shadow (visible on dark backgrounds)
    effectView.layer.shadowColor   = [[NSColor whiteColor] CGColor];
    effectView.layer.shadowOpacity = 0.15;
    effectView.layer.shadowRadius  = 6.0;
    effectView.layer.shadowOffset  = CGSizeMake(0, 0);

    panel.contentView = effectView;
    self.effectView = effectView;

    // Content drawn on top of the effect view
    self.contentView = [[SPOverlayContentView alloc] initWithFrame:rect];
    self.contentView.wantsLayer = YES;
    self.contentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [effectView addSubview:self.contentView];

    self.panel = panel;
}

#pragma mark - Public

- (void)updateState:(NSString *)state {
    // Cancel any pending linger dismiss from a previous session
    [self.lingerTimer invalidate];
    self.lingerTimer = nil;

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
    [self resizeAndCenterAnimated:YES];
    [self.contentView setNeedsDisplay:YES];
}

- (void)lingerAndDismiss {
    [self.lingerTimer invalidate];
    self.lingerTimer = nil;

    // Dynamic linger: clamp(charCount * 0.03, 0.8, 2.5)
    NSString *displayText = self.contentView.interimText ?: self.contentView.statusText ?: @"";
    NSUInteger charCount = displayText.length;
    NSTimeInterval linger = fmin(fmax(charCount * 0.03, 0.8), 2.5);

    self.lingerTimer = [NSTimer scheduledTimerWithTimeInterval:linger
                                                      repeats:NO
                                                        block:^(NSTimer *timer) {
        self.lingerTimer = nil;
        self.sessionMaxWidth = 0;
        self.sessionMaxHeight = 0;
        [self hide];
        self.currentState = @"idle";
    }];
}

- (void)showTemplateButtons:(NSArray<NSDictionary *> *)templates {
    if (templates.count == 0) return;
    self.templateButtons = templates;
    self.showingTemplates = YES;

    // Remove old button bar
    [self.buttonBarPanel orderOut:nil];
    self.buttonBarPanel = nil;
    self.templateButtonViews = nil;

    // Calculate button sizes — only show name, no shortcut number
    CGFloat btnH = 26;
    CGFloat btnSpacing = 8;
    CGFloat barPad = 6;
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
    };

    CGFloat totalW = 0;
    NSMutableArray<NSNumber *> *widths = [NSMutableArray array];
    for (NSDictionary *tmpl in templates) {
        NSString *label = tmpl[@"name"] ?: @"";
        CGFloat w = [label sizeWithAttributes:attrs].width + 24;
        w = fmax(w, 60); // minimum button width
        [widths addObject:@(w)];
        totalW += w;
    }
    totalW += (templates.count - 1) * btnSpacing + 2 * barPad;
    CGFloat barH = btnH + 2 * barPad;

    // Create button bar panel
    NSPanel *bar = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, totalW, barH)
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
    NSVisualEffectView *bgView = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, totalW, barH)];
    bgView.material = NSVisualEffectMaterialHUDWindow;
    bgView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    bgView.state = NSVisualEffectStateActive;
    bgView.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    bgView.wantsLayer = YES;

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

    bar.contentView = bgView;

    // Add buttons (name only, no number)
    self.templateButtonViews = [NSMutableArray array];
    CGFloat x = barPad;
    for (NSUInteger i = 0; i < templates.count; i++) {
        NSDictionary *tmpl = templates[i];
        NSString *label = tmpl[@"name"] ?: @"";
        CGFloat w = [widths[i] floatValue];

        NSButton *btn = [[NSButton alloc] initWithFrame:NSMakeRect(x, barPad, w, btnH)];
        btn.title = label;
        btn.bezelStyle = NSBezelStyleInline;
        btn.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        btn.tag = (NSInteger)i;
        btn.target = self;
        btn.action = @selector(templateButtonClicked:);
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

    // Extend linger time when templates are showing
    [self.lingerTimer invalidate];
    self.lingerTimer = nil;
    self.lingerTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                      repeats:NO
                                                        block:^(NSTimer *timer) {
        self.lingerTimer = nil;
        [self hideTemplateButtons];
        self.sessionMaxWidth = 0;
        self.sessionMaxHeight = 0;
        [self hide];
        self.currentState = @"idle";
    }];
}

- (void)templateButtonClicked:(NSButton *)sender {
    NSInteger index = sender.tag;
    [self highlightButtonAtIndex:index thenDismiss:YES];
}

- (void)hideTemplateButtons {
    self.showingTemplates = NO;
    self.templateButtons = nil;
    self.templateButtonViews = nil;
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
        NSDictionary *tmpl = self.templateButtons[i];
        NSNumber *shortcut = tmpl[@"shortcut"];
        if (shortcut && shortcut.integerValue == number) {
            [self highlightButtonAtIndex:(NSInteger)i thenDismiss:YES];
            return YES;
        }
    }
    return NO;
}

/// Briefly highlight a button with a scale+glow animation, then trigger the delegate.
- (void)highlightButtonAtIndex:(NSInteger)index thenDismiss:(BOOL)dismiss {
    if (index < 0 || index >= (NSInteger)self.templateButtonViews.count) return;

    NSButton *btn = self.templateButtonViews[index];
    NSInteger templateIndex = index;

    // Flash highlight animation
    btn.wantsLayer = YES;
    btn.layer.backgroundColor = [[NSColor colorWithWhite:1.0 alpha:0.4] CGColor];

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.15;
        ctx.allowsImplicitAnimation = YES;
        btn.layer.backgroundColor = [[NSColor colorWithWhite:1.0 alpha:0.6] CGColor];
        btn.alphaValue = 1.0;
    } completionHandler:^{
        // Brief pause then dismiss
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self hideTemplateButtons];
            [self.delegate overlayPanel:self didSelectTemplateAtIndex:templateIndex];
        });
    }];
}

#pragma mark - Layout

- (void)resizeAndCenterAnimated:(BOOL)animated {
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13.0 weight:NSFontWeightMedium],
    };
    NSString *displayText = (self.contentView.interimText.length > 0)
                            ? self.contentView.interimText
                            : self.contentView.statusText;
    NSAttributedString *str = [[NSAttributedString alloc] initWithString:displayText ?: @"" attributes:attrs];
    
    CGFloat iconSpace = kHorizontalPad + kIconAreaWidth + kIconTextGap;
    
    // 1. Determine natural single-line width
    CGFloat naturalW = [str size].width;
    CGFloat desiredW = iconSpace + naturalW + kHorizontalPad;
    
    // 2. Clamp to screen/max limits
    NSScreen *screen = [NSScreen mainScreen];
    NSRect visible = screen.visibleFrame;
    CGFloat absoluteMaxW = fmin(kMaxWidth, visible.size.width - 2 * kScreenHorizontalMargin);
    
    CGFloat pillW = desiredW;
    CGFloat pillH = kPillHeight;

    if (desiredW > absoluteMaxW) {
        pillW = absoluteMaxW;
        CGFloat textMaxW = pillW - iconSpace - kHorizontalPad;
        NSRect textRect = [str boundingRectWithSize:NSMakeSize(textMaxW, kMaxHeight)
                                            options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine];
        pillH = fmax(kPillHeight, ceil(textRect.size.height) + 20.0);
    }

    // 3. Stabilization: Only-grow during active session
    if (animated && self.sessionMaxWidth > 0) {
        pillW = fmax(pillW, self.sessionMaxWidth);
    }
    if (animated && self.sessionMaxHeight > 0) {
        pillH = fmax(pillH, self.sessionMaxHeight);
    }
    
    if (animated) {
        self.sessionMaxWidth = pillW;
        self.sessionMaxHeight = pillH;
    }

    // 4. Update internal layout width to prevent wrapping mid-animation
    self.contentView.layoutWidth = pillW;

    // 5. Final Frame
    CGFloat x = NSMidX(visible) - pillW / 2.0;
    CGFloat y = NSMinY(visible) + kBottomMargin;
    NSRect newFrame = NSMakeRect(x, y, pillW, pillH);

    if (animated) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = kResizeDuration;
            ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            [[self.panel animator] setFrame:newFrame display:YES];
        }];
    } else {
        [self.panel setFrame:newFrame display:YES];
    }
}

#pragma mark - Show / Hide

- (void)show {
    [self.panel orderFrontRegardless];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = kFadeInDuration;
        self.panel.animator.alphaValue = 1.0;
    }];
}

- (void)hide {
    [self hideTemplateButtons];
    [self stopAnimation];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = kFadeOutDuration;
        self.panel.animator.alphaValue = 0.0;
    } completionHandler:^{
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
