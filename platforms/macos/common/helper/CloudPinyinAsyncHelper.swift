import Darwin
import Foundation

private let responseMagic = "RIME_CLOUD_V1"
private let squirrelRefreshNotification = Notification.Name("SquirrelCloudPinyinResponseReadyNotification")

private struct RequestState {
  let id: String
  let contextInput: String
  let queryInput: String
  let delayMilliseconds: Int
  let timeoutMilliseconds: Int
  let candidatesPerSource: Int
  let maxCandidates: Int
  let modifiedAt: Date
}

private struct CandidateRecord {
  let text: String
  var pinyin: String
  var fromSogou: Bool
  var fromGoogle: Bool

  var sourceCode: String {
    if fromSogou && fromGoogle {
      return "SG+GG"
    }
    return fromSogou ? "SG" : "GG"
  }
}

private struct ProviderResult {
  let provider: String
  let status: String
  let elapsedMilliseconds: Int
  let candidates: [CandidateRecord]
}

private enum RequestError: Error {
  case timedOut
  case invalidResponse
  case httpStatus(Int)
}

private final class CloudPinyinService {
  private let requestURL: URL
  private let responseURL: URL
  private let heartbeatURL: URL
  private let logURL: URL
  private let lockURL: URL
  private let refreshNotificationObject: String
  private let logQueue = DispatchQueue(label: "rime.cloud-pinyin.log")
  private var lockDescriptor: Int32 = -1

  init(userDirectoryPath: String) {
    let directory = URL(fileURLWithPath: userDirectoryPath, isDirectory: true)
    requestURL = directory.appendingPathComponent("cloud_pinyin_async.request")
    responseURL = directory.appendingPathComponent("cloud_pinyin_async.response")
    heartbeatURL = directory.appendingPathComponent("cloud_pinyin_async.heartbeat")
    logURL = directory.appendingPathComponent("cloud_pinyin_async.log")
    lockURL = directory.appendingPathComponent("cloud_pinyin_async.lock")
    refreshNotificationObject = directory.standardizedFileURL.path
  }

  func run() {
    guard acquireSingleInstanceLock() else {
      return
    }
    defer {
      if lockDescriptor >= 0 {
        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
      }
    }

    log("helper started pid=\(getpid())")
    var observedRequestID: String?
    var pending: RequestState?
    var nextHeartbeat = Date.distantPast

    while true {
      autoreleasepool {
        let now = Date()
        if now >= nextHeartbeat {
          writeHeartbeat()
          nextHeartbeat = now.addingTimeInterval(2)
        }

        if let request = readRequest(), request.id != observedRequestID {
          observedRequestID = request.id
          pending = request
          if request.queryInput.isEmpty {
            truncateResponse()
            pending = nil
          }
        }

        if let request = pending {
          let due = request.modifiedAt.addingTimeInterval(
            Double(request.delayMilliseconds) / 1_000
          )
          if now >= due {
            pending = nil
            process(request)
          }
        }
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
  }

  private func acquireSingleInstanceLock() -> Bool {
    lockDescriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard lockDescriptor >= 0 else {
      return false
    }
    return flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0
  }

  private func readRequest() -> RequestState? {
    do {
      let raw = try String(contentsOf: requestURL, encoding: .utf8)
        .trimmingCharacters(in: .newlines)
      let fields = raw.components(separatedBy: "\t")
      guard fields.count >= 7, !fields[0].isEmpty else {
        return nil
      }
      let attributes = try FileManager.default.attributesOfItem(atPath: requestURL.path)
      let modifiedAt = attributes[.modificationDate] as? Date ?? Date()
      return RequestState(
        id: fields[0],
        contextInput: fields[1],
        queryInput: fields[2],
        delayMilliseconds: clamp(Int(fields[3]) ?? 500, minimum: 100, maximum: 3_000),
        timeoutMilliseconds: clamp(Int(fields[4]) ?? 900, minimum: 200, maximum: 5_000),
        candidatesPerSource: clamp(Int(fields[5]) ?? 5, minimum: 1, maximum: 10),
        maxCandidates: clamp(Int(fields[6]) ?? 8, minimum: 1, maximum: 20),
        modifiedAt: modifiedAt
      )
    } catch {
      return nil
    }
  }

  private func process(_ request: RequestState) {
    log("query begin id=\(request.id) length=\(request.queryInput.utf8.count)")

    let publishQueue = DispatchQueue(label: "rime.cloud-pinyin.publish")
    let group = DispatchGroup()
    var merged: [CandidateRecord] = []
    var indexByText: [String: Int] = [:]
    var sogouStatus = "pending"
    var googleStatus = "pending"
    var sogouMilliseconds = -1
    var googleMilliseconds = -1
    var revision = 0
    var previousSignature = ""

    func accept(_ result: ProviderResult) {
      publishQueue.sync {
        if result.provider == "sogou" {
          sogouStatus = result.status
          sogouMilliseconds = result.elapsedMilliseconds
        } else {
          googleStatus = result.status
          googleMilliseconds = result.elapsedMilliseconds
        }

        merge(
          result.candidates,
          into: &merged,
          indexByText: &indexByText,
          maximum: request.maxCandidates
        )

        guard readRequest()?.id == request.id else {
          log("query stale id=\(request.id), result discarded")
          return
        }
        guard !merged.isEmpty else {
          return
        }

        let signature = merged.map {
          "\($0.text)\u{1f}\($0.pinyin)\u{1f}\($0.sourceCode)"
        }.joined(separator: "\u{1e}")
        guard signature != previousSignature else {
          return
        }
        previousSignature = signature
        revision += 1

        writeResponse(
          request: request,
          revision: revision,
          candidates: merged,
          sogouMilliseconds: sogouMilliseconds,
          googleMilliseconds: googleMilliseconds,
          sogouStatus: sogouStatus,
          googleStatus: googleStatus
        )
        log(
          "query publish id=\(request.id) rev=\(revision) count=\(merged.count) "
            + "sogou=\(sogouStatus)/\(sogouMilliseconds)ms "
            + "google=\(googleStatus)/\(googleMilliseconds)ms"
        )
      }
    }

    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      accept(self.fetchSogou(request))
      group.leave()
    }

    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      accept(self.fetchGoogle(request))
      group.leave()
    }

    group.wait()
    publishQueue.sync {
      if merged.isEmpty {
        log(
          "query empty id=\(request.id) sogou=\(sogouStatus) google=\(googleStatus)"
        )
      }
    }
  }

