# KOReader Stream

KOReader Stream is an experimental, WebDAV-focused fork of
[KOReader](https://github.com/koreader/koreader). It opens remote CBZ comics
with seekable HTTP range requests, so a reader can jump between pages without
first downloading the complete archive. CBR support is available in a strict,
best-effort mode because solid RAR archives are not inherently random-access.

> [!IMPORTANT]
> This project still requires validation on its target Kobo hardware. Builds
> are experimental and support Kobo firmware 4.x only; do not install them on
> firmware 5.x.

## What this fork adds

- Synchronous, seekable WebDAV streaming for CBZ and CBR documents.
- A bounded in-memory block cache with configurable 8–64 MiB limits.
- A retained range-probe stream that avoids a second connection setup per book.
- Strong response validation for byte ranges, file size, validators, redirects,
  TLS, and truncated responses.
- Opt-in page lookahead and strict CBR transfer limits.
- A network lease that keeps Wi-Fi available while a remote book is open.
- Kobo power defaults that suspend after inactivity, stop idle TCP probes, and
  turn Wi-Fi off when it is no longer needed.
- Privacy controls that prevent remote pages, covers, and decoded tiles from
  being persisted to disk.
- Stable, non-secret book descriptors so reading progress can survive a remote
  file's ETag changing.
- A reduced Kobo package focused on reading and the WebDAV streaming flow.

The full design, security properties, limitations, and device-validation
checklist are in [WebDAV comic streaming](doc/WebDAV_comic_streaming.md).

## Download and install

Tagged builds are published as experimental assets on the repository's
[Releases](https://github.com/yoshitaka420/koreader-stream/releases) page. Use
the standard `kobo` ZIP for an initial installation or the `.updated.tar` file
to update an existing installation. Every download has a SHA-256 checksum.

The main branch is also built on the
[Actions](https://github.com/yoshitaka420/koreader-stream/actions) page for
testers. Those temporary artifacts expire; normal users should use a tagged
release.

Follow [Installing KOReader Stream on Kobo](doc/Kobo_builds.md) for firmware
requirements, checksum verification, first installation, updates, WebDAV
configuration, rollback, and removal.

## Getting started

Clone the project and prepare its public dependencies:

```sh
git clone https://github.com/yoshitaka420/koreader-stream.git
cd koreader-stream
./kodev fetch-thirdparty
```

`fetch-thirdparty` checks out the public upstream `koreader-base` submodule and
automatically applies this repository's native streaming patch queue. No second
KOReader Stream repository or deploy key is required.

Follow KOReader's upstream documentation for
[build environment setup](doc/Building.md) and
[target-specific builds](doc/Building_targets.md). The common development
checks are:

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

For a Kobo Libra Colour, confirm the installed firmware before choosing
the release. Only firmware 4.x is currently supported; upstream firmware-5
support is not production-ready. Hardware behavior, suspend/resume, Wi-Fi
recovery, memory limits, and battery impact must be validated on the device
before deployment.

Create the same package produced by GitHub Actions with:

```sh
./kodev release --ignore-translation kobo
```

## Using WebDAV streaming

1. Configure a WebDAV server in **WebDAV streaming** on the device.
2. Open that server and select a `.cbz` or `.cbr` file.
3. KOReader checks range-request support and opens the comic directly.
4. Use **Streaming settings** in **WebDAV streaming** to configure RAM cache size,
   page lookahead, idle Wi-Fi shutdown, strict CBR behavior, progress retention,
   and network stats.
5. Reaching the end of a streamed book marks it as read. Read books show a
   checkmark in the WebDAV list; long-press a file to mark it read or unread
   manually.
6. Long-press a remote file or folder and choose **Delete** to remove it from
   WebDAV. Folder deletion includes its contents.

The focused WebDAV browser lists streamable CBZ/CBR books and folders only;
generic cloud download, upload, folder creation, and folder-sync actions are
not exposed.

WebDAV read/unread state is stored by server and normalized remote path in a
dedicated settings file. It is flushed immediately, survives KOReader
restarts, and remains available even when per-book progress retention is
disabled.

CBZ is the recommended format. A solid CBR may require reading most of the
archive to reach a later page; strict mode stops that inefficient transfer
instead of silently downloading the complete file.

Remote deletion is permanent unless the WebDAV service implements its own
trash or recovery policy. KOReader also removes matching local remote-book
descriptors and retained progress after the server confirms deletion. Close a
remote book before deleting that book or one of its parent folders.

## Kobo power defaults

New Kobo profiles enable KOReader's inactive-Wi-Fi shutdown and leave remote
page lookahead off. Lookahead downloads and renders pages before they are
requested, so enable 1 or 2 only when lower page-turn latency matters more than
radio and CPU use. A remote book keeps a network lease while it is open so an
uncached page never fails merely because Wi-Fi went to sleep; closing the book
allows the normal inactivity timer to turn Wi-Fi off.

The focused Kobo package includes KOReader's **Auto power save** and
**Automatic dimmer** plugins. It autosuspends after five idle minutes and dims
the frontlight after two idle minutes by default; both remain configurable.
Suspend remains the largest safe idle-power saving; autostandby is deliberately
not enabled by this fork because its hardware reliability varies between Kobo
generations.

## Upstream and license

KOReader Stream is based on [KOReader](https://github.com/koreader/koreader)
and its [koreader-base](https://github.com/koreader/koreader-base) framework.
Upstream documentation and community support remain the best references for
general KOReader behavior.

The code is distributed under the GNU Affero General Public License v3.0. See
[COPYING](COPYING). KOReader and the KOReader logo belong to their respective
project and contributors.
