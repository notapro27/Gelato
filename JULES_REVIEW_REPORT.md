# Independent Jules Source Review Report

**Tag:** `JULES_REVIEW_REPORT_V1`
**Target Upstream PR:** lostb1t/Gelato#348
**Target Fork:** notapro27/Gelato
**Target Branch:** `fix/undated-watch-state-migration`
**Exact Immutable HEAD SHA:** `713a84db503f5712832d323b1cfb4bd260af6156`

---

## Executive Summary

An independent technical assessment was conducted on PR #348 at exact immutable HEAD SHA `713a84db503f5712832d323b1cfb4bd260af6156` in repository `notapro27/Gelato`. PR #348 addresses watch state loss occurring during virtual episode replacement or legacy stream row adoption when source watch state items contain `null` `LastPlayedDate` values.

This report replaces prior review attempts and provides an independent, verified assessment of the PR commit diff against its parent (`05f670a5e90320720f21040f306cdd4b17b6cbfc`). The code changes, threat dimensions, synthetic test suite execution, build exclusions, and edge-case behavior were thoroughly evaluated.

**Final Verdict:** `PASS`

---

## Exact File Inventory

Independent inspection of commit `713a84db503f5712832d323b1cfb4bd260af6156` (`git diff-tree --no-commit-id --name-only -r 713a84db503f5712832d323b1cfb4bd260af6156`) confirms that exactly four (4) files were modified or added:

1. `Gelato.csproj` — Added `<Compile Remove="tests/**/*.cs" />` to ensure synthetic test files under the `tests/` directory are excluded from compilation in the primary plugin release assembly (`Gelato.dll`).
2. `GelatoManager.cs` — Added `HasMeaningfulWatchState` helper and updated `ShouldAdoptWatchState`, `CopyAdoptedWatchState`, and `AdoptWatchState` methods to preserve undated watch state during virtual episode replacement and row adoption.
3. `tests/WatchStateMigrationChecks/Program.cs` — New synthetic test suite validating 13 distinct watch state adoption policy scenarios.
4. `tests/WatchStateMigrationChecks/WatchStateMigrationChecks.csproj` — C# project file for building and running the synthetic watch state migration checks against `Gelato.csproj`.

---

## Threat Model & Security/Integrity Assessment

The watch state adoption subsystem is responsible for migrating user watch progress, played status, play count, and last played timestamps from virtual episodes or legacy stream rows onto primary media items.

Key threat dimensions evaluated:
- **T1: Watch State Erasure / Progress Loss:** Undated watch states (`LastPlayedDate == null`) being ignored during replacement, resetting user progress to unplayed.
- **T2: User Data Contamination / Isolation Failure:** Blending watch state across different Jellyfin user accounts during background adoption routines.
- **T3: Stale Overwrite / State Corruption:** An older, empty, or unverified source watch state overwriting newer or meaningful local state on the primary item.
- **T4: Concurrency / Race Conditions:** Simultaneous stream syncs or background row adoption modifying user item data concurrently without locking.
- **T5: Idempotency Violations:** Repeated execution of adoption logic causing growing play counts or corrupted timestamps.

---

## Detailed Technical Assessment & Findings

### 1. Null `LastPlayedDate` & Undated Watch State Handling (`T1`, `T3`)
Prior to PR #348, `AdoptWatchState` evaluated whether to adopt source watch state using:
```csharp
(data.LastPlayedDate ?? DateTime.MinValue) >= (best.LastPlayedDate ?? DateTime.MinValue)
```
If `best.LastPlayedDate` was `null`, it defaulted to `DateTime.MinValue`. When `data` (local) was empty (also `null`), `DateTime.MinValue >= DateTime.MinValue` evaluated to `true`, causing `ShouldAdoptWatchState` to return `false`. Undated watch state was silently dropped on episode replacement.

PR #348 refactors the policy in `GelatoManager.cs`:
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
**Assessment:**
- If source has no meaningful state (`!HasMeaningfulWatchState(source)`), adoption is skipped (`false`).
- If local has no meaningful state (`!HasMeaningfulWatchState(local)`), adoption proceeds (`true`) even when `source.LastPlayedDate` is `null`.
- If BOTH local and source have meaningful state, both timestamps must be non-null and `sourceDate > localDate` must be strictly true. Undated source state cannot overwrite existing meaningful local state.

### 2. Played, PlayCount, and Resume Position Migration (`T1`)
`CopyAdoptedWatchState` merges watch state attributes cleanly:
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
**Assessment:**
- `Played` status uses boolean OR (`source.Played || local.Played`).
- `PlayCount` takes the maximum (`Math.Max(local.PlayCount, source.PlayCount)`).
- `PlaybackPositionTicks` is copied if source represents an active playback or played item, preserving local position when source only contains a play count increment.
- Timestamp offset (`CopyOffset`) is applied when `source.LastPlayedDate` is present to ensure Jellyfin recognizes updated user data.

