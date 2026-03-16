import Foundation

extension Bundle {
    /// Resource bundle that works both in SPM development (`swift run`) and in `.app` bundles.
    /// SPM's auto-generated `Bundle.module` only checks `Bundle.main.bundleURL` (the .app root),
    /// but macOS .app bundles store resources in `Contents/Resources/`.
    static let appResources: Bundle = {
        let bundleName = "ClaudeBoard_ClaudeBoard"

        // .app bundle: Contents/Resources/
        if let resourceURL = Bundle.main.resourceURL,
           let bundle = Bundle(url: resourceURL.appendingPathComponent("\(bundleName).bundle")) {
            return bundle
        }

        // SPM `swift run` / development: next to the executable
        if let bundle = Bundle(url: Bundle.main.bundleURL.appendingPathComponent("\(bundleName).bundle")) {
            return bundle
        }

        // Fallback to SPM's generated accessor
        return Bundle.module
    }()
}
