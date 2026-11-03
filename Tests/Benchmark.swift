import Foundation
import CryptoKit
@main struct Bench {
 static func main() throws {
  let clips = (0..<200).map { Clip.text("item-\($0):" + String(repeating: "clipboard benchmark content ", count: 9700)) }
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-bench-\(UUID())")
  defer { try? FileManager.default.removeItem(at: folder) }
  let vault = try Vault(directory: folder, key: SymmetricKey(size: .bits256))
  func time(_ f: () throws -> Void) rethrows -> Double { let t = CFAbsoluteTimeGetCurrent(); try f(); return (CFAbsoluteTimeGetCurrent()-t)*1000 }
  let first = try time { try vault.write(Archive(clips: clips, boot: "")) }
  var changed=clips; changed[0].pinned = true
  let pin = try time { try vault.write(Archive(clips: changed, boot: "")) }
  let preview = time { for _ in 0..<5 { for clip in clips { _ = clip.summary.count } } }
  let metadata = clips.reduce(0) { $0 + $1.byteCount }
  print(String(format:"fixture_bytes=%d first_save_ms=%.2f pin_save_ms=%.2f preview_1000_ms=%.2f",metadata,first,pin,preview))
 }
}
