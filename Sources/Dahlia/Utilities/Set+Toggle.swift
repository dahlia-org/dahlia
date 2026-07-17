extension Set {
    /// 要素が含まれていれば削除し、なければ追加する。
    mutating func toggle(_ element: Element) {
        if contains(element) {
            remove(element)
        } else {
            insert(element)
        }
    }
}
