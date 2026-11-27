#import "CompareLanguage.h"
#import <document/OakDocument.h>
#import <lsp/LSPManager.h>
#import <settings/settings.h>
#import <ns/ns.h>
#include <stdlib.h>

NSString* CompareCanonicalPath (NSString* path)
{
	if(!path.length)
		return path;
	if(char* resolved = realpath(path.fileSystemRepresentation, nullptr))
	{
		NSString* result = [NSFileManager.defaultManager stringWithFileSystemRepresentation:resolved length:strlen(resolved)];
		free(resolved);
		return result;
	}
	return path.stringByStandardizingPath;
}

NSUInteger CompareUTF8Column (NSString* path, NSUInteger line, NSUInteger character)
{
	NSString* contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
	if(!contents)
		return character;
	// Lines as a server counts them: split at LF, CRLF ending one too.
	NSArray<NSString*>* lines = [contents componentsSeparatedByString:@"\n"];
	if(line >= lines.count)
		return character;
	NSString* text = lines[line];
	if([text hasSuffix:@"\r"])
		text = [text substringToIndex:text.length - 1];
	NSUInteger end = MIN(character, text.length);
	if(end < text.length) // not inside a surrogate pair
		end = [text rangeOfComposedCharacterSequenceAtIndex:end].location;
	return [[text substringToIndex:end] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
}

NSDictionary* CompareBestDefinition (NSArray<NSDictionary*>* locations, NSString* path, NSUInteger line)
{
	NSString* here = CompareCanonicalPath(path);
	for(NSDictionary* location in locations)
	{
		NSString* target = CompareCanonicalPath([NSURL URLWithString:location[@"uri"]].path);
		if(![target isEqualToString:here] || [location[@"line"] unsignedIntegerValue] != line)
			return location;
	}
	return locations.firstObject;
}

// Documents are shared by path, so two comparisons showing the same file
// share its document and its registration with the server: it is opened
// with LSPManager by the first service and closed by the last.
static NSCountedSet<NSUUID*>* Registrations ()
{
	static NSCountedSet* registrations = [NSCountedSet new];
	return registrations;
}

@implementation CompareLanguageService
{
	OakDocument* _document;
	BOOL _loaded;     // our open of the document, to balance with close
	BOOL _registered; // counted in Registrations()
	BOOL _closed;
}

+ (instancetype)serviceForPath:(NSString*)path fileType:(NSString*)fileType
{
	if(!path)
		return nil;
	// As LSPManager decides, without loading the file when nothing is set up.
	settings_t const settings = settings_for_path(to_s(path), fileType ? to_s(fileType) : NULL_STR, to_s(path.stringByDeletingLastPathComponent));
	if(settings.get("lspCommand", "").empty() || !settings.get("lspEnabled", true))
		return nil;
	return [[self alloc] initWithPath:path];
}

- (instancetype)initWithPath:(NSString*)path
{
	if(self = [super init])
	{
		_path = path;
		_document = [OakDocument documentWithPath:path];
		_document.recentTrackingDisabled = YES; // not one of the user's recent documents

		__weak CompareLanguageService* weakSelf = self;
		OakDocument* document = _document;
		[_document loadWithoutUIWithCompletionHandler:^(OakDocumentIOResult result, NSString* errorMessage, oak::uuid_t const& filterUUID){
			CompareLanguageService* strongSelf = weakSelf;
			if(!strongSelf || strongSelf->_closed)
			{
				[document close]; // balances the open done by loading
				return;
			}
			strongSelf->_loaded = YES;
			if(result == OakDocumentIOResultSuccess)
			{
				if([Registrations() countForObject:document.identifier] == 0)
					[LSPManager.sharedManager documentDidOpen:document];
				[Registrations() addObject:document.identifier];
				strongSelf->_registered = YES;
			}
		}];
	}
	return self;
}

- (void)dealloc
{
	[self close];
}

- (void)close
{
	if(_closed)
		return;
	_closed = YES;
	if(_registered)
	{
		[Registrations() removeObject:_document.identifier];
		if([Registrations() countForObject:_document.identifier] == 0)
			[LSPManager.sharedManager documentWillClose:_document];
	}
	if(_loaded)
		[_document close];
}

- (BOOL)isAvailable
{
	return !_closed && [LSPManager.sharedManager hasClientForDocument:_document];
}

- (BOOL)isReady
{
	NSString* status = self.available ? [LSPManager.sharedManager serverStatusForDocument:_document] : nil;
	return [status isEqualToString:@"running"] || [status isEqualToString:@"indexing"];
}

- (void)definitionAtLine:(NSUInteger)line character:(NSUInteger)character completion:(void(^)(NSArray<NSDictionary*>*))completion
{
	if(!self.available)
		return completion(@[ ]);
	// The document reloads itself when the file changes on disk; send what it has.
	[LSPManager.sharedManager flushPendingChangesForDocument:_document];
	[LSPManager.sharedManager requestDefinitionForDocument:_document line:line character:character completion:^(NSArray<NSDictionary*>* locations){
		completion(locations ?: @[ ]);
	}];
}

- (void)hoverAtLine:(NSUInteger)line character:(NSUInteger)character completion:(void(^)(NSDictionary*))completion
{
	if(!self.available)
		return completion(nil);
	[LSPManager.sharedManager flushPendingChangesForDocument:_document];
	[LSPManager.sharedManager requestHoverForDocument:_document line:line character:character completion:completion];
}
@end
