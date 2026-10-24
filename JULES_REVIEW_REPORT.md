# Independent Jules Source Review Report

**Tag:** `JULES_REVIEW_REPORT_V1`
**Target Upstream PR:** lostb1t/Gelato#348
**Target Fork:** notapro27/Gelato
**Target Branch:** `fix/undated-watch-state-migration`
**Exact Immutable SHA:** `713a84db503f5712832d323b1cfb4bd260af6156`

---

## Executive Summary

An independent source-only technical review was conducted on upstream Gelato PR #348 (commit SHA `713a84db503f5712832d323b1cfb4bd260af6156`). The PR addresses watch state loss when virtual episodes or legacy stream rows are replaced or adopted, specifically when watch state records contain `null` `LastPlayedDate` values.

All modified files and relevant watch state migration logic were reviewed against threat modeling dimensions including data loss, user isolation, state precedence, timestamp ordering, idempotency, concurrency, and regression risks. Synthetic test suites were executed to verify adoption rules across 13 distinct edge-case scenarios.

**Final Verdict:** `PASS`

---

## Scope & Changed Files

The review evaluated all files modified or added in commit `713a84db503f5712832d323b1cfb4bd260af6156`:

1. `GelatoManager.cs` — Updated `ShouldAdoptWatchState`, `CopyAdoptedWatchState`, and `AdoptWatchState` helper methods to handle undated watch state adoption.
2. `ScheduledTasks/RepairWatchStateTask.cs` — Updated stream row filtering (`!item.IsStream()`).
3. `Services/LegacyRowAdoptionService.cs` — Updated stream row identification (`v.HasStreamTag()`).
4. `tests/WatchStateMigrationChecks/Program.cs` — New synthetic unit test suite validating 13 watch state adoption scenarios.
5. `tests/WatchStateMigrationChecks/WatchStateMigrationChecks.csproj` — Project file for watch state migration synthetic checks.

---

## Threat Model & Risk Analysis

The watch state migration subsystem handles moving user playback progress, played status, play counts, and last played timestamps from virtual episodes / legacy stream rows onto primary media items during adoption or replacement.

Key threats evaluated:
- **T1: Watch State Erasure / Progress Loss:** Failure to adopt undated watch state (where `LastPlayedDate` is `null`) leading to wiped user progress on episode replacement.
- **T2: User Data Leakage / Isolation Failure:** Blending or cross-contaminating watch state between distinct Jellyfin user accounts during background adoption.
- **T3: Stale Overwrite / Local State Corruption:** An older or empty source watch state overwriting newer or meaningful local state on the primary item.
- **T4: Concurrency / Race Conditions:** Simultaneous stream syncs or background row adoption tasks modifying user data concurrently without locking.
- **T5: Idempotency Violations:** Repeated execution of adoption logic causing growing play counts or corrupted timestamps.

---

## Detailed Findings

### 1. Null `LastPlayedDate` & Undated State Handling (`T1`)
Prior to PR #348, `ShouldAdoptWatchState` required `local.LastPlayedDate` and `source.LastPlayedDate` to both be non-null and evaluated `sourceDate > localDate`. When virtual episodes or stream rows lacked a timestamp (`LastPlayedDate == null`), adoption was silently skipped, resulting in lost watch state when items were replaced.

PR #348 updates `ShouldAdoptWatchState`:
```csharp
private static bool HasMeaningfulWatchState(UserItemData data) =>
    data.Played || data.PlayCount > 0 || data.PlaybackPositionTicks > 0;

private static bool ShouldAdoptWatchState(UserItemData local, UserItemData source)
{
    if (!HasMeaningfulWatchState(source))
        return false;
    if (!HasMeaningfulWatchState(local))
        return true;

    return local.LastPlayedDate is { } localDate
        && source.LastPlayedDate is { } sourceDate
        && sourceDate > localDate;
}
```
If `local` has no meaningful watch state and `source` does, adoption returns `true` even when `source.LastPlayedDate` is `null`. Undated watch state is preserved upon virtual episode replacement.

