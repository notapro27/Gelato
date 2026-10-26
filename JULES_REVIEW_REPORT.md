# Independent Review Report — PR #5 Single-Series Allowlist

## Target & Comparison Base
* **Target PR:** PR #5 (`fix/allowlisted-local-series-trees`)
* **Target Head Commit:** `a985889b7cadbf8f15ea3e075c3919e9035aec9d`
* **Comparison Base Commit:** `c9d2d466602f4a1398c0fa0a71fa1106928eac56` (Gelato v0.26.29.0)
* **Verdict:** `PASS_WITH_CONDITIONS`

---

## Changed Files Diff Summary
The complete ten-file diff in PR #5 consists of:
1. `Config/LocalSeriesTreeScope.cs` (New fail-closed scope parser and evaluator)
2. `Config/PluginConfiguration.cs` (Added `LocalSeriesTreeAllowlist` property and `CanExtendLocalSeriesTree` helper)
3. `Config/config.html` (Added UI field `txtLocalSeriesTreeAllowlist` for allowed series GUIDs)
4. `Config/gelato-settings.js` (Added UI binding and trim handling for `LocalSeriesTreeAllowlist`)
5. `Filters/InsertActionFilter.cs` (Scoped local series insertion/extension to allowlisted series)
6. `GelatoManager.cs` (Guarded direct tree sync, continuing series sync, and background local series passes)
7. `Plugin.cs` (Enforced configuration update validation: fail-closed parsing and required cleanup before changing allowlist)
8. `Providers/GelatoSeriesProvider.cs` (Guarded series provider metadata refresh using file-backed path check and scope helper)
9. `tests/LOCAL_SERIES_SCOPE.md` (Documentation for offline allowlist scope test suite)
10. `tests/run-local-series-scope.sh` (Offline synthetic contract check script)

---

## Provenance & Verification Commands
All verification commands were executed independently in a clean .NET 10 environment (`dotnet 10.0.103`) using target head `a985889b7cadbf8f15ea3e075c3919e9035aec9d`.

### 1. Build Verification
```sh
dotnet build Gelato.csproj -c Release
```
*Output:* Build succeeded with 0 Errors and 16 pre-existing CS warnings.

### 2. Offline Synthetic Scope Test Suite
```sh
./tests/run-local-series-scope.sh
```
*Output:*
```
PASS 18 offline scope/model checks
PASS source call-site guards present
```

### 3. Adversarial Edge Case & Counterexample Suite
Constructed and executed an independent C# adversarial test binary targeting `LocalSeriesTreeScope` and `PluginConfiguration`:

```sh
dotnet run --project /tmp/adv_test/AdvRunner.csproj
```
*Output Results:*
* **[Test 1] Uppercase GUID format:** Accepted (`True`) — `Guid.TryParseExact` with "D" format correctly handles uppercase and lowercase hex chars.
* **[Test 2] Braced GUID format (`{GUID}`):** Rejected (`True`) — Enforced strictly by `idText.Length == 36`.
* **[Test 3] Exceeding max 32 entry limit:** Rejected (`True`) — 33 GUID entries fail parsing closed.
* **[Test 4] Granularity Evaluation:** Scoped strictly series-wide (`True`). `CanExtendLocalSeriesTree` accepts Jellyfin Series GUIDs; providing a Season GUID returns `false`.
* **[Test 5] Partial Invalid Entry in List:** Fail-Closed (`True`) — Any malformed item (`g1,NOT_A_GUID,g2`) invalidates the entire allowlist.
* **[Test 6] `Guid.Empty`:** Rejected (`True`).

---

## Detailed Evaluation & Concrete Findings

### 1. Fail-Closed GUID Allowlist Parsing & Defaults
`LocalSeriesTreeScope.TryParse` parses comma-separated strings into a `HashSet<Guid>`. It fails closed if:
* The input string is `null`, empty, or whitespace.
* Entry count is strictly `< 1` or `> 32`.
* Any item is not exactly 36 characters long, fails standard `"D"` format GUID parsing, equals `Guid.Empty`, or is a duplicate.
When invalid, the hash set is cleared and returns `false`. `CanExtendLocalSeriesTree` returns `false` if `ExtendLocalSeriesTrees` is `false` or if `LocalSeriesTreeScope.IsAllowed` fails.

