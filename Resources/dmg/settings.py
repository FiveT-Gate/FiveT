# dmgbuild settings for the FiveT disk image: `build.sh --dmg` runs
#   dmgbuild -s Resources/dmg/settings.py -D app=... -D readme=... -D icon=... -D background=... \
#            "FiveT <version>" <out.dmg>
# The window shows background.png (background@2x.png next to it is used on Retina screens), made from
# background.html by Tools/make-dmg-background.sh. The positions below are the icon centres the
# artwork is drawn around: move one here and there together.

app = defines["app"]            # noqa: F821 (dmgbuild provides `defines`)
readme = defines["readme"]      # noqa: F821
icon = defines["icon"]          # noqa: F821  the volume's own icon (desktop, sidebar)

background = defines["background"]   # noqa: F821  Resources/dmg/background.png

files = [app, (readme, "Read Me First.txt")]
symlinks = {"Applications": "/Applications"}
# Not FiveT.app: hiding its extension puts a Finder flag (com.apple.FinderInfo) on the bundle, which
# fails macOS's strict signature check once the app is copied out (1.7.1 shipped with it). Finder
# shows an app without ".app" anyway.
hide_extensions = ["Read Me First.txt"]

# The art is 660 x 440 so that its last 40 points sit under the window edge: the title bar is 22 to
# 32 points depending on the macOS version, and a shorter one must not uncover the window colour.
window_rect = ((200, 140), (660, 432))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True

icon_size = 112
text_size = 12
label_pos = "bottom"
arrange_by = None
icon_locations = {
    "FiveT.app": (160, 165),
    "Applications": (500, 165),
    "Read Me First.txt": (590, 318),
}

# LZMA: the smallest download; opens on macOS 10.15 and newer (FiveT needs 13).
format = "ULMO"
