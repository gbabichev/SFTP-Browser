# SFTP Browser

<p align="center">
  <img src="./docs/icon.png" alt="Code app icon" width="96" height="96">
</p>

`SFTP Browser` is a small macOS app for connecting to an SFTP server, browsing remote files, and moving files or folders between your Mac and the server.

It is built for simple username and password SFTP workflows. The app does not require `/usr/bin/sftp`, `sshpass`, Homebrew, or any other command-line SFTP tool to be installed on the system.

## What The App Does

The app lets you:

- connect to an SFTP server with host, port, username, password, and starting folder
- save connection profiles for servers you use often
- remember the last connection details on launch
- browse remote folders in a table view
- jump to a path by typing it into the folder field
- go up a folder, refresh, or create a new folder from the toolbar
- select one or more files or folders
- sort by column headers
- upload files and folders
- download files and folders
- drag files or folders into the app to upload
- drag files or folders out to Finder to download
- rename or delete remote items from the right-click menu
- see transfer progress, ETA, queued transfers, and completed transfers
- cancel active or queued transfers

## Connections

SFTP Browser supports username and password authentication.

Connection details are shown at the top of the window:

- `Host`
- `Port`
- `Username`
- `Password`
- `Remote Path`

The password field includes a small visibility toggle so you can briefly check what you typed before connecting.

Saved profiles are available from the connection menu. Profiles store the server details and remote path. Passwords are stored separately in Keychain.

## File Browsing

The remote file list supports common browser actions:

- double-click a folder to open it
- select files or folders before downloading
- use multi-select for batch downloads
- right-click files or folders for rename and delete
- right-click empty space to create a folder
- click column headers to sort

The table shows basic remote metadata:

- name
- size
- modified date
- permissions

## Transfers

Uploads and downloads run through a transfer queue.

For larger transfers, the app shows:

- current progress
- transferred bytes
- estimated time remaining
- cancel controls

Small transfers may complete without showing a blocking overlay. Longer transfers show progress so it is clear that work is still happening.

Folder uploads, folder downloads, and folder deletion are recursive.

## Security

SFTP Browser verifies host keys.

The first time you connect to a server, the app asks whether to trust the presented host key. After that, future connections compare the server key against the trusted value. If the key changes, the app blocks the connection until the trusted host entry is reviewed.

Passwords are stored in macOS Keychain. Connection profiles and trusted host records are stored locally in app preferences.

## Dependencies / Attribution

SFTP Browser uses Swift Package Manager dependencies that are built into the app. These dependencies are used so the app can speak SFTP directly instead of launching an external command-line tool.

### Citadel

Repository: `https://github.com/orlandos-nl/Citadel.git`

Citadel provides the SSH and SFTP client functionality used by the app.

### SwiftNIO

Repository: `https://github.com/apple/swift-nio.git`

SwiftNIO provides the networking foundation used by Citadel and by the app's transfer code.

### Supporting Packages

The dependency tree also includes:

- `swift-nio-ssh`
- `swift-crypto`
- `swift-log`
- `BigInt`
- `swift-atomics`
- `swift-collections`
- `swift-asn1`
- `swift-system`

Resolved dependency versions are pinned in:

`SFTP-Browser.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

## Build

Open `SFTP-Browser.xcodeproj` in Xcode and build the `SFTP-Browser` scheme.

From the command line:

```bash
xcodebuild \
  -project SFTP-Browser.xcodeproj \
  -scheme SFTP-Browser \
  -destination generic/platform=macOS \
  build
```

## Caveats

- SFTP Browser is meant to be a simple file browser, not a full replacement for every advanced SFTP client.
- Username and password authentication is supported. SSH key authentication is not currently exposed in the UI.
- Update checking requires an `UpdateCheckReleasesURL` value in the app's generated Info.plist settings.

## Changelog

### 1.0.0

- Initial release.
