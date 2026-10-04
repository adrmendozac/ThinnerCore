import Foundation
import CommonCrypto

/// A file's identity: device, inode, size, and modification time.
/// Used to detect changes between the preflight and the swap.
struct FileIdentity: Equatable, Codable, Sendable {
    let device: UInt64    // dev_t
    let inode: UInt64     // ino_t
    let size: UInt64
    let mtime: Int64      // seconds
    let mtimeNsec: Int64  // nanoseconds
    
    /// Reads the identity of the file at `path` using `lstat` (no symlink following).
    static func of(_ path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: UInt64(info.st_size),
            mtime: Int64(info.st_mtimespec.tv_sec),
            mtimeNsec: Int64(info.st_mtimespec.tv_nsec)
        )
    }
    
    /// Reads the identity from an open file descriptor.
    static func of(fd: Int32) -> FileIdentity? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        return FileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: UInt64(info.st_size),
            mtime: Int64(info.st_mtimespec.tv_sec),
            mtimeNsec: Int64(info.st_mtimespec.tv_nsec)
        )
    }
}

/// SHA-256 hashing utilities for the write path.
enum SHA256 {
    /// Hex-encoded lowercase SHA-256 of the complete file at `path`.
    static func hash(file path: String) throws(Problem) -> String {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw Problem("Failed to open '\(path)' for hashing: \(errnoDescription())")
        }
        defer { close(fd) }
        
        var ctx = CC_SHA256_CTX()
        CC_SHA256_Init(&ctx)
        
        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
        defer { buffer.deallocate() }
        
        while true {
            let bytesRead = read(fd, buffer, bufferSize)
            if bytesRead < 0 {
                throw Problem("Failed to read '\(path)' for hashing: \(errnoDescription())")
            }
            if bytesRead == 0 {
                break
            }
            CC_SHA256_Update(&ctx, buffer, CC_LONG(bytesRead))
        }
        
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &ctx)
        
        return hex(digest)
    }
    
    /// Hex-encoded SHA-256 of `count` bytes starting at `offset` in the file
    /// at `path`. Used to hash a single slice of a fat binary.
    static func hash(file path: String, offset: UInt64, count: UInt64) throws(Problem) -> String {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw Problem("Failed to open '\(path)' for hashing slice: \(errnoDescription())")
        }
        defer { close(fd) }
        
        var ctx = CC_SHA256_CTX()
        CC_SHA256_Init(&ctx)
        
        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
        defer { buffer.deallocate() }
        
        var remaining = count
        var currentOffset = Int64(offset)
        
        while remaining > 0 {
            let toRead = min(Int(remaining), bufferSize)
            let bytesRead = pread(fd, buffer, toRead, currentOffset)
            if bytesRead < 0 {
                throw Problem("Failed to read '\(path)' for hashing slice: \(errnoDescription())")
            }
            if bytesRead == 0 {
                throw Problem("Unexpected EOF in '\(path)' while hashing slice")
            }
            CC_SHA256_Update(&ctx, buffer, CC_LONG(bytesRead))
            remaining -= UInt64(bytesRead)
            currentOffset += Int64(bytesRead)
        }
        
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &ctx)
        
        return hex(digest)
    }
    
    /// Hex string from a CC_SHA256 digest.
    private static func hex(_ digest: [UInt8]) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
