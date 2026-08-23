import AVFoundation
import SwiftUI
import UIKit

/// Hosts the live camera preview and the analysis-region guide.
///
/// The preview layer's pixels are never read for analysis: it is a display
/// path only. Analysis frames come from `AVCaptureVideoDataOutput` on the
/// processing queue.
struct CameraPreviewView: UIViewRepresentable {
    /// `nil` before the session is prepared, or in the Simulator.
    var session: AVCaptureSession?
    /// The analysis region, in normalized preview coordinates.
    var regionOfInterest: CGRect

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.regionOfInterest = regionOfInterest
        view.attach(session: session)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.regionOfInterest = regionOfInterest
        uiView.attach(session: session)
    }
}

/// A `UIView` whose backing layer is the preview layer, so the video does not
/// have to be resized in a separate sublayer on every layout pass.
final class CameraPreviewUIView: UIView {

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    private var previewLayer: AVCaptureVideoPreviewLayer? {
        layer as? AVCaptureVideoPreviewLayer
    }

    /// Portrait, matching the app's locked orientation.
    private static let portraitRotationAngle: CGFloat = 90

    var regionOfInterest: CGRect = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6) {
        didSet {
            guard regionOfInterest != oldValue else { return }
            setNeedsLayout()
        }
    }

    private let regionLayer = CAShapeLayer()
    private let placeholderLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        // A measurement happens inside a dark shroud, so the surround stays
        // dark rather than adopting a light appearance.
        backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1.0)

        previewLayer?.videoGravity = .resizeAspectFill

        regionLayer.fillColor = UIColor.clear.cgColor
        regionLayer.strokeColor = UIColor.systemTeal.cgColor
        regionLayer.lineWidth = 2
        regionLayer.lineDashPattern = [6, 4]
        layer.addSublayer(regionLayer)

        placeholderLabel.text = "Camera preview unavailable"
        placeholderLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        placeholderLabel.font = .preferredFont(forTextStyle: .footnote)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textAlignment = .center
        placeholderLabel.numberOfLines = 0
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ])

        isAccessibilityElement = true
        accessibilityLabel = "Camera preview"
        accessibilityValue = "The dashed rectangle marks the analysis region. Fill it with the sample."
    }

    func attach(session: AVCaptureSession?) {
        guard let previewLayer else { return }
        if previewLayer.session !== session {
            previewLayer.session = session
        }
        placeholderLabel.isHidden = session != nil

        if let connection = previewLayer.connection,
           connection.isVideoRotationAngleSupported(Self.portraitRotationAngle) {
            connection.videoRotationAngle = Self.portraitRotationAngle
        }
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
