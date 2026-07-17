# WebDAV comic streaming

## Status and scope

This fork implements synchronous, seekable WebDAV streaming for CBZ and CBR
documents without changing MuPDF itself.

CBZ is the supported random-access format. CBR remains experimental because a
solid RAR may require reading most of the archive before a later page can be
decoded. Strict CBR mode aborts an inefficient operation; it never falls back
to a complete local download.

The implementation spans KOReader's normal frontend/base boundary, but all
project-owned changes are tracked in this repository:

- the public `koreader-base` submodule plus `patches/koreader-base/` own
  libcurl, the seekable `fz_stream`, MuPDF FFI bindings, bounded RAM cache,
  validators, telemetry, and native tests;
- the main tree owns WebDAV UI, descriptor identity, reader lifecycle, cache
  and cover privacy, Wi-Fi leases, settings, and frontend tests.

## Revisions to the original plan

Source inspection and executable tests required these changes:

1. The active WebDAV UI is `plugins/cloudstorage.koplugin`, not the historical
   frontend cloud-storage path.
2. The one-byte capability probe is native and response-bounded. A LuaSocket
   sink could otherwise consume a complete `200 OK` response from a server
   that ignored `Range`.
3. MuPDF's comic handler deliberately turns some archive and image exceptions
   into a generic archive error or a blank page. The binding checks the remote
   stream after archive open and every page load so authentication, changed
   file, network, and strict-limit failures remain visible.
4. LRU eviction happens before allocating an incoming block. Consequently the
   block buffers never transiently exceed the configured ceiling.
5. Metadata identity is the MD5 of `server UUID + NUL + normalized remote
   path`, not a hash of descriptor contents. Progress therefore survives ETag
   updates.
6. The descriptor is a small real `.cbz` or `.cbr` file because history and
   reader code require a filesystem path. It contains JSON metadata only and
   never credentials or comic bytes.
7. CBR strict limits are applied independently to archive opening and each
   page load. The default limit is `min(64 MiB, max(16 MiB, 25% of archive))`.
8. Persistent tiles, covers, screensaver images, and CoverBrowser extraction
   are blocked explicitly; relying on the native RAM cache alone is
   insufficient.
9. On macOS, the static curl build disables curl's optional
   `SCDynamicStoreCopyProxies` NAT64 workaround. That initializer recursively
   entered the system allocator in KOReader's runtime. Normal hostname
   resolution and all target-device builds are unaffected.
10. The original “hundreds, not thousands” line estimate was too optimistic.
    The hardened implementation is roughly 1,900 production lines across the
    frontend and native patch queue, plus about 800 lines of adversarial and
    integration tests. Most of that size is isolated in the native stream,
    descriptor lifecycle, and test server rather than MuPDF.

## Data flow

```text
Cloud Storage selection
  -> bounded GET bytes=0-0 probe
  -> non-secret remote descriptor
  -> DocumentRegistry / PdfDocument
  -> libcurl-backed seekable fz_stream
  -> bounded in-memory block LRU
  -> MuPDF ZIP/libarchive comic reader
  -> current page and configurable lookahead
```

The stream is synchronous. A MuPDF read for a cache miss blocks until the
requested range arrives or fails. MuPDF's asynchronous `FZ_ERROR_TRYLATER`
path is intentionally out of scope.

## Network and consistency rules

Every block request:

- sends `Range: bytes=start-end`, `Accept-Encoding: identity`, and
  `Cache-Control: no-transform`;
- accepts only HTTP(S), rejects URL user-info, verifies TLS certificates, and
  forbids HTTPS-to-HTTP redirects;
- does not forward credentials across an origin-changing redirect;
- requires `206 Partial Content`;
- requires an exact `Content-Range`, unchanged total size, and exact body
  length;
- requires a strong ETag or Last-Modified validator to remain present and
  unchanged when the capability probe returned one;
- uses `If-Range` with a strong ETag, otherwise Last-Modified when available;
- retries one transient connection, timeout, send, receive, or partial-body
  failure;
- returns a typed, user-facing error and never starts a normal download.

If the probe supplies neither a strong ETag nor Last-Modified, exact range,
size, and body-length validation still applies. The reader opens without an
extra confirmation prompt.