### 3. User Isolation (`T2`)
`AdoptWatchState` explicitly iterates through all system users via `userManager.GetUsers()`:
```csharp
foreach (var user in userManager.GetUsers())
{
    var best = rows.Select(r => userDataManager.GetUserData(user, r))
        .Where(d => d is not null && HasMeaningfulWatchState(d))
        .OrderByDescending(d => d!.LastPlayedDate ?? DateTime.MinValue)
        .FirstOrDefault();
    ...
    userDataManager.SaveUserData(user, primary, data, ...);
}
```
**Assessment:** Each user's watch state is fetched, evaluated, and saved independently. User data cannot leak across user account boundaries.

### 4. Local / Source Precedence & Timestamp Ordering (`T3`)
- Empty local + meaningful undated source -> Source adopted.
- Meaningful dated local + meaningful undated source -> Local kept (`ShouldAdoptWatchState` returns `false`).
- Meaningful undated local + meaningful dated source -> Local kept (`ShouldAdoptWatchState` returns `false`).
- Both dated: `sourceDate > localDate` required. Equal dates (`sourceDate == localDate`) keep local state.

### 5. Idempotence & Concurrency (`T4`, `T5`)
- **Idempotence:** Re-running adoption on an already adopted item produces identical state. `PlayCount` uses `Math.Max`, `Played` uses OR, and `PlaybackPositionTicks` remains consistent.
- **Concurrency:** `GelatoManager` wraps item replacements and state adoptions in per-item exclusive locks via `RunExclusiveAsync(primary.Id, ...)`, avoiding race conditions during concurrent stream sync operations.

### 6. Release Build Test Project Exclusion
`Gelato.csproj` includes:
```xml
<ItemGroup>
  <Compile Remove="tests/**/*.cs" />
</ItemGroup>
```
**Assessment:** Direct verification via `dotnet build Gelato.csproj` confirms that source files under `tests/` are excluded from compilation when building the primary plugin binary (`Gelato.dll`).

---

## Attributable Test Execution & Provenance

The synthetic test suite provided in PR #348 (`tests/WatchStateMigrationChecks/WatchStateMigrationChecks.csproj`) was compiled and executed in the build environment at SHA `713a84db503f5712832d323b1cfb4bd260af6156`.

### Test Environment
- **SDK:** .NET SDK 10.0.103
- **Target Framework:** `net10.0`
- **OS/Arch:** Linux x86_64 sandbox environment

### Execution Commands
```bash
# 1. Build release project assembly
dotnet build Gelato.csproj

# 2. Run synthetic watch state migration checks
dotnet run --project tests/WatchStateMigrationChecks/WatchStateMigrationChecks.csproj
```

### Raw Test Execution Output
```text
Watch-state migration policy PASS cases=13
```

### Verified Scenarios (13 Cases)
1. `null/null meaningful virtual adopts into empty local` — `PASS`
2. `normal timestamped virtual adopts` — `PASS`
3. `newer local state preserved` — `PASS`
4. `equal timestamp conflict keeps local` — `PASS`
5. `undated resume-only state adopts` — `PASS`
6. `watched flag and play count adopt` — `PASS`
7. `independent users keep separate decisions` — `PASS`
8. `repeated undated adoption is idempotent` — `PASS`
9. `newer watched source intentionally clears older resume` — `PASS`
10. `count-only source does not clear local resume` — `PASS`
11. `dated source cannot override meaningful undated local` — `PASS`
12. `undated source cannot override meaningful dated local` — `PASS`
13. `empty source does not update local` — `PASS`

### CI Run Status
The GitHub workflow configuration for PR builds (`.github/workflows/pr-build.yml`) defines automated dotnet build steps. External CI run URL logs are unverified in this isolated sandbox environment.

---

## Limitations & Residual Risks

1. **Undated Conflict Resolution:** If both local and source items possess meaningful watch state and one or both lack a `LastPlayedDate`, local state takes precedence. If the source item had newer activity in real-world time but lacked a timestamp, local state is retained. This behavior is intentional to prevent unverified overwrites.
2. **Reflection Dependency:** Synthetic tests in `Program.cs` invoke private static methods `ShouldAdoptWatchState` and `CopyAdoptedWatchState` on `GelatoManager` via reflection. Internal method signature refactorings would break test execution if not kept in sync.

---

## Final Verdict

PR #348 at exact immutable SHA `713a84db503f5712832d323b1cfb4bd260af6156` correctly resolves the undated watch state migration issue without introducing user isolation breaches, data corruption risks, or release build packaging defects.

**Final Verdict:** `PASS`
