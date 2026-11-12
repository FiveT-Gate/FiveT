using Xunit;

namespace FiveT.Tests;

/// <summary>The rules of the .fivet backup file that need no window: how imported connections join the saved ones, and the Mac's dates.</summary>
public class BackupTests
{
    private static Connection C(string name, Guid? id = null) => new() { Id = id ?? Guid.NewGuid(), Name = name };

    [Fact]
    public void Merge_adds_new_connections_at_the_end()
    {
        var saved = new[] { C("Office"), C("Lab") };
        var (list, added, replaced) = Backup.Merge(saved, new[] { C("Home") });
        Assert.Equal(new[] { "Office", "Lab", "Home" }, list.Select(c => c.Name));
        Assert.Equal((1, 0), (added, replaced));
    }

    [Fact]
    public void Merge_replaces_the_saved_connection_with_the_same_id_where_it_stands()
    {
        var id = Guid.NewGuid();
        var saved = new[] { C("First"), C("Office", id), C("Last") };
        var (list, added, replaced) = Backup.Merge(saved, new[] { C("Office (new)", id), C("Home") });
        Assert.Equal(new[] { "First", "Office (new)", "Last", "Home" }, list.Select(c => c.Name));
        Assert.Equal((1, 1), (added, replaced));
    }

    [Fact]
    public void Merge_leaves_the_saved_list_itself_alone()
    {
        var saved = new List<Connection> { C("Office") };
        Backup.Merge(saved, new[] { C("Home") });
        Assert.Single(saved);
    }

    [Fact]
    public void Merge_of_an_empty_file_changes_nothing()
    {
        var saved = new[] { C("Office") };
        var (list, added, replaced) = Backup.Merge(saved, Array.Empty<Connection>());
        Assert.Equal(saved, list);
        Assert.Equal((0, 0), (added, replaced));
    }

    [Fact]
    public void MacSeconds_counts_from_2001_in_UTC()
    {
        Assert.Equal(0, Backup.MacSeconds(new DateTime(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc)));
        Assert.Equal(86400, Backup.MacSeconds(new DateTime(2001, 1, 2, 0, 0, 0, DateTimeKind.Utc)));
        // A local time is converted first: the same moment gives the same number.
        var utc = new DateTime(2026, 11, 12, 12, 0, 0, DateTimeKind.Utc);
        Assert.Equal(Backup.MacSeconds(utc), Backup.MacSeconds(utc.ToLocalTime()));
    }
}
