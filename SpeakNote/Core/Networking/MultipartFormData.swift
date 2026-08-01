import Foundation

public struct MultipartTextField: Sendable, Equatable {
  public let name: String
  public let value: String

  public init(name: String, value: String) {
    self.name = name
    self.value = value
  }
}

public struct MultipartFilePart: Sendable, Equatable {
  public let name: String
  public let fileURL: URL
  public let fileName: String
  public let contentType: String

  public init(name: String, fileURL: URL, fileName: String, contentType: String) {
    self.name = name
    self.fileURL = fileURL
    self.fileName = fileName
    self.contentType = contentType
  }
}

public struct FileBackedMultipartForm: Sendable, Equatable {
  public let fileURL: URL
  public let contentType: String
  public let contentLength: Int64

  public func remove() {
    try? FileManager.default.removeItem(at: fileURL)
  }
}

public enum MultipartFormDataError: Error, Sendable, Equatable {
  case invalidHeader
  case unreadableFile
  case temporaryFileCreationFailed
}

public enum MultipartFormData {
  public static func write(
    fields: [MultipartTextField],
    file: MultipartFilePart,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory
  ) throws -> FileBackedMultipartForm {
    try validateHeader(file.name)
    try validateHeader(file.fileName)
    try validateHeader(file.contentType)
    for field in fields {
      try validateHeader(field.name)
    }

    let values = try file.fileURL.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
    guard file.fileURL.isFileURL, values.isRegularFile == true, values.isReadable == true else {
      throw MultipartFormDataError.unreadableFile
    }

    let boundary = "SpeakNote-\(UUID().uuidString)"
    let outputURL = temporaryDirectory.appendingPathComponent(
      "SpeakNote-Multipart-\(UUID().uuidString)"
    )
    guard
      FileManager.default.createFile(
        atPath: outputURL.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      )
    else {
      throw MultipartFormDataError.temporaryFileCreationFailed
    }

    do {
      let output = try FileHandle(forWritingTo: outputURL)
      defer { try? output.close() }

      for field in fields {
        try output.write(
          contentsOf: Data(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n\(field.value)\r\n"
              .utf8
          ))
      }
      try output.write(
        contentsOf: Data(
          "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.fileName)\"\r\nContent-Type: \(file.contentType)\r\n\r\n"
            .utf8
        ))

      let input = try FileHandle(forReadingFrom: file.fileURL)
      defer { try? input.close() }
      while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
        try output.write(contentsOf: chunk)
      }
      try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
      try output.synchronize()

      let size = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      return FileBackedMultipartForm(
        fileURL: outputURL,
        contentType: "multipart/form-data; boundary=\(boundary)",
        contentLength: Int64(size)
      )
    } catch {
      try? FileManager.default.removeItem(at: outputURL)
      if error is MultipartFormDataError { throw error }
      throw MultipartFormDataError.unreadableFile
    }
  }

  private static func validateHeader(_ value: String) throws {
    guard !value.isEmpty, !value.contains("\r"), !value.contains("\n"), !value.contains("\"") else {
      throw MultipartFormDataError.invalidHeader
    }
  }
}
