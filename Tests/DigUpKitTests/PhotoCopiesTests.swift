import Testing
@testable import DigUpKit

@Suite struct PhotoCopiesTests {
    /// As found in ~/Pictures: shot, converted and edited, each a search hit of its own.
    @Test func theEditedCopyTakesTheBestPlace() {
        let paths = ["/p/IMG_1938.HEIC", "/p/IMG_0001.JPG", "/p/IMG_1938.JPG", "/p/IMG_E1938.JPG", "/p/beach.jpg"]
        #expect(PhotoCopies.one(paths, path: { $0 }) == ["/p/IMG_E1938.JPG", "/p/IMG_0001.JPG", "/p/beach.jpg"])
    }

    @Test func otherwiseTheBestPlacedCopy() {
        #expect(PhotoCopies.one(["/p/beach.JPG", "/p/IMG_2.JPG", "/p/beach.heic"], path: { $0 })
            == ["/p/beach.JPG", "/p/IMG_2.JPG"])
    }

    @Test func onlyTheSamePhotoInTheSameFolder() {
        let paths = ["/a/IMG_1938.HEIC", "/b/IMG_E1938.JPG", "/a/IMG_E1939.JPG", "/a/IMG_EXTRA.JPG", "/a/IMG_E.JPG",
                     "/a/IMG_19380.JPG"]
        #expect(PhotoCopies.one(paths, path: { $0 }) == paths)
    }

    /// A Live Photo's movie shares the photo's name: it stays.
    @Test func videosPassThrough() {
        let paths = ["/p/IMG_1938.MOV", "/p/IMG_E1938.JPG", "/p/IMG_1938.HEIC"]
        #expect(PhotoCopies.one(paths, path: { $0 }, isPhoto: { !$0.hasSuffix(".MOV") })
            == ["/p/IMG_1938.MOV", "/p/IMG_E1938.JPG"])
    }
}
