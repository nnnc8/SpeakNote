import Foundation
import XCTest

@testable import SpeakNote

final class RetryPolicyTests: XCTestCase {
  func testRetriesOnly408429AndServerErrorsAtMostTwice() {
    let policy = RetryPolicy(maximumRetryCount: 2)

    for status in [408, 429, 500, 503, 599] {
      XCTAssertTrue(policy.shouldRetry(statusCode: status, retryCount: 0))
      XCTAssertTrue(policy.shouldRetry(statusCode: status, retryCount: 1))
      XCTAssertFalse(policy.shouldRetry(statusCode: status, retryCount: 2))
    }
    for status in [400, 401, 403, 404, 413] {
      XCTAssertFalse(policy.shouldRetry(statusCode: status, retryCount: 0))
    }
  }

  func testUsesFullJitterAndRetryAfter() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let policy = RetryPolicy(
      maximumRetryCount: 2,
      baseDelay: 2,
      maximumDelay: 30,
      randomUnit: { 0.25 },
      now: { now }
    )

    XCTAssertEqual(policy.delay(headers: [:], retryCount: 0), 0.5)
    XCTAssertEqual(policy.delay(headers: [:], retryCount: 1), 1)
    XCTAssertEqual(policy.delay(headers: ["Retry-After": "7"], retryCount: 0), 7)

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
    XCTAssertEqual(
      policy.delay(
        headers: ["retry-after": formatter.string(from: now.addingTimeInterval(9))], retryCount: 0),
      9,
      accuracy: 0.01
    )
  }
}
