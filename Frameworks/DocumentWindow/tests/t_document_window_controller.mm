#import <Cocoa/Cocoa.h>
#import "../src/DocumentWindowController.h"
#import "../src/TerminalPanelViewController.h"
#include <sys/xattr.h>

void test_window_without_documents_is_kept_for_file_browser_or_terminal ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		@autoreleasepool
		{
			[NSApplication sharedApplication];
			[DocumentWindowController disableSessionSave];
			DocumentWindowController* controller = [[DocumentWindowController alloc] init];
			OAK_ASSERT(!controller.keepsWindowWithoutDocuments);

			controller.fileBrowserVisible = YES;
			OAK_ASSERT(controller.keepsWindowWithoutDocuments);
			// Enabling the file browser in a window that was never laid out aborted when the project layout was pinned to a frame.
			OAK_ASSERT(![[controller valueForKey:@"layoutView"] translatesAutoresizingMaskIntoConstraints]);
			controller.fileBrowserVisible = NO;
			OAK_ASSERT(!controller.keepsWindowWithoutDocuments);

			TerminalPanelViewController* panel = [controller valueForKey:@"terminalPanelController"];
			panel.terminalShellPath      = @"/bin/sh";
			panel.terminalShellArguments = @[ ];
			[panel startTerminal];
			if(panel.hasTerminal) // built without the Swift terminal component
			{
				OAK_ASSERT(controller.keepsWindowWithoutDocuments);
				[panel stopTerminal];
				OAK_ASSERT(!controller.keepsWindowWithoutDocuments);
			}
			[DocumentWindowController enableSessionSave];
		}
	});
}

void test_launch_restores_only_projects_with_unsaved_changes ()
{
	@autoreleasepool
	{
		NSString* folder = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
		[NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];

		NSString* backedUp = NSUUID.UUID.UUIDString;
		NSString* backup = [folder stringByAppendingPathComponent:@"untitled"];
		[@"unsaved text" writeToFile:backup atomically:NO encoding:NSUTF8StringEncoding error:nil];
		char const* value = backedUp.UTF8String;
		OAK_ASSERT_EQ(setxattr(backup.fileSystemRepresentation, "com.macromates.backup.identifier", value, strlen(value), 0, 0), 0);
		[@"no identifier" writeToFile:[folder stringByAppendingPathComponent:@"stray"] atomically:NO encoding:NSUTF8StringEncoding error:nil];

		NSDictionary* unsaved  = @{ @"projectPath": @"/unsaved", @"documents": @[ @{ @"path": @"/unsaved/a.txt" }, @{ @"identifier": backedUp.lowercaseString } ] };
		NSDictionary* empty    = @{ @"projectPath": @"/empty",   @"documents": @[ @{ @"identifier": NSUUID.UUID.UUIDString } ] };
		NSDictionary* saved    = @{ @"projectPath": @"/saved",   @"documents": @[ @{ @"path": @"/saved/b.txt" } ] };
		NSDictionary* nothing  = @{ @"projectPath": @"/nothing" };

		NSArray* restored = [DocumentWindowController sessionProjects:@[ empty, unsaved, saved, nothing ] withUnsavedChangesInFolder:folder];
		OAK_ASSERT([restored isEqual:@[ unsaved ]]);
		OAK_ASSERT_EQ([DocumentWindowController sessionProjects:@[ unsaved ] withUnsavedChangesInFolder:[folder stringByAppendingPathComponent:@"missing"]].count, 0);

		[NSFileManager.defaultManager removeItemAtPath:folder error:nil];
	}
}
