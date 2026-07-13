import Foundation
import CNibHID

/// Swift wrapper over the CNibHID shim: opens a tablet HID interface and delivers
/// raw input reports to a closure. All protocol decoding happens in Swift.
public final class HIDTransport {
    public typealias ReportHandler = (_ reportID: UInt32, _ payload: [UInt8]) -> Void

    private var ctx: OpaquePointer?
    private let vendorID: UInt16
    private let productID: UInt16
    private let onReport: ReportHandler
    private let onAttach: (() -> Void)?

    /// A connected HID device's USB identity.
    public struct DeviceInfo: Equatable, Sendable {
        public let vendorID: UInt16
        public let productID: UInt16
    }

    /// Enumerate currently-connected HID devices for `vendorID` (nil = any vendor).
    /// Synchronous; safe to call before any transport is opened.
    public static func enumerate(vendorID: UInt16? = nil, max: Int = 64) -> [DeviceInfo] {
        var buf = [NibHIDDeviceInfo](repeating: NibHIDDeviceInfo(), count: max)
        let n = buf.withUnsafeMutableBufferPointer {
            nib_hid_enumerate(vendorID ?? 0, $0.baseAddress, $0.count)
        }
        return buf.prefix(Int(n)).map { DeviceInfo(vendorID: $0.vendorID, productID: $0.productID) }
    }

    public init(vendorID: UInt16, productID: UInt16,
                onAttach: (() -> Void)? = nil,
                onReport: @escaping ReportHandler) {
        self.vendorID = vendorID
        self.productID = productID
        self.onAttach = onAttach
        self.onReport = onReport
    }

    /// Open the device and schedule it on the current run loop.
    /// Call CFRunLoopRun() / dispatchMain() afterwards to receive reports.
    public func start() {
        let selfPtr = Unmanaged.passRetained(self).toOpaque()
        ctx = nib_hid_create(
            vendorID, productID,
            { userCtx, reportID, report, length in
                guard let userCtx, let report else { return }
                let me = Unmanaged<HIDTransport>.fromOpaque(userCtx).takeUnretainedValue()
                let payload = Array(UnsafeBufferPointer(start: report, count: length))
                me.onReport(reportID, payload)
            },
            { userCtx, _, _ in
                guard let userCtx else { return }
                let me = Unmanaged<HIDTransport>.fromOpaque(userCtx).takeUnretainedValue()
                me.onAttach?()
            },
            nil,
            selfPtr
        )
        nib_hid_start(ctx)
    }

    /// Send a feature report (the pen mode-switch / config channel).
    @discardableResult
    public func sendFeature(reportID: UInt32, _ bytes: [UInt8]) -> Bool {
        guard let ctx else { return false }
        return bytes.withUnsafeBufferPointer {
            nib_hid_send_feature(ctx, reportID, $0.baseAddress, $0.count) == 0
        }
    }

    /// Send an output report (the touch enable / vendor config channel).
    @discardableResult
    public func sendOutput(reportID: UInt32, _ bytes: [UInt8]) -> Bool {
        guard let ctx else { return false }
        return bytes.withUnsafeBufferPointer {
            nib_hid_send_output(ctx, reportID, $0.baseAddress, $0.count) == 0
        }
    }

    public func stop() {
        if let ctx { nib_hid_stop(ctx); nib_hid_free(ctx) }
        ctx = nil
    }
}
