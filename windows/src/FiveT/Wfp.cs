using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace FiveT;

/// <summary>
/// A set of Windows Filtering Platform filters that lives exactly as long as this object: they are added
/// in a dynamic session, which Windows itself removes when the session's handle closes, also when FiveT
/// crashes or is killed. So FiveT can never leave a PC blocked with no app to unblock it, nothing is left
/// behind for an uninstall to clean up, and the user's own firewall rules and settings are never touched.
///
/// The filters sit in a sublayer of FiveT's own at the layers that authorise outgoing connections (IPv4 and
/// IPv6). The kill switch (<see cref="KillSwitch"/>) is "permit these, block the rest".
/// </summary>
public sealed class WfpSession : IDisposable
{
    private IntPtr _engine;

    public sealed record Rules
    {
        /// <summary>Addresses and networks that stay reachable ("10.0.0.0/8", "203.0.113.10", "fe80::/10").</summary>
        public List<string> Permit { get; init; } = new();
        /// <summary>The network adapter (its LUID) whose traffic passes: the VPN's own tunnel.</summary>
        public ulong? PermitInterfaceLuid { get; init; }
        public bool PermitLoopback { get; init; } = true;
        /// <summary>Everything not permitted above is blocked.</summary>
        public bool BlockEverythingElse { get; init; } = true;
        /// <summary>Only these are blocked (for the self-test, which must not cut the PC off).</summary>
        public List<string> Block { get; init; } = new();
    }

    /// <summary>Adds the filters, all or none. Throws <see cref="InvalidOperationException"/> with Windows' error when it cannot.</summary>
    public WfpSession(Rules rules, string name = "FiveT kill switch")
    {
        var session = new FWPM_SESSION0 { displayData = new FWPM_DISPLAY_DATA0 { name = name, description = "Removed by Windows when FiveT exits." }, flags = SessionFlagDynamic };
        Check(FwpmEngineOpen0(null, RpcAuthnWinnt, IntPtr.Zero, ref session, out _engine), "open the filter engine");
        var memory = new List<IntPtr>();
        try
        {
            Check(FwpmTransactionBegin0(_engine, 0), "begin");
            var subLayer = Guid.NewGuid();
            var sl = new FWPM_SUBLAYER0 { subLayerKey = subLayer, displayData = new FWPM_DISPLAY_DATA0 { name = name, description = "" }, weight = 0xFFFF };
            Check(FwpmSubLayerAdd0(_engine, ref sl, IntPtr.Zero), "add the sublayer");

            foreach (var v6 in new[] { false, true })
            {
                var layer = v6 ? LayerAleAuthConnectV6 : LayerAleAuthConnectV4;
                if (rules.PermitLoopback)
                    Add(layer, subLayer, ActionPermit, PermitWeight, name + ": this PC", new FWPM_FILTER_CONDITION0
                    {
                        fieldKey = ConditionFlags, matchType = MatchFlagsAllSet,
                        conditionValue = new FWP_VALUE0 { type = TypeUInt32, value = (IntPtr)FlagIsLoopback },
                    });
                if (rules.PermitInterfaceLuid is { } luid)
                    Add(layer, subLayer, ActionPermit, PermitWeight, name + ": the VPN's tunnel", new FWPM_FILTER_CONDITION0
                    {
                        fieldKey = ConditionIpLocalInterface, matchType = MatchEqual,
                        conditionValue = new FWP_VALUE0 { type = TypeUInt64, value = Alloc(memory, BitConverter.GetBytes(luid)) },
                    });
                foreach (var (list, action, weight, what) in new[] { (rules.Permit, ActionPermit, PermitWeight, "allowed"), (rules.Block, ActionBlock, BlockWeight, "blocked") })
                    foreach (var net in list)
                    {
                        if (!TryParseNetwork(net, out var address, out var prefix)) throw new InvalidOperationException($"'{net}' is not an address or network");
                        if (address.AddressFamily == AddressFamily.InterNetworkV6 != v6) continue;
                        Add(layer, subLayer, action, weight, $"{name}: {what} {net}", new FWPM_FILTER_CONDITION0
                        {
                            fieldKey = ConditionIpRemoteAddress, matchType = MatchEqual, conditionValue = AddressValue(memory, address, prefix),
                        });
                    }
                if (rules.BlockEverythingElse) Add(layer, subLayer, ActionBlock, BlockAllWeight, name + ": everything else", null);
            }
            Check(FwpmTransactionCommit0(_engine), "commit");
        }
        catch
        {
            Dispose();
            throw;
        }
        finally
        {
            foreach (var p in memory) Marshal.FreeHGlobal(p);
        }
    }

