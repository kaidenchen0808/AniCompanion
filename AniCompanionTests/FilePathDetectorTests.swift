import XCTest
@testable import AniCompanion

final class FilePathDetectorTests: XCTestCase {

    func test_absolutePath_detected() {
        let ms = FilePathDetector.matches(in: "报告在这里：/Users/ken/report.pdf 你看看")
        XCTAssertEqual(ms.count, 1)
        XCTAssertEqual(ms[0].absolute, "/Users/ken/report.pdf")
    }

    func test_tildePath_expanded() {
        let ms = FilePathDetector.matches(in: "文件在 ~/Desktop/notes.md 哦")
        XCTAssertEqual(ms.count, 1)
        XCTAssertTrue(ms[0].absolute.hasPrefix("/Users/"))
        XCTAssertTrue(ms[0].absolute.hasSuffix("/Desktop/notes.md"))
    }

    func test_urlNotDetected_asPath() {
        // URL 里的路径段不能误判（链接渲染归 markdown link，文件卡归本地路径）
        let ms = FilePathDetector.matches(in: "看这个 https://example.com/Users/ken/report.pdf 里面")
        XCTAssertFalse(ms.contains { $0.absolute.contains("report.pdf") })
    }

    func test_plainText_noFalsePositive() {
        let ms = FilePathDetector.matches(in: "这个方案 9.9 比 9.11 大，/Users 不是一个完整路径")
        XCTAssertEqual(ms.count, 0)   // 无扩展名不匹配
    }

    func test_trailingPunctuation_trimmed() {
        let ms = FilePathDetector.matches(in: "见 /tmp/总结.xlsx。")
        XCTAssertEqual(ms.first?.absolute, "/tmp/总结.xlsx")
    }

    func test_multiplePaths_allFound() {
        let ms = FilePathDetector.matches(in: "先看 ~/a.pdf 再看 /tmp/b.mp4")
        XCTAssertEqual(ms.count, 2)
        XCTAssertEqual(ms.map(\.absolute).last, "/tmp/b.mp4")
    }

    func test_symbolMapping() {
        XCTAssertEqual(FilePathDetector.symbol(for: "pdf"), "doc.richtext")
        XCTAssertEqual(FilePathDetector.symbol(for: "MP4"), "film")   // 大小写不敏感
    }
}
