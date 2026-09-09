import Darwin
import Foundation

/// Idle memory relief. After heavy transient work (decoding a retina screenshot, exporting a PNG,
/// browsing gallery previews) the allocator holds a lot of freed-but-not-returned pages. When the
/// app goes back to idle we ask every malloc zone to hand those pages back to the OS, so the idle
/// footprint drops close to the fresh-launch baseline instead of the post-use high-water mark.
enum Memory {
    static func releaseFreeMemory() {
        DispatchQueue.global(qos: .utility).async {
            _ = malloc_zone_pressure_relief(nil, 0) // nil = all zones, 0 = release as much as possible
        }
    }
}
