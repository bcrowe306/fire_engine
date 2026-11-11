# dmgbuild settings for Pads' disk image: the app beside a link to
# Applications, to drag it there. `app` and `icon` come with -D.
import os

app = defines["app"]  # noqa: F821 (dmgbuild gives `defines`)
files = [app]
symlinks = {"Applications": "/Applications"}
badge_icon = defines["icon"]  # noqa: F821
format = "UDZO"
icon_size = 128
window_rect = ((200, 200), (540, 320))
icon_locations = {os.path.basename(app): (140, 150), "Applications": (400, 150)}
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
