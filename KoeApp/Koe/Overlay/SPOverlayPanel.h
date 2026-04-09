#import <Cocoa/Cocoa.h>

@protocol SPOverlayPanelDelegate <NSObject>
@optional
/// Called when user selects a prompt template (by click or keyboard shortcut).
/// templateIndex is 0-based index into the prompt_templates array.
- (void)overlayPanel:(id)panel didSelectTemplateAtIndex:(NSInteger)templateIndex;
@end

/// Floating status pill displayed at bottom-center of screen, above the Dock.
@interface SPOverlayPanel : NSObject

@property (nonatomic, weak) id<SPOverlayPanelDelegate> delegate;

- (instancetype)init;

/// Update displayed state.
- (void)updateState:(NSString *)state;

/// Update interim ASR text shown during recording.
- (void)updateInterimText:(NSString *)text;

/// Update display text shown during non-recording phases.
- (void)updateDisplayText:(NSString *)text;

/// Dismiss the overlay after a dynamic linger period based on text length.
- (void)lingerAndDismiss;

/// Show template selection buttons. Templates is array of dicts with "name" and "shortcut" keys.
- (void)showTemplateButtons:(NSArray<NSDictionary *> *)templates;

/// Hide template buttons and return to normal display.
- (void)hideTemplateButtons;

/// Handle a number key press (1-9). Returns YES if a template was triggered.
- (BOOL)handleNumberKey:(NSInteger)number;

@end
