# App icon

`AppIcon.svg` is the source art. `AppIcon.icns` is generated from it and is what
`install.sh` copies into `Desk Launch.app/Contents/Resources/`.

`install.sh` uses the prebuilt `.icns` so installing never depends on an SVG
renderer. Regenerate it after editing the SVG:

```sh
# needs librsvg: brew install librsvg
cd "$(git rev-parse --show-toplevel)"
work="$(mktemp -d)"; set="$work/AppIcon.iconset"; mkdir -p "$set"
r() { rsvg-convert -w "$1" -h "$1" Resources/AppIcon.svg -o "$2"; }
r 16   "$set/icon_16x16.png"
r 32   "$set/icon_16x16@2x.png"
r 32   "$set/icon_32x32.png"
r 64   "$set/icon_32x32@2x.png"
r 128  "$set/icon_128x128.png"
r 256  "$set/icon_128x128@2x.png"
r 256  "$set/icon_256x256.png"
r 512  "$set/icon_256x256@2x.png"
r 512  "$set/icon_512x512.png"
r 1024 "$set/icon_512x512@2x.png"
iconutil -c icns "$set" -o Resources/AppIcon.icns
```

Then re-run `./install.sh` and reopen the app.

## Sizing

The art keeps the macOS proportion: the rounded tile is 824 px inside the
1024 px canvas, i.e. 100 px of transparent padding on each side. Without that
padding the icon renders noticeably larger than its neighbours in the Dock.
