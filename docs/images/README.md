# README previews

The images in this folder are **rendered UI previews** of AgentBar's popover — not
photos of a running app. They reproduce the app's live-feed design (the exact palette,
layout, and components from `app/Sources/AgentBar/Views/`) so the README can show what
AgentBar looks like without a signed macOS build.

## Regenerate

Requires Node and a Chromium build. From the repo root:

```sh
node docs/images/generate.js docs/images            # writes dashboard/permission/activity .html
# then render each with headless Chromium at 2x, e.g.:
chromium --headless=new --hide-scrollbars \
  --force-device-scale-factor=2 --default-background-color=00000000 \
  --window-size=420,1100 --screenshot=docs/images/dashboard.png \
  file://$PWD/docs/images/dashboard.html
```

Render onto a transparent background (`--default-background-color=00000000`) with a window
tall enough to fit the content, then crop the transparent margins to the popover's bounding
box — e.g. with Pillow:

```python
from PIL import Image
im = Image.open("docs/images/dashboard.png").convert("RGBA")
im.crop(im.getchannel("A").getbbox()).save("docs/images/dashboard.png")
```

The previews are kept in sync with the live UI in `app/Sources/AgentBar/Views/` — the source
pills (CLAUDE / COPILOT), the model · mode · context meta line, and the keyboard-nav hint all
mirror `QueueView`/`FeedComponents`. Swap these for real screenshots of the built app whenever
a signed build is available.
