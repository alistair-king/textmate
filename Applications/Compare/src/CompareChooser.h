#import <Cocoa/Cocoa.h>

// File → New Comparison… (⌘N), also shown when Compare starts with nothing
// to compare: pick a left and a right — two folders or two files — with
// Choose… (an open panel) or by dropping them on either side's card.
@interface CompareChooserWindowController : NSWindowController
// Called with both paths when Compare is clicked; the window then closes.
@property (nonatomic, copy) void (^compareHandler)(NSString* left, NSString* right);

// Absolute paths (standardized); nil when not chosen. Settable for tests.
@property (nonatomic, copy) NSString* leftPath;
@property (nonatomic, copy) NSString* rightPath;

// Why the two can't be compared yet, or nil when Compare is enabled.
@property (nonatomic, readonly) NSString* problem;
@property (nonatomic, readonly) NSButton* compareButton; // for tests
- (IBAction)compare:(id)sender;
- (IBAction)swapSides:(id)sender; // the ⇄ button between the sides
@end
