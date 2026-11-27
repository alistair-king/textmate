#import <Cocoa/Cocoa.h>

// Language server features for one side of a file tab, through TextMate's
// LSPManager: the file is opened as a document of this process (from disk,
// as TextMate's editor loads it) with the server its settings name
// (`lspCommand`, `lspEnabled`, `lspRootPath`). Each folder's files get the
// server for their own workspace root, so two worktrees get two servers.
// Main thread only.
@interface CompareLanguageService : NSObject
// Nil when no language server is configured for the file. `fileType` is the
// one Compare detected for highlighting (nil without a grammar).
+ (instancetype)serviceForPath:(NSString*)path fileType:(NSString*)fileType;
@property (nonatomic, readonly) NSString* path;
// A server is set up for the file (it may still be starting).
@property (nonatomic, readonly, getter = isAvailable) BOOL available;
// The server has answered `initialize`, so requests get answers.
@property (nonatomic, readonly, getter = isReady) BOOL ready;

// `line` and `character` are 0-based, `character` in UTF-16 units. Locations
// are { uri, line, character }; an empty array when there is no definition.
- (void)definitionAtLine:(NSUInteger)line character:(NSUInteger)character completion:(void(^)(NSArray<NSDictionary*>* locations))completion;
// { value, kind, language } as LSPClient reports it, nil for none.
- (void)hoverAtLine:(NSUInteger)line character:(NSUInteger)character completion:(void(^)(NSDictionary* hover))completion;
// Closes the document with the server; also done on dealloc.
- (void)close;
@end

// The location to go to among a definition request's results: the first one
// that is not where the request was made, else the first.
NSDictionary* CompareBestDefinition (NSArray<NSDictionary*>* locations, NSString* path, NSUInteger line);

// The 0-based byte column in UTF-8 of a server's UTF-16 `character` on a
// line of the file on disk, as TextMate's txmt:// URLs count columns.
// `character` itself when the file cannot be read as UTF-8.
NSUInteger CompareUTF8Column (NSString* path, NSUInteger line, NSUInteger character);

// The path with symbolic links resolved (/var → /private/var), for comparing
// paths a server reports with ours.
NSString* CompareCanonicalPath (NSString* path);
