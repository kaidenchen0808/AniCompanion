import XCTest
@testable import AniCompanion

final class MarkdownNormalizerTests: XCTestCase {

    func test_blockMath_convertedToFencedMath() {
        let input = "公式如下：\n$$\nE = mc^2\n$$\n完毕"
        let out = MarkdownNormalizer.normalize(input)
        XCTAssertTrue(out.contains("```math\nE = mc^2\n```"))
        XCTAssertFalse(out.contains("$$"))
    }

    func test_inlineMath_singleDollar_untouched() {
        // 行内 $x^2$ 本期不转（inline 无自定义渲染钩子，保持字面可读）
        let input = "设 $x^2$ 为变量"
        XCTAssertEqual(MarkdownNormalizer.normalize(input), "设 $x^2$ 为变量")
    }

    func test_highlightMarker_toBold() {
        XCTAssertEqual(MarkdownNormalizer.normalize("这是==重点==内容"), "这是**重点**内容")
    }

    func test_htmlBoldItalic_toMarkdown() {
        XCTAssertEqual(MarkdownNormalizer.normalize("<b>粗</b>和<i>斜</i>"), "**粗**和*斜*")
        XCTAssertEqual(MarkdownNormalizer.normalize("<strong>粗</strong>与<em>斜</em>"), "**粗**与*斜*")
    }

    func test_brAlreadyHandled_upstream() {
        // <br> 在 displayContent 层处理；normalizer 不重复处理，确认无冲突
        XCTAssertEqual(MarkdownNormalizer.normalize("a<br>b"), "a<br>b")
    }

    func test_fencedMathBlockUntouched() {
        let input = "```math\nx = 1\n```"
        XCTAssertEqual(MarkdownNormalizer.normalize(input), input)
    }

    func test_plainTextUntouched() {
        let input = "普通回复，无特殊语法。价格 $5 和 $10 不算公式。"
        XCTAssertEqual(MarkdownNormalizer.normalize(input), input)
    }
}
