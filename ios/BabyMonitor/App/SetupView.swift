import SwiftUI

struct SetupView: View {
    @AppStorage("password") private var password = ""
    @AppStorage("deviceName") private var deviceName = ""
    @AppStorage("role") private var roleRaw = Role.parent.rawValue
    @AppStorage("nurseryAddress") private var nurseryAddress = ""
    let onStart: (Session) -> Void

    private var role: Role { Role(rawValue: roleRaw) ?? .parent }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "moon.stars.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.yellow)
                        Text("Baby Monitor")
                            .font(.largeTitle.bold())
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section("This phone is the…") {
                    Picker("Role", selection: $roleRaw) {
                        Text("👀 Parent").tag(Role.parent.rawValue)
                        Text("👶 Baby station").tag(Role.baby.rawValue)
                    }
                    .pickerStyle(.segmented)
                    Text(role == .parent
                         ? "Watch and listen, and get alerts, even when your phone is locked."
                         : "Stays in the nursery, plugged in, pointed at the crib.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    SecureField("Family password", text: $password)
                        .textContentType(.password)
                    TextField(role == .parent ? "Your name, e.g. Mom" : "Room name, e.g. Nursery", text: $deviceName)
                } footer: {
                    Text("Use the same password on every phone.")
                }

                if role == .parent {
                    Section {
                        TextField("Nursery’s Tailscale address (optional)", text: $nurseryAddress)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Away from home")
                    } footer: {
                        Text("To listen over cellular, install Tailscale on both phones and enter the address shown on the nursery phone, e.g. 100.101.102.103. At home the phones find each other by themselves.")
                    }
                }

                Section {
                    Button {
                        onStart(Session(role: role, password: password, name: resolvedName, remoteAddress: role == .parent ? nurseryAddress : ""))
                    } label: {
                        Text("Start")
                            .bold()
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(password.count < 4)
                } footer: {
                    if password.count < 4 {
                        Text("The password needs at least 4 characters.")
                    }
                }
            }
        }
    }

    private var resolvedName: String {
        let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return String(trimmed.prefix(40)) }
        return role == .parent ? "Parent" : "Nursery"
    }
}
