# dmgbuild settings for the Dimmerly installer window.
#
# Invoked by packaging/dmg/build-dmg.sh with:
#   -D app=<path to Dimmerly.app>
#   -D background=<path to background.png; background@2x.png is picked up beside it>
#
# Window and icon positions must stay in sync with make-background.swift.

import os

application = defines["app"]  # noqa: F821 - provided by dmgbuild
app_name = os.path.basename(application)

format = "ULMO"
filesystem = "HFS+"

files = [application]
symlinks = {"Applications": "/Applications"}
# Do not use hide_extensions: it sets com.apple.FinderInfo on the bundle, which
# breaks strict code signature verification. Finder hides .app by default.

icon = os.path.join(application, "Contents", "Resources", "AppIcon.icns")
background = defines["background"]  # noqa: F821

# Finder treats window_rect as the outer frame, title bar included. The extra 28 pt
# is the macOS 15 title bar, so the content area matches the 660x400 background;
# the taller macOS 26+ title bar crops only plain gradient at the bottom.
window_rect = ((200, 120), (660, 428))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

arrange_by = None
icon_size = 128
text_size = 13
icon_locations = {
    app_name: (165, 180),
    "Applications": (495, 180),
}
