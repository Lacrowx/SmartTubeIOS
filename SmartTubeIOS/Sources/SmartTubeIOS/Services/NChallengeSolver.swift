import Foundation
import JavaScriptCore
import SmartTubeIOSCore
import os

private let solverLog = Logger(subsystem: appSubsystem, category: "NChallenge")

// MARK: - YouTubePlayerScript

/// YouTube's player script (`base.js`) for one player version.
///
/// Send its `signatureTimestamp` with the `/player` request so the `n` values in the returned
/// stream URLs belong to this script. Observed on the CDN: segments with a solved `n` still
/// answer 403 for about the first 1.5 s after the `/player` response, then 200.
struct YouTubePlayerScript: Sendable {
    let version: String
    let signatureTimestamp: Int
    let source: String

    /// Fetches the player version currently served on youtube.com and its script.
    static func fetchCurrent(session: URLSession = .shared) async throws -> YouTubePlayerScript {
        guard let home = URL(string: "https://www.youtube.com/") else { throw URLError(.badURL) }
        var request = URLRequest(url: home)
        request.setValue(WebSession.userAgent, forHTTPHeaderField: "User-Agent")
        let (homeData, _) = try await session.data(for: request)
        let html = String(bytes: homeData, encoding: .utf8) ?? ""
        guard let version = firstMatch(#"/s/player/([a-f0-9]{8})/"#, in: html),
            let scriptURL = URL(
                string: "https://www.youtube.com/s/player/\(version)/player_es6.vflset/en_US/base.js")
        else { throw URLError(.cannotParseResponse) }
        let (scriptData, _) = try await session.data(from: scriptURL)
        guard let source = String(bytes: scriptData, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        guard let sts = firstMatch(#"signatureTimestamp:(\d+)"#, in: source).flatMap(Int.init) else {
            throw URLError(.cannotParseResponse)
        }
        solverLog.notice("player \(version, privacy: .public) sts=\(sts) (\(scriptData.count) bytes)")
        return YouTubePlayerScript(version: version, signatureTimestamp: sts, source: source)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}

// MARK: - NChallengeSolver

/// Solves YouTube's `n` challenges with yt-dlp's EJS solver (the bundled
/// `yt.solver.lib.min.js` and `yt.solver.core.min.js`) in JavaScriptCore, so it runs on every
/// platform, tvOS included. The first call for a player version parses the script (~1.5 s);
/// later calls reuse the preprocessed player.
actor NChallengeSolver {

    enum SolverError: Error {
        case scriptsMissing
        case javaScript(String)
    }

    static let shared = NChallengeSolver()

    private var context: JSContext?
    private var preparedVersion: String?
    private var solved: [String: String] = [:]

    /// Returns `challenge → solution` for each `n` challenge.
    func solve(_ challenges: [String], player: YouTubePlayerScript) throws -> [String: String] {
        let context = try loadedContext()
        if preparedVersion != player.version {
            solved = [:]
            context.setObject(player.source, forKeyedSubscript: "__stPlayer" as NSString)
            let prepared = try run(
                "jsc({type:'player',player:__stPlayer,output_preprocessed:true,requests:[]}).preprocessed_player",
                in: context)
            context.setObject(prepared, forKeyedSubscript: "__stPrepared" as NSString)
            context.evaluateScript("delete globalThis.__stPlayer")
            preparedVersion = player.version
        }
        let missing = challenges.filter { solved[$0] == nil }
        if !missing.isEmpty {
            context.setObject(missing, forKeyedSubscript: "__stChallenges" as NSString)
            let json = try run(
                "JSON.stringify(jsc({type:'preprocessed',preprocessed_player:__stPrepared,"
                    + "requests:[{type:'n',challenges:__stChallenges}]}))",
                in: context)
            for (challenge, solution) in try Self.solutions(fromJSON: json) {
                solved[challenge] = solution
            }
        }
        return challenges.reduce(into: [:]) { result, challenge in
            result[challenge] = solved[challenge]
        }
    }

    private func loadedContext() throws -> JSContext {
        if let context { return context }
        guard let libURL = Bundle.module.url(forResource: "yt.solver.lib.min", withExtension: "js"),
            let coreURL = Bundle.module.url(forResource: "yt.solver.core.min", withExtension: "js"),
            let lib = try? String(contentsOf: libURL, encoding: .utf8),
            let core = try? String(contentsOf: coreURL, encoding: .utf8),
            let context = JSContext()
        else { throw SolverError.scriptsMissing }
        context.evaluateScript(lib)
        context.evaluateScript("Object.assign(globalThis, lib);")
        context.evaluateScript(core)
        if let exception = context.exception { throw SolverError.javaScript(exception.toString()) }
        self.context = context
        return context
    }

    private func run(_ script: String, in context: JSContext) throws -> String {
        context.exception = nil
        let value = context.evaluateScript(script)
        if let exception = context.exception { throw SolverError.javaScript(exception.toString()) }
        guard let value, !value.isUndefined, !value.isNull, let string = value.toString() else {
            throw SolverError.javaScript("no result")
        }
        return string
    }

    /// Parses the solver output `{"type":"result","responses":[{"type":"result","data":{…}}]}`.
    static func solutions(fromJSON json: String) throws -> [String: String] {
        guard let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            root["type"] as? String == "result",
            let responses = root["responses"] as? [[String: Any]]
        else { throw SolverError.javaScript("unexpected output: \(json.prefix(200))") }
        var result: [String: String] = [:]
        for response in responses {
            guard response["type"] as? String == "result", let data = response["data"] as? [String: String] else {
                throw SolverError.javaScript(String(describing: response["error"] ?? "error response"))
            }
            result.merge(data) { _, new in new }
        }
        return result
    }
}
