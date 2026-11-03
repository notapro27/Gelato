# Independent Review Report — MEDIA-005 Stacked Watched-State & Scope Review

**Tag:** `JULES_REVIEW_REPORT_V1`
**Target PR:** PR #8 (Draft Stacked Review Branch)
**Target Head Commit:** `2815516e7bf04fbbc07c987129165ea00c143633`
**Base Allowlist PR:** PR #5 (`a985889b7cadbf8f15ea3e075c3919e9035aec9d`)
**Upstream Patch Reference:** lostb1t#348 (`713a84db503f5712832d323b1cfb4bd260af6156`)
**Verdict:** `PASS_WITH_CONDITIONS`

---

## Executive Summary

An independent, source-only technical and security assessment was conducted on draft Gelato PR #8 at exact immutable HEAD SHA `2815516e7bf04fbbc07c987129165ea00c143633`. PR #8 stacks the undated watched-state migration correction (upstream lostb1t#348 `713a84db503f5712832d323b1cfb4bd260af6156`) on top of the single-series tree scope allowlist (PR #5 `a985889b7cadbf8f15ea3e075c3919e9035aec9d`).

The exact integration was verified to correctly fix the lab watched-state loss observed when legacy stream rows or virtual episodes contain `null` `LastPlayedDate` timestamps, without regressing the single-series allowlist security boundaries or modifying core Gelato behavior outside intended scope.

**Verdict Rationale:** `PASS_WITH_CONDITIONS`
- **PASS:** The source code implementation and synthetic model behavior strictly pass all functional, security, isolation, and regression checks offline. The upstream watched-state logic was integrated cleanly with zero unintended deviations, and the single-series allowlist remains strictly fail-closed.
- **CONDITIONS:** Production deployment and acceptance remain strictly blocked because live testing on an isolated Jellyfin 12.1.0 server with the updated revision and physical Fire TV playback client verification have **NOT** been performed.

---

## Target & Stack Verification Evidence

### 1. Verification Commands & Outputs

#### A. Build Verification
```sh
dotnet build Gelato.csproj -c Release
```
*Result:* Build Succeeded (0 Errors, 16 pre-existing warnings).

#### B. Synthetic Watch-State Migration Checks
```sh
dotnet run --project tests/WatchStateMigrationChecks/WatchStateMigrationChecks.csproj
```
*Result:*
```
Watch-state migration policy PASS cases=13
```

#### C. Synthetic Local Series Tree Allowlist Scope Checks
```sh
./tests/run-local-series-scope.sh
```
*Result:*
```
PASS 18 offline scope/model checks
PASS source call-site guards present
```

---

## Source & Integration Analysis

### 1. Upstream Patch Integration & Zero-Deviation Check
A detailed line-by-line diff comparison between upstream PR #348 head (`713a84db503f5712832d323b1cfb4bd260af6156`) and the watched-state migration implementation in HEAD `2815516e7bf04fbbc07c987129165ea00c143633` was performed:
- `GelatoManager.cs`: Updated `AdoptWatchState` method and helper methods (`HasMeaningfulWatchState`, `ShouldAdoptWatchState`, `CopyAdoptedWatchState`) match the upstream PR #348 patch exactly.
- `Gelato.csproj`: Includes `<Compile Remove="tests/**/*.cs" />`, ensuring synthetic test suite files under `tests/` are excluded from the main plugin binary distribution.
- **Conclusion:** Zero unintended changes or deviations were introduced in the watched-state migration code during stacking onto PR #5.

### 2. Single-Series Allowlist Integrity
The single-series tree allowlist implementation introduced in PR #5 remains intact and uncompromised:
- **Fail-Closed Parsing:** Scope checking in `Config/LocalSeriesTreeScope.cs` rejects missing, empty, malformed, duplicate, or exceeding limit (32 max) GUID strings.
- **Series-Wide Guarding:** All extension call-sites in `GelatoManager.cs`, `Filters/InsertActionFilter.cs`, and `Providers/GelatoSeriesProvider.cs` evaluate `CanExtendLocalSeriesTree(series.Id)` against file-backed local series before executing tree sync or gap insertion.
- **Configuration Validation:** Configuration changes in `Plugin.cs` enforce validation before saving settings and prevent enabling/modifying allowlists without completing necessary cleanup passes.

