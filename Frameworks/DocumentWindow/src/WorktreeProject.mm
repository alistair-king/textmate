#import "WorktreeProject.h"

static NSString* ReadFile (NSString* path)
{
	return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
}

static NSString* Trim (NSString* str)
{
	return [str stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// Returns the value of “key” in the git config section whose header matches “section” (a regex).
static NSString* ConfigValue (NSString* config, NSString* section, NSString* key)
{
	NSString* pattern = [NSString stringWithFormat:@"^\\s*\\[%@\\][^\\[]*?^\\s*%@\\s*=\\s*(.*?)\\s*$", section, key];
	NSRegularExpression* regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive|NSRegularExpressionAnchorsMatchLines error:nil];
	NSTextCheckingResult* match = [regex firstMatchInString:config options:0 range:NSMakeRange(0, config.length)];
	if(!match)
		return nil;
	NSString* value = [config substringWithRange:[match rangeAtIndex:1]];
	if(value.length >= 2 && [value hasPrefix:@"\""] && [value hasSuffix:@"\""])
		value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
	return value;
}

static NSString* RepositoryName (NSString* remoteURL)
{
	NSString* name = Trim(remoteURL);
	while([name hasSuffix:@"/"])
		name = [name substringToIndex:name.length - 1];
	NSRange separator = [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/:"] options:NSBackwardsSearch];
	if(separator.location != NSNotFound)
		name = [name substringFromIndex:NSMaxRange(separator)];
	if([name.lowercaseString hasSuffix:@".git"])
		name = [name substringToIndex:name.length - 4];
	return name.length ? name : nil;
}

NSString* WorktreeProjectName (NSString* checkout)
{
	if(!checkout.length)
		return nil;
	checkout = checkout.stringByStandardizingPath;

	// Locate the main checkout: “checkout” itself, or for a linked worktree the
	// owner of the “.git/worktrees/<name>” directory its .git file points to.
	BOOL isDirectory = NO;
	NSString* dotGit = [checkout stringByAppendingPathComponent:@".git"];
	if(![NSFileManager.defaultManager fileExistsAtPath:dotGit isDirectory:&isDirectory])
		return nil;

	NSString* mainCheckout = checkout;
	if(!isDirectory)
	{
		NSString* link = ReadFile(dotGit);
		if(![link hasPrefix:@"gitdir:"])
			return nil;
		NSString* gitDir = Trim([link substringFromIndex:7]);
		if(!gitDir.isAbsolutePath) // worktree.useRelativePaths
			gitDir = [checkout stringByAppendingPathComponent:gitDir];
		gitDir = gitDir.stringByStandardizingPath;
		if(![gitDir.stringByDeletingLastPathComponent.lastPathComponent isEqualToString:@"worktrees"])
			return nil;
		NSString* commonDir = gitDir.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
		if(![commonDir.lastPathComponent isEqualToString:@".git"])
			return nil; // bare repository
		mainCheckout = commonDir.stringByDeletingLastPathComponent;
	}

	// Only siblings of the main checkout belong to the container.
	NSString* container = mainCheckout.stringByDeletingLastPathComponent;
	if(![checkout.stringByDeletingLastPathComponent isEqualToString:container] || [container isEqualToString:@"/"])
		return nil;

	NSString* config = ReadFile([mainCheckout stringByAppendingPathComponent:@".git/config"]);
	if(!config)
		return nil;

	NSString* layout = ConfigValue(config, @"textmate", @"layout");
	if(layout && [layout caseInsensitiveCompare:@"worktrees"] == NSOrderedSame)
		return container.lastPathComponent;

	// Projects laid out by hand: the container is named after the repository.
	NSString* name = RepositoryName(ConfigValue(config, @"remote\\s+\"origin\"", @"url"));
	if(name && [container.lastPathComponent caseInsensitiveCompare:name] == NSOrderedSame)
		return container.lastPathComponent;
	return nil;
}
