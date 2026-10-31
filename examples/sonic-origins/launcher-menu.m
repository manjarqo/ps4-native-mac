#import <AppKit/AppKit.h>
#include <errno.h>
#include <signal.h>

// The carousel has six white circles, exactly one with a red center. Reject other screens.
static NSInteger carouselIndex(NSString *path) {
    NSBitmapImageRep *image = [[NSBitmapImageRep alloc] initWithData:[NSData dataWithContentsOfFile:path]];
    if (!image || image.pixelsWide < 640 || image.pixelsHigh < 360) return -1;
    NSInteger selected = -1;
    for (NSInteger i = 0; i < 6; i++) {
        // Check the white circle rim as well as its center, so a row of text is rejected.
        const int rim[4][2] = {{-10, 0}, {10, 0}, {0, -10}, {0, 10}};
        for (NSInteger point = 0; point < 4; point++) {
            NSInteger x = (NSInteger)llround((390 + 35 * i + rim[point][0]) * image.pixelsWide / 1920.0);
            NSInteger y = (NSInteger)llround((303 + rim[point][1]) * image.pixelsHigh / 1080.0);
            NSColor *color = [[image colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            if (!color || color.redComponent < .85 || color.greenComponent < .85 || color.blueComponent < .85) return -1;
        }
        for (NSInteger dx = -3; dx <= 3; dx += 3) {
            NSInteger x = (NSInteger)llround((390 + 35 * i + dx) * image.pixelsWide / 1920.0);
            NSInteger y = (NSInteger)llround(303 * image.pixelsHigh / 1080.0);
            NSColor *color = [[image colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            if (!color) return -1;
            CGFloat r = color.redComponent, g = color.greenComponent, b = color.blueComponent;
            BOOL red = r > .75 && g < .25 && b < .30;
            BOOL white = r > .85 && g > .85 && b > .85;
            if (!red && !white) return -1;
            if (dx == -3 && red) {
                if (selected != -1) return -1;
                selected = i;
            }
            if (red != (selected == i)) return -1;
        }
    }
    return selected;
}

// This is an external launcher and a manual pad remote, not a guest launch parameter.
@interface SonicMenu : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property NSWindow *window;
@property NSPopUpButton *games;
@property NSString *controlPath;
@property pid_t gamePID;
@property BOOL choosing;
@property NSInteger targetIndex;
@property NSString *shotDirectory;
@property NSString *lastShot;
@property NSTextField *statusLabel;
@property BOOL autoSelecting;
@property NSInteger lastIndex;
@property NSInteger stableCount;
@property NSInteger attempts;
@property NSInteger movementCount;
@property NSInteger lastMovedFrom;
@end

@implementation SonicMenu
- (NSTextField *)label:(NSString *)text frame:(NSRect)frame {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.frame = frame;
    [self.window.contentView addSubview:label];
    return label;
}
- (void)button:(NSString *)title frame:(NSRect)frame action:(SEL)action tag:(NSInteger)tag {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.frame = frame;
    button.tag = tag;
    [self.window.contentView addSubview:button];
}
- (void)choose:(id)sender {
    (void)sender;
    printf("%ld\n", (long)self.games.indexOfSelectedItem);
    fflush(stdout);
    [NSApp terminate:nil];
}
- (void)normal:(id)sender {
    (void)sender;
    puts("normal");
    [NSApp terminate:nil];
}
- (void)cancel:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}
- (BOOL)writeCommand:(NSString *)command {
    // The runtime consumes appended commands after its first pad read. No startup timings.
    FILE *file = fopen(self.controlPath.fileSystemRepresentation, "a");
    if (!file || fputs(command.UTF8String, file) < 0) {
        if (file) fclose(file);
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Could not send controller input";
        alert.informativeText = @"Close this panel and use the game keyboard controls.";
        [alert runModal];
        self.autoSelecting = NO;
        return NO;
    }
    if (fclose(file) != 0) { NSBeep(); return NO; }
    return YES;
}
- (void)pad:(NSButton *)sender {
    if (sender.tag != 0x4000) {
        self.autoSelecting = NO;
        self.statusLabel.stringValue = @"Manual control. Highlight the target, then confirm in Origins.";
    }
    [self writeCommand:[NSString stringWithFormat:@"p %lx 100\nw 120\n", (unsigned long)sender.tag]];
}
- (void)selectFromScreenshot:(NSTimer *)timer {
    (void)timer;
    if (!self.autoSelecting) return;
    if (++self.attempts > 90 || self.movementCount >= 8) {
        self.autoSelecting = NO;
        self.statusLabel.stringValue = @"Selection could not be verified. Use the manual buttons below.";
        return;
    }
    NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.shotDirectory error:nil];
    NSString *newest = nil;
    for (NSString *name in files) {
        if ([name hasSuffix:@".png"] && (!newest || [name compare:newest] == NSOrderedDescending)) newest = name;
    }
    if (newest && ![newest isEqualToString:self.lastShot]) {
        NSString *path = [self.shotDirectory stringByAppendingPathComponent:newest];
        NSInteger index = carouselIndex(path);
        if (index >= 0) {
            self.stableCount = index == self.lastIndex ? self.stableCount + 1 : 1;
            self.lastIndex = index;
            if (self.stableCount >= 2) {
                if (index == self.targetIndex) {
                    self.autoSelecting = NO;
                    self.statusLabel.stringValue = @"Target highlighted in Origins. Confirm your mode and character to play.";
                } else if (index == self.lastMovedFrom) {
                    // A held mode submenu or ignored press must never create a blind input loop.
                    self.autoSelecting = NO;
                    self.statusLabel.stringValue = @"Carousel did not move. Close the in-game submenu or use manual controls.";
                } else {
                    unsigned mask = index < self.targetIndex ? 0x20 : 0x80;
                    [self writeCommand:[NSString stringWithFormat:@"p %x 100\nw 120\n", mask]];
                    self.lastMovedFrom = index;
                    self.stableCount = 0;
                    self.movementCount++;
                    self.statusLabel.stringValue = @"Selecting target in Origins; waiting to verify the highlighted game…";
                }
            }
        } else {
            self.stableCount = 0;
            self.lastIndex = -1;
        }
        if (self.lastShot) [[NSFileManager defaultManager] removeItemAtPath:[self.shotDirectory stringByAppendingPathComponent:self.lastShot] error:nil];
        self.lastShot = newest;
    }
    if (self.autoSelecting) [self writeCommand:@"shot\n"];
}
- (void)checkGame:(NSTimer *)timer {
    (void)timer;
    if (kill(self.gamePID, 0) != 0 && errno == ESRCH) [NSApp terminate:nil];
}
- (BOOL)windowShouldClose:(NSWindow *)sender {
    (void)sender;
    [NSApp terminate:nil];
    return YES;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    NSArray<NSString *> *titles = @[@"Sonic the Hedgehog", @"Sonic CD", @"Sonic the Hedgehog 2", @"Sonic 3 & Knuckles"];
    NSRect rect = NSMakeRect(0, 0, 490, self.choosing ? 238 : 310);
    self.window = [[NSWindow alloc] initWithContentRect:rect
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.delegate = self;
    self.window.title = @"Sonic Origins";
    if (self.choosing) {
        NSTextField *title = [self label:@"Choose a game" frame:NSMakeRect(22, 195, 446, 24)];
        title.font = [NSFont boldSystemFontOfSize:18];
        self.games = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, 153, 450, 30) pullsDown:NO];
        [self.games addItemsWithTitles:titles];
        [self.window.contentView addSubview:self.games];
        [self label:@"Opens Origins and selects the target when its carousel is visible. Clear startup notices yourself. Confirm your mode and character in Origins to play."
            frame:NSMakeRect(22, 80, 446, 66)];
        [self button:@"Cancel" frame:NSMakeRect(18, 22, 90, 32) action:@selector(cancel:) tag:0];
        [self button:@"Normal startup" frame:NSMakeRect(180, 22, 135, 32) action:@selector(normal:) tag:0];
        [self button:@"Open with guide" frame:NSMakeRect(320, 22, 150, 32) action:@selector(choose:) tag:0];
    } else {
        NSInteger index = self.targetIndex;
        self.window.title = [@"Select: " stringByAppendingString:titles[index]];
        self.window.level = NSFloatingWindowLevel;
        [self label:[NSString stringWithFormat:@"Target: %@", titles[index]] frame:NSMakeRect(22, 265, 446, 28)].font = [NSFont boldSystemFontOfSize:17];
        [self label:@"Wait for the game to load. Confirm startup notices yourself. When the game carousel is visible, selection follows its highlighted dot. Confirm your mode and character in Origins."
            frame:NSMakeRect(22, 173, 446, 85)];
        self.statusLabel = [self label:@"Waiting for the Origins game carousel…" frame:NSMakeRect(22, 153, 446, 30)];
        self.statusLabel.font = [NSFont systemFontOfSize:11];
        [self button:@"Left" frame:NSMakeRect(22, 125, 95, 32) action:@selector(pad:) tag:0x80];
        [self button:@"Right" frame:NSMakeRect(125, 125, 95, 32) action:@selector(pad:) tag:0x20];
        [self button:@"Confirm ✕" frame:NSMakeRect(228, 125, 117, 32) action:@selector(pad:) tag:0x4000];
        [self button:@"Back ◯" frame:NSMakeRect(353, 125, 115, 32) action:@selector(pad:) tag:0x2000];
        [self label:@"Each click sends one short controller press. Click again if input arrived before the game was ready. Keyboard: arrows / WASD, Space / Return to confirm, Escape / Tab / P for Options."
            frame:NSMakeRect(22, 52, 446, 65)];
        [self button:@"Close guide" frame:NSMakeRect(340, 10, 130, 32) action:@selector(cancel:) tag:0];
        [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(checkGame:) userInfo:nil repeats:YES];
        [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(selectFromScreenshot:) userInfo:nil repeats:YES];
    }
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        BOOL choosing = argc == 2 && strcmp(argv[1], "--choose") == 0;
        if (argc == 3 && strcmp(argv[1], "--inspect") == 0) {
            printf("%ld\n", (long)carouselIndex([NSString stringWithUTF8String:argv[2]]));
            return 0;
        }
        BOOL assisting = argc == 6 && strcmp(argv[1], "--assist") == 0;
        if (assisting) {
            char *end = NULL;
            long index = strtol(argv[2], &end, 10);
            if (!*argv[2] || *end || index < 0 || index > 3) return 2;
            long pid = strtol(argv[4], &end, 10);
            if (!*argv[4] || *end || pid <= 1 || pid > INT_MAX) return 2;
        } else if (!choosing) {
            fprintf(stderr, "Usage: launcher-menu --choose | --assist <0..3> <pad-control-file> <game-pid> <screenshot-dir> | --inspect <image>\n");
            return 2;
        }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        SonicMenu *delegate = [[SonicMenu alloc] init];
        delegate.choosing = choosing;
        if (assisting) {
            delegate.controlPath = [NSString stringWithUTF8String:argv[3]];
            delegate.gamePID = (pid_t)strtol(argv[4], NULL, 10);
            delegate.targetIndex = strtol(argv[2], NULL, 10);
            delegate.shotDirectory = [NSString stringWithUTF8String:argv[5]];
            delegate.autoSelecting = YES;
            delegate.lastIndex = -1;
            delegate.lastMovedFrom = -1;
        }
        NSApp.delegate = delegate;
        [NSApp run];
    }
    return 0;
}
