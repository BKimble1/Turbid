import Foundation
@testable import Lucid

/// Builders for synthetic camera capability sets.
///
/// Selection has to be provable without hardware, so every scenario the
/// selector must handle is expressed here as data.
enum CapabilityFactory {

    static func format(id: Int = 0,
                       width: Int = 1920,
                       height: Int = 1080,
                       pixelFormat: OSType = MeasurementPixelFormat.fullRangeYUV,
                       minFrameRate: Double = 1,
                       maxFrameRate: Double = 60,
                       minISO: Float = 34,
                       maxISO: Float = 2176,
                       minExposureSeconds: Double = 1.0 / 8000.0,
                       maxExposureSeconds: Double = 1.0,
                       supportsVideoHDR: Bool = false,
                       isBinned: Bool = false,
                       supportsCinematicStabilization: Bool = false) -> CaptureFormatDescriptor {
        CaptureFormatDescriptor(
            id: id,
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            minFrameRate: minFrameRate,
            maxFrameRate: maxFrameRate,
            minISO: minISO,
            maxISO: maxISO,
            minExposureSeconds: minExposureSeconds,
            maxExposureSeconds: maxExposureSeconds,
            fieldOfViewDegrees: 106,
            supportsVideoHDR: supportsVideoHDR,
            isBinned: isBinned,
            supportsCinematicStabilization: supportsCinematicStabilization
        )
    }

    static func camera(uniqueID: String,
                       name: String = "Camera",
                       deviceType: String = "AVCaptureDeviceTypeBuiltInWideAngleCamera",
                       isVirtual: Bool = false,
                       constituents: [String] = [],
                       minimumFocusDistanceMillimetres: Int? = 100,
                       supportsContinuousAutoFocus: Bool = true,
                       supportsAutoFocus: Bool = true,
                       supportsLockedFocus: Bool = true,
                       supportsCustomLensPositionLock: Bool = true,
                       supportsNearFocusRangeRestriction: Bool = true,
                       hasTorch: Bool = true,
                       supportsTorchOnMode: Bool = true,
                       supportsContinuousAutoExposure: Bool = true,
                       supportsLockedExposure: Bool = true,
                       supportsCustomExposure: Bool = true,
                       supportsContinuousAutoWhiteBalance: Bool = true,
                       supportsLockedWhiteBalance: Bool = true,
                       supportsCustomWhiteBalanceGainsLock: Bool = true,
                       maxWhiteBalanceGain: Float = 4,
                       formats: [CaptureFormatDescriptor]? = nil) -> CameraCapabilities {
        CameraCapabilities(
            uniqueID: uniqueID,
            localizedName: name,
            deviceTypeRawValue: deviceType,
            modelID: "synthetic",
            isVirtualDevice: isVirtual,
            constituentDeviceTypes: constituents,
            minimumFocusDistanceMillimetres: minimumFocusDistanceMillimetres,
            supportsContinuousAutoFocus: supportsContinuousAutoFocus,
            supportsAutoFocus: supportsAutoFocus,
            supportsLockedFocus: supportsLockedFocus,
            supportsCustomLensPositionLock: supportsCustomLensPositionLock,
            supportsNearFocusRangeRestriction: supportsNearFocusRangeRestriction,
            hasTorch: hasTorch,
            supportsTorchOnMode: supportsTorchOnMode,
            supportsContinuousAutoExposure: supportsContinuousAutoExposure,
            supportsLockedExposure: supportsLockedExposure,
            supportsCustomExposure: supportsCustomExposure,
            supportsContinuousAutoWhiteBalance: supportsContinuousAutoWhiteBalance,
            supportsLockedWhiteBalance: supportsLockedWhiteBalance,
            supportsCustomWhiteBalanceGainsLock: supportsCustomWhiteBalanceGainsLock,
            maxWhiteBalanceGain: maxWhiteBalanceGain,
            formats: formats ?? [format()]
        )
    }

    /// A plausible Ultra Wide: focuses very close.
    static func ultraWide(uniqueID: String = "ultra-wide",
                          hasTorch: Bool = true,
                          minimumFocusDistanceMillimetres: Int? = 20) -> CameraCapabilities {
        camera(uniqueID: uniqueID,
               name: "Back Ultra Wide Camera",
               deviceType: "AVCaptureDeviceTypeBuiltInUltraWideCamera",
               minimumFocusDistanceMillimetres: minimumFocusDistanceMillimetres,
               hasTorch: hasTorch)
    }

    /// A plausible Wide: focuses further away.
    static func wide(uniqueID: String = "wide",
                     minimumFocusDistanceMillimetres: Int? = 120) -> CameraCapabilities {
        camera(uniqueID: uniqueID,
               name: "Back Camera",
               deviceType: "AVCaptureDeviceTypeBuiltInWideAngleCamera",
               minimumFocusDistanceMillimetres: minimumFocusDistanceMillimetres)
    }

    /// A virtual device that can switch constituent cameras mid-capture.
    static func triple(uniqueID: String = "triple") -> CameraCapabilities {
        camera(uniqueID: uniqueID,
               name: "Back Triple Camera",
               deviceType: "AVCaptureDeviceTypeBuiltInTripleCamera",
               isVirtual: true,
               constituents: [
                   "AVCaptureDeviceTypeBuiltInUltraWideCamera",
                   "AVCaptureDeviceTypeBuiltInWideAngleCamera",
                   "AVCaptureDeviceTypeBuiltInTelephotoCamera"
               ],
               minimumFocusDistanceMillimetres: 20)
    }
}