## Cache and privacy lifecycle

The default range block is 1 MiB and the default block-cache ceiling is 32 MiB.
The larger block avoids excessive redirect and request latency on comic-sized
images while retaining bounded over-fetch. The UI offers 8, 16, 32, and 64
MiB cache ceilings. The cache is RAM-only.

Any failed range request, including a changed validator, immediately clears
the native range blocks. When a remote document closes or switches:

- native range blocks are cleared and owned credential buffers are zeroed;
- decoded document tiles are evicted from `DocCache`;
- MuPDF's decoded-object store is emptied;
- no page is serialized to KOReader's disk cache;
- cover, thumbnail, screensaver, and CoverBrowser extraction paths refuse the
  remote descriptor;
- the document's network lease is released;
- Lua references to the URL, username, and password are discarded.

With progress retention enabled, the descriptor and ordinary reading metadata
remain. With “forget book” selected, descriptor, sidecar progress, history,
collections, cached book information, and empty descriptor directories are
removed together. Startup cleanup handles interrupted zero-byte descriptors
and forgotten books.

## UI and power behavior

Tapping a WebDAV `.cbz` or `.cbr` streams it immediately. KOReader checks
Wi-Fi, performs the native probe, persists a stable server UUID, creates the
descriptor, closes Cloud Storage, and opens ReaderUI without an action or
validator-confirmation dialog. Normal reader controls and recovery paths stay
available, but the alternate tap-to-download comic flow is removed.

On a normal KOReader launch, FileManager is created as a recovery layer and
the first configured WebDAV server is opened over it on the next UI tick.
Closing the cloud browser still exposes FileManager, and explicit file or
directory command-line launches remain available for recovery. The startup
callback is registered only on FileManager; ReaderUI must never reopen the
WebDAV browser over a book that has just finished rendering.

Every remote-document open overrides stale per-book display settings before
they are read. Streamed paged documents start in page view with full-page fit;
streamed reflowable documents start in page view as well. Local books retain
normal KOReader per-book settings. The user can still change the view while a
remote book is open, but a later open reapplies the streaming policy.

Long-pressing a remote file or folder exposes an explicit delete action.
DELETE requests use the resource URI returned by WebDAV, carry a zero content
length, wait for connectivity through KOReader's normal network guard, and
follow only bounded same-origin redirects. A server-confirmed deletion removes
matching local descriptors and progress metadata; collection deletion cleans
descriptors for descendants as well. An already-absent response refreshes the
listing but conservatively retains local reading metadata. A malformed or
partly failed `207 Multi-Status` remains an error instead of being mistaken for
success. KOReader also blocks deletion of the currently open remote book or
one of its parent collections until that book is closed.

Reaching the end of a streamed book automatically marks that WebDAV resource
as read, independently of the local-book auto-mark preference. Read books show
`✓ Read` beside their size in the WebDAV browser. Long-pressing a file also
offers **Mark as read** or **Mark as unread**, and the normal reader book-status
control stays synchronized with the same state. The registry is keyed by the
stable server UUID and normalized remote path, flushed immediately to a
dedicated settings file, and therefore survives restarts and descriptor or
sidecar cleanup. A confirmed file or collection deletion removes the matching
read-state records; an ambiguous already-absent response retains them.

The packaged browser intentionally lists CBZ/CBR resources and collections
only. Generic cloud downloads, uploads, collection creation, and folder-sync
controls are removed from the focused streaming UI.

Kobo release packages use a strict feature allowlist. WebDAV streaming is the
only installed content/network plugin and WebDAV is its only provider. The
power-relevant Auto power save and Automatic dimmer plugins are also packaged.
The legacy Cloud Storage application is omitted. The Tools menu contains only
WebDAV streaming; text editor, news downloader, Wallabag, move-to-archive,
archive viewer, OPDS, terminal, synchronization, statistics, and other
auxiliary plugins and search tools are neither packaged nor exposed. Essential
reading/navigation, progress and history, display and network settings, USB
storage, exit, recovery, suspend, and frontlight controls remain.

Streaming settings include:

- RAM block-cache size;
- page lookahead of 0, 1, or 2 (off by default to avoid speculative radio,
  decode, and render work);
