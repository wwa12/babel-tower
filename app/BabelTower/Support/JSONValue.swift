import Foundation

/// 通用 JSON 值。预设配置里"关闭思考参数"等任意形状参数的载体：
/// 各服务参数形状不一（字符串 / 布尔 / 嵌套对象），统一用它装进配置，代码不按服务名分支。
enum JSONValue: Hashable, Codable, Sendable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case object([String: JSONValue])
    case array([JSONValue])
    case null
}

extension JSONValue {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension JSONValue {
    /// 先试布尔再试数字：布尔 true 若先按数字解会变成 1，必须优先。
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if container.decodeNil() {
            self = .null
        } else {
            let context = DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "无法识别的 JSON 值"
            )
            throw DecodingError.dataCorrupted(context)
        }
    }
}
