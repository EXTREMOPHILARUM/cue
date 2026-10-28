import AppKit
import Foundation
let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
let iconset=root.appendingPathComponent("assets/AppIcon.iconset")
try FileManager.default.createDirectory(at:iconset,withIntermediateDirectories:true)
try FileManager.default.createDirectory(at:root.appendingPathComponent("icons"),withIntermediateDirectories:true)
func image(_ size:Int, template:Bool=false) throws -> Data {
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
    let scale=CGFloat(size)/1024
    NSAffineTransform(transform:AffineTransform(scale:scale)).concat()
    if !template { NSColor(white:0.18,alpha:1).setFill();NSBezierPath(roundedRect:NSRect(x:30,y:30,width:964,height:964),xRadius:220,yRadius:220).fill() }
    let bubble=NSBezierPath(roundedRect:NSRect(x:210,y:320,width:604,height:430),xRadius:100,yRadius:100)
    NSColor.white.set();if template { bubble.lineWidth=65;bubble.stroke() } else { bubble.fill() }
    let tail=NSBezierPath();tail.move(to:NSPoint(x:335,y:335));tail.line(to:NSPoint(x:300,y:200));tail.line(to:NSPoint(x:480,y:335));tail.close();tail.fill()
    (template ? NSColor.white : NSColor(white:0.18,alpha:1)).setFill()
    for (x,h) in [(350,110),(475,240),(600,160)] { NSBezierPath(roundedRect:NSRect(x:x,y:535-h/2,width:60,height:h),xRadius:30,yRadius:30).fill() }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using:.png,properties:[:])!
}
for size in [16,32,64,128,256,512,1024] {
    let data=try image(size)
    if [16,32,48,128].contains(size) { try data.write(to:root.appendingPathComponent("icons/icon\(size).png")) }
    if size<=512 { try data.write(to:iconset.appendingPathComponent("icon_\(size)x\(size).png")) }
    if size>=32 { let half=size/2;try data.write(to:iconset.appendingPathComponent("icon_\(half)x\(half)@2x.png")) }
}
try image(48).write(to:root.appendingPathComponent("icons/icon48.png"))
try image(36,template:true).write(to:root.appendingPathComponent("native/Sources/CallAssistant/Resources/Canvas/menu-icon.png"))
