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
- Strong response validation for byte ranges, file size, validators, redirects,
  TLS, and truncated responses.
- Configurable page lookahead and strict CBR transfer limits.
- A network lease that keeps Wi-Fi available while a remote book is open.
- Privacy controls that prevent remote pages, covers, and decoded tiles from
  being persisted to disk.
- Stable, non-secret book descriptors so reading progress can survive a remote
  file's ETag changing.
- A reduced Kobo package focused on reading and the Cloud Storage+ WebDAV flow.

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
./kodev test -b front remotedocument remote_pdfdocument network_manager
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

1. Configure a WebDAV server in Cloud Storage+ on the device.
2. Open that server and select a `.cbz` or `.cbr` file.
3. KOReader checks range-request support and opens the comic directly.
4. Use **Streaming settings** in Cloud Storage+ to configure RAM cache size,
   page lookahead, strict CBR behavior, progress retention, and network stats.

CBZ is the recommended format. A solid CBR may require reading most of the
archive to reach a later page; strict mode stops that inefficient transfer
instead of silently downloading the complete file.

## Upstream and license

KOReader Stream is based on [KOReader](https://github.com/koreader/koreader)
and its [koreader-base](https://github.com/koreader/koreader-base) framework.
Upstream documentation and community support remain the best references for
general KOReader behavior.

The code is distributed under the GNU Affero General Public License v3.0. See
[COPYING](COPYING). KOReader and the KOReader logo belong to their respective
project and contributors.
