#ifndef COMPARE_URL_H_7Q2KXW4M
#define COMPARE_URL_H_7Q2KXW4M

#import <Foundation/Foundation.h>

// textmate-compare://compare?left=<abs path>&right=<abs path>[&focus=<rel path>]
//
// Shared by tm-compare, Compare.app and TextMate. Paths may contain any
// character, so values are encoded with a query set that excludes the
// separators (& = + #) NSURLComponents would otherwise leave as is.

namespace compare {

	static NSString* const kCompareURLScheme = @"textmate-compare";
	static NSString* const kCompareURLHost   = @"compare";

	inline NSString* encode_query_value (NSString* value)
	{
		NSMutableCharacterSet* allowed = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
		[allowed removeCharactersInString:@"&=+#;"];
		return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed];
	}

	inline BOOL is_valid_root (NSString* path)
	{
		return path.length && path.isAbsolutePath;
	}

	// A focus path names a folder below the left root: relative, without
	// empty, “.” or “..” components.
	inline BOOL is_valid_focus (NSString* focus)
	{
		if(!focus.length || focus.isAbsolutePath)
			return NO;
		for(NSString* component in [focus componentsSeparatedByString:@"/"])
		{
			if(!component.length || [component isEqualToString:@"."] || [component isEqualToString:@".."])
				return NO;
		}
		return YES;
	}

	inline NSURL* url (NSString* left, NSString* right, NSString* focus = nil)
	{
		if(!is_valid_root(left) || !is_valid_root(right) || (focus.length && !is_valid_focus(focus)))
			return nil;
		NSMutableString* query = [NSMutableString stringWithFormat:@"left=%@&right=%@", encode_query_value(left), encode_query_value(right)];
		if(focus.length)
			[query appendFormat:@"&focus=%@", encode_query_value(focus)];
		NSURLComponents* components = [NSURLComponents new];
		components.scheme = kCompareURLScheme;
		components.host   = kCompareURLHost;
		components.path   = @"/";
		components.percentEncodedQuery = query;
		return components.URL;
	}

	// txmt://open?url=file://<abs path>[&line=<1-based>[&column=<1-based>]]:
	// TextMate opens the file, at the line (and column) when given. Its
	// handler splits on & and = before decoding, so the value is encoded like ours.
	inline NSURL* textmate_url (NSString* path, NSInteger line = 0, NSInteger column = 0)
	{
		if(!is_valid_root(path))
			return nil;
		NSMutableString* query = [NSMutableString stringWithFormat:@"url=%@", encode_query_value([@"file://" stringByAppendingString:path])];
		if(line > 0)
			[query appendFormat:@"&line=%ld", (long)line];
		if(line > 0 && column > 0)
			[query appendFormat:@"&column=%ld", (long)column];
		NSURLComponents* components = [NSURLComponents new];
		components.scheme = @"txmt";
		components.host   = @"open";
		components.percentEncodedQuery = query;
		return components.URL;
	}

	struct request_t
	{
		NSString* left  = nil;
		NSString* right = nil;
		NSString* focus = nil; // nil when the left root itself is the focus
	};

	inline BOOL parse (NSURL* url, request_t* request)
	{
		if(![url.scheme isEqualToString:kCompareURLScheme] || ![url.host isEqualToString:kCompareURLHost])
			return NO;
		NSURLComponents* components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
		request_t result;
		for(NSString* pair in [components.percentEncodedQuery componentsSeparatedByString:@"&"])
		{
			NSRange equal = [pair rangeOfString:@"="];
			if(equal.location == NSNotFound)
				return NO;
			NSString* name  = [pair substringToIndex:equal.location];
			NSString* value = [[pair substringFromIndex:NSMaxRange(equal)] stringByRemovingPercentEncoding];
			if(!value)
				return NO;
			NSString* __strong* slot = [name isEqualToString:@"left"] ? &result.left : [name isEqualToString:@"right"] ? &result.right : [name isEqualToString:@"focus"] ? &result.focus : nullptr;
			if(!slot || *slot) // unknown or repeated parameter
				return NO;
			*slot = value;
		}
		if(!is_valid_root(result.left) || !is_valid_root(result.right))
			return NO;
		if(result.focus && !is_valid_focus(result.focus))
			return NO;
		if(request)
			*request = result;
		return YES;
	}

} /* compare */

#endif /* end of include guard: COMPARE_URL_H_7Q2KXW4M */
