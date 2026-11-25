#ifndef COMPARE_WATCH_H_N2D7RC4E
#define COMPARE_WATCH_H_N2D7RC4E

#import <Foundation/Foundation.h>
#import <CoreServices/CoreServices.h>

// File-system change notifications for folders, delivered on the main queue
// as batches of changed paths (FSEvents file events, coalesced by
// `latency`). Header-only: used by Compare.app and by TextMate's
// Compare To menu. Stops when destroyed.

namespace compare {

	struct folder_watch_t
	{
		using handler_t = void (^)(NSArray<NSString*>* paths);

		folder_watch_t () = default;
		folder_watch_t (folder_watch_t const&) = delete;
		folder_watch_t& operator= (folder_watch_t const&) = delete;
		~folder_watch_t () { stop(); }

		// Replaces any previous watch. `excluded` (at most 8) are skipped by FSEvents.
		void start (NSArray<NSString*>* folders, NSArray<NSString*>* excluded, CFTimeInterval latency, handler_t handler)
		{
			stop();
			if(!folders.count)
				return;
			_handler = [handler copy];
			FSEventStreamContext context = { 0, (void*)this, nullptr, nullptr, nullptr };
			FSEventStreamCreateFlags flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot;
			_stream = FSEventStreamCreate(kCFAllocatorDefault, &callback, &context, (__bridge CFArrayRef)folders, kFSEventStreamEventIdSinceNow, latency, flags);
			if(!_stream)
				return;
			if(excluded.count)
				FSEventStreamSetExclusionPaths(_stream, (__bridge CFArrayRef)[excluded subarrayWithRange:NSMakeRange(0, MIN(excluded.count, (NSUInteger)8))]);
			FSEventStreamSetDispatchQueue(_stream, dispatch_get_main_queue());
			FSEventStreamStart(_stream);
		}

		void stop ()
		{
			if(_stream)
			{
				FSEventStreamStop(_stream);
				FSEventStreamInvalidate(_stream);
				FSEventStreamRelease(_stream);
				_stream = nullptr;
			}
			_handler = nil;
		}

		bool running () const { return _stream != nullptr; }

	private:
		static void callback (ConstFSEventStreamRef stream, void* info, size_t count, void* paths, FSEventStreamEventFlags const* flags, FSEventStreamEventId const* ids)
		{
			folder_watch_t* watch = (folder_watch_t*)info;
			if(watch->_handler)
				watch->_handler((__bridge NSArray*)(CFArrayRef)paths);
		}

		FSEventStreamRef _stream = nullptr;
		handler_t _handler = nil;
	};

} /* compare */

#endif /* end of include guard: COMPARE_WATCH_H_N2D7RC4E */