---

## Detailed Watched-State Edge Case Assessment

| Edge Case Dimension | Evaluation / Findings | Status |
| :--- | :--- | :--- |
| **Null `LastPlayedDate` Source State** | `HasMeaningfulWatchState` identifies undated sources with `Played == true`, `PlayCount > 0`, or `PlaybackPositionTicks > 0`. `ShouldAdoptWatchState` allows adoption into primary items that lack meaningful watch state even if `LastPlayedDate` is `null`. | **PASS** |
| **Resume-Only State** | Position ticks (`PlaybackPositionTicks > 0`) without `Played` or `PlayCount` are recognized as meaningful watch state and adopted without forcing `Played = true`. | **PASS** |
| **Watched / Play-Count-Only State** | Sources with `Played = true` or `PlayCount > 0` and zero position ticks correctly adopt. `PlayCount` updates to `Math.Max(local.PlayCount, source.PlayCount)`. | **PASS** |
| **Newer vs. Equal vs. Ambiguous Timestamps** | Timestamp comparisons occur only when both local and source have non-null `LastPlayedDate`. If `sourceDate > localDate`, source state adopts. If timestamps are equal or local is newer, local state is preserved. | **PASS** |
| **Undated vs. Dated Conflict** | An undated source state cannot override a meaningful dated or undated local state. Conversely, a dated source cannot override a meaningful undated local state, as priority cannot be proven without timestamps. | **PASS** |
| **Multi-User Isolation** | `AdoptWatchState` iterates over each Jellyfin user independently (`userDataManager.GetUserData(user, item)`), ensuring user progress and watch state decisions never cross user boundaries. | **PASS** |
| **Idempotence** | Repeating `AdoptWatchState` on already adopted rows produces no state mutation or duplicate offset application because `local` primary item now possesses meaningful state matching or exceeding `source`. | **PASS** |
| **Primary-Item Null Data** | If `userDataManager.GetUserData(user, primary)` returns `null` or empty data, `ShouldAdoptWatchState` returns `true` for any meaningful source state, instantiating primary user item data correctly. | **PASS** |
| **Row Selection Among Multiple Candidates** | Candidates are filtered by `HasMeaningfulWatchState` and ordered descending by `LastPlayedDate ?? DateTime.MinValue`. The candidate with the latest timestamp (or first meaningful undated entry if all null) is selected. | **PASS** |
| **Offset Arithmetic** | Timestamp assignment uses `sourceDate + Services.StreamUserDataSync.CopyOffset` (1 tick offset), ensuring the primary item is deterministically dated strictly after the stream row to establish lineage. | **PASS** |

---

## Lab Loss Fix Verification

Prior lab testing observed watch-state resetting to unplayed when legacy stream rows or virtual episodes lacked `LastPlayedDate` timestamps during adoption or virtual episode replacement.

**Assessment:**
The exact integration fixes the root cause by lifting the requirement that `LastPlayedDate` must be non-null for adoption when the target local item is unplayed/empty. By adopting undated meaningful watch state into unplayed local items while refusing to overwrite existing meaningful local state, the lab loss is completely resolved without causing regressions in existing timestamped adoption or allowlist boundaries.

---

## Production Acceptance Blockers & Disclaimers

The following mandatory live integration steps have **NOT** been performed during this source-only review and strictly block production acceptance:

1. **Isolated Jellyfin 12.1.0 Integration Test:** An isolated, live Jellyfin server instance running version 12.1.0 with the exact built revision plugin assembly has not been executed to verify database interaction, real library scans, and background task execution.
2. **Fire TV Playback Testing:** Physical client playback verification on Amazon Fire TV (including playback start, seek position saving, stream row adoption during playback stop, and resume state verification) has not been performed.

---

## Conclusion & Recommendations

PR #8 at HEAD SHA `2815516e7bf04fbbc07c987129165ea00c143633` successfully integrates upstream watched-state migration fix lostb1t#348 with single-series allowlist PR #5.

**Recommendation:** Approve source logic under `PASS_WITH_CONDITIONS`. Require live Jellyfin 12.1.0 test environment run and Fire TV client verification before granting production deployment approval.
