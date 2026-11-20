#ifndef COMPARE_DIFF_H_9TB4MWQ2
#define COMPARE_DIFF_H_9TB4MWQ2

#import <Foundation/Foundation.h>
#include <vector>

// Line diff of two files laid out as aligned rows for a side-by-side view.
// Each row shows one line per side, or a gap where that side has no line.

namespace compare {

	enum class row_kind : uint8_t {
		same,     // the line is on both sides, unchanged
		changed,  // paired lines that differ
		removed,  // line only on the left (gap on the right)
		added,    // line only on the right (gap on the left)
	};

	struct diff_row_t
	{
		row_kind kind;
		long left  = -1; // 0-based line on the left, -1 for a gap
		long right = -1; // 0-based line on the right, -1 for a gap
		long hunk  = -1; // index into text_diff_t::hunks, -1 for same rows
	};

	struct diff_hunk_t
	{
		long left_start, left_count;   // 0-based lines in the left file
		long right_start, right_count; // 0-based lines in the right file
		long first_row, row_count;     // rows in text_diff_t::rows
	};

	struct text_diff_t
	{
		NSString* problem = nil;      // set when no text diff is available
		NSArray<NSString*>* left_lines  = @[ ];
		NSArray<NSString*>* right_lines = @[ ];
		std::vector<diff_row_t> rows;
		std::vector<diff_hunk_t> hunks;
		BOOL left_missing_newline  = NO; // last line has no line terminator
		BOOL right_missing_newline = NO;
		BOOL left_crlf  = NO;            // uses CRLF line endings
		BOOL right_crlf = NO;
	};

	// Files larger than this are not diffed.
	static NSUInteger const kDiffSizeLimit = 8 * 1024 * 1024;

	// Pure: diffs two byte buffers (histogram algorithm, as Git uses). Binary
	// content (a NUL byte) sets `problem`. Text is decoded as UTF-8, falling
	// back to ISO Latin 1; displayed lines omit the line terminator.
	text_diff_t diff_data (NSData* left, NSData* right);

	// Reads and diffs two files. A nil path is an empty side (file missing).
	text_diff_t diff_files (NSString* left, NSString* right);

	// The range of the part of `lhs` that differs from `rhs`
	// after removing their common prefix and suffix (in UTF-16 units).
	NSRange changed_range (NSString* lhs, NSString* rhs);

} /* compare */

#endif /* end of include guard: COMPARE_DIFF_H_9TB4MWQ2 */
