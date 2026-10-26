#!/usr/bin/env bash
# Offline synthetic contract checks; no Jellyfin server or provider requests.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
dotnet_bin=${DOTNET_BIN:-dotnet}
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
cat > "$tmp/ScopeChecks.csproj" <<EOF
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup>
  <ItemGroup><ProjectReference Include="$root/Gelato.csproj" /></ItemGroup>
</Project>
EOF
cat > "$tmp/Program.cs" <<'EOF'
using Gelato.Config;

var a = Guid.Parse("11111111-1111-4111-8111-111111111111");
var b = Guid.Parse("22222222-2222-4222-8222-222222222222");
var checks = 0;
void Check(bool ok, string name) { if (!ok) throw new Exception(name); checks++; }
Check(!LocalSeriesTreeScope.IsAllowed(null, a), "missing list");
Check(!LocalSeriesTreeScope.IsAllowed("", a), "empty list");
Check(!LocalSeriesTreeScope.IsAllowed("bad", a), "invalid entry");
Check(!LocalSeriesTreeScope.IsAllowed($"{a},bad", a), "mixed invalid entry");
Check(!LocalSeriesTreeScope.IsAllowed($"{a},{a}", a), "duplicate entry");
Check(!LocalSeriesTreeScope.IsAllowed(Guid.Empty.ToString(), Guid.Empty), "empty id");
Check(LocalSeriesTreeScope.IsAllowed(a.ToString(), a), "selected series");
Check(!LocalSeriesTreeScope.IsAllowed(a.ToString(), b), "other series");
Check(LocalSeriesTreeScope.IsAllowed($" {a} , {b} ", b), "two selected series");
var config = new PluginConfiguration { ExtendLocalSeriesTrees = false, LocalSeriesTreeAllowlist = a.ToString() };
Check(!config.CanExtendLocalSeriesTree(a), "setting disabled despite list");
config.ExtendLocalSeriesTrees = true;
Check(config.CanExtendLocalSeriesTree(a) && !config.CanExtendLocalSeriesTree(b), "configuration scopes selected id");
var user = new UserConfig { UserId = b };
var effective = user.ApplyOverrides(config);
Check(effective.CanExtendLocalSeriesTree(a) && !effective.CanExtendLocalSeriesTree(b), "user override keeps scope");
config.LocalSeriesTreeAllowlist = $"{a},bad";
Check(!config.CanExtendLocalSeriesTree(a), "malformed saved configuration fails closed");

// Synthetic local episodes and virtual gaps; only the allowed series may be touched.
var local = new Dictionary<Guid, HashSet<int>> { [a] = [1, 2, 4, 6], [b] = [1, 2, 4, 6] };
var virtuals = new Dictionary<Guid, HashSet<int>> { [a] = [], [b] = [] };
void Refresh() {
    foreach (var id in local.Keys) {
        if (!LocalSeriesTreeScope.IsAllowed(a.ToString(), id)) continue;
        virtuals[id].RemoveWhere(local[id].Contains);
        foreach (var ep in new[] { 3, 5 }) if (!local[id].Contains(ep)) virtuals[id].Add(ep);
    }
}
Refresh(); Refresh();
Check(virtuals[a].SetEquals([3, 5]), "allowed gaps once after repeated refresh");
Check(virtuals[b].Count == 0 && local[b].SetEquals([1, 2, 4, 6]), "other series untouched");
Check(local[a].SetEquals([1, 2, 4, 6]), "original local preferred");
var watched = (played: true, playCount: 1, resumeTicks: 600000000L);
local[a].Add(3); Refresh(); Refresh();
Check(virtuals[a].SetEquals([5]) && local[a].Contains(3), "local replaces virtual without duplicate");
Check(watched == (true, 1, 600000000L), "ordinary watched state retained in model");
Console.WriteLine($"PASS {checks} offline scope/model checks");
EOF
"$dotnet_bin" restore "$tmp/ScopeChecks.csproj" --source "$tmp" -v quiet
"$dotnet_bin" run --project "$tmp/ScopeChecks.csproj" --no-restore -v quiet
for expected in \
  'cfg.CanExtendLocalSeriesTree(local.Id)' \
  'cfg.CanExtendLocalSeriesTree(s.Id)' \
  'cfg.CanExtendLocalSeriesTree(series.Id)'; do
  grep -Fq "$expected" "$root/GelatoManager.cs" "$root/Filters/InsertActionFilter.cs" "$root/Providers/GelatoSeriesProvider.cs"
done
printf '%s\n' 'PASS source call-site guards present'
