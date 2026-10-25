// A 1×1 Metal view that clears to one extended-range linear colour every frame. In a 1×1 window it
// is the EDR trigger: while it is on screen macOS keeps the panel in EDR mode and opens headroom.
import AppKit
import MetalKit

final class ClearView: MTKView, MTKViewDelegate {
    static let sharedDevice: MTLDevice = MTLCreateSystemDefaultDevice()!
    private static let queue: MTLCommandQueue = sharedDevice.makeCommandQueue()!

    /// CACurrentMediaTime() of the last frame the GPU finished; 0 until the first one.
    private(set) var lastFrame: CFTimeInterval = 0

    /// `headroom`: the EDR headroom this view asks macOS for. The system grants exactly that (when
    /// the panel can), so anything above it means other content wants more (HDR video, photos).
    init(frame: NSRect, headroom: CGFloat) {
        super.init(frame: frame, device: Self.sharedDevice)
        wantsLayer = true
        colorPixelFormat = .rgba16Float
        colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        autoResizeDrawable = false
        drawableSize = CGSize(width: 1, height: 1)
        layer?.isOpaque = false
        if let l = layer as? CAMetalLayer {
            if #available(macOS 26.0, *) {
                l.preferredDynamicRange = .high
            } else {
                l.wantsExtendedDynamicRangeContent = true
            }
            l.contentsHeadroom = headroom
        }
        clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        delegate = self
        // No display-link loop: Booster presents a frame every 0.2 s with draw(), since EDR content
        // that stops updating eventually stops counting.
        isPaused = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setColor(_ value: Double, alpha: Double = 1) {
        clearColor = MTLClearColor(red: value, green: value, blue: value, alpha: alpha)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let buffer = Self.queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        buffer.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async { self?.lastFrame = CACurrentMediaTime() }
        }
        buffer.present(drawable)
        buffer.commit()
    }
}
