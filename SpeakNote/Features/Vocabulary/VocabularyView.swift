import SwiftUI

struct VocabularyView: View {
  @ObservedObject var coordinator: VocabularyCoordinator

  var body: some View {
    NavigationSplitView {
      List(
        coordinator.profiles,
        selection: Binding(
          get: { coordinator.selectedProfileID },
          set: { profileID in
            Task { await coordinator.select(profileID) }
          }
        )
      ) { profile in
        HStack {
          Text(profile.name)
          Spacer()
          if coordinator.activeProfileID == profile.id {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.green)
              .accessibilityLabel("Active")
          }
        }
        .tag(profile.id)
      }
      .navigationTitle("Profiles")
      .toolbar {
        Button {
          coordinator.beginNewProfile()
        } label: {
          Label("New Profile", systemImage: "plus")
        }
        Button(role: .destructive) {
          Task { await coordinator.deleteSelectedProfile() }
        } label: {
          Label("Delete Profile", systemImage: "trash")
        }
        .disabled(coordinator.selectedProfileID == nil || coordinator.isBusy)
      }
    } detail: {
      if coordinator.selectedProfileID != nil || coordinator.isCreatingProfile {
        profileEditor
      } else {
        ContentUnavailableView(
          "Select a Profile",
          systemImage: "person.text.rectangle",
          description: Text(
            "Create a profile for language, provider, vocabulary, and note defaults.")
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
      Button("OK") { coordinator.errorMessage = nil }
    } message: {
      Text(coordinator.errorMessage ?? "")
    }
  }

  private var profileEditor: some View {
    Form {
      Section("Profile") {
        TextField("Name", text: $coordinator.profileName)
        TextField(
          "Recognition language (automatic when empty)",
          text: $coordinator.recognitionLanguageCode
        )
        TextField(
          "Output language (same as input when empty)",
          text: $coordinator.outputLanguageCode
        )
        Picker("Transcription provider", selection: $coordinator.providerIdentifier) {
          Text("Use app setting").tag("")
          Text("Groq Cloud").tag(ProviderID.groq.rawValue)
          Text("Apple Speech").tag(ProviderID.appleSpeech.rawValue)
        }
        Picker(
          "Default structured note",
          selection: $coordinator.defaultNoteTypeIdentifier
        ) {
          ForEach(NoteType.allCases, id: \.rawValue) { noteType in
            Text(noteType.vocabularyTitle).tag(noteType.rawValue)
          }
        }
        Toggle("Use this profile's vocabulary", isOn: $coordinator.vocabularyEnabled)

        HStack {
          Button("Save Profile") {
            Task { await coordinator.saveProfile() }
          }
          .disabled(coordinator.isBusy)

          if coordinator.selectedProfileIsActive {
            Button("Deactivate") {
              Task { await coordinator.deactivateProfile() }
            }
          } else {
            Button("Save and Activate") {
              Task { await coordinator.activateSelectedProfile() }
            }
          }
        }
      }

      if coordinator.selectedProfileID != nil {
        customTermsSection
        replacementRulesSection
        suggestionsSection
      } else {
        Section {
          Text("Save the profile before adding terms or rules.")
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(
      coordinator.isCreatingProfile
        ? String(localized: "New Profile") : String(localized: "Vocabulary")
    )
  }

  private var customTermsSection: some View {
    Section("Custom Terms") {
      Text(
        "Enabled terms are selected by priority for the transcription prompt. The prompt has a conservative 224-token budget."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      HStack {
        TextField("Term", text: $coordinator.termDraft)
        TextField("Pronunciation hint", text: $coordinator.pronunciationDraft)
        TextField("Priority", value: $coordinator.termPriority, format: .number)
          .frame(width: 80)
        Button("Add") {
          Task { await coordinator.addCustomTerm() }
        }
        .disabled(coordinator.isBusy)
      }

      ForEach(coordinator.customTerms) { term in
        HStack {
          Button {
            Task { await coordinator.toggleCustomTerm(term) }
          } label: {
            Image(systemName: term.isEnabled ? "checkmark.circle.fill" : "circle")
          }
          .buttonStyle(.plain)
          .accessibilityLabel(
            term.isEnabled
              ? String(localized: "Disable term") : String(localized: "Enable term")
          )

          VStack(alignment: .leading) {
            Text(term.term)
            if let hint = term.pronunciationHint {
              Text("Hint: \(hint)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Spacer()
          Text("Priority \(term.priority)")
            .font(.caption)
            .foregroundStyle(.secondary)
          Button(role: .destructive) {
            Task { await coordinator.deleteCustomTerm(term) }
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private var replacementRulesSection: some View {
    Section("Replacement Rules") {
      Text(
        "Rules run after the immutable raw transcript is saved and before text processing. Matches do not cascade."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      HStack {
        TextField("Match", text: $coordinator.ruleMatchDraft)
        TextField("Replace with", text: $coordinator.ruleReplacementDraft)
        TextField("Priority", value: $coordinator.rulePriority, format: .number)
          .frame(width: 80)
      }
      Toggle("Case-sensitive", isOn: $coordinator.ruleCaseSensitive)
      Toggle(
        "Require word boundaries",
        isOn: $coordinator.ruleRequiresWordBoundaries
      )
      Button("Add Rule") {
        Task { await coordinator.addReplacementRule() }
      }
      .disabled(coordinator.isBusy)

      ForEach(coordinator.replacementRules) { rule in
        HStack {
          Button {
            Task { await coordinator.toggleReplacementRule(rule) }
          } label: {
            Image(systemName: rule.isEnabled ? "checkmark.circle.fill" : "circle")
          }
          .buttonStyle(.plain)
          .accessibilityLabel(
            rule.isEnabled
              ? String(localized: "Disable rule") : String(localized: "Enable rule")
          )
          Text("\(rule.match) → \(rule.replacement)")
          Spacer()
          Text("Priority \(rule.priority)")
            .font(.caption)
            .foregroundStyle(.secondary)
          Button(role: .destructive) {
            Task { await coordinator.deleteReplacementRule(rule) }
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private var suggestionsSection: some View {
    Section("Suggestions") {
      Text(
        "Suggestions are generated only from local correction history. Nothing is added until you accept it."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Button("Refresh Suggestions") {
        Task { await coordinator.refreshSuggestions() }
      }
      .disabled(coordinator.isBusy)

      ForEach(coordinator.suggestions) { suggestion in
        HStack {
          VStack(alignment: .leading) {
            Text("\(suggestion.original) → \(suggestion.replacement)")
            Text("Seen \(suggestion.occurrenceCount) times · \(suggestion.status.vocabularyTitle)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          if suggestion.status == .pending {
            Button("Accept") {
              Task { await coordinator.acceptSuggestion(suggestion) }
            }
            Button("Reject", role: .destructive) {
              Task { await coordinator.rejectSuggestion(suggestion) }
            }
          }
        }
      }
    }
  }
}

extension NoteType {
  fileprivate var vocabularyTitle: String {
    switch self {
    case .classNotes: String(localized: "Class Notes")
    case .meetingMinutes: String(localized: "Meeting Minutes")
    case .generalNotes: String(localized: "General Notes")
    }
  }
}

extension VocabularySuggestionStatus {
  fileprivate var vocabularyTitle: String {
    switch self {
    case .pending: String(localized: "Pending")
    case .accepted: String(localized: "Accepted")
    case .rejected: String(localized: "Rejected")
    }
  }
}
