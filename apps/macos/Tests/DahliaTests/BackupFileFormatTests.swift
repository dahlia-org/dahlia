import UniformTypeIdentifiers
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct BackupFileFormatTests {
        @Test
        func contentTypeMatchesArchive() {
            #expect(BackupFileFormat.pathExtension == "gz")
            #expect(BackupFileFormat.contentType == UTType(filenameExtension: "gz"))
        }
    }
#endif
