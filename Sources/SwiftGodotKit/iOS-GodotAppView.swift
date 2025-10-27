//
//  GodotAppView.swift
//
//

import OSLog
import SwiftUI
import SwiftGodot

#if os(iOS)
public struct GodotAppView: UIViewRepresentable {
    @SwiftUI.Environment(\.godotApp) var app: GodotApp?
    var view = UIGodotAppView(frame: CGRect.zero)
    
    public init() { }

    public func makeUIView(context: Context) -> UIGodotAppView {
        guard let app else {
            Logger.App.error("No GodotApp instance, you must pass it on the environment using \\.godotApp")
            return view
        }
        
        app.start()
        view.contentScaleFactor = UIScreen.main.scale
        view.isMultipleTouchEnabled = true
        view.app = app
        return view
    }

    public func updateUIView(_ uiView: UIGodotAppView, context: Context) {
        uiView.startGodotInstance()
    }
}

typealias TTGodotAppView = UIGodotAppView
typealias TTGodotWindow = UIGodotWindow

public class UIGodotAppView: UIView {
    public override class var layerClass: AnyClass { CAMetalLayer.self }
    public var renderingLayer: CAMetalLayer? { layer as? CAMetalLayer }

    private var displayLink : CADisplayLink?
    private var embedded: DisplayServerEmbedded?
    public var app: GodotApp?

