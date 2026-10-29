# File Tracking & Indexing Research for LSP Workspace/didChangeWatchedFiles

## Executive Summary

TextMate has **multiple overlapping file tracking mechanisms** that could be leveraged for LSP workspace/didChangeWatchedFiles implementation:

1. **FSEventsManager** - macOS FSEvents-based directory watching (FileBrowser)
2. **KEventManager** - Kevent-based file-level watching (FileBrowser)
3. **SCM watcher_t** - File system watcher for SCM repositories
4. **track_paths_t** - Document-level file change tracking via dispatch_source
5. **FileItem observers** - Directory content enumeration and change tracking

---

## 1. FSEventsManager (FileBrowser Framework)

**File:** `/Frameworks/FileBrowser/src/FSEventsManager.{h,mm}`

### What It Does
- High-level wrapper around macOS FSEvents API
- Watches directory changes with optional subdirectory monitoring
- Uses `FSEventStreamCreate()` with 0.5s latency
- **No explicit file/folder creation/deletion detection** — reports entire directory changes

### Key Classes
```
FSEventsManager (singleton)
├── FSEventsDirectory (per watched directory)
│   └── FSEventsClient (per observer callback)
└── fs_events_t (C++ wrapper around FSEventStreamRef)
```

### API
```mm
- (id)addObserverToDirectoryAtURL:(NSURL*)url usingBlock:(void(^)(NSURL*))handler;
- (id)addObserverToDirectoryAtURL:(NSURL*)url 
         observeSubdirectories:(BOOL)flag usingBlock:(void(^)(NSURL*))handler;
- (void)removeObserver:(id)someObserver;
- (void)reloadDirectoryAtURL:(NSURL*)url;
```

### Callback Behavior
- Callback invoked when directory or its subdirectories change
- Parameter: NSURL of the changed directory (not individual files)
- **Does NOT enumerate what changed** — caller must rescan directory

### FSEvents Implementation Details
```cpp
FSEventStreamRef _eventStream;
FSEventStreamContext contextInfo = { 0, this, nullptr, nullptr, nullptr };
FSEventStreamCreate(kCFAllocatorDefault, &fs_events_t::callback, 
                    &contextInfo, (__bridge CFArrayRef)pathsToWatch, 
                    kFSEventStreamEventIdSinceNow, 0.5, 
                    kFSEventStreamCreateFlagNone)
```

---

## 2. KEventManager (FileBrowser Framework)

**File:** `/Frameworks/FileBrowser/src/KEventManager.{h,mm}`

### What It Does
- Kevent-based file-level change detection
- Tracks individual file operations (write, delete, rename, extend, etc.)
- Uses `dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, ...)`
- Maintains tree of watched file paths with parent-child relationships

### Key Classes
```
KEventManager (singleton)
└── KEventManagerNode (tree structure for paths)
    ├── dispatch_source_t _dispatchSource (per inode)
    ├── NSMutableArray<KEventManagerCallback*> _callbacks
    └── NSMapTable<NSString*, KEventManagerNode*> _childNodesMap
```

### API
```mm
- (id)addObserverToItemAtURL:(NSURL*)url usingBlock:(void(^)(NSURL*, NSUInteger))handler;
- (void)removeObserver:(id)someObserver;
- (void)dumpNodes;
```

### Callback Signature
```mm
void(^handler)(NSURL*, NSUInteger mask)
```
Where mask includes:
- `DISPATCH_VNODE_DELETE` - File deleted
- `DISPATCH_VNODE_WRITE` - File written to
- `DISPATCH_VNODE_EXTEND` - File extended
- `DISPATCH_VNODE_ATTRIB` - File attributes changed
- `DISPATCH_VNODE_LINK` - Links changed
- `DISPATCH_VNODE_RENAME` - File renamed
- `DISPATCH_VNODE_REVOKE` - Vnode revoked
- `DISPATCH_VNODE_FUNLOCK` - File unlock

### Key Implementation
```mm
dispatch_source_t source = dispatch_source_create(
    DISPATCH_SOURCE_TYPE_VNODE, fd, 
    DISPATCH_VNODE_DELETE|DISPATCH_VNODE_WRITE|DISPATCH_VNODE_EXTEND|
    DISPATCH_VNODE_ATTRIB|DISPATCH_VNODE_LINK|DISPATCH_VNODE_RENAME|
    DISPATCH_VNODE_REVOKE, 
    dispatch_get_main_queue());
```

---

## 3. FileItem Observer System

**Files:** `/Frameworks/FileBrowser/src/FileItemObserver.mm`, `/FileItem.h`

