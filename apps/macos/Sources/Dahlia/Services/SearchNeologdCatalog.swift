import Foundation

enum SearchNeologdCatalog {
    /// The bundled Lindera dictionary runtime is 6.x; offer its matching release series.
    static let fallback: [SearchNeologdRelease] = [
        SearchNeologdRelease(version: "6.2.0", sha256: "b941e41a27fee042fc932fb6d5ebc58946c1e5e9a21088b9e026e31964370070", size: 140_741_186),
        SearchNeologdRelease(version: "6.1.0", sha256: "e59d3db018ae0bb651e558c5ddfbbb2e0faddc0642091c2cfdfcfe86244318b1", size: 140_741_186),
        SearchNeologdRelease(version: "6.0.0", sha256: "b40f6e497005ded8ad7b2b5347990fb62314afbae0f57e0a6fe5f9e3623e6c70", size: 140_741_186),
    ]

    static func fetch(session: URLSession) async throws -> [SearchNeologdRelease] {
        var releases: [SearchNeologdRelease] = []
        // Bound requests even if newer incompatible releases eventually fill the first page.
        for page in 1 ... 3 {
            let url = URL(string: "https://api.github.com/repos/lindera/lindera/releases?per_page=100&page=\(page)")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SearchDictionaryError.catalogUnavailable }
            let page = try JSONDecoder().decode([Release].self, from: data)
            releases += page.compactMap(\.dictionary)
            if latestThree(releases).count >= 3 || page.count < 100 { break }
        }
        let latest = latestThree(releases)
        guard !latest.isEmpty else { throw SearchDictionaryError.catalogUnavailable }
        return latest
    }

    static func latestThree(_ releases: [SearchNeologdRelease]) -> [SearchNeologdRelease] {
        var versions: Set<String> = []
        return Array(releases.filter { $0.isValid && $0.version.hasPrefix("6.") }
            .sorted(by: SearchNeologdRelease.newerFirst)
            .filter { versions.insert($0.version).inserted }.prefix(3))
    }

    private struct Release: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft, prerelease, assets
        }

        var dictionary: SearchNeologdRelease? {
            guard !draft, !prerelease, tagName.hasPrefix("v6.") else { return nil }
            let version = String(tagName.dropFirst())
            guard let asset = assets.first(where: { $0.name == "lindera-ipadic-neologd-\(version).zip" }),
                  let digest = asset.digest, digest.hasPrefix("sha256:") else { return nil }
            let release = SearchNeologdRelease(version: version, sha256: String(digest.dropFirst(7)), size: asset.size)
            return release.isValid ? release : nil
        }
    }

    private struct Asset: Decodable {
        let name: String
        let digest: String?
        let size: Int64
    }
}
