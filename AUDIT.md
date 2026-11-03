# Clipboard audit

The performance and security review below was completed for version 1.1. Version 1.2 completes the Clipboard rename with a new bundle and Keychain identity, private storage path, sync folder, file extensions and encryption namespace. It starts fresh and leaves data from the previous app identity untouched. The release build and automated checks were rerun after the rename; the performance measurements below are from the original review.

Reviewed and revised on 2 November 2026. Scope: every application source file, the persistence and network boundaries, native window and paste handling, build scripts, and installation package. This is a source review with automated regression checks, not an independent penetration test or a claim that all vulnerabilities have been eliminated.

## UI changes

- Removed the live time counters and visible source labels from cards. Source attribution remains available in tooltips and search.
- Replaced the blue accent and app icon palette with graphite tones.
- Reduced the panel to 352 x 500 points, with Windows-style compact tabs, a smaller title, a bordered Clear all button, simpler cards, direct pin buttons, and a See more menu.
- Search and filters stay collapsed until requested with the search icon, Command+F, or typing. The core clipboard view stays uncluttered.
- Retained native Liquid Glass and applied matching 22-point continuous corner masks to the hosted content and glass layers. This addresses content escaping into the corners; actual rendering still needs desktop visual verification.
- Added a native drag region at the upper edge. The last dragged position is persisted, restored across restarts, and clamped to available monitor space. Position memory defaults to enabled and can be disabled or reset in Settings.

## Findings and implemented fixes

