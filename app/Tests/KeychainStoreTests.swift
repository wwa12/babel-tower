import XCTest
@testable import BabelTower

/// 真实钥匙串增删改查测试（Security 框架代码路径的实现部分）。
/// 使用测试专用 service 与虚构内容，用后即删，不触碰用户真实条目。
final class KeychainStoreTests: XCTestCase {

    private var store: KeychainStore!

    override func setUp() {
        // 独立于 App bundle id，避免影响真实存储
        store = KeychainStore(service: "com.wwa12.babeltower.tests")
    }

    override func tearDown() {
        // 无论成败都清掉测试条目；忽略不存在的情况
        for account in ["testAccountA", "testAccountB"] {
            try? store.deleteAPIKey(forAccount: account)
        }
        store = nil
    }

    func testSaveAndLoad() throws {
        try store.saveAPIKey("虚构测试Key-甲", forAccount: "testAccountA")
        XCTAssertEqual(try store.loadAPIKey(forAccount: "testAccountA"), "虚构测试Key-甲")
    }

    func testSaveTwiceUpdatesValue() throws {
        try store.saveAPIKey("虚构测试Key-旧", forAccount: "testAccountA")
        try store.saveAPIKey("虚构测试Key-新", forAccount: "testAccountA")
        XCTAssertEqual(try store.loadAPIKey(forAccount: "testAccountA"), "虚构测试Key-新")
    }

    func testLoadMissingAccountReturnsNil() throws {
        XCTAssertNil(try store.loadAPIKey(forAccount: "不存在的账号"))
    }

    func testDeleteRemovesItem() throws {
        try store.saveAPIKey("虚构测试Key-乙", forAccount: "testAccountA")
        try store.deleteAPIKey(forAccount: "testAccountA")
        XCTAssertNil(try store.loadAPIKey(forAccount: "testAccountA"))
    }

    func testDeleteMissingAccountDoesNotThrow() throws {
        try store.deleteAPIKey(forAccount: "从未写入过的账号")
    }

    func testAccountsAreIsolated() throws {
        try store.saveAPIKey("虚构测试Key-甲", forAccount: "testAccountA")
        try store.saveAPIKey("虚构测试Key-乙", forAccount: "testAccountB")
        XCTAssertEqual(try store.loadAPIKey(forAccount: "testAccountA"), "虚构测试Key-甲")
        XCTAssertEqual(try store.loadAPIKey(forAccount: "testAccountB"), "虚构测试Key-乙")
        try store.deleteAPIKey(forAccount: "testAccountA")
        XCTAssertNil(try store.loadAPIKey(forAccount: "testAccountA"))
        XCTAssertEqual(try store.loadAPIKey(forAccount: "testAccountB"), "虚构测试Key-乙")
    }
}
