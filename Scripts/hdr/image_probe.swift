// Disposable AT-021a numerical probe, NOT the shipping HDR engine.
// Build/run instructions and limitations: Requirements/Design/AT-021a-HDR-Feasibility.md.
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Vision
import CryptoKit

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: image-probe NEW-OUTPUT-DIRECTORY [RAW ...]\n", stderr); exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard !FileManager.default.fileExists(atPath: out.path) else {
    fputs("Use a new disposable output directory.\n", stderr); exit(2)
}
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let display = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf,
                                  .cacheIntermediates: false])
var report: [String: Any] = [:]
func hash(_ u: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: u)).map { String(format:"%02x",$0) }.joined() }
func image(_ p: [Float], _ w: Int, _ h: Int) -> CIImage {
    p.withUnsafeBytes { CIImage(bitmapData: Data($0), bytesPerRow:w*16, size:CGSize(width:w,height:h), format:.RGBAf, colorSpace:linear) }
}
func pixels(_ i: CIImage) -> [Float] {
    let w = Int(i.extent.width), h = Int(i.extent.height)
    var p = [Float](repeating:0,count:w*h*4)
    context.render(i, toBitmap:&p, rowBytes:w*16, bounds:i.extent, format:.RGBAf, colorSpace:linear)
    return p
}
func require(_ ok: Bool, _ message: String) throws {
    if !ok { throw NSError(domain:"HDRProbe",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
}
// Known scene radiance with colored highlights through 8.0. Exposure samples clip at 1.0.
// Merge is exposure-normalized weighted RGB, excluding any clipped color channel.
// No deghosting, response-curve estimation or production quality claim.
let w=512, h=256
let times: [Float] = [0.0625,0.25,1]
var truth=[Float](repeating:1,count:w*h*4)
for y in 0..<h { for x in 0..<w {
    let v = Float(pow(2,Double(x)/Double(w-1)*12-9))
    for c in 0..<3 { truth[(y*w+x)*4+c] = v * [Float(1),0.6,0.3][c] }
} }
let brackets = times.map { t in truth.enumerated().map { $0.offset%4 == 3 ? Float(1) : min(1,$0.element*t) } }
var merged=truth
var fallback=0
for p in 0..<w*h {
    var numerator=[Float](repeating:0,count:3), denominator:Float=0
    for (j,t) in times.enumerated() {
        let rgb=(0..<3).map { brackets[j][p*4+$0] }
        let maximum=rgb.max()!
        let weight:Float = maximum >= 0.98 || maximum <= 0.001 ? 0 : min(maximum,1-maximum)
        denominator += weight
        for c in 0..<3 { numerator[c] += weight*rgb[c]/t }
    }
    if denominator==0 { fallback += 1 }
    for c in 0..<3 { merged[p*4+c] = denominator>0 ? numerator[c]/denominator : brackets[0][p*4+c]/times[0] }
}
let maxError=zip(merged,truth).map { abs($0-$1) }.max()!
try require(maxError<0.00001 && fallback==0,"synthetic radiance merge failed")
// Monotonic luminance compression; same gain on RGB preserves ratios before gamut clipping.
var mapped=merged
for p in 0..<w*h {
    let r=merged[p*4],g=merged[p*4+1],b=merged[p*4+2]
    let l=0.2126*r+0.7152*g+0.0722*b
    for c in 0..<3 { mapped[p*4+c] = merged[p*4+c]/(1+l) * 0.65 }
}
let tiff=out.appendingPathComponent("synthetic-tone-mapped.tif")
print("stage tone TIFF");fflush(stdout)
try context.writeTIFFRepresentation(of:image(mapped,w,h),to:tiff,format:.RGBA16,colorSpace:display,options:[:])
let src=CGImageSourceCreateWithURL(tiff as CFURL,nil)!
let cg=CGImageSourceCreateImageAtIndex(src,0,nil)!
let props=CGImageSourceCopyPropertiesAtIndex(src,0,nil)! as NSDictionary
let reread=pixels(CIImage(cgImage:cg))
let tiffError=zip(mapped,reread).map { abs($0-$1) }.max()!
try require(cg.bitsPerComponent==16 && cg.colorSpace?.copyICCData() != nil && tiffError<0.001,"TIFF depth/profile/roundtrip failed")
let floatFile=out.appendingPathComponent("synthetic-linear-float.tif")
print("stage float TIFF");fflush(stdout)
try context.writeTIFFRepresentation(of:image(merged,w,h),to:floatFile,format:.RGBAf,colorSpace:linear,options:[:])
let floatRead=pixels(CIImage(contentsOf:floatFile)!)
let floatError=zip(merged,floatRead).map { abs($0-$1) }.max()!
try require(floatRead.max()!>7 && floatError<0.00001,"float TIFF clipped highlights")
report["synthetic"]=["dimensions":[w,h],"exposureScales":times,"sceneMaximum":truth.max()!,"mergeMaximumError":maxError,"fallbackPixels":fallback,"floatTIFFMaximumError":floatError,"toneMappedTIFFMaximumLinearError":tiffError,"bitsPerComponent":cg.bitsPerComponent,"profile":props["ProfileName"] ?? "unknown","iccBytes":(cg.colorSpace!.copyICCData()! as Data).count]
// Vision translation probe: textured target, known shift; same exposure and clipped bracket.
var texture=[Float](repeating:1,count:512*512*4)
var seed:UInt64=123
for y in 0..<512 { for x in 0..<512 {
 seed = seed &* 6364136223846793005 &+ 1
 let v=Float((seed>>32)%1000)/1250 + 0.05
 for c in 0..<3 { texture[(y*512+x)*4+c]=v }
} }
let base=image(texture,512,512).applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:2]).cropped(to:CGRect(x:0,y:0,width:512,height:512))
var alignments:[[String:Any]]=[]
for ev in [Float(0),Float(2)] {
 let moved=base.transformed(by:CGAffineTransform(translationX:7,y:-5)).cropped(to:base.extent).applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:ev])
 let reference=context.createCGImage(base,from:base.extent,format:.RGBA8,colorSpace:display)!
 let target=context.createCGImage(moved,from:base.extent,format:.RGBA8,colorSpace:display)!
 let request=VNTranslationalImageRegistrationRequest(targetedCGImage:target)
 let start=Date()
 try VNImageRequestHandler(cgImage:reference).perform([request])
 guard let a=request.results?.first?.alignmentTransform else { throw NSError(domain:"no alignment",code:1) }
 // Verify the inverse known shift, including vertical sign.
 print("alignment ev=\(ev) tx=\(a.tx) ty=\(a.ty)");fflush(stdout)
 let error=hypot(Double(a.tx)+7,Double(a.ty)-5)
 alignments.append(["exposureEV":ev,"tx":a.tx,"ty":a.ty,"expected":[-7,5],"pixelError":error,"seconds":Date().timeIntervalSince(start)])
 if ev == 0 { try require(error<1,"Vision same-exposure synthetic translation error") }
}
report["visionTranslation"]=alignments
var raws:[[String:Any]]=[]
for name in CommandLine.arguments.dropFirst(2) {
 let original=URL(fileURLWithPath:name), before=try hash(original)
 let copy=out.appendingPathComponent(original.lastPathComponent)
 try FileManager.default.copyItem(at:original,to:copy)
 guard let raw=CIRAWFilter(imageURL:copy) else {throw NSError(domain:"RAW unavailable",code:1)}
 print("stage RAW \(original.lastPathComponent)");fflush(stdout)
 let defaults:[String:Any]=["boost":raw.boostAmount,"localTone":raw.localToneMapAmount,"baselineExposure":raw.baselineExposure,"shadowBias":raw.shadowBias,"edr":raw.extendedDynamicRangeAmount,"decoder":raw.decoderVersion.rawValue]
 raw.boostAmount=0;raw.baselineExposure=0;raw.shadowBias=0;raw.isGamutMappingEnabled=false
 if raw.isLocalToneMapSupported {raw.localToneMapAmount=0}
 if raw.isLensCorrectionSupported {raw.isLensCorrectionEnabled=false}
 if raw.isLuminanceNoiseReductionSupported {raw.luminanceNoiseReductionAmount=0}
 if raw.isColorNoiseReductionSupported {raw.colorNoiseReductionAmount=0}
 if raw.isSharpnessSupported {raw.sharpnessAmount=0}
 if raw.isContrastSupported {raw.contrastAmount=0}
 if raw.isDetailSupported {raw.detailAmount=0}
 // EDR behavior must be measured, not assumed to establish scene linearity.
 raw.extendedDynamicRangeAmount=2
 raw.scaleFactor=Float(min(1,1024/max(raw.nativeSize.width,raw.nativeSize.height)))
 raw.exposure=0
 let start=Date();let a=pixels(raw.outputImage!);let decodeTime=Date().timeIntervalSince(start)
 var rawMapped=a
 for p in 0..<(a.count/4) {
     let l=max(0,0.2126*a[p*4]+0.7152*a[p*4+1]+0.0722*a[p*4+2])
     for c in 0..<3 { rawMapped[p*4+c]=max(0,a[p*4+c])/(1+l)*0.65 }
 }
 let proxy=raw.outputImage!
 let rawTIFF=out.appendingPathComponent(original.deletingPathExtension().lastPathComponent+"-tone-mapped.tif")
 try context.writeTIFFRepresentation(of:image(rawMapped,Int(proxy.extent.width),Int(proxy.extent.height)),to:rawTIFF,format:.RGBA16,colorSpace:display,options:[:])
 let rawSource=CGImageSourceCreateWithURL(rawTIFF as CFURL,nil)!
 let rawCG=CGImageSourceCreateImageAtIndex(rawSource,0,nil)!
 let rawRoundtrip=pixels(CIImage(cgImage:rawCG))
 let rawError=zip(rawMapped,rawRoundtrip).map {abs($0-$1)}.max()!
 try require(rawCG.bitsPerComponent==16 && rawCG.colorSpace?.copyICCData() != nil && rawError<0.001,"RAW tone-mapped TIFF roundtrip failed")
 raw.exposure = -1;let b=pixels(raw.outputImage!)
 var errors:[Float]=[];var ratios:[Float]=[]
 for i in a.indices where i%4 != 3 && a[i]>0.01 && a[i]<0.8 {
  errors.append(abs(b[i]-a[i]*0.5));ratios.append(b[i]/a[i])
 }
 ratios.sort();errors.sort()
 try require(!ratios.isEmpty,"no RAW midtones")
 let maximum=a.enumerated().filter{$0.offset%4 != 3}.map(\.element).max()!
 raw.exposure=0;raw.scaleFactor=1
 let fullStart=Date();let full=raw.outputImage!
 // Force full-resolution decode without retaining a 24MP Swift float array.
 let fullURL=out.appendingPathComponent(original.deletingPathExtension().lastPathComponent+"-linear.tif")
 try context.writeTIFFRepresentation(of:full,to:fullURL,format:.RGBAf,colorSpace:linear,options:[:])
 let fullSeconds=Date().timeIntervalSince(fullStart)
 try require(try hash(original)==before && hash(copy)==before,"source changed")
 raws.append(["file":original.lastPathComponent,"sha256":before,"nativeSize":[raw.nativeSize.width,raw.nativeSize.height],"defaults":defaults,"proxyDecodeSeconds":decodeTime,"proxyMaximum":maximum,"minusOneEVRatioMedian":ratios[ratios.count/2],"minusOneEVAbsoluteErrorP99":errors[Int(Double(errors.count-1)*0.99)],"fullFloatTIFFSeconds":fullSeconds,"fullFloatTIFFBytes":try FileManager.default.attributesOfItem(atPath:fullURL.path)[.size]!,"originalUnchanged":true,"toneMappedProxyBits":rawCG.bitsPerComponent,"toneMappedProxyMaximumError":rawError,"whiteBalanceTemperature":raw.neutralTemperature,"whiteBalanceTint":raw.neutralTint])
}
report["raw"]=raws
report["os"]=ProcessInfo.processInfo.operatingSystemVersionString
let json=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
try json.write(to:out.appendingPathComponent("image-report.json"))
print(String(data:json,encoding:.utf8)!)
