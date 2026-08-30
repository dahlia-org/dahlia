import UniformTypeIdentifiers
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct BackupFileFormatTests {
        @Test
        func contentTypeMatchesSQLiteFiles() {
            #expect(BackupFileFormat.pathExtension == "sqlite")
            #expect(BackupFileFormat.contentType == UTType(filenameExtension: "sqlite"))
            #expect(BackupFileFormat.contentType != .database)
        }
    }
#endif
