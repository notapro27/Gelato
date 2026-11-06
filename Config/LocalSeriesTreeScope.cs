namespace Gelato.Config;

/// <summary>Fail-closed scope for extending file-backed series trees.</summary>
public static class LocalSeriesTreeScope
{
    public static bool TryParse(string? value, out HashSet<Guid> ids)
    {
        ids = [];
        if (string.IsNullOrWhiteSpace(value))
            return false;

        var entries = value.Split(',');
        if (entries.Length is < 1 or > 32)
            return false;

        foreach (var entry in entries)
        {
            var idText = entry.Trim();
            if (idText.Length != 36 ||
                !Guid.TryParseExact(idText, "D", out var id) ||
                id == Guid.Empty || !ids.Add(id))
            {
                ids.Clear();
                return false;
            }
        }

        return true;
    }

    public static bool IsAllowed(string? value, Guid seriesId) =>
        seriesId != Guid.Empty && TryParse(value, out var ids) && ids.Contains(seriesId);
}
