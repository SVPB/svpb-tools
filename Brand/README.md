# Brand assets

The band's icon is the **circuit thistle** — the mark that sits to the left of the
wordmark in the SVPB logo. These files are vector traces of it, taken from
artboard 5 of `SV_Pipeband_Logo_Final.ai` (the standalone, full-detail drawing),
recoloured to match the way the thistle is coloured in the logo lockup.

The `.ai` lives in Box under
`Silicon Valley Pipe Band / Band Documents / Logo / SVPB Logo /`.

## Colours

| Part | Hex | Where |
|---|---|---|
| Bloom (upper spikes) | `#AA04BC` | purple |
| Leaves (lower traces) | `#44C40E` | green |
| Wordmark | `#0008BF` | blue — not used by these files |

The `.ai` is an sRGB document, so these are sRGB values. They are *not* the
values that `colors.txt` in the Box folder used to list; that file has been
corrected.

## Files

| File | What it is |
|---|---|
| `svpb-thistle.svg` | Master. Tall crop, transparent background, stroke weights exactly as drawn. |
| `svpb-thistle-white.svg` | Same, on a white background. |
| `svpb-thistle-square-white.svg` | Square crop, white background — for anywhere that wants a square logo. |
| `slack-app-icon-512.png` | 512×512 on white. Upload this as the TNG Slack app icon. |

Web assets derived from the same drawing live in `web/`:
`favicon.ico` (16/32/48), `favicon.svg`, `apple-touch-icon.png`, and
`thistle.svg` for the page header. TNG no longer serves them itself (#89): they are
SVPB's, not TNG's, and a server shows whatever its admins upload.

## Putting them on a server

Sign in as an admin and open **Admin → Organisation** (`/admin/org`). Upload:

| Slot | File |
|---|---|
| Header logo | `web/thistle.svg` |
| Favicon | `web/favicon.svg` (or `web/favicon.ico`) |
| Touch icon | `web/apple-touch-icon.png` |

and set the short name to `SVPB` and the full name to `Silicon Valley Pipe Band`, or put
`ORG_SHORT_NAME` and `ORG_NAME` in the server's `.env`.

## Optical sizing

The thistle is fine line art — strokes are about 1% of its height. Below roughly
40px it stops resolving. The small renderings (`web/favicon.*` and
`web/thistle.svg`) therefore use stroke weights scaled up 1.8×; the master
and the large PNGs use the true weights. If you regenerate anything, keep that
split, and keep butt caps and miter joins so the traces stay square-ended like
the original.
