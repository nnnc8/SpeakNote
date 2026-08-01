import SwiftUI

struct DictationHistoryView: View {
  @ObservedObject var coordinator: DictationHistoryCoordinator
  @State private var reprocessLevel = CompressionLevel.clean

  var body: some View {
    NavigationSplitView {
      List(
        coordinator.records,
        selection: Binding(
          get: { coordinator.selectedRecordID },
          set: { newValue in
            Task { await coordinator.select(newValue) }
          }
        )
      ) { record in
        VStack(alignment: .leading, spacing: 4) {
          Text(record.rawTranscript)
            .lineLimit(2)
          Text(record.createdAt, format: .dateTime)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .tag(record.id)
      }
      .navigationTitle("Dictation History")
      .overlay {
        if coordinator.records.isEmpty && !coordinator.isBusy {
          ContentUnavailableView(
            "No Dictations",
            systemImage: "text.bubble",
            description: Text("Saved quick dictations will appear here.")
          )
        }
      }
    } detail: {
      if let record = coordinator.selectedRecord {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            GroupBox("Raw transcript") {
              Text(record.rawTranscript)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
              Button("Copy Raw") {
                coordinator.copy(record.rawTranscript)
              }
              Picker("Reprocess as", selection: $reprocessLevel) {
                ForEach(CompressionLevel.allCases, id: \.self) { level in
                  Text(level.historyTitle).tag(level)
                }
              }
              .frame(maxWidth: 220)
              Button("Reprocess") {
                Task { await coordinator.reprocess(level: reprocessLevel) }
              }
              .disabled(coordinator.isBusy)
              Spacer()
              Button("Delete", role: .destructive) {
                Task { await coordinator.deleteSelectedRecord() }
              }
              .disabled(coordinator.isBusy)
            }

            ForEach(coordinator.runs) { run in
              GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                  HStack {
                    Text(run.modelID)
                    Spacer()
                    Text(run.createdAt, format: .dateTime)
                      .foregroundStyle(.secondary)
                  }
                  .font(.caption)

                  if let output = run.outputText {
                    Text(output)
                      .textSelection(.enabled)
                    Button("Copy Output") {
                      coordinator.copy(output)
                    }
                  } else {
                    Text("Processing failed. The raw transcript was preserved.")
                      .foregroundStyle(.secondary)
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
          .padding()
        }
        .navigationTitle("Dictation")
      } else {
        ContentUnavailableView(
          "Select a Dictation",
          systemImage: "sidebar.left",
          description: Text("Review raw transcripts and append processing runs.")
        )
      }
    }
    .task {
      await coordinator.load()
    }
    .alert(
      "SpeakNote",
      isPresented: Binding(
        get: { coordinator.errorMessage != nil },
        set: { if !$0 { coordinator.errorMessage = nil } }
      )
    ) {
      Button("OK") {
        coordinator.errorMessage = nil
      }
    } message: {
      Text(coordinator.errorMessage ?? "")
    }
  }
}

extension CompressionLevel {
  fileprivate var historyTitle: String {
    switch self {
    case .verbatim: String(localized: "Verbatim")
    case .clean: String(localized: "Clean")
    case .polished: String(localized: "Polished")
    case .concise: String(localized: "Concise")
    }
  }
}