  private func fetchGoogle(_ request: RequestState) -> ProviderResult {
    let startedAt = Date()
    do {
      var components = URLComponents(string: "https://inputtools.google.com/request")!
      components.queryItems = [
        URLQueryItem(name: "text", value: request.queryInput),
        URLQueryItem(name: "itc", value: "zh-t-i0-pinyin"),
        URLQueryItem(name: "num", value: String(request.candidatesPerSource)),
        URLQueryItem(name: "cp", value: "0"),
        URLQueryItem(name: "cs", value: "1"),
        URLQueryItem(name: "ie", value: "utf-8"),
        URLQueryItem(name: "oe", value: "utf-8"),
      ]
      var urlRequest = URLRequest(url: components.url!)
      urlRequest.httpMethod = "GET"
      configureHeaders(&urlRequest)
      let data = try perform(urlRequest, timeoutMilliseconds: request.timeoutMilliseconds)
      let candidates = try parseGoogle(
        data,
        input: request.queryInput,
        count: request.candidatesPerSource
      )
      return ProviderResult(
        provider: "google",
        status: candidates.isEmpty ? "empty" : "ok",
        elapsedMilliseconds: elapsedMilliseconds(since: startedAt),
        candidates: candidates
      )
    } catch {
      return ProviderResult(
        provider: "google",
        status: status(for: error),
        elapsedMilliseconds: elapsedMilliseconds(since: startedAt),
        candidates: []
      )
    }
  }

  private func fetchSogou(_ request: RequestState) -> ProviderResult {
    let startedAt = Date()
    var finalStatus = "empty"

    for attempt in 0..<2 {
      do {
        let elapsed = elapsedMilliseconds(since: startedAt)
        let remaining = max(200, request.timeoutMilliseconds - elapsed)
        let url = URL(
          string: "https://shouji.sogou.com/web_ime/mobile.php"
            + "?durtot=0&h=000000000000000&r=store_mf_wandoujia&v=3.7"
        )!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try buildSogouPayload(request.queryInput)
        urlRequest.setValue(
          "application/x-www-form-urlencoded",
          forHTTPHeaderField: "Content-Type"
        )
        configureHeaders(&urlRequest)

        let data = try perform(urlRequest, timeoutMilliseconds: remaining)
        let candidates = try parseSogou(
          data,
          input: request.queryInput,
          count: request.candidatesPerSource
        )
        return ProviderResult(
          provider: "sogou",
          status: candidates.isEmpty ? "empty" : "ok",
          elapsedMilliseconds: elapsedMilliseconds(since: startedAt),
          candidates: candidates
        )
      } catch {
        finalStatus = status(for: error)
        if attempt == 0,
          finalStatus == "http_400",
          elapsedMilliseconds(since: startedAt) < request.timeoutMilliseconds - 200
        {
          Thread.sleep(forTimeInterval: 0.04)
          continue
        }
        break
      }
    }

    return ProviderResult(
      provider: "sogou",
      status: finalStatus,
      elapsedMilliseconds: elapsedMilliseconds(since: startedAt),
      candidates: []
    )
  }

