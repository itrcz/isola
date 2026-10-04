# Contributing

Build on an Apple Silicon Mac with Xcode command line tools and Go 1.27.1 or newer:

```sh
bash scripts/build.sh
bash scripts/test.sh
```

Changes to guest integration should include the relevant smoke test in `Tests/`.
Keep host and guest protocol compatibility in mind: older Tools must report unsupported
features rather than silently applying incomplete settings.

Use `bash scripts/preview_ui.sh --light` or `--dark --compact --ru` to inspect UI
changes in a separate app with a temporary VM configuration. It does not start a VM.

For disk changes, run `bash scripts/test.sh --disk` on an APFS host volume. This
creates and mounts temporary test images; it must never operate on a user's VM.
For window changes, run `bash scripts/test.sh --ui` in a logged-in macOS desktop session.

Keep VM disks, restore images, credentials and personal screenshots out of commits.
Please describe the user-visible change and the checks you ran in pull requests.

## Packaging a release

Update the version and build number in `scripts/Info.plist`, add notes in
`docs/releases/`, then run:

```sh
bash scripts/test.sh
bash scripts/release.sh
```

The ZIP and SHA-256 checksum are written to `dist/release/`. The packaging script
uses a fresh staging directory, includes dependency notices and verifies the
signature again after extracting the ZIP. It does not upload or publish anything.
GitHub Actions also builds downloadable artifacts for pushes and pull requests.
