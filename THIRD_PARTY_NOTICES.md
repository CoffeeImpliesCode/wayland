# Third-party notices

The first-party code in this repository is licensed under MIT; see [LICENSE](LICENSE). The bundled protocol XML files below remain under their own licenses. Their embedded copyright and permission notices are retained.

## Protocol specifications

| Component | Path | License | Copyright holder(s) | Upstream |
|---|---|---|---|---|
| Wayland | `protocols/wayland/wayland.xml` | MIT/Expat (notice in file) | Kristian Høgsberg; Intel Corporation; Collabora, Ltd. | <https://gitlab.freedesktop.org/wayland/wayland> |
| wayland-protocols | `protocols/wayland-protocols/stable/linux-dmabuf/linux-dmabuf-v1.xml` | MIT/Expat (notice in file) | Collabora, Ltd. | <https://gitlab.freedesktop.org/wayland/wayland-protocols> |
| wayland-protocols | `protocols/wayland-protocols/stable/presentation-time/presentation-time.xml` | MIT/Expat (notice in file) | Collabora, Ltd. | <https://gitlab.freedesktop.org/wayland/wayland-protocols> |
| wayland-protocols | `protocols/wayland-protocols/stable/tablet/tablet-v2.xml` | MIT/Expat (notice in file) | Stephen "Lyude" Chandler Paul; Red Hat, Inc. | <https://gitlab.freedesktop.org/wayland/wayland-protocols> |
| wayland-protocols | `protocols/wayland-protocols/stable/viewporter/viewporter.xml` | MIT/Expat (notice in file) | Collabora, Ltd. | <https://gitlab.freedesktop.org/wayland/wayland-protocols> |
| wayland-protocols | `protocols/wayland-protocols/stable/xdg-shell/xdg-shell.xml` | MIT/Expat (notice in file) | Kristian Høgsberg; Rafael Antognolli; Jasper St. Pierre; Intel Corporation; Samsung Electronics Co., Ltd.; Red Hat Inc. | <https://gitlab.freedesktop.org/wayland/wayland-protocols> |
| wayland-protocols | `protocols/wayland-protocols/staging/cursor-shape/cursor-shape-v1.xml` | MIT/Expat (notice in file) | The Chromium Authors; Simon Ser | <https://gitlab.freedesktop.org/wayland/wayland-protocols> |
| wayland-protocols | `protocols/wayland-protocols/staging/ext-session-lock/ext-session-lock-v1.xml` | MIT/Expat (notice in file) | Isaac Freund | <https://gitlab.freedesktop.org/wayland/wayland-protocols> |
| wayland-protocols | `protocols/wayland-protocols/staging/fractional-scale/fractional-scale-v1.xml` | MIT/Expat (notice in file) | Kenny Levinsen | <https://gitlab.freedesktop.org/wayland/wayland-protocols> |
| wayland-protocols | `protocols/wayland-protocols/staging/tearing-control/tearing-control-v1.xml` | MIT/Expat (notice in file) | Xaver Hugl | <https://gitlab.freedesktop.org/wayland/wayland-protocols> |
| wayland-protocols | `protocols/wayland-protocols/staging/xdg-activation/xdg-activation-v1.xml` | MIT/Expat (notice in file) | Aleix Pol Gonzalez; Carlos Garnacho | <https://gitlab.freedesktop.org/wayland/wayland-protocols> |
| wayland-protocols | `protocols/wayland-protocols/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml` | MIT/Expat (notice in file) | Jonas Ådahl; Red Hat Inc. | <https://gitlab.freedesktop.org/wayland/wayland-protocols> |
| wayland-protocols | `protocols/wayland-protocols/unstable/pointer-gestures/pointer-gestures-unstable-v1.xml` | X11-style license (notice below) | Red Hat Inc. | <https://gitlab.freedesktop.org/wayland/wayland-protocols> |
| wayland-protocols | `protocols/wayland-protocols/unstable/primary-selection/primary-selection-unstable-v1.xml` | MIT/Expat (notice in file) | Red Hat | <https://gitlab.freedesktop.org/wayland/wayland-protocols> |
| wayland-protocols | `protocols/wayland-protocols/unstable/relative-pointer/relative-pointer-unstable-v1.xml` | MIT/Expat (notice in file) | Jonas Ådahl; Red Hat Inc. | <https://gitlab.freedesktop.org/wayland/wayland-protocols> |
| wayland-protocols | `protocols/wayland-protocols/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml` | MIT/Expat (notice in file) | Simon Ser | <https://gitlab.freedesktop.org/wayland/wayland-protocols> |
| wayland-protocols | `protocols/wayland-protocols/unstable/xdg-output/xdg-output-unstable-v1.xml` | MIT/Expat (notice in file) | Red Hat Inc. | <https://gitlab.freedesktop.org/wayland/wayland-protocols> |
| wlroots | `protocols/wlroots/wlr-data-control-unstable-v1.xml` | X11-style license (notice below) | Simon Ser; Ivan Molodetskikh | <https://gitlab.freedesktop.org/wlroots/wlroots> |
| wlroots | `protocols/wlroots/wlr-foreign-toplevel-management-unstable-v1.xml` | X11-style license (notice below) | Ilia Bozhinov | <https://gitlab.freedesktop.org/wlroots/wlroots> |
| wlroots | `protocols/wlroots/wlr-screencopy-unstable-v1.xml` | MIT/Expat (notice in file) | Simon Ser; Andri Yngvason | <https://gitlab.freedesktop.org/wlroots/wlroots> |
| wlroots | `protocols/wlroots/wlr-layer-shell-unstable-v1.xml` | X11-style license (notice below) | Drew DeVault | <https://gitlab.freedesktop.org/wlroots/wlroots> |

The MIT/Expat copyright and permission text for the listed XML files is included in each file. The four X11-style files require their copyright and permission notice in supporting documentation. Their copyright statements and complete shared permission text follow.

### X11-style notices

Applies to:

- `protocols/wayland-protocols/unstable/pointer-gestures/pointer-gestures-unstable-v1.xml` — Copyright © 2015, 2021 Red Hat Inc.
- `protocols/wlroots/wlr-data-control-unstable-v1.xml` — Copyright © 2018 Simon Ser; Copyright © 2019 Ivan Molodetskikh.
- `protocols/wlroots/wlr-foreign-toplevel-management-unstable-v1.xml` — Copyright © 2018 Ilia Bozhinov.
- `protocols/wlroots/wlr-layer-shell-unstable-v1.xml` — Copyright © 2017 Drew DeVault.

```text
Permission to use, copy, modify, distribute, and sell this
software and its documentation for any purpose is hereby granted
without fee, provided that the above copyright notice appear in
all copies and that both that copyright notice and this permission
notice appear in supporting documentation, and that the name of
the copyright holders not be used in advertising or publicity
pertaining to distribution of the software without specific,
written prior permission.  The copyright holders make no
representations about the suitability of this software for any
purpose.  It is provided "as is" without express or implied
warranty.

THE COPYRIGHT HOLDERS DISCLAIM ALL WARRANTIES WITH REGARD TO THIS
SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS, IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR ANY
SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN
AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
THIS SOFTWARE.
```