### Architecture
```
FileItem (Observer category)
└── addObserverToDirectoryAtURL:usingBlock:
    ├── URLObserver (per directory, cached)
    │   ├── URLObserverClient* (per callback)
    │   └── id driver (FileSystemObserver for local files)
    └── FileSystemObserver (combines FSEvents + SCM)
        ├── FSEventsObserver → FSEventsManager
        └── SCMObserver → SCMManager
```

### How FileSystemObserver Works
1. **FSEvents trigger** → calls `loadContentsOfDirectoryAtURL:` on background queue
2. **contentsOfDirectoryAtURL** enumerates actual files with metadata:
   - NSURLIsDirectoryKey
   - NSURLIsPackageKey
   - NSURLIsSymbolicLinkKey
   - NSURLIsHiddenKey
   - NSURLLocalizedNameKey
   - NSURLEffectiveIconKey
3. **SCM status integration** → filters out deleted files from SCM perspective
4. **Cache management** → `URLObserver.cachedURLs` stores current directory content
5. **Callback invocation** → all URLObserverClient handlers called with NSURL array

### Code Flow
```objc
dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSArray<NSURL*>* urls = [NSFileManager.defaultManager 
        contentsOfDirectoryAtURL:url 
        includingPropertiesForKeys:@[...] options:0 error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf updateFSEventsURLs:urls scmURLs:nil];
    });
});
```

---

## 4. SCM File Tracking

**Files:** 
- `/Frameworks/scm/src/fs_events.h` - C++ watcher_t
- `/Frameworks/FileBrowser/src/SCMManager.h` - Objective-C wrapper
- `/Frameworks/FileBrowser/src/FileItemObserver.mm` - Integration

### SCM watcher_t (C++)
```cpp
namespace scm {
    struct watcher_t {
        watcher_t(std::string const& path, 
                 std::function<void(std::set<std::string> const&)> const& callback);
        ~watcher_t();
        
    private:
        static void callback_function(ConstFSEventStreamRef streamRef, 
                                     void* clientCallBackInfo, size_t numEvents, 
                                     void* eventPaths, 
                                     FSEventStreamEventFlags const eventFlags[], 
                                     FSEventStreamEventId const eventIds[]);
        
        std::string path;
        std::function<void(std::set<std::string> const&)> callback;
        std::string mount_point;
        FSEventStreamRef stream;
    };
}
```

### SCMManager Integration
- Watches repository directories for file changes
- Provides SCMRepository with `std::map<std::string, scm::status::type> status`
- Tracks deleted files separately from SCM perspective
- Used by FileSystemObserver to filter SCM-deleted files

---

## 5. Document-Level File Change Tracking

**File:** `/Frameworks/settings/src/track_paths.h`

### track_paths_t (C++ Header-Only)
```cpp
struct track_paths_t {
    void add(std::string const& path);
    void remove(std::string const& path);
    bool is_changed(std::string const& path);
    
private:
    struct track_fds_t {
        void watch(int fd);  // dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, ...)
        void unwatch(int fd);
        bool is_changed(int fd);
    };
    
    std::map<std::string, std::pair<int, bool>> _open_files;
};
```

### Capabilities
- Tracks individual open document files via file descriptors
- Uses `dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd, ...)`
- Watches: DELETE, WRITE, EXTEND, RENAME, REVOKE
- Can detect when file is deleted then recreated
- **Per-document tracking, not workspace-wide**

---

## 6. Project/Workspace Root Detection

**File:** `/Frameworks/lsp/src/LSPManager.mm`

### Current Implementation
```cpp
static std::string detectWorkspaceRoot(std::string const& filePath) {
    std::string dir = path::parent(filePath);
    std::string previousDir;
    
    while(dir != previousDir && dir != "/") {
        for(auto const& marker : workspaceMarkers()) {
            if(path::exists(path::join(dir, marker)))
                return dir;
        }
        previousDir = dir;
        dir = path::parent(dir);
    }
    
    return path::parent(filePath);  // Fallback
}

static std::set<std::string> workspaceMarkers() {
    static std::set<std::string> markers = {
        ".git", ".hg", ".svn", "package.json", "Gemfile", 
        "go.mod", "Cargo.toml", "pyproject.toml", "setup.py", ".clangd"
    };
    return markers;
}
```

### Settings Override
```cpp
std::string rootPath = settings.get("lspRootPath", "");
if(rootPath.empty())
    rootPath = detectWorkspaceRoot(filePath);
```

---

## 7. Document Tracking in LSP Manager

**File:** `/Frameworks/lsp/src/LSPManager.mm`