### 2. Virtual-to-Local Played, PlayCount, and Resume Preservation (`T1`, `T3`)
`CopyAdoptedWatchState` merges attributes cleanly:
```csharp
private static void CopyAdoptedWatchState(UserItemData local, UserItemData source)
{
    if (source.Played || source.PlaybackPositionTicks > 0)
        local.PlaybackPositionTicks = source.PlaybackPositionTicks;
    local.Played = source.Played || local.Played;
    local.PlayCount = Math.Max(local.PlayCount, source.PlayCount);
    if (source.LastPlayedDate is { } sourceDate)
        local.LastPlayedDate = sourceDate + Services.StreamUserDataSync.CopyOffset;
}
```
- `Played` flag is OR-merged (`source.Played || local.Played`).
- `PlayCount` takes the maximum (`Math.Max(local.PlayCount, source.PlayCount)`).
- Resume ticks (`PlaybackPositionTicks`) are copied if the source represents an active playback or played state, while count-only sources preserve local resume position.

### 3. User Isolation (`T2`)
`AdoptWatchState` iterates explicitly through `userManager.GetUsers()` and evaluates/saves user item data per individual user account:
```csharp
foreach (var user in userManager.GetUsers())
{
    var best = rows.Select(r => userDataManager.GetUserData(user, r)) ...
    ...
    userDataManager.SaveUserData(user, primary, data, ...);
}
```
Each user's watch state is queried and updated independently. No user data leaks between accounts.

### 4. Meaningful Local State Precedence & Timestamp Comparison (`T3`)
- When `local` already possesses meaningful watch state (`HasMeaningfulWatchState(local) == true`), an undated source state (`source.LastPlayedDate == null`) cannot override local state (`ShouldAdoptWatchState` returns `false`).
- For two dated states, `sourceDate > localDate` is strictly enforced. In case of equal timestamps (`sourceDate == localDate`), the local state is retained.

### 5. Idempotence & Concurrency (`T4`, `T5`)
- **Idempotence:** Re-running adoption on already adopted items produces identical results without compounding play counts or modifying position ticks.
- **Concurrency:** `GelatoManager` manages stream row operations using per-item key locks via `RunExclusiveAsync(primary.Id, ...)` utilizing `_itemWrites`. Concurrent syncs, removals, or adoptions on the same item ID are serialized.

### 6. Codebase Regressions & Method Refactorings
- `ScheduledTasks/RepairWatchStateTask.cs` and `Services/LegacyRowAdoptionService.cs` were updated to use standard stream classifiers (`!item.IsStream()` and `v.HasStreamTag()`).
- Unrelated series enrichment methods in `GelatoManager.cs` (`EnrichMetaAsync`) were streamlined without impacting watch state migration.

---

## Test Results & Execution Provenance

The synthetic unit test project `tests/WatchStateMigrationChecks/WatchStateMigrationChecks.csproj` included in PR #348 was executed in the build environment.

### Execution Command
```bash
dotnet run --project tests/WatchStateMigrationChecks/WatchStateMigrationChecks.csproj
```

### Raw Test Output
```text
Watch-state migration policy PASS cases=13
```

### Evaluated Test Cases (13 Total)
1. Null/null meaningful virtual adopts into empty local — `PASS`
2. Normal timestamped virtual adopts — `PASS`
3. Newer local state preserved — `PASS`
4. Equal timestamp conflict keeps local — `PASS`
5. Undated resume-only state adopts — `PASS`
6. Watched flag and play count adopt — `PASS`
7. Independent users keep separate decisions — `PASS`
8. Repeated undated adoption is idempotent — `PASS`
9. Newer watched source intentionally clears older resume — `PASS`
10. Count-only source does not clear local resume — `PASS`
11. Dated source cannot override meaningful undated local — `PASS`
12. Undated source cannot override meaningful dated local — `PASS`
13. Empty source does not update local — `PASS`

---

## Scope Limitations & Residual Risks

1. **Source & Synthetic Scope:** Review was limited to static source code inspection and synthetic test execution. Production database migrations or live Jellyfin server integration tests were not run.
2. **Undated Conflict Resolution:** If both local and source items have undated watch states and both contain meaningful progress, local state takes precedence. If the source item had newer progress in real-world time but lacked a timestamp, local state will be kept. This is intentional to prevent unverified undated overwrites.

---

## Final Assessment

PR #348 correctly solves the undated watch state loss issue during virtual episode replacement and legacy stream row adoption without introducing user state leakage, race conditions, or state corruption regressions.

**Final Verdict:** `PASS`
