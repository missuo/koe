#import "SPClipboardManager.h"
#import <AppKit/AppKit.h>

@interface SPClipboardManager ()

@property (nonatomic, strong) NSArray<NSPasteboardItem *> *backedUpItems;
@property (nonatomic, assign) NSInteger backedUpChangeCount;
@property (nonatomic, assign) NSInteger writtenChangeCount;
@property (nonatomic, assign) BOOL hasBackup;

@end

@implementation SPClipboardManager

- (void)backup {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    self.backedUpChangeCount = pb.changeCount;

    // Deep copy current pasteboard items
    NSMutableArray<NSPasteboardItem *> *items = [NSMutableArray array];
    for (NSPasteboardItem *item in pb.pasteboardItems) {
        NSPasteboardItem *copy = [[NSPasteboardItem alloc] init];
        for (NSString *type in item.types) {
            NSData *data = [item dataForType:type];
            if (data) {
                [copy setData:data forType:type];
            }
        }
        [items addObject:copy];
    }
    self.backedUpItems = items;
    self.hasBackup = YES;
}

- (void)writeText:(NSString *)text {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:text forType:NSPasteboardTypeString];
    self.writtenChangeCount = pb.changeCount;
}

- (void)scheduleRestoreAfterDelay:(NSUInteger)delayMs {
    if (!self.hasBackup) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [self restoreIfUnchanged];
    });
}

- (void)restoreIfUnchanged {
    if (!self.hasBackup) return;

    NSPasteboard *pb = [NSPasteboard generalPasteboard];

    // Only restore if the clipboard hasn't been modified since we wrote to it
    if (pb.changeCount != self.writtenChangeCount) {
        NSLog(@"[Koe] Clipboard changed since write, skipping restore");
        self.backedUpItems = nil;
        self.hasBackup = NO;
        return;
    }

    [pb clearContents];
    if (self.backedUpItems.count > 0) {
        [pb writeObjects:self.backedUpItems];
    }
    NSLog(@"[Koe] Clipboard restored%@", self.backedUpItems.count == 0 ? @" (was empty)" : @"");
    self.backedUpItems = nil;
    self.hasBackup = NO;
}

@end