### Open Document Tracking
```objc
@interface LSPManager () <LSPClientDelegate> {
    NSMutableDictionary<NSString*, LSPClient*>* _clients;
    NSMutableDictionary<NSUUID*, LSPClient*>* _documentClients;
    NSMutableDictionary<NSUUID*, NSNumber*>* _documentVersions;
    NSMutableSet<NSUUID*>* _openDocuments;  // ← Active documents
    NSMutableDictionary<NSUUID*, NSTimer*>* _changeTimers;
    NSMutableDictionary<NSString*, NSArray<NSDictionary*>*>* _diagnosticsByURI;
}
```

### Document Operations
- `documentDidOpen:(OakDocument*)document` - Track new documents
- `documentDidChange:(OakDocument*)document` - Debounced with 300ms timer
- `documentDidSave:(OakDocument*)document` - Track saves
- `documentWillClose:(OakDocument*)document` - Cleanup

---

## 8. Open Documents & File Chooser

**File:** `/Frameworks/OakFilterList/src/FileChooser.mm`

### Document List Tracking
```objc
[self addRecordsForDocuments:[OakDocumentController.sharedInstance openDocuments]];
```

- OakDocumentController maintains list of open documents
- FileChooser can enumerate open documents by type:
  - kFileChooserOpenDocumentsSourceIndex = 1
  - kFileChooserUncommittedChangesSourceIndex = 2

---

## 9. Potential Integration Points for LSP didChangeWatchedFiles

### Option A: Use FSEventsManager + Directory Enumeration
**Pros:**
- Already singleton in use
- No new infrastructure needed
- Works for directory-level changes

**Cons:**
- Doesn't distinguish create/delete/modify operations
- Requires full directory rescan on each change
- Not granular enough for specific file operations

### Option B: Use KEventManager for File-Level Precision
**Pros:**
- Exact operation type (WRITE, DELETE, RENAME, etc.)
- Per-file granularity
- Already implements tree structure

**Cons:**
- Only individual file watching (need to iterate all workspace files)
- More overhead for large workspaces

### Option C: Hybrid Approach (Recommended)
1. **Watch project root** with FSEventsManager
2. **On FSEvents trigger:**
   - Get cached directory listing from FileItem
   - Compare to previous snapshot
   - Determine create/delete/modify operations
3. **Send didChangeWatchedFiles** with specific operations

### Option D: Leverage FileSystemObserver + SCM Integration
1. **Use existing FileSystemObserver** from FileItem
2. **Hook into existing cached URLs** system
3. **Track changes** at document open/save time
4. **Optionally watch project root** with FSEventsManager

---

## 10. Key Data Structures Available

### FileItem Properties
```objc
@property NSURL* URL;
@property NSURL* resolvedURL;
@property NSURL* parentURL;
@property BOOL directory;
@property NSString* displayName;
@property BOOL missing;
@property BOOL hidden;
@property NSArray<FileItem*>* children;
@property NSArray<FileItem*>* arrangedChildren;
```

### SCMRepository Properties
```objc
@property NSURL* URL;
@property BOOL enabled;
@property BOOL tracksDirectories;
@property std::map<std::string, scm::status::type> status;
```

---

## 11. No Existing didChangeWatchedFiles Implementation

Search results show:
- **NO** didChangeWatchedFiles in LSP framework
- **NO** workspace/didChangeWatchedFiles notifications
- LSP only tracks **open documents**, not entire workspace
- Excellent opportunity for new feature

---

## Recommended Architecture

```
LSPManager
├── _workspaceRoots: Set<String>  (per LSPClient workingDirectory)
├── _watchedDirectories: Map<String, FSEventsObserver>
├── _fileIndex: Map<String, FileMetadata>  (optional, for tracking changes)
│   └── FileMetadata: { mtime, size, isDirectory }
└── workspace/didChangeWatchedFiles protocol

On FSEvents trigger:
1. Load directory contents
2. Compare to _fileIndex snapshot
3. Build change array:
   - type: "created" | "changed" | "deleted"
   - uri: file:// URI
4. Send workspace/didChangeWatchedFiles notification
```

---

## Files to Review Further

1. `/Frameworks/FileBrowser/src/FileItemObserver.mm` - Change integration pattern
2. `/Frameworks/lsp/src/LSPClient.mm` - JSON-RPC notification sending
3. `/Frameworks/DocumentWindow/src/DocumentWindowController.mm` - Document tracking
4. `/Frameworks/document/src/OakDocument.h` - Document abstraction
5. `/Frameworks/scm/src/fs_events.h` - SCM watcher implementation
