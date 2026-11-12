import Foundation

/// SwiftPM executable launches use Bundle.module; packaged macOS apps keep resource bundles
/// under Contents/Resources so the app can be signed and moved independently of the checkout.
enum AtelierResources {
    static var bundle: Bundle {
        let name = "Atelier_AtelierApp.bundle"
        if let resources = Bundle.main.resourceURL,
           let packaged = Bundle(url: resources.appendingPathComponent(name)) { return packaged }
        return Bundle.module
    }
}
