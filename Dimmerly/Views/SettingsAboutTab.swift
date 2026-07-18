//
//  SettingsAboutTab.swift
//  Dimmerly
//

import AppKit
import SwiftUI

// MARK: - About Tab

struct AboutSettingsTab: View {
    /// App version from the main bundle
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    @State private var licenseSheet: OpenSourceLicense?

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    Spacer()
                }

                LabeledContent("Version", value: appVersion)

                LabeledContent("Description") {
                    Text("A macOS menu bar utility for controlling display brightness.")
                        .foregroundStyle(.secondary)
                }

                ExternalLinkButton(
                    title: String(localized: "Privacy Policy", comment: "About link title"),
                    urlString: "https://olujicz.github.io/Dimmerly/privacy-policy.html",
                    helpText: String(localized: "Open the Dimmerly privacy policy", comment: "About link help text")
                )

                ExternalLinkButton(
                    title: String(localized: "Source Code on GitHub", comment: "About link title"),
                    urlString: "https://github.com/olujicz/Dimmerly",
                    helpText: String(localized: "Open the Dimmerly GitHub repository", comment: "About link help text")
                )
            } header: {
                Label("About Dimmerly", systemImage: "info.circle")
            }

            Section {
                ForEach(OpenSourceLicense.all) { license in
                    Button {
                        licenseSheet = license
                    } label: {
                        LabeledContent(license.name, value: license.type)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "View license", comment: "Acknowledgements license button help text"))
                }
            } header: {
                Label("Acknowledgements", systemImage: "text.book.closed")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $licenseSheet) { license in
            OpenSourceLicenseSheet(license: license) { licenseSheet = nil }
        }
    }
}

/// A third-party open-source dependency credited in Settings › About, per its license's
/// notice-inclusion requirement.
struct OpenSourceLicense: Identifiable {
    let id = UUID()
    let name: String
    let type: String
    let copyright: String
    let text: String

    static let all: [OpenSourceLicense] = [
        OpenSourceLicense(
            name: "MenuBarExtraAccess",
            type: "MIT",
            copyright: "Copyright (c) 2023 Steffan Andrews - https://github.com/orchetect",
            text: """
            Permission is hereby granted, free of charge, to any person obtaining a copy \
            of this software and associated documentation files (the "Software"), to deal \
            in the Software without restriction, including without limitation the rights \
            to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
            copies of the Software, and to permit persons to whom the Software is \
            furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all \
            copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
            IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
            FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
            AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
            LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
            OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
            SOFTWARE.
            """
        ),
    ]
}

private struct OpenSourceLicenseSheet: View {
    let license: OpenSourceLicense
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(license.name)
                .font(.headline)
            Text(license.copyright)
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(license.text)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Close", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 320)
    }
}

private struct ExternalLinkButton: View {
    let title: String
    let urlString: String
    let helpText: String

    var body: some View {
        Button {
            guard let url = URL(string: urlString) else { return }
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 2) {
                Text(title)
                Image(systemName: "arrow.up.forward")
                    .imageScale(.small)
            }
        }
        .help(helpText)
    }
}
