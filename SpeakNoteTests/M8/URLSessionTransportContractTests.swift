import Foundation
import XCTest

@testable import SpeakNote

final class URLSessionTransportContractTests: XCTestCase {
  func testURLSessionTransportWiresDataAndFileUploadsWithoutNetwork()
    async throws
  {
    let observed = URLRequestRecorder()
    ContractURLProtocol.setHandler { request in
      observed.append(request)
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 201,
        httpVersion: "HTTP/1.1",
        headerFields: ["Retry-After": "3"]
      )!
      return (response, Data("accepted".utf8))
    }
    defer { ContractURLProtocol.setHandler(nil) }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ContractURLProtocol.self]
    let transport = URLSessionHTTPTransport(configuration: configuration)
    let endpoint = URL(string: "https://transport.invalid/upload")!

    var dataRequest = URLRequest(url: endpoint)
    dataRequest.httpMethod = "POST"
    dataRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let dataResponse = try await transport.send(
      HTTPRequest(
        request: dataRequest,
        body: .data(Data("{}".utf8))
      )
    )

    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpeakNote-URLSession-\(UUID().uuidString).bin")
    try Data("file-body".utf8).write(to: fileURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    var fileRequest = URLRequest(url: endpoint)
    fileRequest.httpMethod = "POST"
    let fileResponse = try await transport.send(
      HTTPRequest(request: fileRequest, body: .file(fileURL))
    )

    XCTAssertEqual(dataResponse.statusCode, 201)
    XCTAssertEqual(dataResponse.headers["retry-after"], "3")
    XCTAssertEqual(dataResponse.body, Data("accepted".utf8))
    XCTAssertEqual(fileResponse.statusCode, 201)
    XCTAssertEqual(observed.requests().map(\.httpMethod), ["POST", "POST"])
  }
}

private final class URLRequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [URLRequest] = []

  func append(_ request: URLRequest) {
    lock.withLock { storage.append(request) }
  }

  func requests() -> [URLRequest] {
    lock.withLock { storage }
  }
}

private final class ContractURLProtocol: URLProtocol, @unchecked Sendable {
  typealias Handler = @Sendable (URLRequest) -> (HTTPURLResponse, Data)

  private static let lock = NSLock()
  nonisolated(unsafe) private static var handler: Handler?

  static func setHandler(_ handler: Handler?) {
    lock.withLock { self.handler = handler }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "transport.invalid"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = Self.lock.withLock({ Self.handler }) else {
      client?.urlProtocol(
        self,
        didFailWithError: URLError(.resourceUnavailable)
      )
      return
    }
    let (response, data) = handler(request)
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
