# README screenshots

These PNGs are actual native Cue windows captured with synthetic data. No user database, browser session, provider account, calendar, model download, or real meeting is used. The summary text is a hand-authored fixture illustrating the summary renderer, not an accuracy benchmark or a live AI result.

To reproduce on macOS with screen-capture permission:

```sh
CUE_README_SCREENSHOTS=1 \
CALL_ASSISTANT_DESIGN_SNAPSHOTS=/tmp/cue-readme-screenshots \
swift test --package-path native --filter DesignTests/testReadmeScreenshotsWhenRequested
```

Copy the three `readme-*.png` outputs into this directory as `library.png`, `summary.png`, and `settings.png`. Inspect every image before committing. Only the isolated fixture windows are captured, not the desktop. Other documentation/layout test snapshots remain bitmap-based and require no screen-capture permission.
