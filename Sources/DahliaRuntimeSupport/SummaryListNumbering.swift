public enum SummaryListNumbering {
    /// 各階層で独立した番号を進め、浅い階層へ戻ったときは深い階層の番号を破棄する。
    public static func numbers(for items: [SummaryListItem]) -> [Int] {
        var counters: [Int: Int] = [:]

        return items.map { item in
            for indent in counters.keys.filter({ $0 > item.indent }) {
                counters.removeValue(forKey: indent)
            }
            let number = (counters[item.indent] ?? 0) + 1
            counters[item.indent] = number
            return number
        }
    }
}
