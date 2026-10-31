import Foundation
import ImageIO
guard CommandLine.arguments.count == 3 else {
    fputs("Usage: inventory SOURCE-DIRECTORY OUTPUT-JSON\n", stderr); exit(2)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default
var rows: [[String:Any]] = []
guard let files = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
    fputs("Cannot enumerate source directory.\n", stderr); exit(2)
}
for case let u as URL in files {
 guard u.pathExtension.lowercased() == "nef", let s = CGImageSourceCreateWithURL(u as CFURL,nil), let p = CGImageSourceCopyPropertiesAtIndex(s,0,nil) as? [String:Any] else {continue}
 let e = p[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:]
 let t = p[kCGImagePropertyTIFFDictionary as String] as? [String:Any] ?? [:]
 rows.append(["path":u.path,"model":t["Model"] ?? "?","time":e["DateTimeOriginal"] ?? "?","t":e["ExposureTime"] ?? 0,"f":e["FNumber"] ?? 0,"iso":e["ISOSpeedRatings"] ?? [],"bias":e["ExposureBiasValue"] ?? 0])
}
let data = try JSONSerialization.data(withJSONObject: rows, options:[.prettyPrinted,.sortedKeys]);try data.write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
print("RAW files: \(rows.count)")
