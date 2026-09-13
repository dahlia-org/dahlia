import UniformTypeIdentifiers
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct BackupFileFormatTests {
        @Test
        func contentTypeMatchesArchive() {
            #expect(BackupFileFormat.pathExtension == "dahliabackup")
            #expect(BackupFileFormat.contentType == UTType(filenameExtension: "dahliabackup"))
        }
    }
#endif
