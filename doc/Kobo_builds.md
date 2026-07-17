# Installing KOReader Stream on Kobo

KOReader Stream packages are experimental. They currently support Kobo
firmware 4.x only and still require validation on the intended hardware. Back
up the device before installing or updating. Do not install these packages on
firmware 5.x.

The workflow publishes one supported target, `kobo`. Upstream intentionally
does not distribute the developer-only `kobov4` target, and upstream
`kobov5` support is not production-ready.

## Download a verified build

For normal installation, open the repository's
[Releases](https://github.com/yoshitaka420/koreader-stream/releases) page and
download:

- `koreader-kobo-….zip` for a first installation;
- `koreader-kobo-….updated.tar` to update an existing KOReader installation;
- `SHA256SUMS-kobo.txt` to verify either file.

Tagged builds are marked as prereleases while device validation is ongoing.
Signed-in testers can also download temporary main-branch artifacts from the
[Kobo build and release](https://github.com/yoshitaka420/koreader-stream/actions/workflows/build.yml)
workflow.

Compare the calculated SHA-256 value with the matching line in
`SHA256SUMS-kobo.txt` before copying a package to the Kobo:

```sh
# Linux
sha256sum koreader-kobo-VERSION.zip

# macOS
shasum -a 256 koreader-kobo-VERSION.zip

# Windows PowerShell
Get-FileHash .\koreader-kobo-VERSION.zip -Algorithm SHA256
```

Repeat the command with the `.updated.tar` filename when updating.

## First installation with NickelMenu

These steps apply to firmware 4.x. KOReader's
[current Kobo installation guide](https://github.com/koreader/koreader/wiki/Installation-on-Kobo-devices)
is the authority for launcher-specific details.

1. In **Settings → Device information**, confirm that the firmware starts with
   `4.`.
2. Back up the Kobo and any existing `.adds/koreader` directory.
3. Install NickelMenu by following its link from the upstream KOReader guide.
   Let the Kobo process the installation and restart before continuing.
4. On firmware 4.17 or newer, open `.kobo/Kobo/Kobo eReader.conf`. Under the
   existing `[FeatureSettings]` section, add this line if it is not present:

   ```ini
   ExcludeSyncFolders=(\\.(?!kobo|adobe).+|([^.][^/]*/)+\\..+)
   ```

5. Extract the release ZIP on the computer. Copy its `koreader` directory into
   the Kobo's `.adds` directory. The resulting launcher must be located at:

   ```text
   .adds/koreader/koreader.sh
   ```

6. Create the text file `.adds/nm/koreader` with exactly this line:

   ```text
   menu_item:main:KOReader Stream:cmd_spawn:quiet:exec /mnt/onboard/.adds/koreader/koreader.sh
   ```

7. Safely eject the Kobo, let it restart if requested, and choose
   **KOReader Stream** from NickelMenu.

If KFMon is already installed and working, keep its launcher setup and replace
only `.adds/koreader` with the directory from this release.

### macOS warning

Do not bulk-copy a populated KOReader directory through macOS's FATKit mount.
Conflicting short filenames can be renamed by the Kobo's filesystem repair.
For a new device, use the semi-automated installer linked from the upstream
guide to install KOReader and a launcher, then switch to KOReader Stream with
the single-file update method below.

## Update an existing installation

The update archive preserves settings and avoids copying thousands of files:

1. Exit KOReader and connect the Kobo over USB.
2. Back up `.adds/koreader`.
3. Download and verify `koreader-kobo-….updated.tar`.
4. Copy it without extracting it to this exact destination:

   ```text
   .adds/koreader/ota/koreader.updated.tar
   ```

5. Safely eject the Kobo and launch KOReader Stream. The launcher applies the
   archive before startup, removes files no longer shipped by the package, and
   restarts into the new version.

Keep the backup off-device until the updated build has been tested. To roll
back, exit KOReader and restore the backed-up `.adds/koreader` directory.

## Configure WebDAV streaming

1. Enable Wi-Fi and launch KOReader Stream.
2. Open **WebDAV streaming**. On a fresh install it opens automatically.
3. Tap the plus button, choose **WebDAV**, and enter a display name, an HTTPS
   WebDAV address, username, password, and optional start folder.
4. Save the server, open it, and tap a `.cbz` or `.cbr` comic.
5. While browsing the server, use the plus menu → **Streaming settings** to
   choose the RAM cache, lookahead, inactive-Wi-Fi behavior, strict CBR,
   progress, and statistics options.
6. A comic is marked read automatically when you reach its end. Read comics
   show `✓ Read` in the list. Long-press a comic to choose **Mark as read** or
   **Mark as unread**; this state survives restarts even when progress
   retention is disabled.
7. To delete a remote comic or collection, long-press it and choose
   **Delete**. Deleting a collection also deletes its contents.

The WebDAV service must support directory listing and exact HTTP byte-range
responses (`206 Partial Content`). Use CBZ where possible. Solid CBR archives
are not truly random-access; leave strict CBR streaming enabled to stop an
unexpected near-complete transfer.

WebDAV deletion is irreversible unless the server provides a trash or restore
feature. The account must grant DELETE permission. KOReader follows only
same-origin redirects for DELETE so credentials are never forwarded to a
different server. Close a streamed book before deleting it or a parent
collection.

## Configure power saving

- Remote page lookahead defaults to **Off (lower power)**. Increase it to 1 or
  2 only if speculative downloads are worth the page-turn latency tradeoff.
- **Disable Wi-Fi when inactive** is enabled on new Kobo profiles. The setting
  takes effect after a restart. An open remote book intentionally keeps Wi-Fi
  leased for reliable cache misses; close the reader or suspend the device
  when taking a long break.
- **Settings → Device → Autosuspend timeout** defaults to 5 minutes and is the
  backstop for missed sleep-cover events. Full suspend turns Kobo Wi-Fi off.
- **Settings → Screen → Automatic dimmer** defaults to a 2-minute idle delay.
  It is especially useful when the frontlight is normally left on.
- Leave autostandby disabled unless it has been validated on the exact Kobo
  model. KOReader warns that standby is unreliable on some older boards, and
  it cannot engage while Wi-Fi is on.

## Uninstall

1. Exit KOReader Stream and connect the Kobo over USB.
2. Back up any settings or reading history you want to keep.
3. Delete `.adds/koreader`.
4. Delete `.adds/nm/koreader` if NickelMenu was configured with the steps
   above.
5. If an older KFMon installation placed `koreader.png` in the device root,
   delete that file and follow KFMon's own removal instructions.
6. Safely eject and restart the Kobo.

NickelMenu can remain installed if it launches other tools. Remove it
separately only if it is no longer needed.

## Publish a release

The main repository must be public before anonymous users can download its
release assets. After a main-branch build succeeds, maintainers can publish an
experimental release by pushing an annotated `stream.v*` tag:

```sh
git tag -a stream.v0.1.0 -m "KOReader Stream v0.1.0"
git push origin stream.v0.1.0
```

The workflow reruns the streaming tests, builds the firmware-4 Kobo package in
KOReader's official toolchain container, verifies its contents, and creates a
GitHub prerelease with the ZIP, single-file updater, and checksums. Rerunning
the tagged workflow replaces existing assets instead of creating a duplicate
release.
