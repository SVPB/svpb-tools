# TNG's built-in artwork

The neutral images TNG serves when an organisation has uploaded none of its own on the
**Organisation** admin page (#89): a pair of beamed notes in the header's colours
(`#1a1a2e`, white). They live here, outside `Public/`, so that `FileMiddleware` never
answers for `/favicon.ico` and the rest before the artwork routes do.

| File | Served at | What it is |
|---|---|---|
| `logo.svg` | `/img/logo` | The notes alone, white, for the dark header. |
| `favicon.svg` | `/favicon.svg` | The notes on a rounded `#1a1a2e` square. The master for the two below. |
| `favicon.ico` | `/favicon.ico` | 16, 32 and 48 px, rendered from `favicon.svg`. |
| `apple-touch-icon.png` | `/apple-touch-icon.png` | 180×180, rendered from `favicon.svg` with square corners: iOS rounds them itself. |

To render the raster files again after changing `favicon.svg`:

```
sed 's/ rx="12"//' favicon.svg > /tmp/touch.svg
rsvg-convert -w 180 -h 180 /tmp/touch.svg -o apple-touch-icon.png
for n in 16 32 48; do rsvg-convert -w $n -h $n favicon.svg -o /tmp/fav$n.png; done
magick /tmp/fav16.png /tmp/fav32.png /tmp/fav48.png favicon.ico
```

An organisation's own artwork is not kept here. SVPB's is in `Brand/`.
