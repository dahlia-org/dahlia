# Release Troubleshooting

Use this reference when Dahlia signing, notarization, or publication fails or stalls. Commands assume the repository root. This is recovery guidance, not permission to skip release gates.

The maintained notarization entrypoint is `.agents/skills/release-dahlia-app/scripts/notarize.sh`. The former `./scripts/notarize.sh` moved into this skill in PR #346. The default Keychain profile is `dahlia-notary`; `NOTARY_PROFILE` in the environment or `.env.local` can override it. Use the same profile throughout recovery.

## Locate the stalled stage

| Last output or observation | What to check next |
| --- | --- |
| `Conducting pre-submission checks...` with no submission ID | Local archive recognition, DMG attachment/locks, Keychain prompts, and initial Apple API communication. This message alone does not identify the cause. |
| `[PREFLIGHT] ... did not pass the disk image potentiality test. Moving on to other tests.` | Inspect the DMG locally. This is a format-detection diagnostic, not proof of corruption or an Apple rejection. |
| Submission ID received, upload not completed | Upload connectivity, VPN/proxy/firewall, and S3 transfer path. |
| Upload completed, status `In Progress` | Apple processing. Query or wait on the existing submission ID rather than submitting again. |
| `Accepted`, but stapling or publishing failed | Resume the remaining ticket, signature, asset, and publication checks. Do not rebuild an already-notarized artifact. |

Do not infer that bundled JavaScript causes a preflight stall. On 2026-10-05, Dahlia's JS assets were unchanged from the previous release; a retained local disk-image attachment was found and detaching it resolved the stall. This is an observed recovery, not a universal explanation for that log message.

## DMG unavailable during preflight

First inspect attachments and file users without stopping unrelated processes:

```bash
hdiutil info
lsof -n "$PWD/Dahlia.dmg"
hdiutil imageinfo Dahlia.dmg
```

Match the exact `image-path` for this repository's `Dahlia.dmg`. A retained `diskimages-helper`, an attached device, and `hdiutil verify` reporting `Resource temporarily unavailable` indicate local image contention. A DMG can still be recognized as UDZO by `imageinfo` while being unavailable to other checks.

Stop only the current submission with Ctrl+C in its terminal before attempting recovery. If this exact DMG remains attached, detach its current whole-image device using the normal command below. Replace `/dev/diskN` with the device from the matching `hdiutil info` entry; device numbers change and must not be copied from a prior run.

```bash
hdiutil detach /dev/diskN
hdiutil verify Dahlia.dmg
codesign --verify --verbose=2 Dahlia.dmg
```

Do not detach other images, kill all disk-image helpers, or default to forced detachment. If normal detachment fails, inspect its error and current file users before proceeding. Do not retry submission until the image verification and signature checks succeed.

## Submission or upload connectivity

Check for a pending Keychain access dialog. Confirm credential access without exposing credentials:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun notarytool history --keychain-profile dahlia-notary
```

Successful history access does not prove that submission or S3 upload connectivity works. For HTTP 403 with an updated Apple agreement, have the Account Holder accept the agreement and confirm access after propagation; do not rotate working credentials as the first response.

After stopping the old submission and checking history for an existing submission, use verbose output to locate the failure:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun notarytool submit Dahlia.dmg \
    --keychain-profile dahlia-notary --wait --verbose
```

For an upload connectivity issue, retry with `--no-s3-acceleration` added to that command, or test another network / without VPN where permitted. This option changes the upload route, not local DMG preflight. Do not use `--force` to bypass a failed preflight check. Inspect verbose logs locally and redact credentials or authentication data before sharing them.

If a submission ID already exists, inspect and wait on that ID instead of uploading again. Replace the quoted placeholder with the actual ID:

```bash
xcrun notarytool info 'SUBMISSION_ID' --keychain-profile dahlia-notary
xcrun notarytool wait 'SUBMISSION_ID' --keychain-profile dahlia-notary
```

For a completed rejection, obtain its diagnostic log:

```bash
xcrun notarytool log 'SUBMISSION_ID' --keychain-profile dahlia-notary \
  .build/notarization-log.json
```

## Resume validation and publication

If the signed DMG already exists and passes local validation, a manual `notarytool submit` avoids rebuilding it. A temporary recovery script is session-specific and is not a maintained entrypoint. If source or version changes, rebuild through the maintained notarization script instead.

After the submission reports `Accepted`, complete these checks on the same artifact. Stop on any failure; the chained commands below do not continue after a failed check:

```bash
xcrun stapler staple Dahlia.dmg && \
xcrun stapler validate Dahlia.dmg && \
hdiutil verify Dahlia.dmg && \
codesign --verify --verbose=2 Dahlia.dmg && \
spctl -a -vvv -t open --context context:primary-signature Dahlia.dmg
```

If Sentry is configured, also perform the dSYM upload from `notarize.sh` using the same `.env.local` configuration and the matching release build:

```bash
./scripts/upload-dsyms.sh .build/release Dahlia
```

Retain the skill's clean-tree, committed/pushed version, reviewed bilingual notes, and publication authorization requirements. Then use the publishing script, which validates the DMG versions, tickets, signatures, Sparkle configuration, and localized assets before creating the release:

```bash
.agents/skills/release-dahlia-app/scripts/create-github-release.sh \
  --notes-file-ja .build/release-notes/release-note-ja.md \
  --notes-file-en .build/release-notes/release-note-en.md
```

If publication fails, inspect whether the target GitHub Release was already created before retrying; do not replace an existing release or its assets blindly. Before reporting completion, verify the public tag points to the intended commit, the four published assets, the latest appcast, and downloaded artifact signatures/versions against the validated local artifact.

## Apple references

- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow): submission, tickets, and upload configuration.
- [Apple DTS discussion of S3 upload connectivity](https://developer.apple.com/forums/thread/760421): upload timeouts, alternate networks, and VPN checks.
- Local `man notarytool` and `xcrun notarytool submit --help`: options supported by the installed tool.
