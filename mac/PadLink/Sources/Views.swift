import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.permissionsOK {
                MainView()
            } else {
                SetupView()
            }
        }
        .frame(width: 380, height: 520)
        .background(.background)
    }
}

// MARK: - Main

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 22)

            Spacer(minLength: 12)

            BigButton(state: buttonState) { model.bigButton() }

            StatusText()
                .padding(.top, 26)
                .padding(.horizontal, 28)
                .frame(height: 92, alignment: .top)

            Spacer(minLength: 8)

            footer
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("PadLink")
                .font(.system(size: 15, weight: .semibold))
            Text(model.pairedPad.map { "Gekoppelt mit \($0)" } ?? "Noch kein Pad gekoppelt")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var buttonState: BigButton.Look {
        switch model.phase {
        case .idle, .problem: return .off
        case .streaming: return .on
        default: return .busy
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Picker("", selection: $model.mode) {
                ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isActive)

            HStack {
                Menu {
                    Picker("Bildqualität", selection: $model.quality) {
                        ForEach(Quality.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle("Im WLAN: AirDrop beim Zeichnen pausieren (weniger Ruckler, fragt nach dem Passwort)",
                           isOn: $model.pauseAirDrop)
                } label: {
                    Label("Bild: \(model.quality.title)", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.isActive)

                Spacer()

                if model.pairedPad != nil {
                    Button("Anderes Pad koppeln") { model.forgetPad() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}

struct StatusText: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            switch model.phase {
            case .idle:
                title(model.pairedPad == nil ? "Drück den Knopf zum Koppeln" : "Drück den Knopf")
                subtitle("Öffne vorher PadLink auf dem Pad.")
            case .searching:
                title("Suche Pad …")
                subtitle("Per Kabel oder im gleichen WLAN.")
            case .choosePad(let names):
                title("Welches Pad?")
                HStack {
                    ForEach(names, id: \.self) { n in
                        Button(n) { model.choose(n) }.controlSize(.large)
                    }
                }
            case .connecting(let name):
                title("Verbinde mit \(name) …")
            case .waitingForApproval:
                title("Tippe auf dem Pad auf „Erlauben“")
                subtitle("Das musst du nur einmal machen.")
            case .streaming:
                title(model.viaCable ? "Verbunden per Kabel" : "Verbunden per WLAN")
                HStack(spacing: 6) {
                    Circle().fill(latencyColor).frame(width: 8, height: 8)
                    Text(latencyText)
                }
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)
            case .problem(let msg):
                title("Hat nicht geklappt")
                subtitle(msg)
                if !model.cableReport.isEmpty { CableDetails(text: model.cableReport) }
            }
        }
        .multilineTextAlignment(.center)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
    }

    private var latencyText: String {
        model.latencyMs > 0 ? "\(model.viaCable ? "Kabel" : "WLAN") \(Int(model.latencyMs.rounded())) ms · \(model.fps) Bilder/s" : "Messe Verzögerung …"
    }
    private var latencyColor: Color {
        switch model.latencyMs {
        case 0: return .secondary
        case ..<15: return .green
        case ..<35: return .yellow
        default: return .orange
        }
    }

    private func title(_ s: String) -> some View {
        Text(s).font(.system(size: 18, weight: .semibold))
    }
    private func subtitle(_ s: String) -> some View {
        Text(s).font(.system(size: 13)).foregroundStyle(.secondary)
    }
}

// MARK: - Big button

struct BigButton: View {
    enum Look { case off, busy, on }
    let state: Look
    let action: () -> Void
    @State private var pressed = false
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(fill)
                    .shadow(color: shadow, radius: pressed ? 6 : 18, y: pressed ? 2 : 8)

                if state == .busy {
                    Circle()
                        .stroke(Color.white.opacity(0.5), lineWidth: 3)
                        .scaleEffect(pulse ? 1.12 : 0.96)
                        .opacity(pulse ? 0 : 1)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)
                        .onAppear { pulse = true }
                        .onDisappear { pulse = false }
                }

                VStack(spacing: 10) {
                    Image(systemName: state == .on ? "stop.fill" : "paintbrush.pointed.fill")
                        .font(.system(size: 46, weight: .medium))
                    Text(label)
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(.white)
            }
            .frame(width: 196, height: 196)
            .scaleEffect(pressed ? 0.96 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(PressStyle(pressed: $pressed))
        .keyboardShortcut(.defaultAction)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: state)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .off: return "Verbinden"
        case .busy: return "Abbrechen"
        case .on: return "Trennen"
        }
    }
    private var fill: LinearGradient {
        let c: [Color] = switch state {
        case .off:  [Color(red: 0.24, green: 0.48, blue: 0.98), Color(red: 0.16, green: 0.36, blue: 0.88)]
        case .busy: [Color(red: 0.42, green: 0.55, blue: 0.80), Color(red: 0.33, green: 0.45, blue: 0.70)]
        case .on:   [Color(red: 0.20, green: 0.72, blue: 0.45), Color(red: 0.13, green: 0.60, blue: 0.36)]
        }
        return LinearGradient(colors: c, startPoint: .top, endPoint: .bottom)
    }
    private var shadow: Color {
        switch state {
        case .off: return Color.blue.opacity(0.35)
        case .busy: return Color.gray.opacity(0.3)
        case .on: return Color.green.opacity(0.35)
        }
    }
}

private struct PressStyle: ButtonStyle {
    @Binding var pressed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, p in
                withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) { pressed = p }
            }
    }
}

// MARK: - First-run setup

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var askedScreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Einmal einrichten")
                    .font(.system(size: 22, weight: .bold))
                Text("PadLink braucht zwei Erlaubnisse vom Mac. Danach nie wieder.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            PermissionRow(
                number: 1, title: "Bildschirm zeigen",
                detail: "Damit dein Bild auf dem Pad erscheint.",
                done: model.hasScreenAccess
            ) {
                askedScreen = true
                model.askScreenAccess()
            }

            PermissionRow(
                number: 2, title: "Mit dem Stift steuern",
                detail: "Damit der Stift in Photoshop malt – mit Druckstärke.",
                done: model.hasInputAccess
            ) { model.askInputAccess() }

            Spacer()

            if askedScreen && !model.hasScreenAccess {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Schon erlaubt? Dann PadLink einmal neu starten.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("PadLink neu starten") { model.relaunch() }
                        .controlSize(.large)
                }
            }
        }
        .padding(28)
    }
}

private struct PermissionRow: View {
    let number: Int
    let title: String
    let detail: String
    let done: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : Color.accentColor.opacity(0.15))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if !done {
                Button("Erlauben", action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .animation(.easeInOut, value: done)
    }
}

/// Step-by-step record of the last cable attempt — so a screenshot shows what went wrong on another Mac.
struct CableDetails: View {
    let text: String
    @State private var open = false

    var body: some View {
        VStack(spacing: 6) {
            Button(open ? "Kabel-Details ausblenden" : "Kabel-Details") { open.toggle() }
                .buttonStyle(.link)
                .font(.system(size: 12))
            if open {
                ScrollView {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                Button("Kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .font(.system(size: 12))
            }
        }
        .padding(.top, 4)
    }
}
