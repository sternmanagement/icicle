# dmgbuild settings for Icicle's drag-to-install disk image.
# Paths come in as defines from make_dmg.sh: -D app=... -D background=... -D icon=...

app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}

format = "UDZO"
icon = defines["icon"]  # volume icon shown on the desktop and in the Finder sidebar
background = defines["background"]

window_rect = ((200, 140), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 13
icon_locations = {
    "Icicle.app": (165, 205),
    "Applications": (495, 205),
}