### 2. Series-Wide Scope vs. Season-Specific Scope
**Explicit Assessment:** The allowlist mechanism is **strictly series-wide**, not season-specific.
`CanExtendLocalSeriesTree(seriesId)` checks the top-level Jellyfin `Series.Id` against the allowlist. Gelato does not maintain season-level allowlists or season GUID filtering. When a series GUID is allowlisted, extension applies across all missing seasons and episodes within that series.

### 3. Configuration & Validation Logic
In `Plugin.UpdateConfiguration`:
1. If `ExtendLocalSeriesTrees` is `true`, `LocalSeriesTreeScope.TryParse` MUST succeed, or an `ArgumentException` is thrown (HTTP 400 response from web API).
2. If changing an existing allowlist while `ExtendLocalSeriesTrees` remains `true`, `UpdateConfiguration` throws an `ArgumentException` requiring the admin to first disable tree extension (which triggers a cleanup pass of virtual items) before applying a new allowlist.

### 4. User Overrides & Concurrency
`UserConfig.ApplyOverrides` copies `LocalSeriesTreeAllowlist` and `ExtendLocalSeriesTrees` from `PluginConfiguration`. Non-admin users cannot override the allowlist with arbitrary GUIDs without passing base validation. In `Plugin.GetConfig`, effective per-user configuration maintains identical scoping.

### 5. Call Site Guards & Alternate Path Analysis
All entry points for local series tree extension were audited:
* `GelatoManager.SyncSeriesTrees`: Guards continuing local series query (`cfg.CanExtendLocalSeriesTree(s.Id)`).
* `GelatoManager.SyncLocalSeriesTreesAsync`: Guards non-continuing local series query (`cfg.CanExtendLocalSeriesTree(s.Id)`).
* `GelatoManager.SyncSeriesTreesAsync`: Guards local series tree extension entry point (`cfg.CanExtendLocalSeriesTree(local.Id)`).
* `GelatoManager.ReturnTakenLocalEpisodesAsync`: Restricts returning taken local episodes to allowlisted local series (`!cfg.ExtendLocalSeriesTrees || cfg.CanExtendLocalSeriesTree(s.Id)`).
* `InsertActionFilter.HandleLocalSeriesAsync`: Scopes local item creation/sync (`cfg.CanExtendLocalSeriesTree(series.Id)`).
* `GelatoSeriesProvider.GetMetadataAsync`: Scopes file-backed series metadata sync using `series.IsFileProtocol || string.IsNullOrEmpty(series.Path)` and `cfg.CanExtendLocalSeriesTree(series.Id)`.

Nonallowlisted series cannot be extended through any background task or direct provider request.

### 6. Local Row Preference, Duplicates, and Virtual-to-Local Replacement
Local disk-backed files take precedence over virtual Gelato stubs. When a new local file is added for an episode previously represented virtually, `InsertActionFilter` and `GelatoManager.RemoveShadowedEpisodes` clean up the virtual stub, replacing it with the file-backed item without creating duplicate slots or orphan records.

---

## Known External Dependency & Watched-State Defect

### Watched-State Migration Limitation
As identified in the synthetic integration lab, an API-valid virtual watched/resume record that lacks a `LastPlayedDate` timestamp loses its watched state when replaced by a newly scanned local file in this PR base (`c9d2d466602f4a1398c0fa0a71fa1106928eac56`).

* **Status:** This defect is being addressed upstream in PR lostb1t#348 (`fix/undated-watch-state-migration` at commit `713a84db503f5712832d323b1cfb4bd260af6156`).
* **Source Review Finding:** PR #5 does not silently incorporate or fix PR #348. Full watched-state migration acceptance depends on merging upstream PR #348 or backporting the undated watch-state repair fix.

---

## Residual Risks & Conditions for Approval
1. **Upstream Watch-State Dependency:** Full acceptance of virtual-to-local watched-state migration requires upstream PR lostb1t#348 for undated watch records (`LastPlayedDate == null`).
2. **Series Granularity Awareness:** System administrators must be aware that allowlisting a series ID extends all seasons for that show (series-wide behavior).
3. **Configuration Change Workflow:** Updating the allowlist requires setting `ExtendLocalSeriesTrees = false`, saving to run virtual cleanup, and then enabling with the new GUID allowlist.

---

## Report Artifact Details & Final Verdict
* **Report Artifact Path:** `JULES_REVIEW_REPORT.md`
* **Verdict:** `PASS_WITH_CONDITIONS`
