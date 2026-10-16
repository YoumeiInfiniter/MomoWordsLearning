import Foundation
import MaimemoAXCore

enum HeadwordChecks {
    struct Failure: Error { let message: String }
    static func run() throws {
        let window = CGRect(x: 100, y: 40, width: 900, height: 700)
        let heading = CGRect(x: 300, y: 105, width: 480, height: 50)
        let example = CGRect(x: 120, y: 320, width: 840, height: 70)
        func candidate(_ text: String, role: String = "AXButton", source: String = "AXDescription", frame: CGRect? = nil) -> AXTextCandidate? {
            MaimemoHeadwordRecognizer.candidate(text: text, role: role, sourceAttribute: source,
                frame: frame ?? heading, sequence: 10, windowFrame: window)
        }
        func expect(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure(message: message) }
        }
        for phrase in ["affix value to sth.", "be obsessed with sth.", "take one's time", "a well-known fact"] {
            try expect(candidate(phrase)?.text == phrase, "完整短语、缩写、空格或词内标点丢失：\(phrase)")
        }
        try expect(candidate("  Be   obsessed\twith sth. ")?.text == "be obsessed with sth.", "标题空白未归一")
        try expect(candidate("take one’s time")?.text == "take one's time", "弯引号未归一")
        for label in ["phraseAnnotationAll", "moreLines", "leftArrow", "moreDots", "markWf", "unpin", "lookup dark", "cambridge eng dark"] {
            try expect(candidate(label) == nil, "内部控件名被当作词条：\(label)")
        }
        try expect(candidate("be obsessed with sth.", source: "AXHelp") == nil, "帮助文字不应成为词条")
        try expect(candidate("be obsessed with sth.", frame: example) == nil, "正文短语不应冒充标题")
        try expect(candidate("Modern people are becoming obsessed with material wealth.", role: "AXTextArea", frame: example) == nil, "例句被误抓")
        try expect(candidate("This boils down to money.", role: "AXTextArea") == nil, "顶部短例句不应冒充标题")
        try expect(candidate("cambridge eng", frame: CGRect(x: 300, y: 130, width: 80, height: 18)) == nil, "小控件被当成标题")
        try expect(candidate("be obsessed\nwith sth.") == nil, "多行正文不应拼成短语")
        for text in ["[biː əbˈsest wɪθ]", "[短语] 对某事物着迷", "108 min", ""] {
            try expect(candidate(text) == nil, "音标／中文／图标被误抓")
        }
        let phrase = candidate("affix value to sth.")!
        let normal = candidate("aware", role: "AXStaticText")!
        let small = candidate("aware", role: "AXStaticText", frame: CGRect(x: 300, y: 500, width: 80, height: 18))!
        try expect(normal.text == "aware", "单词回归")
        let ranked = MaimemoHeadwordRecognizer.ranked([small, normal, phrase])
        try expect(ranked.first?.text == "aware" && ranked.count == 2 && ranked.first?.score == normal.score,
                   "标题排序或同词候选去重异常")
        try expect(MaimemoHeadwordRecognizer.ranked([phrase]).first?.text == "affix value to sth.", "截图短语未选中")
        print("ax-reader-check: 短语标题、缩写／撇号／连字符、控件名过滤、例句隔离、单词与候选去重通过")
    }
}
