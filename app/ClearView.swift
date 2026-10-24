// A 1×1-drawable Metal view that clears to one extended-range linear colour every frame. Stretched
// over a whole screen with a "multiply" compositing filter it scales everything beneath it; as a
// 1×1 window without the filter it is the EDR trigger that makes macOS open up headroom.
import AppKit
import MetalKit

final class ClearView: MTKView, MTKViewDelegate {
    static let sharedDevice: MTLDevice = MTLCreateSystemDefaultDevice()!
    private static let queue: MTLCommandQueue = sharedDevice.makeCommandQueue()!

    /// CACurrentMediaTime() of the last frame the GPU finished; 0 until the first one.
    private(set) var lastFrame: CFTimeInterval = 0
    /// Called on the main queue after each completed frame.
    var onFrame: (() -> Void)?
    /// Called at the start of every frame (main thread, also while a menu is tracking), so a fade
    /// advances exactly once per presented frame.
    var beforeDraw: (() -> Void)?

    init(frame: NSRect, multiply: Bool) {
        super.init(frame: frame, device: Self.sharedDevice)
        wantsLayer = true
        colorPixelFormat = .rgba16Float
        colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        autoResizeDrawable = false
        drawableSize = CGSize(width: 1, height: 1)
        // Keep presenting: about a second after the last frame macOS stops applying the filter.
        preferredFramesPerSecond = 5
        layer?.isOpaque = false
        (layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true
        // The filter must sit on the content view's own layer; on a sublayer macOS 26+ shows black.
        if multiply {
            layer?.compositingFilter = "multiply"
            layer?.backgroundColor = CGColor(gray: 1, alpha: 1)  // no contents yet = multiply by 1
        }
        clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        delegate = self
        isPaused = true  // only Booster.show() starts the frame loop
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setColor(_ value: Double, alpha: Double = 1) {
        clearColor = MTLClearColor(red: value, green: value, blue: value, alpha: alpha)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        beforeDraw?()
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let buffer = Self.queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        buffer.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async {
                self?.lastFrame = CACurrentMediaTime()
                self?.onFrame?()
            }
        }
        buffer.present(drawable)
        buffer.commit()
    }
}
