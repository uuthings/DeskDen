import Foundation

public enum ProviderUsageBrowserNativeProtocol {
    public static func handle(_ data: Data, mailbox: ProviderUsageBrowserMailbox, at date: Date = Date()) throws -> Data {
        try ProviderUsageBrowserJSON.keys(data, allowed: ["version", "type", "result"])
        struct Header: Decodable { var version: Int; var type: String }
        let header = try JSONDecoder().decode(Header.self, from: data), type = header.type
        guard header.version == 1, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderUsageBrowserProtocolError.invalidMessage }
        if type == "poll" {
            guard Set(object.keys) == ["version", "type"] else { throw ProviderUsageBrowserProtocolError.invalidMessage }
            try mailbox.heartbeat(at: date)
            if let request = try mailbox.requests(at: date).first {
                let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
                return try JSONSerialization.data(withJSONObject: ["version": 1, "type": "request", "request": value])
            }
            return Data(#"{"version":1,"type":"idle"}"#.utf8)
        }
        guard type == "result", Set(object.keys) == ["version", "type", "result"], let result = object["result"] as? [String: Any] else {
            throw ProviderUsageBrowserProtocolError.invalidMessage
        }
        let response = try ProviderUsageBrowserJSON.decodeResult(JSONSerialization.data(withJSONObject: result))
        try mailbox.accept(response, at: date)
        return Data(#"{"version":1,"type":"idle"}"#.utf8)
    }
}
