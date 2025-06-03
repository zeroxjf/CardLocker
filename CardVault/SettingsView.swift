struct SettingsView: View {
  @AppStorage("displayMode") private var displayMode: DisplayMode = .both
  @AppStorage("useICloud") private var useICloud: Bool = false
  @EnvironmentObject var statusBarController: StatusBarController
  @EnvironmentObject var store: CardStore

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        GroupBox(label: Text("Appearance").font(.headline)) {
          Picker("Display Mode", selection: $displayMode) {
            ForEach(DisplayMode.allCases, id: \.self) { mode in
              Text(mode.rawValue).tag(mode)
            }
          }
          .pickerStyle(RadioGroupPickerStyle())
          .padding(.top, 4)
        }

        GroupBox(label: Text("Cloud Sync").font(.headline)) {
          Toggle("Enable iCloud Sync", isOn: $useICloud)
        }

        // Placeholder for future settings section
        GroupBox(label: Text("Preferences").font(.headline)) {
          Text("More settings coming soon...")
            .foregroundColor(.secondary)
        }

        Spacer(minLength: 12)
      }
      .padding(20)
      .frame(maxWidth: 400)
    }
    .frame(width: 420)
  }
}