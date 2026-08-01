import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppKitVoiceNoteFilePicker: VoiceNoteFilePicking {
  func chooseAudioFile() async -> URL? {
    let supportedTypes = AudioImportFormat.allCases.compactMap {
      UTType(filenameExtension: $0.rawValue)
    }
    guard supportedTypes.count == AudioImportFormat.allCases.count else {
      return nil
    }

    let panel = NSOpenPanel()
    panel.allowedContentTypes = supportedTypes
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.message = String(
      localized: "Choose one audio file (M4A, MP3, WAV, AIFF, or CAF)."
    )
    panel.prompt = String(localized: "Import")

    guard await panel.begin() == .OK,
      let url = panel.url,
      AudioImportFormat(url: url) != nil
    else {
      return nil
    }
    return url
  }
}
