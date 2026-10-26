import XCTest
@testable import AniCompanion

final class MarkdownStripperTests: XCTestCase {

    func test_fencedCodeBlock_becomesSpokenPlaceholder() {
        let input = "看这段：\n```swift\nprint(1)\nlet x = 2\n```\n就这样"
        XCTAssertTrue(MarkdownStripper.strip(input).contains("看这段"))
        XCTAssertFalse(MarkdownStripper.strip(input).contains("print"))
        XCTAssertTrue(MarkdownStripper.strip(input).contains("代码"))
    }

    func test_unclosedFence_dropped() {
        let input = "我来写：\n```python\ndef a(): pass"   // 流式中断的半截围栏
        let out = MarkdownStripper.strip(input)
        XCTAssertFalse(out.contains("def"))
        XCTAssertTrue(out.contains("我来写"))
    }

    func test_inlineCode_unwrapped() {
        XCTAssertEqual(MarkdownStripper.strip("用 `npm test` 跑"), "用 npm test 跑")
    }

    func test_boldItalicStrikethrough_unmarked() {
        XCTAssertEqual(MarkdownStripper.strip("**重要**的话"), "重要的话")
        XCTAssertEqual(MarkdownStripper.strip("*斜体*和__下划线__"), "斜体和下划线")
        XCTAssertEqual(MarkdownStripper.strip("~~删掉~~保留"), "删掉保留")
    }

    func test_headingsAndQuotes_prefixRemoved() {
        XCTAssertEqual(MarkdownStripper.strip("## 标题"), "标题")
        XCTAssertEqual(MarkdownStripper.strip("### 三级"), "三级")
        XCTAssertEqual(MarkdownStripper.strip("> 引用的话"), "引用的话")
    }

    func test_links_keepTextOnly() {
        XCTAssertEqual(MarkdownStripper.strip("见[文档](https://x.com/y)说明"), "见文档说明")
    }

    func test_images_keepAlt() {
        XCTAssertEqual(MarkdownStripper.strip("图![截图](https://a.com/b.png)结束"), "图截图结束")
    }

    func test_listMarkers_removed() {
        XCTAssertEqual(MarkdownStripper.strip("- 第一项"), "第一项")
        XCTAssertEqual(MarkdownStripper.strip("* 第二"), "第二")
        XCTAssertEqual(MarkdownStripper.strip("3. 第三"), "第三")
    }

    func test_table_separatorsDropped_cellsJoined() {
        let input = "| 命令 | 作用 |\n|---|---|\n| `ls` | 列目录 |"
        let out = MarkdownStripper.strip(input)
        XCTAssertFalse(out.contains("---"))
        XCTAssertFalse(out.contains("|"))
        XCTAssertTrue(out.contains("命令"))
        XCTAssertTrue(out.contains("ls"))
        XCTAssertTrue(out.contains("列目录"))
    }

    func test_emotionTags_preserved() {
        XCTAssertEqual(MarkdownStripper.strip("[happy] 你好呀"), "[happy] 你好呀")
    }

    func test_realWorldMix() {
        let input = """
        [happy] 好哦主人！步骤如下：
        1. 打开 `Terminal`
        2. 运行 **pnpm test**

        详情看[文档](https://example.com)，代码是：
        ```bash
        pnpm install
        ```
        """
        let out = MarkdownStripper.strip(input)
        XCTAssertTrue(out.hasPrefix("[happy]"))
        XCTAssertTrue(out.contains("打开 Terminal"))
        XCTAssertTrue(out.contains("pnpm test"))
        XCTAssertFalse(out.contains("**"))
        XCTAssertFalse(out.contains("文档](https"))
        XCTAssertFalse(out.contains("pnpm install"))
    }

    func test_excessBlankLines_collapsed() {
        XCTAssertEqual(MarkdownStripper.strip("a\n\n\n\nb"), "a\n\nb")
    }
}