    private void Add(Guid layer, Guid subLayer, uint action, byte weight, string name, FWPM_FILTER_CONDITION0? condition)
    {
        var conditions = IntPtr.Zero;
        try
        {
            if (condition is { } c)
            {
                conditions = Marshal.AllocHGlobal(Marshal.SizeOf<FWPM_FILTER_CONDITION0>());
                Marshal.StructureToPtr(c, conditions, false);
            }
            var filter = new FWPM_FILTER0
            {
                filterKey = Guid.NewGuid(),
                displayData = new FWPM_DISPLAY_DATA0 { name = name, description = "" },
                layerKey = layer, subLayerKey = subLayer,
                weight = new FWP_VALUE0 { type = TypeUInt8, value = (IntPtr)weight },
                numFilterConditions = condition == null ? 0u : 1u, filterCondition = conditions,
                action = new FWPM_ACTION0 { type = action },
            };
            Check(FwpmFilterAdd0(_engine, ref filter, IntPtr.Zero, out _), $"add the filter '{name}'");
        }
        finally
        {
            if (conditions != IntPtr.Zero) Marshal.FreeHGlobal(conditions);
        }
    }

    /// <summary>Closes the session: Windows removes every filter it added.</summary>
    public void Dispose()
    {
        var e = Interlocked.Exchange(ref _engine, IntPtr.Zero);
        if (e != IntPtr.Zero) FwpmEngineClose0(e);
    }

    ~WfpSession() => Dispose();

    // MARK: Values

    /// <summary>"10.0.0.0/8", "203.0.113.10" or "fe80::/10" as an address and a prefix length.</summary>
    public static bool TryParseNetwork(string text, out IPAddress address, out int prefix)
    {
        address = IPAddress.None;
        prefix = 0;
        var slash = text.IndexOf('/');
        if (!IPAddress.TryParse(slash < 0 ? text : text[..slash], out var parsed)) return false;
        address = parsed.IsIPv4MappedToIPv6 ? parsed.MapToIPv4() : parsed;
        var max = address.AddressFamily == AddressFamily.InterNetworkV6 ? 128 : 32;
        prefix = max;
        return slash < 0 || (int.TryParse(text[(slash + 1)..], out prefix) && prefix >= 0 && prefix <= max);
    }

