//
//  MenuBarDDCControls.swift
//  Dimmerly
//

import AppKit
import SwiftUI

// MARK: - DDC Controls Modifier

#if !APPSTORE
    extension DisplayBrightnessRow {
        /// Convenience modifier to wire DDC hardware controls from HardwareBrightnessManager.
        ///
        /// Sets all DDC-related properties (volume, mute, hasDDC, callbacks) in one call,
        /// keeping the call site clean in `displaySliders`.
        func ddcControls(
            hardwareManager: HardwareBrightnessManager,
            displayID: CGDirectDisplayID,
            isBuiltIn: Bool = false
        ) -> DisplayBrightnessRow {
            // Built-in display does not support DDC
            guard !isBuiltIn else { return self }

            var copy = self
            let hasDDC = hardwareManager.isEnabled && hardwareManager.supportsDDC(for: displayID)
            copy.hasDDC = hasDDC

            if hasDDC {
                let cap = hardwareManager.capability(for: displayID)

                if cap?.supportsVolume == true {
                    copy.hardwareVolume = hardwareManager.hardwareVolume[displayID] ?? 0.5
                    copy.onVolumeChange = { newValue in
                        hardwareManager.setHardwareVolume(for: displayID, to: newValue)
                    }
                }

                if cap?.supportsAudioMute == true {
                    copy.isMuted = hardwareManager.hardwareMute[displayID] ?? false
                    copy.onMuteToggle = {
                        hardwareManager.toggleMute(for: displayID)
                    }
                }

                if cap?.supportsInputSource == true {
                    copy.activeInputSource = hardwareManager.activeInputSource[displayID]
                    copy.availableInputSources = hardwareManager.availableInputSources(for: displayID)
                    copy.onInputSourceChange = { source in
                        hardwareManager.setInputSource(for: displayID, to: source)
                    }
                }
            }

            return copy
        }
    }
#endif
