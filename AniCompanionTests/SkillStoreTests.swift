import XCTest
@testable import AniCompanion

final class SkillStoreTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("skills-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func write(_ name: String, frontmatter: String, body: String = "正文") {
        let d = dir.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? "---\n\(frontmatter)\n---\n\(body)".write(to: d.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    func test_scan_parsesNameAndDescription() {
        write("translate", frontmatter: "name: translate\ndescription: 中英互译，术语准确")
        write("recipe", frontmatter: "name: recipe\ndescription: 菜谱推荐与做法")
        let skills = SkillStore.scan(root: dir)
        XCTAssertEqual(skills.count, 2)
        XCTAssertEqual(skills.first?.name, "recipe")   // 名称字母序稳定
        XCTAssertTrue(skills.contains { $0.name == "translate" && $0.description == "中英互译，术语准确" })
    }

    func test_scan_skipsBrokenDirectories() {
        write("good", frontmatter: "name: good\ndescription: 好")
        // 坏货：无 SKILL.md 的目录、frontmatter 缺 name 的、非 markdown 前缀的
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("empty"), withIntermediateDirectories: true)
        write("no-name", frontmatter: "description: 只有描述")
        try? "no frontmatter at all".write(to: dir.appendingPathComponent("plain").appendingPathComponent("SKILL.md") ?? dir, atomically: true, encoding: .utf8)
        let skills = SkillStore.scan(root: dir)
        XCTAssertEqual(skills.map(\.name), ["good"])
    }

    func test_descriptionTakesFirstLine_only() {
        write("multi", frontmatter: "name: multi\ndescription: 首行描述\n  折行的第二行")
        let skills = SkillStore.scan(root: dir)
        XCTAssertEqual(skills.first?.description, "首行描述")
    }

    func test_filter_matchesNameAndDescription_caseInsensitive() {
        let all = [
            Skill(name: "translate", description: "中英互译", path: "/x/1"),
            Skill(name: "weekly-report", description: "生成周报", path: "/x/2"),
        ]
        XCTAssertEqual(SkillStore.filter(all, query: "TRANS").map(\.name), ["translate"])
        XCTAssertEqual(SkillStore.filter(all, query: "周报").map(\.name), ["weekly-report"])
        XCTAssertEqual(SkillStore.filter(all, query: "").count, 2)
        XCTAssertEqual(SkillStore.filter(all, query: "zzz").count, 0)
    }

    func test_loadBody_truncated() {
        write("long", frontmatter: "name: long\ndescription: d", body: String(repeating: "字", count: 9000))
        let skills = SkillStore.scan(root: dir)
        let body = SkillStore.loadBody(for: skills[0])
        XCTAssertLessThanOrEqual(body.count, 4000)
        XCTAssertTrue(body.hasPrefix("字"))
    }
}