    private static FWP_VALUE0 AddressValue(List<IntPtr> memory, IPAddress address, int prefix)
    {
        var bytes = address.GetAddressBytes();
        if (bytes.Length == 4)
        {
            // FWP_V4_ADDR_AND_MASK: address and mask as numbers in host byte order.
            var addr = (uint)(bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]);
            var mask = prefix == 0 ? 0u : uint.MaxValue << (32 - prefix);
            return new FWP_VALUE0 { type = TypeV4AddrMask, value = Alloc(memory, BitConverter.GetBytes(addr & mask).Concat(BitConverter.GetBytes(mask)).ToArray()) };
        }
        // FWP_V6_ADDR_AND_MASK: 16 address bytes, then the prefix length.
        return new FWP_VALUE0 { type = TypeV6AddrMask, value = Alloc(memory, bytes.Append((byte)prefix).ToArray()) };
    }

    private static IntPtr Alloc(List<IntPtr> memory, byte[] bytes)
    {
        var p = Marshal.AllocHGlobal(Math.Max(bytes.Length, 8));
        Marshal.Copy(bytes, 0, p, bytes.Length);
        memory.Add(p);
        return p;
    }

    private static void Check(uint status, string what)
    {
        if (status != 0) throw new InvalidOperationException($"Windows Filtering Platform could not {what} (error 0x{status:X8})");
    }

    // MARK: fwpuclnt.dll (64-bit layouts; FiveT is built for x64 and ARM64 only)

    private const uint RpcAuthnWinnt = 10, SessionFlagDynamic = 1;
    private const uint ActionBlock = 0x1001, ActionPermit = 0x1002;
    private const uint MatchEqual = 0, MatchFlagsAllSet = 6;
    private const uint TypeUInt8 = 1, TypeUInt32 = 3, TypeUInt64 = 4, TypeV4AddrMask = 0x100, TypeV6AddrMask = 0x101;
    private const uint FlagIsLoopback = 1;
    // A permit outweighs a block of a named address, which outweighs "everything else".
    private const byte PermitWeight = 12, BlockWeight = 8, BlockAllWeight = 1;

    private static readonly Guid LayerAleAuthConnectV4 = new("c38d57d1-05a7-4c33-904f-7fbceee60e82");
    private static readonly Guid LayerAleAuthConnectV6 = new("4a72393b-319f-44bc-84c3-ba54dcb3b6b4");
    private static readonly Guid ConditionIpRemoteAddress = new("b235ae9a-1d64-49b8-a44c-5ff3d9095045");
    private static readonly Guid ConditionIpLocalInterface = new("4cd62a49-59c3-4969-b7f3-bda5d32890a4");
    private static readonly Guid ConditionFlags = new("632ce23b-5167-435c-86d7-e903684aa80c");

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct FWPM_DISPLAY_DATA0
    {
        [MarshalAs(UnmanagedType.LPWStr)] public string? name;
        [MarshalAs(UnmanagedType.LPWStr)] public string? description;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct FWPM_SESSION0
    {
        public Guid sessionKey;
        public FWPM_DISPLAY_DATA0 displayData;
        public uint flags;
        public uint txnWaitTimeoutInMSec;
        public uint processId;
        public IntPtr sid;
        [MarshalAs(UnmanagedType.LPWStr)] public string? username;
        public int kernelMode;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FWP_BYTE_BLOB
    {
        public uint size;
        public IntPtr data;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct FWPM_SUBLAYER0
    {
        public Guid subLayerKey;
        public FWPM_DISPLAY_DATA0 displayData;
        public uint flags;
        public IntPtr providerKey;
        public FWP_BYTE_BLOB providerData;
        public ushort weight;
    }

    /// <summary>FWP_VALUE0 and FWP_CONDITION_VALUE0: a type and a union that is a number or a pointer.</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct FWP_VALUE0
    {
        public uint type;
        public IntPtr value;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FWPM_FILTER_CONDITION0
    {
        public Guid fieldKey;
        public uint matchType;
        public FWP_VALUE0 conditionValue;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FWPM_ACTION0
    {
        public uint type;
        public Guid filterType;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct FWPM_FILTER0
    {
        public Guid filterKey;
        public FWPM_DISPLAY_DATA0 displayData;
        public uint flags;
        public IntPtr providerKey;
        public FWP_BYTE_BLOB providerData;
        public Guid layerKey;
        public Guid subLayerKey;
        public FWP_VALUE0 weight;
        public uint numFilterConditions;
        public IntPtr filterCondition;
        public FWPM_ACTION0 action;
        public ulong context0, context1;   // union { UINT64 rawContext; GUID providerContextKey; }
        public IntPtr reserved;
        public ulong filterId;
        public FWP_VALUE0 effectiveWeight;
    }

    [DllImport("fwpuclnt.dll", CharSet = CharSet.Unicode)]
    private static extern uint FwpmEngineOpen0(string? serverName, uint authnService, IntPtr authIdentity, ref FWPM_SESSION0 session, out IntPtr engineHandle);
    [DllImport("fwpuclnt.dll")] private static extern uint FwpmEngineClose0(IntPtr engineHandle);
    [DllImport("fwpuclnt.dll")] private static extern uint FwpmTransactionBegin0(IntPtr engineHandle, uint flags);
    [DllImport("fwpuclnt.dll")] private static extern uint FwpmTransactionCommit0(IntPtr engineHandle);
    [DllImport("fwpuclnt.dll")] private static extern uint FwpmSubLayerAdd0(IntPtr engineHandle, ref FWPM_SUBLAYER0 subLayer, IntPtr sd);
    [DllImport("fwpuclnt.dll")] private static extern uint FwpmFilterAdd0(IntPtr engineHandle, ref FWPM_FILTER0 filter, IntPtr sd, out ulong id);
}

/// <summary>
/// The kill switch (Settings → General → VPN Settings; the Mac's ks-on / ks-off). While a VPN that carried
/// all traffic is down without its user having switched it off, nothing leaves the PC except to the PC
/// itself, the local network (the router, DHCP, a DNS server there), the tunnel a VPN is opening, and the
/// addresses given: the VPN's server and the PC's DNS servers, so the VPN can come back.
/// Never for a Forti connection: it only carries its office's addresses, so there is nothing to guard.
/// </summary>
public static class KillSwitch
{
    /// <summary>What always stays reachable (the Mac's list): private, link-local and multicast ranges, and broadcast.</summary>
    public static readonly string[] LocalRanges =
    {
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4", "255.255.255.255",
        "fe80::/10", "ff00::/8",
    };

    private static WfpSession? _session;
    private static readonly object Gate = new();

    public static bool IsActive { get { lock (Gate) return _session != null; } }

    /// <summary>
    /// Blocks the PC's internet now, or replaces what the block lets through. Returns null, or why it could
    /// not. The new filters are in place before the old ones go, so nothing slips out in between.
    /// </summary>
    public static string? Block(IEnumerable<string> addresses, ulong? tunnelLuid)
    {
        lock (Gate)
        {
            try
            {
                var allowed = LocalRanges.Concat(addresses.Where(a => WfpSession.TryParseNetwork(a, out _, out _))).Distinct().ToList();
                var next = new WfpSession(new WfpSession.Rules { Permit = allowed, PermitInterfaceLuid = tunnelLuid });
                _session?.Dispose();
                _session = next;
                return null;
            }
            catch (Exception e) { return e.Message; }
        }
    }

    public static void Unblock()
    {
        lock (Gate)
        {
            _session?.Dispose();
            _session = null;
        }
    }
}