    private var didInitLayer = false
    private var observers: [NSObjectProtocol] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        displayLink?.invalidate()
        displayLink = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    public override var bounds: CGRect {
        didSet {
            updateDrawableSize()
            resizeWindow()
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        configureMetalLayerIfNeeded()
        updateDrawableSize()

        if let instance = app?.instance, instance.isStarted() {
            if embedded == nil {
                embedded = DisplayServerEmbedded(nativeHandle: DisplayServer.shared.handle!)
            }
            resizeWindow()
        }
    }

    public override func didMoveToSuperview() {
        super.didMoveToSuperview()
        configureMetalLayerIfNeeded()
        installAppLifecycleObservers()
        startGodotInstance()
    }

    private func configureMetalLayerIfNeeded() {
        guard !didInitLayer, let metal = renderingLayer else { return }
        didInitLayer = true
        metal.isOpaque = true
        metal.contentsScale = contentScaleFactor
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let metal = renderingLayer else { return }
        let scale = contentScaleFactor
        let size  = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        metal.drawableSize = CGSize(width: max(1, size.width), height: max(1, size.height))
        logger.debug("drawableSize set to \(metal.drawableSize.debugDescription)")
    }

    func resizeWindow() {
        guard let embedded, let metal = renderingLayer else {
            logger.error("resizeWindow called before embedded/layer ready")
            return
        }
        let ds = metal.drawableSize
        embedded.resizeWindow(
            size: Vector2i(x: Int32(ds.width), y: Int32(ds.height)),
            id: Int32(DisplayServer.mainWindowId)
        )
        logger.debug("resizeWindow → \(Int(ds.width))×\(Int(ds.height))")
    }

    private func installAppLifecycleObservers() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.displayLink?.isPaused = true
            logger.debug("DisplayLink paused (willResignActive)")
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateDrawableSize()
            self?.resizeWindow()
            self?.displayLink?.isPaused = false
            logger.debug("DisplayLink resumed (didBecomeActive)")
        })
    }

    func startGodotInstance() {
        guard let app, let instance = app.instance else { return }
        guard !instance.isStarted() else { return }

        configureMetalLayerIfNeeded()
        updateDrawableSize()
        guard let metal = renderingLayer else { return }

        let ptr = UInt(bitPattern: Unmanaged.passUnretained(metal).toOpaque())
        logger.debug("Setting native surface to layer ptr \(String(format:"0x%lx", ptr))")
        let native = RenderingNativeSurfaceApple.create(layer: ptr)
        DisplayServerEmbedded.setNativeSurface(native)

        instance.start()

        let displayLink = CADisplayLink(target: self, selector: #selector(iterate))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink

        app.startPending()
    }

    @objc
    func iterate() {
        if let instance = app?.instance, instance.isStarted() {
            instance.iteration()
        }
    }

    public override func removeFromSuperview() {
        displayLink?.invalidate()
        displayLink = nil
        if let instance = app?.instance {
            GodotInstance.destroy(instance: instance)
        }
        super.removeFromSuperview()
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let app, let instance = app.instance, let renderingLayer else { return }
        let contentsScale = renderingLayer.contentsScale
        
        var touchData: [[String : Any]] = []
        for touch in touches {
            let touchId = app.getTouchId(touch: touch)
            if touchId == -1 {
                continue
            }
            var location = touch.location(in: self)
            if !self.layer.frame.contains(location) {
                continue
            }
            location.x -= renderingLayer.frame.origin.x
            location.y -= renderingLayer.frame.origin.y
            let tapCount = touch.tapCount
            touchData.append([ "touchId": touchId, "location": location, "tapCount": tapCount ])
        }
        {
            let windowId = Int32(DisplayServer.mainWindowId)
            for touch in touchData {
                guard let touchId = touch["touchId"] as? Int,
                      let location = touch["location"] as? CGPoint,
                      let tapCount = touch["tapCount"] as? Int,
                      let displayServer = DisplayServer.shared as? DisplayServerEmbedded
                else { continue }
                
                displayServer.touchPress (
                    idx: Int32(touchId),
                    x: Int32(location.x * contentsScale),
                    y: Int32(location.y * contentsScale),
                    pressed: true,
                    doubleClick: tapCount > 1,
                    window: windowId
                )
            }
        }()
    }
    
    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let app, let renderingLayer, let instance = app.instance else { return }
        let contentsScale = renderingLayer.contentsScale
        
        var touchData: [[String : Any]] = []
        for touch in touches {
            let touchId = app.getTouchId(touch: touch)
            if touchId == -1 {
                continue
            }
            var location = touch.location(in: self)
            if !self.layer.frame.contains(location) {
                continue
            }
            location.x -= renderingLayer.frame.origin.x
            location.y -= renderingLayer.frame.origin.y
            var prevLocation = touch.previousLocation(in: self)
            if !self.layer.frame.contains(prevLocation) {
                continue
            }
            prevLocation.x -= renderingLayer.frame.origin.x
            prevLocation.y -= renderingLayer.frame.origin.y
            let alt = touch.altitudeAngle
            let azim = touch.azimuthUnitVector(in: self)
            let force = touch.force
            let maximumPossibleForce = touch.maximumPossibleForce
            touchData.append([ "touchId": touchId, "location": location, "prevLocation": prevLocation, "alt": alt, "azim": azim, "force": force, "maximumPossibleForce": maximumPossibleForce ])
        }
        
        {
            let windowId = Int32(DisplayServer.mainWindowId)
            for touch in touchData {
                guard let touchId = touch["touchId"] as? Int,
                      let location = touch["location"] as? CGPoint,
                      let prevLocation = touch["prevLocation"] as? CGPoint,
                      let alt = touch["alt"] as? CGFloat,
                      let azim = touch["azim"] as? CGVector,
                      let force = touch["force"] as? CGFloat,
                      let maximumPossibleForce = touch["maximumPossibleForce"] as? CGFloat,
                      let displayServer = DisplayServer.shared as? DisplayServerEmbedded else { continue }
                displayServer.touchDrag(idx: Int32(touchId), prevX: Int32(prevLocation.x  * contentsScale), prevY: Int32(prevLocation.y  * contentsScale), x: Int32(location.x * contentsScale), y: Int32(location.y * contentsScale), pressure: Double(force) / Double(maximumPossibleForce), tilt: Vector2(x: Float(azim.dx) * Float(cos(alt)), y: Float(azim.dy) * cos(Float(alt))), window: windowId)
            }
        }()
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let app, let renderingLayer, let instance = app.instance else { return }
        let contentsScale = renderingLayer.contentsScale
        
        var touchData: [[String : Any]] = []
        for touch in touches {
            let touchId = app.getTouchId(touch: touch)
            if touchId == -1 {
                continue
            }
            app.removeTouchId(id: touchId)
            var location = touch.location(in: self)
            if !self.layer.frame.contains(location) {
                continue
            }
            location.x -= renderingLayer.frame.origin.x
            location.y -= renderingLayer.frame.origin.y
            touchData.append([ "touchId": touchId, "location": location ])
        }
        
        {
            let windowId = Int32(DisplayServer.mainWindowId)
            for touch in touchData {
                guard let touchId = touch["touchId"] as? Int,
                      let location = touch["location"] as? CGPoint,
                      let displayServer = DisplayServer.shared as? DisplayServerEmbedded else { continue }
                displayServer.touchPress (
                    idx: Int32(touchId),
                    x: Int32(location.x * contentsScale),
                    y: Int32(location.y * contentsScale),
                    pressed: false,
                    doubleClick: false,
                    window: windowId
                )
            }
        }()
    }
    
    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let app, let instance = app.instance else { return }
        var touchData: [[String : Any]] = []
        for touch in touches {
            let touchId = app.getTouchId(touch: touch)
            if touchId == -1 {
                continue
            }
            app.removeTouchId(id: touchId)
            touchData.append([ "touchId": touchId ])
        }
        
        {
            let windowId = Int32(DisplayServer.mainWindowId)
            for touch in touchData {
                guard let touchId = touch["touchId"] as? Int,
                      let displayServer = DisplayServer.shared as? DisplayServerEmbedded else { continue }
                
                displayServer.touchesCanceled(idx: Int32(touchId), window: windowId)
            }
        }()
    }
}
#endif
