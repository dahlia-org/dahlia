import UniformTypeIdentifiers
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct BackupFileFormatTests {
        @Test
        func contentTypeMatchesArchiveAndAcceptsLegacySQLite() {
            #expect(BackupFileFormat.pathExtension == "dahliabackup")
            #expect(BackupFileFormat.contentType == UTType(filenameExtension: "dahliabackup"))
            #expect(BackupFileFormat.legacyContentType == UTType(filenameExtension: "sqlite"))
        }
    }
#endif
