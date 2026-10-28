import UIKit
import GLKit
import MetalKit

@MainActor
final class ReactPerformance25 {
    private final class Record {
        weak var view: UIView?
        let scale: CGFloat
        let samples: GLKViewDrawableMultisample?
        let autoResize: Bool?
        let originalSize: CGSize?
        var writtenScale: CGFloat?, writtenSize: CGSize?
        init(_ view: UIView) {
            self.view=view;scale=view.contentScaleFactor
            samples=(view as? GLKView)?.drawableMultisample
            autoResize=(view as? MTKView)?.autoResizeDrawable
            originalSize=(view as? MTKView)?.drawableSize
        }
        func restore() {
            guard let view else { return }
            if let gl=view as? GLKView, let writtenScale, abs(gl.contentScaleFactor-writtenScale)<0.01 {
                gl.contentScaleFactor=scale
                if gl.drawableMultisample == .multisampleNone, let samples { gl.drawableMultisample=samples }
                gl.deleteDrawable();gl.setNeedsDisplay()
            }
            if let metal=view as? MTKView, let writtenSize, metal.drawableSize == writtenSize {
                metal.autoResizeDrawable=autoResize ?? true
                metal.drawableSize=(autoResize == false ? originalSize : nil) ?? CGSize(width:metal.bounds.width*scale,height:metal.bounds.height*scale)
            }
        }
    }
    private var records: [ObjectIdentifier:Record]=[:]
    private var last=0.0
    private(set) var status="FPS UP выключен"
    func update(in scene: UIWindowScene, enabled: Bool) {
        guard enabled else { if !records.isEmpty { restore() };status="FPS UP выключен";return }
        let now=CACurrentMediaTime();guard now-last>=1 else{return};last=now
        var queue=scene.windows.filter { $0.windowLevel == .normal && !$0.isHidden }.map { $0 as UIView }, index=0, seen=Set<ObjectIdentifier>()
        while index<queue.count && index<5000 {
            let view=queue[index];index+=1
            let key=ObjectIdentifier(view);guard seen.insert(key).inserted else{continue}
            queue.append(contentsOf:view.subviews)
            guard !view.isHidden,view.bounds.width>100,view.bounds.height>100,view is GLKView || view is MTKView else{continue}
            let record=records[key] ?? Record(view);records[key]=record
            let scale=max(0.5,record.scale*0.5)
            if let gl=view as? GLKView {
                if abs(gl.contentScaleFactor-scale)>0.01 || gl.drawableMultisample != .multisampleNone {
                    gl.contentScaleFactor=scale;gl.drawableMultisample = .multisampleNone;gl.deleteDrawable();gl.setNeedsDisplay()
                }
                record.writtenScale=scale
            } else if let metal=view as? MTKView {
                let size=CGSize(width:max(1,(metal.bounds.width*scale).rounded()),height:max(1,(metal.bounds.height*scale).rounded()))
                metal.autoResizeDrawable=false
                if metal.drawableSize != size { metal.drawableSize=size }
                record.writtenSize=size
            }
        }
        for key in Array(records.keys) where !seen.contains(key) { records.removeValue(forKey:key)?.restore() }
        records=records.filter { $0.value.view != nil }
        status=records.isEmpty ? "FPS UP: облегчён оверлей; 3D-экран ещё не найден" : "FPS UP: 50% разрешения 3D · облегчённый оверлей"
    }
    func restore() { records.values.forEach{$0.restore()};records.removeAll();last=0 }
}