  private func configureHeaders(_ request: inout URLRequest) {
    request.setValue(
      "Mozilla/5.0 (Macintosh; Apple Silicon Mac OS X) AppleWebKit/537.36",
      forHTTPHeaderField: "User-Agent"
    )
    request.setValue("*/*", forHTTPHeaderField: "Accept")
  }

  private func perform(_ request: URLRequest, timeoutMilliseconds: Int) throws -> Data {
    let configuration = URLSessionConfiguration.ephemeral
    let timeout = Double(timeoutMilliseconds) / 1_000
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let session = URLSession(configuration: configuration)
    let semaphore = DispatchSemaphore(value: 0)
    let resultLock = NSLock()
    var result: Result<Data, Error>?

    let task = session.dataTask(with: request) { data, response, error in
      let resolved: Result<Data, Error>
      if let error {
        resolved = .failure(error)
      } else if let response = response as? HTTPURLResponse,
        !(200...299).contains(response.statusCode)
      {
        resolved = .failure(RequestError.httpStatus(response.statusCode))
      } else if let data {
        resolved = .success(data)
      } else {
        resolved = .failure(RequestError.invalidResponse)
      }
      resultLock.lock()
      result = resolved
      resultLock.unlock()
      semaphore.signal()
    }
    task.resume()

    if semaphore.wait(timeout: .now() + timeout + 0.25) == .timedOut {
      task.cancel()
      session.invalidateAndCancel()
      throw RequestError.timedOut
    }
    session.finishTasksAndInvalidate()

    resultLock.lock()
    let resolved = result
    resultLock.unlock()
    guard let resolved else {
      throw RequestError.invalidResponse
    }
    return try resolved.get()
  }

  private func buildSogouPayload(_ input: String) throws -> Data {
    let key = Array(input.utf8)
    let token: [UInt8] = [0, 5, 0, 0, 0, 0, 1]
    let totalLength = token.count + key.count + 3
    guard key.count <= 255, totalLength <= 255 else {
      throw RequestError.invalidResponse
    }

    var payload = [UInt8]()
    payload.reserveCapacity(totalLength)
    payload.append(UInt8(totalLength))
    payload.append(contentsOf: token)
    payload.append(UInt8(key.count))
    payload.append(contentsOf: key)
    payload.append(payload.reduce(0, ^))
    return Data(payload)
  }

  private func parseSogou(_ data: Data, input: String, count: Int) throws
    -> [CandidateRecord]
  {
    let bytes = [UInt8](data)
    guard bytes.count >= 0x16, Int(bytes[0]) + 2 == bytes.count else {
      throw RequestError.invalidResponse
    }
    let wordCount = try readUInt16(bytes, at: 0x12)
    guard wordCount > 0, wordCount <= 32 else {
      return []
    }

    var position = 0x14
    var candidates: [CandidateRecord] = []
    for _ in 0..<wordCount where candidates.count < count {
      let wordLength = try readUInt16(bytes, at: position)
      position += 2
      try ensureAvailable(bytes, position: position, length: wordLength)
      let wordData = Data(bytes[position..<(position + wordLength)])
      position += wordLength

      let firstUnknownLength = try readUInt16(bytes, at: position)
      position += 2
      try ensureAvailable(bytes, position: position, length: firstUnknownLength)
      position += firstUnknownLength

      let secondUnknownLength = try readUInt16(bytes, at: position)
      position += 2
      try ensureAvailable(bytes, position: position, length: secondUnknownLength + 1)
      position += secondUnknownLength + 1

      if let word = String(data: wordData, encoding: .utf16LittleEndian),
        !word.isEmpty
      {
        candidates.append(
          CandidateRecord(
            text: word,
            pinyin: input,
            fromSogou: true,
            fromGoogle: false
          )
        )
      }
    }
    return candidates
  }

  private func parseGoogle(_ data: Data, input: String, count: Int) throws
    -> [CandidateRecord]
  {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [Any],
      root.count >= 2,
      root[0] as? String == "SUCCESS",
      let blocks = root[1] as? [Any],
      let first = blocks.first as? [Any],
      first.count >= 2,
      let words = first[1] as? [Any]
    else {
      throw RequestError.invalidResponse
    }

    let metadata = first.count > 3 ? first[3] as? [String: Any] : nil
    let annotations = metadata?["annotation"] as? [Any]
    let matchedLengths = metadata?["matched_length"] as? [Any]
    var candidates: [CandidateRecord] = []

    for index in words.indices where candidates.count < count {
      guard let word = words[index] as? String, !word.isEmpty else {
        continue
      }
      let matchedLength: Int
      if let value = matchedLengths?[safe: index] as? NSNumber {
        matchedLength = value.intValue
      } else {
        matchedLength = input.count
      }
      guard matchedLength == input.count else {
        continue
      }

      let pinyin = annotations?[safe: index] as? String ?? input
      candidates.append(
        CandidateRecord(
          text: word,
          pinyin: pinyin,
          fromSogou: false,
          fromGoogle: true
        )
      )
    }
    return candidates
  }

