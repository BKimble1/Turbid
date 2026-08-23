import SwiftUI
import UIKit

/// The SwiftUI boundary for the live camera preview.
///
/// Phase 1 deliberately renders a placeholder: no `AVCaptureVideoPreviewLayer`
/// exists yet. The wrapper is complete and shipping — only the layer it hosts
/// changes in Phase 2 — so the SwiftUI layout, sizing and alignment overlay can
/// be built and reviewed now.
struct CameraPreviewView: UIViewRepresentable {
    /// The normalized analysis region drawn over the preview.
    var regionOfInterest: CGRect

    func makeUIView(context: Context) -> CameraPreviewPlaceholderView {
        let view = CameraPreviewPlaceholderView()
        view.regionOfInterest = regionOfInterest
        return view
    }

    func updateUIView(_ uiView: CameraPreviewPlaceholderView, context: Context) {
        uiView.regionOfInterest = regionOfInterest
    }
}

/// Draws the analysis region guide over an inert dark background.
final class CameraPreviewPlaceholderView: UIView {
    var regionOfInterest: CGRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5) {
        didSet {
            guard regionOfInterest != oldValue else { return }
            setNeedsLayout()
        }
    }

    private let regionLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        // Fixed dark ground rather than a system colour: a measurement is made
        // inside a dark shroud, so the preview never adopts a light appearance.
        backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1.0)
        isAccessibilityElement = true
        accessibilityLabel = "Camera preview placeholder"
        accessibilityValue = "Live preview is added in Phase 2. The dashed rectangle shows where the analysis region will sit."

        regionLayer.fillColor = UIColor.clear.cgColor
        regionLayer.strokeColor = UIColor.systemTeal.cgColor
        regionLayer.lineWidth = 2
        regionLayer.lineDashPattern = [6, 4]
        layer.addSublayer(regionLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rect = CGRect(
            x: bounds.width * regionOfInterest.origin.x,
            y: bounds.height * regionOfInterest.origin.y,
            width: bounds.width * regionOfInterest.size.width,
            height: bounds.height * regionOfInterest.size.height
        )
        regionLayer.frame = bounds
        regionLayer.path = UIBezierPath(roundedRect: rect, cornerRadius: 8).cgPath
    }
}
