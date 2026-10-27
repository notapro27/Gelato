# Local series tree allowlist candidate

This review branch starts from Gelato 0.26.29.0 source commit `c9d2d466602f4a1398c0fa0a71fa1106928eac56` and is separate from the undated watch-state correction in upstream PR #348. The original 0.26.28.0 scope commit remains preserved in a separate branch. Neither branch is installed or approved for production.

The existing `ExtendLocalSeriesTrees` switch remains off by default. Enabling it now requires a comma-separated list of canonical Jellyfin series GUIDs (maximum 32); an absent, empty, duplicate, malformed, or partly malformed list fails closed. Saving an enabled configuration with such a list is rejected. To change a list while extension is enabled, first disable extension and let its existing cleanup finish. The list is copied into effective per-user configuration.

Scheduled sync, the direct tree-sync entry point, local-series insert handling, and metadata-refresh handling all check the allowlist before extending a file-backed series. The scheduled return-taken-episodes pass is restricted to allowlisted local series while extension is enabled. File-backed status is determined from path/protocol; an old Stremio provider ID cannot by itself bypass the guard. Gelato-created remote series retain their existing sync behavior.

Run the offline checks with a .NET 10 SDK and cached Jellyfin dependencies:

```sh
dotnet build Gelato.csproj -c Release
DOTNET_BIN=dotnet tests/run-local-series-scope.sh
```

The synthetic checks exercise parser rejection, disabled mode, one- and two-series selection, effective user configuration, repeated gap refresh, local preference, replacement without duplicate slots, and a model of ordinary watched/resume preservation. The build compiles the actual plugin and test project; source call-site assertions check each guard. These checks do **not** run Jellyfin, Gelato's real library manager, a provider, Fire TV playback, or actual watched-state migration. The known missing-LastPlayedDate migration defect remains in this branch; upstream PR #348 is a separate dependency for production acceptance. A new isolated Jellyfin integration run is required on this changed revision before considering deployment, including an unrelated nonallowlisted series, repeat scans/restart, local replacement, and watched/resume edge cases. No production setting may be enabled from these offline results.
