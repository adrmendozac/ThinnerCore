import Darwin
import Testing
@testable import ThinnerCore

@Suite struct FileFlagsTests {
    @Test func namesUnreproducibleFlagsAsLsDoes() {
        #expect(FileFlags.unreproducible(0) == nil)
        #expect(FileFlags.unreproducible(UInt32(UF_NODUMP | UF_OPAQUE | UF_TRACKED | UF_HIDDEN)) == nil)
        #expect(FileFlags.unreproducible(UInt32(UF_COMPRESSED)) == "compressed")
        #expect(FileFlags.unreproducible(UInt32(UF_COMPRESSED | UF_HIDDEN)) == "compressed")
        #expect(FileFlags.unreproducible(UInt32(SF_RESTRICTED | UF_COMPRESSED)) == "restricted,compressed")
        #expect(SkipReason.fileFlags("compressed").code == "fileFlags")
    }
}
