import Combine
import Foundation

@MainActor
final class DictationHistoryCoordinator: ObservableObject {
  @Published private(set) var records: [DictationRecordDTO] = []
  @Published private(set) var runs: [ProcessingRunDTO] = []
  @Published var selectedRecordID: UUID?
  @Published private(set) var isBusy = false
  @Published var errorMessage: String?

  private let historyRepository: any DictationHistoryStoring
  private let textProcessor: any TextProcessingEngine
  private let settingsRepository: any SettingsStoring
  private let copier: any ManualTextCopying

  init(
    historyRepository: any DictationHistoryStoring,
    textProcessor: any TextProcessingEngine,
    settingsRepository: any SettingsStoring,
    copier: any ManualTextCopying = SystemManualTextCopier()
  ) {
    self.historyRepository = historyRepository
    self.textProcessor = textProcessor
    self.settingsRepository = settingsRepository
    self.copier = copier
  }

  var selectedRecord: DictationRecordDTO? {
    guard let selectedRecordID else { return nil }
    return records.first { $0.id == selectedRecordID }
  }

  func load() async {
    isBusy = true
    defer { isBusy = false }
    do {
      records = try await historyRepository.records()
      if let selectedRecordID,
        !records.contains(where: { $0.id == selectedRecordID })
      {
        self.selectedRecordID = nil
        runs = []
      } else if selectedRecordID != nil {
        try await loadRuns()
      }
    } catch {
      errorMessage = String(localized: "Dictation history could not be loaded.")
    }
  }

  func select(_ id: UUID?) async {
    selectedRecordID = id
    do {
      try await loadRuns()
    } catch {
      runs = []
      errorMessage = String(localized: "Processing history could not be loaded.")
    }
  }

  func reprocess(level: CompressionLevel) async {
    guard let record = selectedRecord else { return }
    isBusy = true
    defer { isBusy = false }

    do {
      let settings = try await settingsRepository.load()
      guard settings.hasAcknowledgedGroqCloudProcessing else {
        errorMessage =
          String(
            localized:
              "Open Settings and acknowledge Groq cloud processing before reprocessing."
          )
        return
      }
      let configuration = TextProcessingConfiguration(
        providerID: settings.textProcessingProviderID,
        modelID: settings.textProcessingModelID,
        compressionLevel: level,
        recognitionLanguageCode: settings.recognitionLanguageCode,
        outputLanguageCode: settings.outputLanguageCode
      )
      let hash = try ProcessingConfigurationHash.make(configuration)
      do {
        let output = try await textProcessor.process(
          transcript: Transcript(
            id: record.id,
            text: record.rawTranscript,
            detectedLanguage: record.detectedLanguage
          ),
          configuration: configuration
        )
        _ = try await historyRepository.appendRun(
          NewProcessingRun(
            ownerID: record.id,
            providerID: configuration.providerID.rawValue,
            modelID: configuration.modelID,
            configurationHash: hash,
            outputText: output.text,
            status: .succeeded
          )
        )
      } catch is CancellationError {
        return
      } catch {
        _ = try await historyRepository.appendRun(
          NewProcessingRun(
            ownerID: record.id,
            providerID: configuration.providerID.rawValue,
            modelID: configuration.modelID,
            configurationHash: hash,
            outputText: nil,
            status: .failed,
            errorCategory: Self.errorCategory(error)
          )
        )
        errorMessage = String(
          localized: "Text processing failed. The raw transcript is unchanged."
        )
      }
      try await loadRuns()
    } catch {
      errorMessage = String(localized: "The processing run could not be saved.")
    }
  }

  func deleteSelectedRecord() async {
    guard let selectedRecordID else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      try await historyRepository.deleteRecord(id: selectedRecordID)
      self.selectedRecordID = nil
      runs = []
      records = try await historyRepository.records()
    } catch {
      errorMessage = String(localized: "The history item could not be deleted.")
    }
  }

  @discardableResult
  func copy(_ text: String) -> Bool {
    let didCopy = copier.copy(text)
    if !didCopy {
      errorMessage = String(localized: "The text could not be copied.")
    }
    return didCopy
  }

  private func loadRuns() async throws {
    guard let selectedRecordID else {
      runs = []
      return
    }
    runs = try await historyRepository.runs(
      ownerKind: .dictation,
      ownerID: selectedRecordID
    )
  }

  private static func errorCategory(_ error: Error) -> String {
    if error is CancellationError { return "cancelled" }
    if error is URLError { return "network" }
    return "provider"
  }
}