| Finding | Change |
| --- | --- |
| A delayed paste could act after the clipboard changed or the user switched apps. | Paste requests now bind to a clipboard change count and destination PID, cancel when superseded, recheck secure input and modifiers, and post only to the intended process. Failed pasteboard writes do not send paste events. |
| Large network responses were checked only after full download into memory; a hostname suffix test was too permissive and redirects followed automatically. | Shared ephemeral URLSession transport validates exact API hosts or proper media subdomains, HTTPS, ports, credentials in URLs, MIME type and status. It rejects redirects and caps accumulated bytes as chunks arrive. Cookies, persistent URL cache and credential storage are disabled. Requests support cancellation and timeouts. This uses the public [URLSession data delegate](https://developer.apple.com/documentation/foundation/urlsessiondatadelegate) and [redirect delegate](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:)) boundaries. |
| Pinning or deleting rewrote the whole encrypted history, including all image bytes. | Version 2 storage writes immutable encrypted payloads plus a small encrypted index. Metadata edits reuse payload ciphertext. Background writes coalesce to the newest pending snapshot per collection, and continuous copy activity cannot postpone scheduling a save indefinitely. |
| A failed history load could leave a writable vault that would later overwrite the inaccessible history. | Failed authentication or loading preserves files and disables affected persistence for the session. A missing Keychain key does not generate a replacement key over an existing encrypted vault. |
| Local and shared files were read without strict size or file-kind checks; file permissions were applied after writes. | A reusable file layer uses bounded descriptor reads, rejects symlinks and non-regular files, creates atomic temporary files with mode 0600, then renames within an opened directory. Private vault directories are mode 0700. The private data directory is excluded from future backups. This is not a guarantee against a malicious process already running as the same user. |
| Repeated text decoding, hashing and image preparation happened during rendering. | Immutable payload metadata, summaries and length-delimited fingerprints are computed once. Small decoded strings use a shared cache with a 16 MB eviction target. Thumbnail preparation is serialized away from the main actor, with a 32 MB cache target. Full-text searches debounce, run off the main actor, and cancel superseded work. |
| Image/GIF validation did not consider decoded dimensions or animation costs. | Validate content rather than filename extensions, reject excessive image dimensions and GIF canvases, cap animated preview cost, and render a still thumbnail for expensive animation previews while retaining the original GIF data. |
| One corrupt sync record prevented receipt of other valid records; remote clip metadata was too widely trusted. | Process records individually, validate identifiers against filenames, accept text-only records, discard remote pin/source metadata, bound file sizes, and preserve malformed neighbouring files. Sync work and key derivation run on a serial worker. |
| Sync key material remained in Keychain after disconnect. | Disconnect removes the saved local sync key and invalidates the active session. Existing shared files remain in the user-selected folder. |
| The shared passphrase derivation profile had a low work factor for new folders. | New folders use PBKDF2-HMAC-SHA256 with 600,000 rounds and a random 32-byte salt. The work factor is versioned and bounded against malicious CPU requests. Existing 210,000-round folders remain compatible. The new cost is informed by [OWASP's PBKDF2 guidance](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html#pbkdf2); this app does not claim FIPS certification. |
| Plain content hashes in payload filenames would expose offline guesses of short content. | Payload names use HMAC with a separate HKDF-derived naming key. Indexes and payloads use authenticated contexts so ciphertext cannot be swapped across collections. Authentication relies on [CryptoKit AES-GCM authenticated data](https://developer.apple.com/documentation/cryptokit/aes/gcm/open(_:using:authenticating:)). |
| Timestamp views and repeatedly assigning an unchanged trust state caused unnecessary UI updates. | Removed timestamp views, only publish changed permission state, and check permissions only while the panel or settings is visible. Clipboard capture suspends during inactive sessions and secure keyboard input. |
| Shortcut recording could conflict with the currently registered global shortcut; notification payloads crossed actor boundaries implicitly. | Suspend shortcut registration during recording, restore it on completion/cancel, extract sendable notification values, and use immutable snapshots for background work. The release build uses Swift 6 concurrency checks with warnings treated as errors. |
| Release signing did not enable hardened runtime. | Enable hardened runtime without adding permissive exception entitlements. The local app remains ad hoc signed and is not notarized. |

The previous encrypted archive format migrates only after the new index is committed. Unreferenced encrypted payloads are removed without deleting payloads still referenced by the GIF library. Deletion does not guarantee physical erasure from SSD blocks, past backups, swap, or other apps' clipboard caches.

## Performance measurements

Local synthetic fixture: 200 text items, 54,321,690 raw payload bytes. Both implementations used the same data and an optimized build on this Mac. Three runs, median milliseconds. The baseline source was preserved before changes; the final benchmark source is `Tests/Benchmark.swift` and can be run with `zsh scripts/benchmark.sh`.

| Operation | Before | After | Difference |
| --- | ---: | ---: | ---: |
| First complete save | 151.85 ms | 224.06 ms | 72.21 ms slower |
| Pin metadata update | 113.48 ms | 9.15 ms | 104.33 ms less, about 12.4x faster |
| Read 1,000 card summaries | 22.94 ms | 2.81 ms | 20.13 ms less, about 8.2x faster |

First-save overhead increased because the new format commits separate payload files. Normal metadata changes avoid rewriting the large payloads. These are storage/model measurements, not measured end-to-end UI latency or a universal performance claim. Fixture creation, including initial metadata preparation, is outside the timed save operations. Disk space also includes encoding, encryption, index and filesystem overhead beyond the configured raw-byte budget.

## Verification

- Optimized Apple Silicon release build for macOS 14+, using Swift 6 and warnings as errors.
- 62 automated checks pass: history rules, original bytes, encrypted round trips, tamper detection, cross-library authentication, legacy migration, storage permissions, symlink/special-file rejection, sync record validation, KDF compatibility and work-factor bounds, length-delimited fingerprints, bounded HTTP with a mock transport, paste policy, monitor geometry, limits and character catalogues.
- ZIP integrity, bundled executable bytes, extracted metadata and extracted code signature are checked by `scripts/package.sh`.
- Test fixtures and separately named pasteboards are used. The user's general clipboard, saved history and Keychain secrets are not used as test data.

## Remaining limits and desktop checks

This execution environment cannot connect to macOS window and pasteboard services. Actual panel rendering, corner appearance, native drag notifications, global shortcuts, focus restoration, Accessibility/Keychain prompts, launch at login, live GIPHY service calls and two-Mac file-provider synchronization therefore remain unverified here. Automated geometry and paste-policy checks do not prove those native interactions work.

Clipboard reads can materialize advertised data before its length can be checked and can wait on another app's pasteboard provider. Storage/network bounds are not an absolute bound on those transient OS allocations. Polling may miss copies made within one sampling interval. Password exclusions and concealed markers depend on the source app; this is not a password classifier or a defence against malware with the user's privileges. Encrypted data must be available in memory for preview and paste.

When configuring two Macs, initialize the sync folder on one Mac and let the file provider finish syncing its salt, KDF profile and verification file before joining from the other. Simultaneous offline folder initialization and provider conflict handling have not been validated. Existing weaker sync profiles are retained for compatibility rather than silently invalidating other devices.

Microsoft-account Cloud Clipboard integration remains unavailable; encrypted folder sync is separate. GIF search still requires a user-provided GIPHY API key. The app is a local signed build, not an App Store or Developer ID notarized release.