- inactive Wi-Fi shutdown (enabled for new Kobo profiles);
- strict CBR streaming (enabled by default);
- retain progress versus forget on close;
- per-book request, byte, opening, peak-cache, and retry statistics.

A reference-counted network lease prevents inactivity-based Wi-Fi shutdown
while a remote book is open. Manual shutdown and suspend remain authoritative.
On resume, KOReader restores Wi-Fi when it had been active; a failed block can
be requested again without reopening the document.

The native range client leaves TCP keepalive disabled, so an idle reusable HTTP
connection does not generate periodic probes. Its bounded retry path opens a
fresh connection when a server or NAT has discarded an idle socket. When the
final network lease is released, the activity monitor resets its adaptive
backoff and begins again at the normal short interval instead of potentially
leaving Wi-Fi up for the previous 30-minute ceiling.

Hinted rendering is guarded so a WebDAV or decode exception always restores
Kobo's normal single online CPU core. The second core is still used briefly
during explicitly enabled hints; removing that race-to-idle optimization would
require measurements on the target hardware.

The focused package retains KOReader's 15-minute autosuspend default and makes
its opt-in Automatic dimmer available. It does not silently enable autostandby:
standby is blocked while Wi-Fi is active and is known to be unreliable on some
Kobo boards. Full suspend remains the reliable long-idle path and powers Wi-Fi
down even when a remote document lease is active.

## Automated validation

The test server supports Basic authentication, PROPFIND, valid ranges,
ignored ranges, malformed Content-Range, changed and missing validators,
truncated and dropped bodies, slow responses, and cross-origin redirects. Its
logs record only whether Authorization was present, never its value.

From the repository root:

```sh
./kodev build
./kodev check
./kodev test -b base webdav_range_stream
./kodev test -b front autosuspend cloudstorage_stream menusorter network_manager \
    networklistener pluginloader readerhighlight readerhinting readerpaging \
    readerstatus_remote readerui remotedocument remote_pdfdocument version \
    webdav_delete
./kodev test -b all
```

The integration test creates a multi-megabyte CBZ, opens its descriptor via
the normal `DocumentRegistry`/`PdfDocument` path, seeks to a non-adjacent page,
asserts that fewer bytes than the archive were transferred, closes it, and
reopens it using credentials resolved from cloud settings.

## Kobo deployment from macOS

Do not bulk-copy or rename a populated KOReader directory through macOS's
FATKit mount. On affected macOS releases this can produce conflicting 8.3
aliases for groups of long filenames. Kobo's boot-time FAT repair then renames
otherwise intact files to `FSCK0000.000`, causing seemingly random missing Lua
modules or fonts.

Deploy a single `koreader/` update tarball as
`ota/koreader.updated.tar` instead. KOReader's launcher extracts it on the Kobo
with the Linux FAT driver before Lua starts. Verify the tarball hash after the
single-file copy, keep rollback archives off-device, and remove any obsolete
`.adds/koreader.*` directory copies. The launcher deletes the completed OTA
archive on its clean re-exec so it does not consume device storage.

## Device validation still required

The emulator cannot establish the installed firmware generation, measure
battery use, or exercise Kobo suspend and Wi-Fi drivers. Before distributing a
package, validate the standard firmware-4 `kobo` build on the actual Libra
Colour and WebDAV service:

- confirm the device is running firmware 4.x; firmware 5.x is not currently a
  supported release target;
- test ordinary and ZIP64 CBZ files with stored and deflated JPEG, PNG, and
  WebP pages;
- test known non-solid RAR4/RAR5 and solid RAR fixtures;
- exercise sleep/wake, manual Wi-Fi loss, server restart, rapid backtracking,
  page jumps, rotation, manga navigation, and low-memory conditions;
- compare the filesystem before and after close and confirm no archive,
  extracted image, rendered page, or cover artifact remains;
- record first-page latency, prefetched-page latency, memory ceiling, and
  battery behavior for 100 MB, 500 MB, and 1 GB archives.

The host used for the emulator tests does not have KOReader's ARM cross
toolchain, so a Kobo package must be built in the documented koxtoolchain or
official KOReader build container before hardware installation.
