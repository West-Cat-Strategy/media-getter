# Media Getter

Native macOS app for downloading, converting, trimming, and transcribing media with bundled command-line tooling.

## Vendored Assets

Most vendored tools are tracked in Git, but `Vendor/Models/ggml-base.en.bin` is intentionally left out because it exceeds GitHub's file size limit.

If that model file is missing locally, run:

```bash
script/vendor_media_tools.sh
```

The Xcode build already reports the same command when a required vendored tool or model asset is missing.
