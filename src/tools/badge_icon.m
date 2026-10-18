// Write an .iconset from an icon image (.icns, .ico or .png) with a "NATIVE" ribbon across the bottom, so the
// native app is told apart from the Wine app in the Dock.   badge_icon <in-image> <out.iconset>   (then icns.py)
#import <AppKit/AppKit.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) { fprintf(stderr, "usage: badge_icon <in-image> <out.iconset>\n"); return 2; }
        NSImage *src = [[NSImage alloc] initWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
        if (!src) { fprintf(stderr, "cannot read %s\n", argv[1]); return 1; }
        NSString *dir = [NSString stringWithUTF8String:argv[2]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        const int pts[5] = {16, 32, 128, 256, 512};
        for (int i = 0; i < 5; i++) for (int scale = 1; scale <= 2; scale++) {
            int px = pts[i] * scale;
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:px pixelsHigh:px bitsPerSample:8 samplesPerPixel:4
                hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
            [NSGraphicsContext saveGraphicsState];
            [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
            [NSGraphicsContext currentContext].imageInterpolation = NSImageInterpolationHigh;
            [src drawInRect:NSMakeRect(0, 0, px, px) fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1.0];
            if (px >= 32) {                       // ribbon: dark green band with white text, bottom fifth of the icon
                CGFloat h = px * 0.2, y = px * 0.1;
                [[NSColor colorWithCalibratedRed:0.05 green:0.45 blue:0.2 alpha:0.92] setFill];
                [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(px * 0.1, y, px * 0.8, h) xRadius:h * 0.3 yRadius:h * 0.3] fill];
                NSDictionary *at = @{NSFontAttributeName: [NSFont boldSystemFontOfSize:h * 0.62], NSForegroundColorAttributeName: NSColor.whiteColor};
                NSAttributedString *t = [[NSAttributedString alloc] initWithString:@"NATIVE" attributes:at];
                NSSize ts = t.size;
                [t drawAtPoint:NSMakePoint((px - ts.width) / 2, y + (h - ts.height) / 2)];
            }
            [NSGraphicsContext restoreGraphicsState];
            NSString *name = scale == 1 ? [NSString stringWithFormat:@"icon_%dx%d.png", pts[i], pts[i]] : [NSString stringWithFormat:@"icon_%dx%d@2x.png", pts[i], pts[i]];
            NSError *err = nil;
            if (![[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[dir stringByAppendingPathComponent:name] options:0 error:&err]) {
                fprintf(stderr, "cannot write %s: %s\n", name.UTF8String, err.localizedDescription.UTF8String); return 1;
            }
        }
    }
    return 0;
}
