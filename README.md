# KOReader Stream

KOReader Stream is an experimental, WebDAV-focused fork of
[KOReader](https://github.com/koreader/koreader). It opens remote CBZ comics
with seekable HTTP range requests, so a reader can jump between pages without
first downloading the complete archive. CBR support is available in a strict,
best-effort mode because solid RAR archives are not inherently random-access.

> [!IMPORTANT]
> This project still requires validation on its target Kobo hardware. Treat
> builds as development artifacts, not production releases.

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

## How it works

```text
Cloud Storage+ WebDAV selection
  -> one-byte range capability probe
  -> non-secret local descriptor
  -> libcurl-backed seekable MuPDF stream
  -> bounded RAM block cache
  -> CBZ/CBR page rendering
```

Credentials are not written into the descriptor or committed to this
repository. KOReader resolves them at runtime from its local Cloud Storage+
settings. Native credential buffers and range-cache blocks are cleared when a
remote document closes.

## Getting started

Clone the project and all submodules:

```sh
git clone --recurse-submodules https://github.com/yoshitaka420/koreader-stream.git
cd koreader-stream
```

If the repository was cloned without submodules:

```sh
git submodule update --init --recursive
```

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
`kobov4` or `kobov5`. Hardware behavior, suspend/resume, Wi-Fi recovery, memory
limits, and battery impact must be validated on the device before deployment.

## Using WebDAV streaming

1. Configure a WebDAV server in Cloud Storage+ on the device.
2. Open that server and select a `.cbz` or `.cbr` file.
3. KOReader checks range-request support and opens the comic directly.
4. Use **Streaming settings** in Cloud Storage+ to configure RAM cache size,
   page lookahead, strict CBR behavior, progress retention, and network stats.

CBZ is the recommended format. A solid CBR may require reading most of the
archive to reach a later page; strict mode stops that inefficient transfer
instead of silently downloading the complete file.

## Repository structure

- `frontend/`, `plugins/`, and `reader.lua`: WebDAV UI, descriptor lifecycle,
  reader integration, privacy controls, and network behavior.
- `base/`: the pinned private `koreader-stream-base` companion containing the
  libcurl/MuPDF seekable stream and native tests.
- `spec/`: frontend unit and integration tests.
- `doc/WebDAV_comic_streaming.md`: detailed architecture and validation notes.

The project currently tracks KOReader and `koreader-base` as upstreams. The
other unchanged submodules continue to use their public KOReader repositories.

## Security and private data

- Never commit WebDAV URLs containing credentials, exported device settings,
  `.env` files, private keys, access tokens, personal libraries, or downloaded
  books.
- Keep real server credentials only in local KOReader settings on the target
  device or development environment.
- Use synthetic credentials and fixtures in tests.
- Before sharing a build or repository snapshot, scan both the working tree and
  Git history for secrets.

## Upstream and license

KOReader Stream is based on [KOReader](https://github.com/koreader/koreader)
and its [koreader-base](https://github.com/koreader/koreader-base) framework.
Upstream documentation and community support remain the best references for
general KOReader behavior.

The code is distributed under the GNU Affero General Public License v3.0. See
[COPYING](COPYING). KOReader and the KOReader logo belong to their respective
project and contributors.
