#import <AppKit/AppKit.h>
#import <mach-o/dyld.h>
#import "compare_url.h"
#include <vector>

static char const* const kUsage =
	"Usage: tm-compare [--focus <relative-path>] <left-folder> <right-folder>\n"
	"       tm-compare <left-file> <right-file>\n"
	"Opens TextMate's comparison of two folders (worktrees), or of two files.\n";

// The absolute, resolved path of an existing file or folder, or nil.
static NSString* ExistingPath (char const* argument, BOOL* isDirectory)
{
	NSString* path = [NSFileManager.defaultManager stringWithFileSystemRepresentation:argument length:strlen(argument)];
	if(!path.isAbsolutePath)
		path = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:path];
	path = path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
	return [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:isDirectory] ? path : nil;
}

int main (int argc, char const* argv[])
{
	@autoreleasepool
	{
		std::vector<char const*> folders; // or files
		NSString* focus = nil;
		for(int i = 1; i < argc; ++i)
		{
			if(strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0)
			{
				fputs(kUsage, stdout);
				return 0;
			}
			else if(strcmp(argv[i], "--focus") == 0 && i + 1 < argc)
			{
				focus = @(argv[++i]);
			}
			else if(argv[i][0] == '-')
			{
				fprintf(stderr, "tm-compare: unknown option %s\n%s", argv[i], kUsage);
				return 1;
			}
			else
			{
				folders.push_back(argv[i]);
			}
		}

		if(folders.size() != 2)
		{
			fputs(kUsage, stderr);
			return 1;
		}

		BOOL isDirectory[2] = { NO, NO };
		NSString* left  = ExistingPath(folders[0], &isDirectory[0]);
		NSString* right = ExistingPath(folders[1], &isDirectory[1]);
		for(size_t i = 0; i < 2; ++i)
		{
			if(!(i == 0 ? left : right))
			{
				fprintf(stderr, "tm-compare: %s does not exist\n", folders[i]);
				return 1;
			}
		}
		if(isDirectory[0] != isDirectory[1])
		{
			fprintf(stderr, "tm-compare: %s is a %s and %s is a %s; compare two folders or two files\n", folders[0], isDirectory[0] ? "folder" : "file", folders[1], isDirectory[1] ? "folder" : "file");
			return 1;
		}
		if(focus && !isDirectory[0])
		{
			fprintf(stderr, "tm-compare: --focus applies to folders, not files\n");
			return 1;
		}
		if([left isEqualToString:right])
		{
			fprintf(stderr, "tm-compare: both arguments are the same %s\n", isDirectory[0] ? "folder" : "file");
			return 1;
		}

		NSURL* request = compare::url(left, right, focus);
		if(!request)
		{
			fprintf(stderr, "tm-compare: --focus must be a relative path without “.” or “..” components\n");
			return 1;
		}

		uint32_t length = 0;
		_NSGetExecutablePath(nullptr, &length);
		std::vector<char> buffer(length);
		_NSGetExecutablePath(buffer.data(), &length);
		NSString* executable = [[NSString stringWithUTF8String:buffer.data()] stringByResolvingSymlinksInPath];
		NSString* contents = executable.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
		NSURL* app = [NSURL fileURLWithPath:[contents stringByAppendingPathComponent:@"Helpers/Compare.app"] isDirectory:YES];

		NSWorkspaceOpenConfiguration* configuration = [NSWorkspaceOpenConfiguration configuration];
		configuration.activates = YES;
		dispatch_semaphore_t finished = dispatch_semaphore_create(0);
		__block NSError* launchError = nil;
		[NSWorkspace.sharedWorkspace openURLs:@[ request ] withApplicationAtURL:app configuration:configuration completionHandler:^(NSRunningApplication* runningApp, NSError* error) {
			launchError = error;
			dispatch_semaphore_signal(finished);
		}];
		if(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) != 0)
		{
			fprintf(stderr, "tm-compare: timed out launching %s\n", app.fileSystemRepresentation);
			return 1;
		}
		if(launchError)
		{
			fprintf(stderr, "tm-compare: could not launch %s: %s\n", app.fileSystemRepresentation, launchError.localizedDescription.UTF8String);
			return 1;
		}
		return 0;
	}
}
