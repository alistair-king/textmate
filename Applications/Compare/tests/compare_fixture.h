#ifndef COMPARE_FIXTURE_H_H4M9XB2C
#define COMPARE_FIXTURE_H_H4M9XB2C

#import <Foundation/Foundation.h>
#include <algorithm>
#include <initializer_list>

// A repository (left, main checkout on `main`) and a linked worktree (right,
// on `feature`) with one example of every comparison status. Shared by the
// model tests and the window tests. Helpers return an error message, nil on
// success, so each test target reports failures its own way.

struct compare_fixture_t
{
	NSString* left  = nil;
	NSString* right = nil;
	NSString* error = nil;
};

namespace compare_fixture {

	inline NSString* run_git (NSString* git, NSString* directory, NSArray<NSString*>* arguments)
	{
		NSTask* task = [NSTask new];
		task.executableURL = [NSURL fileURLWithPath:git];
		task.arguments = [@[ @"-C", directory, @"-c", @"user.name=Test", @"-c", @"user.email=test@example.invalid", @"-c", @"commit.gpgsign=false", @"-c", @"core.hooksPath=/dev/null" ] arrayByAddingObjectsFromArray:arguments];
		task.standardOutput = task.standardError = NSFileHandle.fileHandleWithNullDevice;
		if(![task launchAndReturnError:nil])
			return @"could not run git";
		[task waitUntilExit];
		return task.terminationStatus == 0 ? nil : [@"git failed: " stringByAppendingString:[arguments componentsJoinedByString:@" "]];
	}

	inline NSString* write (NSString* root, NSString* relativePath, NSString* contents)
	{
		NSString* path = [root stringByAppendingPathComponent:relativePath];
		[NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
		return [contents writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil] ? nil : [@"could not write " stringByAppendingString:relativePath];
	}

	inline NSString* link (NSString* root, NSString* relativePath, NSString* destination)
	{
		NSString* path = [root stringByAppendingPathComponent:relativePath];
		[NSFileManager.defaultManager removeItemAtPath:path error:nil];
		return [NSFileManager.defaultManager createSymbolicLinkAtPath:path withDestinationPath:destination error:nil] ? nil : [@"could not link " stringByAppendingString:relativePath];
	}

	inline NSString* remove (NSString* root, NSString* relativePath)
	{
		return [NSFileManager.defaultManager removeItemAtPath:[root stringByAppendingPathComponent:relativePath] error:nil] ? nil : [@"could not remove " stringByAppendingString:relativePath];
	}

	// Twenty numbered lines; the right side changes two separate lines.
	inline NSString* numbered_lines (std::initializer_list<long> changed)
	{
		NSMutableString* text = [NSMutableString string];
		for(long i = 1; i <= 20; ++i)
			[text appendFormat:std::find(changed.begin(), changed.end(), i) != changed.end() ? @"line %ld changed\n" : @"line %ld\n", i];
		return text;
	}

	inline compare_fixture_t create (NSString* git)
	{
		compare_fixture_t fixture;
		NSString* base = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"compare-fixture-" stringByAppendingString:NSUUID.UUID.UUIDString]];
		base = base.stringByResolvingSymlinksInPath;
		NSString* left  = [base stringByAppendingPathComponent:@"main"];
		NSString* right = [base stringByAppendingPathComponent:@"feature"];
		[NSFileManager.defaultManager createDirectoryAtPath:left withIntermediateDirectories:YES attributes:nil error:nil];

		NSArray<NSString*(^)()>* steps = @[
			^{ return run_git(git, left, @[ @"init", @"-q", @"-b", @"main" ]); },
			^{ return write(left, @".gitignore",     @"build/\n"); },
			^{ return write(left, @"same.txt",       @"same\n"); },
			^{ return write(left, @"same-size.txt",  @"aaaa\n"); },
			^{ return write(left, @"grown.txt",      @"short\n"); },
			^{ return write(left, @"gone.txt",       @"tracked\n"); },
			^{ return write(left, @"deep/a/b.txt",   @"original\n"); },
			^{ return write(left, @"deep/a/c.txt",   @"unchanged\n"); },
			^{ return write(left, @"kind",           @"a file on the left\n"); },
			^{ return link(left,  @"link",           @"same.txt"); },
			^{ return write(left, @"multi.txt",      numbered_lines({ })); },
			^{ return run_git(git, left, @[ @"add", @"-A" ]); },
			^{ return run_git(git, left, @[ @"commit", @"-q", @"-m", @"Initial" ]); },
			^{ return run_git(git, left, @[ @"worktree", @"add", @"-q", @"-b", @"feature", right ]); },

			// Left-side changes.
			^{ return write(left, @"left-only.txt",  @"untracked on the left\n"); },
			^{ return write(left, @"build/out.o",    @"ignored\n"); },
			^{ return write(left, @"é.txt",    @"accent\n"); }, // decomposed name

			// Right-side changes.
			^{ return write(right, @"same-size.txt",  @"bbbb\n"); },
			^{ return write(right, @"grown.txt",      @"much longer contents\n"); },
			^{ return write(right, @"deep/a/b.txt",   @"changed\n"); },
			^{ return write(right, @"newdir/x.txt",   @"new on the right\n"); },
			^{ return write(right, @"é.txt",     @"accent\n"); }, // precomposed name
			^{ return remove(right, @"gone.txt"); },
			^{ return remove(right, @"kind"); },
			^{ return write(right, @"kind/inner.txt", @"a folder on the right\n"); },
			^{ return link(right,  @"link",           @"grown.txt"); },
			^{ return write(right, @"multi.txt",      numbered_lines({ 3, 16 })); },
		];
		for(NSString*(^step)() in steps)
		{
			if(NSString* error = step())
			{
				fixture.error = error;
				return fixture;
			}
		}
		fixture.left  = left;
		fixture.right = right;
		return fixture;
	}

} /* compare_fixture */

#endif /* end of include guard: COMPARE_FIXTURE_H_H4M9XB2C */
