#import <Cocoa/Cocoa.h>

// Compare's settings, stored in its user defaults. Changing one posts
// CompareSettingsDidChangeNotification, and every open window compares again.

extern NSString* const CompareExcludedNamesDefaultsKey;     // "compareExcludedNames"
extern NSString* const CompareSettingsDidChangeNotification;

@interface CompareSettings : NSObject
// “Ignore folders and files”: comma-separated names and patterns never shown in
// a comparison (see compare_excludes_t). Defaults to “node_modules”.
@property (class, nonatomic, copy) NSString* excludedNames;
@property (class, nonatomic, readonly) NSString* defaultExcludedNames;
@end

// Compare → Settings… (⌘,): a standard settings window with a General pane.
@interface CompareSettingsWindowController : NSWindowController
@property (class, nonatomic, readonly) CompareSettingsWindowController* sharedController;
@property (nonatomic, readonly) NSTextField* excludedNamesField; // for tests
// Saves what is being typed (also done on Return, leaving the field, and closing).
- (void)commitEditing;
@end
