import Foundation

public struct RetryPolicy: Sendable {
  public let maximumRetryCount: Int
  public let baseDelay: TimeInterval
  public let maximumDelay: TimeInterval
  private let randomUnit: @Sendable () -> Double
  private let now: @Sendable () -> Date

  public init(
    maximumRetryCount: Int = 2,
    baseDelay: TimeInterval = 0.5,
    maximumDelay: TimeInterval = 30,
    randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.maximumRetryCount = max(0, maximumRetryCount)
    self.baseDelay = max(0, baseDelay)
    self.maximumDelay = max(0, maximumDelay)
    self.randomUnit = randomUnit
    self.now = now
  }

  public func shouldRetry(statusCode: Int, retryCount: Int) -> Bool {
    retryCount < maximumRetryCount
      && (statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode))
  }

  public func delay(headers: [String: String], retryCount: Int) -> TimeInterval {
    if let value = headers.first(where: {
      $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame
    })?.value,
      let retryAfter = retryAfterDelay(value)
    {
      return min(maximumDelay, retryAfter)
    }
    let cap = min(maximumDelay, baseDelay * pow(2, Double(retryCount)))
    return cap * min(1, max(0, randomUnit()))
  }

  private func retryAfterDelay(_ value: String) -> TimeInterval? {
    if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
      return seconds
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
    guard let date = formatter.date(from: value) else { return nil }
    return max(0, date.timeIntervalSince(now()))
  }
}
