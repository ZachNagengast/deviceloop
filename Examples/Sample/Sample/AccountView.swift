//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import SwiftUI

/// The Account tab: a sign-in form that takes any email and password, preferences, a sign-out confirmation and a
/// Developer link to `IssuesPage`.
struct AccountView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var signedInEmail: String?
    @State private var emailIsInvalid = false
    @State private var confirmingSignOut = false
    @State private var notifications = true
    @State private var weeklyDigest = false

    var body: some View {
        NavigationStack {
            Form {
                if let signedInEmail {
                    Section {
                        HStack {
                            Text(signedInEmail.prefix(1).uppercased())
                                .font(.title2.bold())
                                .foregroundStyle(.white)
                                .frame(width: 56, height: 56)
                                .background(
                                    LinearGradient(colors: [.indigo, .rose], startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: .circle
                                )
                                .accessibilityHidden(true)
                            VStack(alignment: .leading) {
                                Text(Self.name(of: signedInEmail))
                                    .font(.headline)
                                    .accessibilityIdentifier("sample.account.name")
                                Text(signedInEmail)
                                    .foregroundStyle(.subtle)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    Section {
                        Toggle("Notifications", isOn: $notifications)
                            .accessibilityIdentifier("sample.account.notifications")
                        Toggle("Weekly digest", isOn: $weeklyDigest)
                            .accessibilityIdentifier("sample.account.digest")
                    } header: {
                        SectionText("Preferences")
                    }
                    Section {
                        Button("Sign Out") { confirmingSignOut = true }
                            .accessibilityIdentifier("sample.account.signout")
                    }
                } else {
                    Section {
                        TextField("Email", text: $email, prompt: Text("Email").foregroundStyle(.subtle))
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.vertical, 4)
                            .accessibilityIdentifier("sample.account.email")
                        SecureField("Password", text: $password, prompt: Text("Password").foregroundStyle(.subtle))
                            .textContentType(.password)
                            .padding(.vertical, 4)
                            .accessibilityIdentifier("sample.account.password")
                    } header: {
                        SectionText("Sign in")
                    } footer: {
                        SectionText(emailIsInvalid ? "Enter an email address with an @." : "Any email and password work.")
                            .accessibilityIdentifier("sample.account.hint")
                    }
                    Section {
                        Button("Sign In", action: signIn)
                            .disabled(email.isEmpty || password.isEmpty)
                            .accessibilityIdentifier("sample.account.signin")
                    }
                }
                Section {
                    NavigationLink("Accessibility issues") { IssuesPage() }
                        .accessibilityIdentifier("sample.account.issues")
                } header: {
                    SectionText("Developer")
                } footer: {
                    SectionText("A page of issues for deviceloop ui audit to find.")
                }
            }
            .navigationTitle("Account")
            .alert("Sign out?", isPresented: $confirmingSignOut) {
                Button("Cancel", role: .cancel) {}
                Button("Sign Out") {
                    signedInEmail = nil
                    email = ""
                    password = ""
                    notifications = true
                    weeklyDigest = false
                }
            } message: {
                Text("You can sign back in with any email and password.")
            }
        }
    }

    private func signIn() {
        let address = email.trimmingCharacters(in: .whitespaces)
        guard address.contains("@") else {
            emailIsInvalid = true
            return
        }
        emailIsInvalid = false
        signedInEmail = address
        password = ""
    }

    /// The part of `email` before the @, capitalized: Ada for ada@example.com.
    static func name(of email: String) -> String {
        (email.split(separator: "@").first.map(String.init) ?? email).capitalized
    }
}

/// A section header or footer in the footnote font and the subtle color.
private struct SectionText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.subtle)
    }
}

/// One element per audit type for contrast, hitRegion, sufficientElementDescription, dynamicType, textClipped and trait,
/// each with the identifier sample.issues.<type>.
private struct IssuesPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Each element below fails one check of deviceloop ui audit.")
                    .foregroundStyle(.subtle)
                Button(action: {}) {
                    Image(systemName: "star.fill")
                        .font(.title)
                }
                .accessibilityLabel("")
                .accessibilityIdentifier("sample.issues.sufficientElementDescription")
                Button(action: {}) {
                    Text("Small tap area").frame(width: 200, height: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle().size(width: 8, height: 8))
                .accessibilityIdentifier("sample.issues.hitRegion")
                Text("Low contrast text")
                    .foregroundStyle(Color(.systemGray5))
                    .accessibilityIdentifier("sample.issues.contrast")
                Text("Fixed size text")
                    .font(.system(size: 15))
                    .accessibilityIdentifier("sample.issues.dynamicType")
                Text("A label that is too long for its frame")
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)
                    .accessibilityIdentifier("sample.issues.textClipped")
                Button("Save button") {}
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("sample.issues.trait")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Accessibility issues")
    }
}
