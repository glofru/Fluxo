# CI

`.github/workflows/ci.yml` runs on every push to `main`, every pull request, and by hand (Run workflow). Its jobs
call the same scripts as a local check, so a failure reproduces with one command:

| Job | Runs | Locally |
|---|---|---|
| Build `ios`, `iossim`, `mac`, `tvos`, `tvsim` | The `Fluxo` scheme for each platform, unsigned (`CODE_SIGNING_ALLOWED=NO`): Release for the devices and the Mac, Debug for the simulators. Fails on any compiler warning | `Tools/CI/build.sh <gate>` |
| Unit tests (`ios`, `mac`) | `FluxoTests` through `Fluxo.xctestplan`, on a cloned iPhone simulator and on the Mac ([Testing](testing.md)) | `Tools/CI/test.sh [ios\|mac]` |
| Tools checks | Every check under `Tools/` with CI-sized inputs, `ffmpeg` installed from Homebrew for the test streams, the full git history for the checks that compile older commits | `Tools/CI/checks.sh` |

Each job uploads its logs (and the tests their `.xcresult`) as artifacts. Nothing is signed, uploaded or deployed:
the workflow only reads the repository (`permissions: contents: read`), and every server a check starts listens on
127.0.0.1.

## Xcode 27.2 on GitHub-hosted runners

Fluxo needs **Xcode 27.2** (iOS 27 deployment target, SDKs 27.2). GitHub's general macOS images do not have it:
`macos-26` / `macos-latest` carry Xcode 26. Xcode 27 is only on the **`xcode-27` image**, which GitHub marks as a
preview (`runs-on: xcode-27`; see [actions/runner-images](https://github.com/actions/runner-images)). As of November
2026 that image runs macOS 27.0.1 and has Xcode 27.0, 27.1 (its default) and **27.2 Release Candidate (27B48)**, linked
as `/Applications/Xcode_27.2.app`, with iOS 27.0 / 27.1 and tvOS 27.0 simulator runtimes (no 27.2 runtime yet). So on
GitHub's runners:

- `Tools/CI/select-xcode.sh 27.2` picks `Xcode_27.2.app` (any Xcode whose version is 27.2 or 27.2.x), and fails with
  the list of installed Xcodes when there is none, rather than building with another version.
- The build is the RC's (27B48), not the release Xcode the project is developed with (27B52). The two should not
  differ for this project; when GitHub replaces the RC with the release, nothing changes in the workflow.
- The unit tests run on the newest iOS runtime of the image (27.1); the app's deployment target is 27.0, so that is a
  supported system.
- Preview images can change or go away. If the `xcode-27` label stops working, use a self-hosted runner (below) until
  a general image has Xcode 27.2.

## A self-hosted Mac

Any Mac with Xcode 27.2 can run the whole workflow:

1. A Mac on macOS 27 (Apple silicon), with Xcode 27.2 in `/Applications` (as `Xcode.app` or `Xcode_27.2.app`;
   `FLUXO_XCODE_PATH` in the runner's environment names another place), its license accepted
   (`sudo xcodebuild -license accept`), the first-launch components installed (`xcodebuild -runFirstLaunch`) and the
   iOS and tvOS simulator runtimes (`xcodebuild -downloadPlatform iOS`, `-downloadPlatform tvOS`).
2. Homebrew's `ffmpeg` (`brew install ffmpeg`), or let the workflow install it, and `python3` (Xcode's is enough).
3. Add the runner: repository Settings › Actions › Runners › New self-hosted runner, macOS, and follow the steps
   (`./config.sh --url https://github.com/<owner>/Fluxo --token <token> --labels xcode-27.2`, then `./svc.sh install`
   and `./svc.sh start` to run it as a service). Give it a user account of its own, not an administrator.
4. Point the workflow at it: Settings › Secrets and variables › Actions › Variables › New repository variable
   **`FLUXO_RUNS_ON`** = `["self-hosted", "macOS", "xcode-27.2"]` (JSON: the labels a runner must have). Without the
   variable the jobs use GitHub's `xcode-27` image.

Notes for a self-hosted runner:

- The jobs of a run then queue on it one at a time (one runner runs one job), which also keeps the Mac from
  running several `xcodebuild`s at once. The whole workflow takes about as long as the sum of its jobs.
- `select-xcode.sh` switches the active Xcode only with a password-less `sudo xcode-select`; otherwise it exports
  `DEVELOPER_DIR` for the job, so the Mac's own setting is left alone.
- `test.sh` clones a simulator for its run and deletes the clone at the end; it never boots or changes the Mac's own
  simulators. The derived data of each job goes to the runner's temporary folder.
- A pull request from a fork runs the repository's code on this Mac. Keep "Require approval for all outside
  collaborators" on (Settings › Actions › General › Fork pull request workflows), or use a self-hosted runner only
  for a private repository, as GitHub recommends.

## Not in CI

- **Signing and archives**: the builds are unsigned. Archives, the privacy report and App Store uploads are the
  release checklist's (`docs/AppStore/README.md`).
- **The simulator harness and its XCUITest bundles** (`Tools/Simulator`): they need booted clones, an iPad or an
  Apple TV simulator and the test streams, and some take long; run them by hand ([Testing](testing.md)).
- **The longer engine scripts** of `Tools/EngineSmokeTest` (formats, seeking, leaks): only its live smoke test runs.
- **Real devices**: Siri, Picture in Picture, energy, Chromecast and the hardware decoders need devices.
