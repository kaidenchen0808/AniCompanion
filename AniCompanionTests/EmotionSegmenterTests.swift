import XCTest
@testable import AniCompanion

final class EmotionSegmenterTests: XCTestCase {

    func test_noTags_wholeTextOneSegment() {
        XCTAssertEqual(EmotionSegmenter.segments("今天天气不错。"), ["今天天气不错。"])
    }

    func test_emptyInput_returnsEmpty() {
        XCTAssertEqual(EmotionSegmenter.segments(""), [])
    }

    func test_leadingTag_staysInsideSegment() {
        XCTAssertEqual(EmotionSegmenter.segments("[happy] 好哦"), ["[happy] 好哦"])
    }

    func test_midTag_splits_tagLeadsFollowingText() {
        XCTAssertEqual(
            EmotionSegmenter.segments("[happy] 早呀[shy] 今天天气不错"),
            ["[happy] 早呀", "[shy] 今天天气不错"]
        )
    }

    func test_leadingPlainText_getsOwnSegment() {
        XCTAssertEqual(
            EmotionSegmenter.segments("嗯嗯[happy] 好哦"),
            ["嗯嗯", "[happy] 好哦"]
        )
    }

    func test_consecutiveTags_noEmptySegments() {
        // The seam between two adjacent tags carries no text — the first tag
        // rides along as its own (tag-only) segment, feeding the parser only
        // an emotion change and nothing to speak.
        XCTAssertEqual(
            EmotionSegmenter.segments("[happy][excited] 耶"),
            ["[happy]", "[excited] 耶"]
        )
    }

    func test_blankSeamBetweenTags_dropped() {
        let segments = EmotionSegmenter.segments("[happy] A\n\n[love] B")
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.last, "[love] B")
    }

    func test_unknownBracketTag_isNotASeam() {
        // Only the 16 protocol tags split; arbitrary bracketed text stays inline.
        XCTAssertEqual(
            EmotionSegmenter.segments("[happy] 你好[不是标签] 呀"),
            ["[happy] 你好[不是标签] 呀"]
        )
    }

    func test_fullArc_threeSegments() {
        XCTAssertEqual(
            EmotionSegmenter.segments("[happy] 主人好！[shy] 今天也辛苦啦。[love] 一直陪着你哦。"),
            ["[happy] 主人好！", "[shy] 今天也辛苦啦。", "[love] 一直陪着你哦。"]
        )
    }

    // MARK: - Integration with SentenceParser (the reason this type exists)

    func test_emotionArcPreserved_throughSentenceParser() async {
        // One bulk feed of the whole reply would let stripInlineEmotionTags flatten
        // every sentence to the LAST tag's emotion. Segment-by-segment feeding keeps
        // each segment's leading tag in effect — same attribution as streaming feed.
        let reply = "[happy] 主人好！今天也辛苦啦。[love] 我一直陪着你哦。"

        let parser = SentenceParser()
        for segment in EmotionSegmenter.segments(reply) {
            await parser.feed(segment)
        }
        await parser.finish()

        var collected: [SentenceChunk] = []
        for await chunk in parser.sentences {
            collected.append(chunk)
        }

        XCTAssertEqual(collected.map(\.text), ["主人好！", "今天也辛苦啦。", "我一直陪着你哦。"])
        XCTAssertEqual(collected.map(\.emotion), [.happy, .happy, .love])
    }
}
