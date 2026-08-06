import UIKit

/// Resolves a `Figure.fileName` to its bundled image, mirroring `SeedLoader`'s bundle-lookup
/// pattern. Nothing calls this yet with real data -- `Cobux/Resources/Figures/` is empty until
/// image extraction runs (blocked on Rajan's own Anthropic API key) -- but the lookup itself
/// works today, so bundling real images later needs zero code changes here.
enum FigureImageLoader {
    static func image(for figure: Figure) -> UIImage? {
        guard let url = Bundle.main.url(forResource: figure.fileName, withExtension: nil, subdirectory: "Figures")
                ?? Bundle.main.url(forResource: (figure.fileName as NSString).deletingPathExtension, withExtension: (figure.fileName as NSString).pathExtension, subdirectory: "Figures"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return UIImage(data: data)
    }
}
