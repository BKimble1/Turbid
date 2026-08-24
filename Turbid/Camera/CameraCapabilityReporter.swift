import AVFoundation
import CoreMedia
import Foundation

/// Turns an `AVCaptureDevice` into the plain-value `CameraCapabilities` report
/// the selection logic works with.
///
/// Everything is probed from the device. There is no model-name lookup table:
/// what a camera supports differs between iPhone models, between iOS versions
/// and, for the torch, between thermal states.
enum CameraCapabilityReporter {

    /// Physical rear cameras worth considering. Virtual devices are discovered
    /// too so they can be reported and scored down, not silently ignored.
    static let discoveryDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInUltraWideCamera,
        .builtInWideAngleCamera,
        .builtInTelephotoCamera,
        .builtInDualWideCamera,
        .builtInDualCamera,
        .builtInTripleCamera
    ]

    static func discoverRearCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: discoveryDeviceTypes,
            mediaType: .video,
            position: .back
        ).devices
    }

    static func capabilities(for device: AVCaptureDevice) -> CameraCapabilities {
        // The device reports -1 when it does not know its minimum focus
        // distance; that is an absence of information, not a distance.
        let reportedDistance = device.minimumFocusDistance
        let focusDistance = reportedDistance > 0 ? reportedDistance : nil

        return CameraCapabilities(
            uniqueID: device.uniqueID,
            localizedName: device.localizedName,
            deviceTypeRawValue: device.deviceType.rawValue,
            modelID: device.modelID,
            isVirtualDevice: device.isVirtualDevice,
            constituentDeviceTypes: device.constituentDevices.map(\.deviceType.rawValue),
            minimumFocusDistanceMillimetres: focusDistance,
            supportsContinuousAutoFocus: device.isFocusModeSupported(.continuousAutoFocus),
            supportsAutoFocus: device.isFocusModeSupported(.autoFocus),
            supportsLockedFocus: device.isFocusModeSupported(.locked),
            supportsCustomLensPositionLock: device.isLockingFocusWithCustomLensPositionSupported,
            supportsNearFocusRangeRestriction: device.isAutoFocusRangeRestrictionSupported,
            hasTorch: device.hasTorch,
            supportsTorchOnMode: device.isTorchModeSupported(.on),
            supportsContinuousAutoExposure: device.isExposureModeSupported(.continuousAutoExposure),
            supportsLockedExposure: device.isExposureModeSupported(.locked),
            supportsCustomExposure: device.isExposureModeSupported(.custom),
            supportsContinuousAutoWhiteBalance: device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance),
            supportsLockedWhiteBalance: device.isWhiteBalanceModeSupported(.locked),
            supportsCustomWhiteBalanceGainsLock: device.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
            maxWhiteBalanceGain: device.maxWhiteBalanceGain,
            formats: device.formats.enumerated().map { index, format in
                descriptor(for: format, index: index)
            }
        )
    }

    static func descriptor(for format: AVCaptureDevice.Format, index: Int) -> CaptureFormatDescriptor {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let subType = CMFormatDescriptionGetMediaSubType(format.formatDescription)

        let ranges = format.videoSupportedFrameRateRanges
        let minRate = ranges.map(\.minFrameRate).min() ?? 0
        let maxRate = ranges.map(\.maxFrameRate).max() ?? 0

        return CaptureFormatDescriptor(
            id: index,
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            pixelFormat: subType,
            minFrameRate: minRate,
            maxFrameRate: maxRate,
            minISO: format.minISO,
            maxISO: format.maxISO,
            minExposureSeconds: CMTimeGetSeconds(format.minExposureDuration),
            maxExposureSeconds: CMTimeGetSeconds(format.maxExposureDuration),
            fieldOfViewDegrees: format.videoFieldOfView,
            supportsVideoHDR: format.isVideoHDRSupported,
            isBinned: format.isVideoBinned,
            supportsCinematicStabilization:
                format.isVideoStabilizationModeSupported(.cinematic)
        )
    }
}
