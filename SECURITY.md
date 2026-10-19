# Security Policy

## Supported versions

Mangosteen is a small personal project, so only the latest release receives security fixes.

| Version | Supported |
|---|---|
| 0.8.x (latest) | Yes |
| Older | No |

## Reporting a vulnerability

Please do not open a public issue for security problems.

Report them privately through GitHub instead: open the
[Security tab](https://github.com/SpaceCadet0/Mangosteen/security) of this repository and click
**Report a vulnerability**. Please include:

- the Mangosteen and macOS versions;
- what an attacker can do and under which conditions;
- steps to reproduce, and a sample file if the problem is triggered by one.

You can expect a first reply within 7 days. Fixes are released as a new version on the
[Releases](https://github.com/SpaceCadet0/Mangosteen/releases) page, and the report is credited in the release
notes unless you prefer otherwise.

## Scope

Mangosteen works offline: it makes no network requests and collects no data. Its attack surface is the files it
opens. Reports are especially welcome for:

- files that make Mangosteen or a bundled tool crash, hang or run code when converted, previewed or edited;
- results written outside the folder of the original file, or originals being changed or deleted;
- bundled tools (FFmpeg, ffprobe, cwebp, gif2webp) shipped in an outdated version with a known vulnerability.

Bugs in FFmpeg or libwebp themselves should also be reported upstream to
[FFmpeg](https://ffmpeg.org/security.html) or [libwebp](https://chromium.googlesource.com/webm/libwebp).

## Known limitations

These are deliberate and not considered vulnerabilities:

- the app is signed ad hoc and not notarized;
- the app is not sandboxed, because it writes results next to files anywhere on disk.

Only download Mangosteen from this repository's Releases page.
