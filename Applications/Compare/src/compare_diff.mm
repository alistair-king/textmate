#import "compare_diff.h"
#include <regex.h> // xdiff.h uses regex_t
#include <xdiff.h>
#include <string.h>
#include <algorithm>
#include <array>

namespace compare {

	static NSString* Decode (NSData* data)
	{
		return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
	}

	// Text views start a new line at these too, but xdiff (and Git) split
	// only at LF: shown as symbols, each line stays one row. One UTF-16 unit
	// each way, so highlighting ranges stay aligned.
	static NSString* VisibleSeparators (NSString* line)
	{
		static NSCharacterSet* separators = [NSCharacterSet characterSetWithCharactersInString:@"\r\u0085\u2028\u2029"];
		if([line rangeOfCharacterFromSet:separators].location == NSNotFound)
			return line;
		NSMutableString* visible = [line mutableCopy];
		[visible replaceOccurrencesOfString:@"\r" withString:@"\u240D" options:0 range:NSMakeRange(0, visible.length)];     // ␍
		[visible replaceOccurrencesOfString:@"\u0085" withString:@"\u2424" options:0 range:NSMakeRange(0, visible.length)]; // ␤
		[visible replaceOccurrencesOfString:@"\u2028" withString:@"\u2424" options:0 range:NSMakeRange(0, visible.length)]; // ␤
		[visible replaceOccurrencesOfString:@"\u2029" withString:@"\u00B6" options:0 range:NSMakeRange(0, visible.length)]; // ¶
		return visible;
	}

	// Lines without terminators; a trailing line terminator does not start an
	// extra empty line. Matches how xdiff splits records.
	static NSArray<NSString*>* Lines (NSString* text, BOOL* missingNewline, BOOL* crlf)
	{
		*missingNewline = text.length && ![text hasSuffix:@"\n"];
		*crlf = [text rangeOfString:@"\r\n"].location != NSNotFound;
		if(!text.length)
			return @[ ];
		NSMutableArray<NSString*>* lines = [[text componentsSeparatedByString:@"\n"] mutableCopy];
		if(!*missingNewline)
			[lines removeLastObject];
		for(NSUInteger i = 0; i < lines.count; ++i)
		{
			if([lines[i] hasSuffix:@"\r"])
				lines[i] = [lines[i] substringToIndex:lines[i].length - 1];
			lines[i] = VisibleSeparators(lines[i]);
		}
		return lines;
	}

	text_diff_t diff_data (NSData* left, NSData* right)
	{
		text_diff_t result;
		left  = left  ?: [NSData data];
		right = right ?: [NSData data];
		result.left_data  = left;
		result.right_data = right;
		if(memchr(left.bytes, 0, left.length) || memchr(right.bytes, 0, right.length))
		{
			result.problem = @"Binary file. A text comparison is not available.";
			return result;
		}

		result.left_lines  = Lines(Decode(left), &result.left_missing_newline, &result.left_crlf);
		result.right_lines = Lines(Decode(right), &result.right_missing_newline, &result.right_crlf);

		std::vector<std::array<long, 4>> hunks;
		mmfile_t a = { (char*)left.bytes, (long)left.length }, b = { (char*)right.bytes, (long)right.length };
		xpparam_t parameters = { };
		parameters.flags = XDF_HISTOGRAM_DIFF;
		xdemitconf_t config = { };
		config.hunk_func = [](long startA, long countA, long startB, long countB, void* context) -> int {
			((std::vector<std::array<long, 4>>*)context)->push_back({ startA, countA, startB, countB });
			return 0;
		};
		xdemitcb_t callback = { };
		callback.priv = &hunks;
		if(xdl_diff(&a, &b, &parameters, &config, &callback) < 0)
		{
			result.problem = @"These files could not be compared.";
			return result;
		}

		long leftLine = 0, rightLine = 0;
		auto same = [&](long untilLeft){
			while(leftLine < untilLeft)
				result.rows.push_back({ row_kind::same, leftLine++, rightLine++ });
		};
		for(auto const& hunk : hunks)
		{
			// xdiff reports an insertion as starting after the preceding
			// line; zero-count starts are positions, not lines.
			same(hunk[0]);
			long index = result.hunks.size();
			diff_hunk_t entry = { hunk[0], hunk[1], hunk[2], hunk[3], (long)result.rows.size(), 0 };
			long paired = std::min(hunk[1], hunk[3]);
			for(long i = 0; i < paired; ++i)
				result.rows.push_back({ row_kind::changed, leftLine++, rightLine++, index });
			for(long i = paired; i < hunk[1]; ++i)
				result.rows.push_back({ row_kind::removed, leftLine++, -1, index });
			for(long i = paired; i < hunk[3]; ++i)
				result.rows.push_back({ row_kind::added, -1, rightLine++, index });
			entry.row_count = result.rows.size() - entry.first_row;
			result.hunks.push_back(entry);
		}
		same((long)result.left_lines.count);
		return result;
	}

	static NSData* Read (NSString* path, NSString** problem)
	{
		if(!path)
			return [NSData data];
		NSDictionary* attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
		if(attributes.fileSize > kDiffSizeLimit)
		{
			*problem = @"This file is too large to compare here (limit 8 MB).";
			return nil;
		}
		NSData* data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
		if(!data)
			*problem = [NSString stringWithFormat:@"“%@” could not be read.", path.lastPathComponent];
		return data;
	}

	text_diff_t diff_files (NSString* left, NSString* right)
	{
		NSString* problem = nil;
		NSData* leftData  = Read(left, &problem);
		NSData* rightData = leftData ? Read(right, &problem) : nil;
		if(!leftData || !rightData)
		{
			text_diff_t result;
			result.problem = problem;
			return result;
		}
		return diff_data(leftData, rightData);
	}

	NSRange changed_range (NSString* lhs, NSString* rhs)
	{
		NSUInteger prefix = 0, lhsLength = lhs.length, rhsLength = rhs.length;
		while(prefix < lhsLength && prefix < rhsLength && [lhs characterAtIndex:prefix] == [rhs characterAtIndex:prefix])
			++prefix;
		NSUInteger suffix = 0;
		while(suffix < lhsLength - prefix && suffix < rhsLength - prefix && [lhs characterAtIndex:lhsLength - suffix - 1] == [rhs characterAtIndex:rhsLength - suffix - 1])
			++suffix;
		// Keep surrogate pairs and composed characters whole.
		NSRange range = NSMakeRange(prefix, lhsLength - prefix - suffix);
		return range.length ? [lhs rangeOfComposedCharacterSequencesForRange:range] : range;
	}

} /* compare */
