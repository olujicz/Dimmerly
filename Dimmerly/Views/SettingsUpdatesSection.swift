//
//  SettingsUpdatesSection.swift
//  Dimmerly
//
//  The Updates section of Settings › About in the direct-download build. The App Store
//  edition is updated by the App Store and has no such section.
//

#if !APPSTORE
    import SwiftUI

    struct SettingsUpdatesSection: View {
        /// Optional so previews and staged windows without an updater still render.
        @Environment(UpdaterController.self) private var updater: UpdaterController?

        var body: some View {
            if let updater {
                Section {
                    Button(String(
                        localized: "Check for Updates…",
                        comment: "Settings > About: button that checks for a newer version of Dimmerly"
                    )) {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)

                    // Sparkle stores these settings itself; they're written only when the
                    // user changes a toggle.
                    Toggle(
                        "Automatically check for updates",
                        isOn: Binding(
                            get: { updater.automaticallyChecksForUpdates },
                            set: { updater.setAutomaticallyChecksForUpdates($0) }
                        )
                    )

                    Toggle(
                        "Automatically download and install updates",
                        isOn: Binding(
                            get: { updater.automaticallyDownloadsUpdates },
                            set: { updater.setAutomaticallyDownloadsUpdates($0) }
                        )
                    )
                    .disabled(!updater.automaticallyChecksForUpdates)

                    LabeledContent(
                        "Last checked",
                        value: Self.lastCheckedText(updater.lastUpdateCheckDate, now: .now)
                    )
                } header: {
                    Label("Updates", systemImage: "arrow.down.circle")
                } footer: {
                    Text(Self.privacyNote)
                }
            }
        }

        private static let privacyNote = String(
            localized: """
            Checking for updates downloads a small file from GitHub. \
            Dimmerly doesn't send a system profile.
            """,
            comment: "Settings > About: what an update check sends"
        )

        static func lastCheckedText(_ date: Date?, now: Date) -> String {
            guard let date else {
                return String(localized: "Never", comment: "Settings > About: updates were never checked")
            }
            let formatter = RelativeDateTimeFormatter()
            formatter.dateTimeStyle = .named
            return formatter.localizedString(for: date, relativeTo: now)
        }
    }

    extension OpenSourceLicense {
        /// Sparkle's LICENSE file from the pinned release (Vendor/Sparkle/LICENSE), including
        /// the notices of the code it bundles.
        static let sparkle = OpenSourceLicense(
            name: "Sparkle",
            type: "MIT",
            copyright: """
            Copyright (c) 2006-2013 Andy Matuschak. Copyright (c) 2009-2013 Elgato Systems GmbH. \
            Copyright (c) 2011-2014 Kornel Lesiński. Copyright (c) 2015-2017 Mayur Pawashe. \
            Copyright (c) 2014 C.W. Betts. Copyright (c) 2014 Petroules Corporation. \
            Copyright (c) 2014 Big Nerd Ranch. All rights reserved.
            """,
            text: """
            Permission is hereby granted, free of charge, to any person obtaining a copy of \
            this software and associated documentation files (the "Software"), to deal in \
            the Software without restriction, including without limitation the rights to \
            use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of \
            the Software, and to permit persons to whom the Software is furnished to do so, \
            subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all \
            copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
            IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS \
            FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR \
            COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER \
            IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN \
            CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

            EXTERNAL LICENSES

            bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

            Copyright 2003-2005 Colin Percival. All rights reserved.

            Redistribution and use in source and binary forms, with or without \
            modification, are permitted providing that the following conditions are met: \
            1. Redistributions of source code must retain the above copyright notice, this \
            list of conditions and the following disclaimer. 2. Redistributions in binary \
            form must reproduce the above copyright notice, this list of conditions and the \
            following disclaimer in the documentation and/or other materials provided with \
            the distribution.

            THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED \
            WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF \
            MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT \
            SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, \
            EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT \
            OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS \
            INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN \
            CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING \
            IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY \
            OF SUCH DAMAGE.

            sais.c and sais.h, from sais-lite (2010/08/07) \
            <https://sites.google.com/site/yuta256/sais>:

            Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

            Permission is hereby granted, free of charge, to any person obtaining a copy of \
            this software and associated documentation files (the "Software"), to deal in \
            the Software without restriction, including without limitation the rights to \
            use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of \
            the Software, and to permit persons to whom the Software is furnished to do so, \
            subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all \
            copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
            IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS \
            FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR \
            COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER \
            IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN \
            CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

            Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

            Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

            This software is provided 'as-is', without any express or implied warranty. In \
            no event will the authors be held liable for any damages arising from the use of \
            this software.

            Permission is granted to anyone to use this software for any purpose, including \
            commercial applications, and to alter it and redistribute it freely, subject to \
            the following restrictions:

            1. The origin of this software must not be misrepresented; you must not claim \
            that you wrote the original software. If you use this software in a product, an \
            acknowledgment in the product documentation would be appreciated but is not \
            required.

            2. Altered source versions must be plainly marked as such, and must not be \
            misrepresented as being the original software.

            3. This notice may not be removed or altered from any source distribution.

            SUSignatureVerifier.m:

            Copyright (c) 2011 Mark Hamlin. All rights reserved.

            Redistribution and use in source and binary forms, with or without \
            modification, are permitted providing that the following conditions are met: \
            1. Redistributions of source code must retain the above copyright notice, this \
            list of conditions and the following disclaimer. 2. Redistributions in binary \
            form must reproduce the above copyright notice, this list of conditions and the \
            following disclaimer in the documentation and/or other materials provided with \
            the distribution.

            THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED \
            WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF \
            MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT \
            SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, \
            EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT \
            OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS \
            INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN \
            CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING \
            IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY \
            OF SUCH DAMAGE.
            """
        )
    }
#endif
