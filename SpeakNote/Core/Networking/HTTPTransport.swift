import Foundation

public enum HTTPBody: Sendable, Equatable {
  case none
  case data(Data)
  case file(URL)

  var mayHaveReachedServer: Bool {
    self != .none
  }
}

public struct HTTPRequest: Sendable, Equatable {
  public let request: URLRequest
  public let body: HTTPBody

  public init(request: URLRequest, body: HTTPBody = .none) {
    self.request = request
    self.body = body
  }
}

public struct HTTPResponse: Sendable, Equatable {
  public let statusCode: Int
  public let headers: [String: String]
  public let body: Data

  public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.statusCode = statusCode
    self.headers = Dictionary(
      uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) }
    )
    self.body = body
  }
}

public enum HTTPTransportError: Error, Sendable, Equatable {
  case invalidResponse
  case requestFailed(code: Int?)
  case ambiguousCompletion(code: Int?)
}

public protocol HTTPTransport: Sendable {
  func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public actor URLSessionHTTPTransport: HTTPTransport {
  private let session: URLSession

  public init(configuration: URLSessionConfiguration = .ephemeral) {
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = 120
    configuration.timeoutIntervalForResource = 300
    session = URLSession(configuration: configuration)
  }

  public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    do {
      let result: (Data, URLResponse)
      switch request.body {
      case .none:
        result = try await session.data(for: request.request)
      case .data(let data):
        result = try await session.upload(for: request.request, from: data)
      case .file(let fileURL):
        guard fileURL.isFileURL else {
          throw HTTPTransportError.requestFailed(code: nil)
        }
        result = try await session.upload(for: request.request, fromFile: fileURL)
      }

      guard let response = result.1 as? HTTPURLResponse else {
        throw HTTPTransportError.invalidResponse
      }
      let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
        guard let key = pair.key as? String else { return }
        result[key.lowercased()] = String(describing: pair.value)
      }
      return HTTPResponse(statusCode: response.statusCode, headers: headers, body: result.0)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as HTTPTransportError {
      throw error
    } catch let error as URLError {
      if error.code == .cancelled, Task.isCancelled {
        throw CancellationError()
      }
      let code = error.errorCode
      if request.body.mayHaveReachedServer, Self.canBeAmbiguous(error.code) {
        throw HTTPTransportError.ambiguousCompletion(code: code)
      }
      throw HTTPTransportError.requestFailed(code: code)
    } catch {
      if request.body.mayHaveReachedServer {
        throw HTTPTransportError.ambiguousCompletion(code: nil)
      }
      throw HTTPTransportError.requestFailed(code: nil)
    }
  }

  private static func canBeAmbiguous(_ code: URLError.Code) -> Bool {
    switch code {
    case .badURL,
      .unsupportedURL,
      .cannotFindHost,
      .dnsLookupFailed,
      .cannotConnectToHost,
      .notConnectedToInternet,
      .secureConnectionFailed,
      .serverCertificateHasBadDate,
      .serverCertificateUntrusted,
      .serverCertificateHasUnknownRoot,
      .serverCertificateNotYetValid,
      .clientCertificateRejected,
      .clientCertificateRequired,
      .appTransportSecurityRequiresSecureConnection:
      false
    default:
      true
    }
  }
}
