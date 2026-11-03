/// Shared identifiers for the app, its private storage and encrypted file format.
enum AppIdentity {
    static let bundleIdentifier = "local.clipboard.app"
    static let storagePath = ".local/share/clipboard"
    static let syncFolderName = "Clipboard Sync"
    static let vaultNamespace = "Clipboard/v2"
}