  private func merge(
    _ incoming: [CandidateRecord],
    into merged: inout [CandidateRecord],
    indexByText: inout [String: Int],
    maximum: Int
  ) {
    for candidate in incoming {
      if let index = indexByText[candidate.text] {
        merged[index].fromSogou = merged[index].fromSogou || candidate.fromSogou
        merged[index].fromGoogle = merged[index].fromGoogle || candidate.fromGoogle
        if candidate.fromGoogle, !candidate.pinyin.isEmpty {
          merged[index].pinyin = candidate.pinyin
        }
        continue
      }
      guard merged.count < maximum else {
        continue
      }
      indexByText[candidate.text] = merged.count
      merged.append(candidate)
    }
  }

  private func writeResponse(
    request: RequestState,
    revision: Int,
    candidates: [CandidateRecord],
    sogouMilliseconds: Int,
    googleMilliseconds: Int,
    sogouStatus: String,
    googleStatus: String
  ) {
    var lines = [
      [
        responseMagic,
        request.id,
        request.contextInput,
        request.queryInput,
        String(revision),
        String(sogouMilliseconds),
        String(googleMilliseconds),
        sanitizeStatus(sogouStatus),
        sanitizeStatus(googleStatus),
      ].joined(separator: "\t")
    ]
    for candidate in candidates {
      lines.append(
        [
          "C",
          Data(candidate.text.utf8).base64EncodedString(),
          Data(candidate.pinyin.utf8).base64EncodedString(),
          candidate.sourceCode,
        ].joined(separator: "\t")
      )
    }

    do {
      try (lines.joined(separator: "\n") + "\n")
        .write(to: responseURL, atomically: true, encoding: .utf8)
      DistributedNotificationCenter.default().postNotificationName(
        squirrelRefreshNotification,
        object: refreshNotificationObject,
        userInfo: nil,
        deliverImmediately: true
      )
    } catch {
      log("write response failed: \(error.localizedDescription)")
    }
  }

  private func truncateResponse() {
    do {
      try "".write(to: responseURL, atomically: true, encoding: .utf8)
    } catch {
      log("truncate response failed: \(error.localizedDescription)")
    }
  }

  private func writeHeartbeat() {
    let value = String(Int(Date().timeIntervalSince1970))
    try? value.write(to: heartbeatURL, atomically: true, encoding: .utf8)
  }

  private func status(for error: Error) -> String {
    if let requestError = error as? RequestError {
      switch requestError {
      case .timedOut:
        return "timeout"
      case .invalidResponse:
        return "invalid_response"
      case .httpStatus(let code):
        return "http_\(code)"
      }
    }
    if let urlError = error as? URLError {
      if urlError.code == .timedOut {
        return "timeout"
      }
      return "network:\(urlError.code.rawValue)"
    }
    return "error:\(String(describing: type(of: error)))"
  }

  private func sanitizeStatus(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\t", with: "_")
      .replacingOccurrences(of: "\r", with: "_")
      .replacingOccurrences(of: "\n", with: "_")
  }

  private func elapsedMilliseconds(since date: Date) -> Int {
    Int(Date().timeIntervalSince(date) * 1_000)
  }

  private func readUInt16(_ bytes: [UInt8], at position: Int) throws -> Int {
    try ensureAvailable(bytes, position: position, length: 2)
    return Int(bytes[position]) | (Int(bytes[position + 1]) << 8)
  }

  private func ensureAvailable(_ bytes: [UInt8], position: Int, length: Int) throws {
    guard position >= 0, length >= 0, position + length <= bytes.count else {
      throw RequestError.invalidResponse
    }
  }

  private func clamp(_ value: Int, minimum: Int, maximum: Int) -> Int {
    min(max(value, minimum), maximum)
  }

  private func log(_ message: String) {
    logQueue.sync {
      let timestamp = ISO8601DateFormatter().string(from: Date())
      let data = Data("\(timestamp) \(message)\n".utf8)
      if !FileManager.default.fileExists(atPath: logURL.path) {
        FileManager.default.createFile(atPath: logURL.path, contents: data)
        return
      }
      do {
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
      } catch {
        // Logging must never affect input.
      }
    }
  }
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

guard CommandLine.arguments.count >= 2 else {
  fputs("usage: cloud_pinyin_async_helper <rime-user-directory>\n", stderr)
  exit(2)
}

CloudPinyinService(userDirectoryPath: CommandLine.arguments[1]).run()
