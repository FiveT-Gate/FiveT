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

    [Fact]
    public void Sealed_backup_opens_again_and_holds_no_readable_text()
    {
        const string text = "{\"version\":1,\"connections\":[{\"name\":\"Office\",\"password\":\"s3cret-Ünï\"}]}";
        var file = Backup.Seal(text);
        Assert.Equal(text, Backup.Open(file));
        var raw = System.Text.Encoding.UTF8.GetString(file);
        Assert.DoesNotContain("s3cret", raw);
        Assert.DoesNotContain("connections", raw);
        Assert.NotEqual(file, Backup.Seal(text));   // a fresh nonce each time
    }

    [Fact]
    public void Open_refuses_a_changed_or_cut_sealed_file()
    {
        var file = Backup.Seal("{\"connections\":[]}");
        var changed = (byte[])file.Clone();
        changed[^20] ^= 1;
        Assert.Throws<InvalidDataException>(() => Backup.Open(changed));
        Assert.Throws<InvalidDataException>(() => Backup.Open(file[..20]));
    }

    [Fact]
    public void Open_still_reads_a_plain_file_from_the_Mac_or_an_older_FiveT()
    {
        const string text = "{\"connections\":[]}";
        Assert.Equal(text, Backup.Open(System.Text.Encoding.UTF8.GetBytes(text)));
        Assert.Equal(text, Backup.Open([0xEF, 0xBB, 0xBF, .. System.Text.Encoding.UTF8.GetBytes(text)]));   // with a BOM
    }

    [Fact]
    public void Default_file_name_is_the_date_then_the_backup_name()
    {
        Assert.Equal("2026-11-05_FiveT.fivet", Backup.DefaultFileName(new DateTime(2026, 11, 5, 23, 59, 0)));
    }
}
