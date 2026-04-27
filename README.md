# SFTP Browser

SFTP Browser is a small macOS SwiftUI app for browsing an SFTP server with username and password authentication.

The app lets you:

- Connect to an SFTP server by host, port, username, and password.
- Browse a remote directory.
- Open folders by double-clicking them.
- Move up one remote directory.
- Upload a local file to the current remote directory.
- Download a selected remote file to your Mac.

This is intentionally a simple front end around core SFTP operations. It does not depend on `/usr/bin/sftp`, `sshpass`, Homebrew, or any external command-line tool installed on the user's system.

## Implementation

The app is organized around a small `SFTPService` protocol:

- `SFTPService.swift` defines the connection config, remote file model, and service operations.
- `CitadelSFTPService.swift` implements those operations using an in-app Swift SFTP client.
- `AppViewModel.swift` owns connection state and calls the service.
- `ContentView.swift` provides the SwiftUI interface.

The current SFTP backend opens a new SSH/SFTP connection per operation. That keeps the implementation simple and reliable for a small browser. If the app grows, the next step would be keeping one connection open for the session and adding progress reporting.

## Dependencies

The app uses Swift Package Manager dependencies that are compiled and bundled with the app.

### Citadel

Repository: `https://github.com/orlandos-nl/Citadel.git`

Citadel provides the high-level SSH and SFTP client API used by the app. It handles:

- SSH connection setup.
- Username/password authentication.
- Opening an SFTP subsystem.
- Listing remote directories.
- Reading remote files.
- Writing remote files.

This is the dependency that replaces shelling out to `/usr/bin/sftp`.

### SwiftNIO

Repository: `https://github.com/apple/swift-nio.git`

SwiftNIO provides the asynchronous networking primitives used underneath Citadel. The app imports `NIO` directly for `ByteBuffer`, which is used when streaming upload and download data.

### Transitive Dependencies

These are pulled in through Citadel and SwiftNIO:

- `swift-nio-ssh`: SSH protocol support.
- `swift-crypto`: cryptographic primitives used by SSH.
- `swift-log`: logging API used by Citadel.
- `BigInt`: large integer support for SSH cryptographic operations.
- `swift-atomics`, `swift-collections`, `swift-asn1`, `swift-system`: supporting libraries used by the networking and crypto stack.

The resolved versions are pinned in `SFTP-Browser.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

## Security Notes

The current implementation uses Citadel's accept-any-host-key validator. That is convenient for development, but it is not production-safe because it does not protect against man-in-the-middle attacks.

Before shipping this as a real tool, add:

- Host key verification, ideally with a known-hosts style store.
- Keychain storage for saved passwords.
- Clear handling for authentication failures and untrusted host keys.

## Build

Open `SFTP-Browser.xcodeproj` in Xcode and build the `SFTP-Browser` scheme.

From the command line:

```sh
xcodebuild \
  -project SFTP-Browser.xcodeproj \
  -scheme SFTP-Browser \
  -destination generic/platform=macOS \
  build
```
