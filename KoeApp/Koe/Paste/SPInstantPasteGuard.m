#import "SPInstantPasteGuard.h"
#import <ApplicationServices/ApplicationServices.h>
#import <AppKit/AppKit.h>

@interface SPInstantPasteGuard () {
    AXUIElementRef _element; // retained
}
@property (nonatomic, assign) pid_t frontmostPid;
@property (nonatomic, assign) NSUInteger insertLocation; // UTF-16 offset of pasted text
@property (nonatomic, copy) NSString *rawText;
@property (nonatomic, assign, readwrite) BOOL active;
@end

@implementation SPInstantPasteGuard

- (void)dealloc {
    [self reset];
}

- (void)reset {
    if (_element) {
        CFRelease(_element);
        _element = NULL;
    }
    self.rawText = nil;
    self.active = NO;
}

// ─── AX helpers ─────────────────────────────────────────────────────

static AXUIElementRef copyFocusedElement(void) {
    AXUIElementRef systemWide = AXUIElementCreateSystemWide();
    if (!systemWide) return NULL;
    CFTypeRef focused = NULL;
    AXError err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute, &focused);
    CFRelease(systemWide);
    if (err != kAXErrorSuccess || !focused) return NULL;
    return (AXUIElementRef)focused;
}

static BOOL copySelectedRange(AXUIElementRef element, NSRange *outRange) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute, &value) != kAXErrorSuccess ||
        !value) {
        return NO;
    }
    CFRange range;
    BOOL ok = AXValueGetValue((AXValueRef)value, kAXValueTypeCFRange, &range);
    CFRelease(value);
    if (!ok || range.location < 0 || range.length < 0) return NO;
    *outRange = NSMakeRange((NSUInteger)range.location, (NSUInteger)range.length);
    return YES;
}

static NSString *copyValueString(AXUIElementRef element) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXValueAttribute, &value) != kAXErrorSuccess ||
        !value) {
        return nil;
    }
    if (CFGetTypeID(value) != CFStringGetTypeID()) {
        CFRelease(value);
        return nil;
    }
    return (__bridge_transfer NSString *)value;
}

static void setCaret(AXUIElementRef element, NSUInteger location) {
    CFRange caret = CFRangeMake((CFIndex)location, 0);
    AXValueRef value = AXValueCreate(kAXValueTypeCFRange, &caret);
    if (value) {
        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute, value);
        CFRelease(value);
    }
}

/// The document text must contain exactly `text` at `location`.
static BOOL documentContainsTextAtLocation(AXUIElementRef element,
                                           NSString *text,
                                           NSUInteger location) {
    NSString *value = copyValueString(element);
    if (!value) return NO;
    if (location + text.length > value.length) return NO;
    return [[value substringWithRange:NSMakeRange(location, text.length)] isEqualToString:text];
}

// ─── Capture ────────────────────────────────────────────────────────

- (BOOL)captureAfterPasteWithRawText:(NSString *)rawText {
    [self reset];
    if (rawText.length == 0) return NO;

    AXUIElementRef element = copyFocusedElement();
    if (!element) {
        NSLog(@"[Koe] InstantPaste: no focused AX element — replacement disabled");
        return NO;
    }

    // Both attributes must be readable AND the selection must be settable,
    // otherwise in-place replacement is impossible.
    Boolean rangeSettable = false, textSettable = false;
    AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute, &rangeSettable);
    AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute, &textSettable);
    if (!rangeSettable || !textSettable) {
        NSLog(@"[Koe] InstantPaste: focused element does not support text replacement");
        CFRelease(element);
        return NO;
    }

    NSRange selection;
    if (!copySelectedRange(element, &selection) || selection.length != 0 ||
        selection.location < rawText.length) {
        NSLog(@"[Koe] InstantPaste: unexpected selection after paste — replacement disabled");
        CFRelease(element);
        return NO;
    }

    NSUInteger insertLocation = selection.location - rawText.length;
    if (!documentContainsTextAtLocation(element, rawText, insertLocation)) {
        // The app may have transformed the pasted text (auto-format, IME…);
        // we cannot verify the inserted range, so never touch it.
        NSLog(@"[Koe] InstantPaste: pasted text not found at caret — replacement disabled");
        CFRelease(element);
        return NO;
    }

    pid_t pid = 0;
    AXUIElementGetPid(element, &pid);

    _element = element; // transfer ownership (already retained by copy)
    self.frontmostPid = pid;
    self.insertLocation = insertLocation;
    self.rawText = rawText;
    self.active = YES;
    return YES;
}

// ─── Replace ────────────────────────────────────────────────────────

- (BOOL)replaceWithCorrectedText:(NSString *)correctedText {
    if (!self.active || correctedText.length == 0) {
        [self reset];
        return NO;
    }

    BOOL replaced = NO;
    AXUIElementRef current = copyFocusedElement();

    // Every check below proves "nothing happened since the paste":
    // 1. Focus is on the same element of the same app.
    // 2. The caret is still exactly at the end of the pasted text with no
    //    selection (typing, clicking, or app-driven edits all move it).
    // 3. The document still contains the raw text at the recorded position.
    if (current && CFEqual(current, _element)) {
        pid_t pid = 0;
        AXUIElementGetPid(current, &pid);
        NSRange selection;
        NSUInteger expectedCaret = self.insertLocation + self.rawText.length;

        if (pid == self.frontmostPid &&
            copySelectedRange(current, &selection) &&
            selection.length == 0 && selection.location == expectedCaret &&
            documentContainsTextAtLocation(current, self.rawText, self.insertLocation)) {

            CFRange target = CFRangeMake((CFIndex)self.insertLocation, (CFIndex)self.rawText.length);
            AXValueRef targetValue = AXValueCreate(kAXValueTypeCFRange, &target);
            if (targetValue) {
                AXError selErr = AXUIElementSetAttributeValue(current, kAXSelectedTextRangeAttribute,
                                                              targetValue);
                CFRelease(targetValue);
                if (selErr == kAXErrorSuccess) {
                    AXError repErr = AXUIElementSetAttributeValue(
                        current, kAXSelectedTextAttribute,
                        (__bridge CFTypeRef)correctedText);
                    if (repErr == kAXErrorSuccess &&
                        documentContainsTextAtLocation(current, correctedText,
                                                       self.insertLocation)) {
                        replaced = YES;
                        // Deterministic caret: end of the corrected text.
                        setCaret(current, self.insertLocation + correctedText.length);
                        NSLog(@"[Koe] InstantPaste: replaced %lu chars with %lu chars in place",
                              (unsigned long)self.rawText.length,
                              (unsigned long)correctedText.length);
                    } else {
                        // The raw range is now selected; collapse the selection
                        // back to the caret so the user's next keystroke cannot
                        // overwrite their text.
                        setCaret(current, expectedCaret);
                        NSLog(@"[Koe] InstantPaste: replacement not verified (err=%d)", repErr);
                    }
                } else {
                    NSLog(@"[Koe] InstantPaste: could not select pasted range (err=%d)", selErr);
                }
            }
        } else {
            NSLog(@"[Koe] InstantPaste: state changed since paste — leaving raw text untouched");
        }
    } else {
        NSLog(@"[Koe] InstantPaste: focus changed since paste — leaving raw text untouched");
    }

    if (current) CFRelease(current);
    [self reset];
    return replaced;
}

@end
