using System.Reflection;

// Compiled instead of LocalSeeds.cs in a distribution build (-p:Distribution=true) and when LocalSeeds.cs does not
// exist (see FiveT.csproj). The assembly carries a marker so build.ps1 / release.ps1 can prove that the FiveT.dll
// they are about to package has no seeded credentials: they look for the text below in the published file.
[assembly: AssemblyMetadata("FiveT.NoLocalSeeds", "true")]

namespace FiveT;

internal static partial class LocalSeeds
{
    public static List<Connection> Connections() => new();
}
