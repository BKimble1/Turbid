# Continuous integration

Two workflows, both **manual only**. Nothing runs on a push or a pull request:
every run costs macOS runner minutes, and each interface test drives a real
12.5-second analysis of synthetic frames on a Simulator that is slow at it.

| Workflow | File | What it does |
|---|---|---|
| `iOS CI` | `.github/workflows/ios-ci.yml` | Static checks, project generation, compile, tests |
| `TestFlight Upload` | `.github/workflows/testflight.yml` | Release archive, sign, upload to App Store Connect |

Both run on `macos-latest` — a standard GitHub-hosted runner, never a `-large`
or `-xlarge` image, which bill at a multiple and buy nothing here.

## Choosing a level

Pick the smallest level that covers what actually changed. Running more than
that is not caution, it is spending someone's minutes to re-prove something
that was already proved.

| Level | Runs | Use it when |
|---|---|---|
| `build-only` | `Tools/check.sh`, then a Simulator compile | Comments, documentation, a rename, anything that cannot change behaviour but could still fail to compile |
| `unit` | The above, then the whole `TurbidTests` target | **The default.** Any change under `Turbid/Domain`, `Turbid/Analysis`, `Turbid/Camera` or `Turbid/Services` |
| `targeted-ui` | The above build, then only the tests you name | A change to a screen, a navigation path or an accessibility identifier. Leave `tests` empty for the four-test smoke set |
| `full` | Everything, including all nine interface tests | Before a release you intend to promote, or when a change touches the measurement flow end to end |

`full` costs roughly five complete analysis runs. It is not the safe default;
it is the expensive one.

### The default smoke set

`targeted-ui` with an empty `tests` input runs exactly four tests — the
smallest set that proves the app launches, gates on the disclosure, navigates,
and produces a result from the simulated camera path:

    TurbidUITests/PermissionAndOnboardingUITests/testFirstLaunchShowsTheDisclosureBeforeAnythingElse
    TurbidUITests/PermissionAndOnboardingUITests/testDeniedCameraAccessExplainsItselfAndOffersSettings
    TurbidUITests/MeasurementFlowUITests/testSetupOffersTheChecklistAndTheLiveViewBeforeCommitting
    TurbidUITests/MeasurementFlowUITests/testScreeningResultReportsClarityWithoutAnNTUValue

Only the last one runs a full measurement. The other three are seconds each.

`-only-testing:` accepts a target, a `Target/Class`, or a
`Target/Class/testMethod`, so one dispatch can mix a whole target with
individual tests:

    TurbidTests,TurbidUITests/MeasurementFlowUITests/testScreeningResultReportsClarityWithoutAnNTUValue

## Running them

The workflows dispatch from the repository's **default branch**. There is no
`main` in this repository: the default branch is `claude/attached-prompt-ce0ef9`.
Substitute whatever the default branch is called when you read this — if it is
renamed to `main`, these commands are unchanged apart from the `--ref`.

    # iOS CI, cheapest useful level
    gh workflow run "iOS CI" --ref claude/attached-prompt-ce0ef9 -f level=unit

    # iOS CI, the four-test smoke set
    gh workflow run "iOS CI" --ref claude/attached-prompt-ce0ef9 -f level=targeted-ui

    # iOS CI, specific tests
    gh workflow run "iOS CI" --ref claude/attached-prompt-ce0ef9 \
      -f level=targeted-ui \
      -f tests="TurbidUITests/CalibrationUITests/testAMatchingCalibrationProducesAnNTUEstimateWithAnUncertainty"

    # Watch the run that just started
    gh run list --workflow "iOS CI" --limit 1
    gh run watch "$(gh run list --workflow 'iOS CI' --limit 1 --json databaseId --jq '.[0].databaseId')"

    # On failure, read the failing step and fetch the result bundle
    gh run view --log-failed
    gh run download "$(gh run list --workflow 'iOS CI' --limit 1 --json databaseId --jq '.[0].databaseId')"

TestFlight takes a confirmation string so a stray click cannot ship a build:

    gh workflow run "TestFlight Upload" --ref claude/attached-prompt-ce0ef9 -f confirm=UPLOAD
    gh run watch "$(gh run list --workflow 'TestFlight Upload' --limit 1 --json databaseId --jq '.[0].databaseId')"

None of these commands take a credential. All four App Store Connect secrets
are read inside the workflow from GitHub Actions secrets and never appear in
an input, an argument or a log.

## TestFlight

`TestFlight Upload` normally runs from the default branch — the branch whose
CI is green and whose contents you are willing to put in front of a tester. It
does **not** rerun the test suite: `iOS CI` is the gate, and repeating it here
would double the runner minutes to re-prove what already passed.

What it does, in order:

1. Regenerates and validates the project, and fails if the project does not
   declare `com.idlery.turbid` or has lost `ITSAppUsesNonExemptEncryption`.
2. Writes the `.p8` key under `$RUNNER_TEMP` with `umask 077`.
3. Asks App Store Connect for every build number that already exists — across
   every version, and including builds uploaded by Codemagic or from a laptop —
   and takes the largest plus one. It does not assume a run number is free.
4. Archives Release for `generic/platform=iOS` with Apple automatic signing and
   cloud-managed certificates (`-allowProvisioningUpdates` plus the three
   authentication flags).
5. Reads the archive's own `Info.plist` back and fails unless the bundle
   identifier, build number and marketing version are exactly what was asked
   for.
6. Exports with `method: app-store-connect` and `destination: upload`, so
   `xcodebuild` delivers the build itself. `manageAppVersionAndBuildNumber` is
   `false` — it defaults to `true`, and Xcode would otherwise renumber the
   build chosen in step 3.
7. Polls App Store Connect until the build is visible.
8. Deletes the key and the fetched provisioning profiles, whatever happened.

The build number comes from App Store Connect, so the marketing version in the
project (`MARKETING_VERSION`) is the only version anyone has to maintain by
hand. Bump it there when the release warrants it.

## For future changes

Match the level to the blast radius of the change:

- Touched only `Tools/`, `docs/` or a comment → `build-only`, or nothing at all
  if `sh Tools/check.sh` passes locally and no Swift changed.
- Touched Swift under `Turbid/Domain`, `Turbid/Analysis` or `Turbid/Camera` →
  `unit`.
- Touched a view, a navigation route or an accessibility identifier →
  `targeted-ui`, naming the affected tests rather than taking the whole set.
- About to upload a build people will install → `unit`, then `targeted-ui`,
  then `TestFlight Upload`.

Do not reach for `full` to feel thorough. Reach for it when a change genuinely
spans the whole measurement flow, and say why in the commit message.
