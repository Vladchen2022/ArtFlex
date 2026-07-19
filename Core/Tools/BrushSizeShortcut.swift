enum BrushSizeShortcut {
    static func step(for size: Float) -> Float {
        if size <= 10 { return 1 }
        if size <= 50 { return 5 }
        if size <= 100 { return 10 }
        if size <= 200 { return 25 }
        if size <= 300 { return 50 }
        return 100
    }
}
