// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using NetFluss.Core;
using Xunit;

namespace NetFluss.Core.Tests;

/// <summary>Issue #70: the helper must never run from a folder that can be the app's own.</summary>
public class HelperPathsTests
{
    private static readonly string ProgramFiles = Path.Combine(Path.GetTempPath(), "Program Files");
    private static readonly HelperPaths Paths = new(ProgramFiles);

    [Fact]
    public void TheHelper_HasAFolderOfItsOwn()
    {
        Assert.Equal(Path.Combine(ProgramFiles, "NetFluss Helper", "Bin"), Paths.Binaries);
        Assert.Equal(Path.Combine(ProgramFiles, "NetFluss Helper", "VpnStaging"), Paths.VpnStaging);
        Assert.Equal(Path.Combine(Paths.Binaries, "NetFluss.Service.exe"), Paths.ServiceExecutable);
    }

    /// <summary>An app installed to Program Files\NetFluss has its Helper folder there.</summary>
    [Fact]
    public void TheHelper_IsNeverInsideTheOldAppFolder()
    {
        Assert.False(HelperPaths.IsSameOrInside(Paths.Binaries, Paths.LegacyRoot));
        Assert.False(HelperPaths.IsSameOrInside(Paths.VpnStaging, Paths.LegacyRoot));
    }

    /// <summary>Installing replaces Bin and deletes what it does not ship.</summary>
    [Fact]
    public void VpnStaging_IsNotInsideTheBinaries() => Assert.False(HelperPaths.IsSameOrInside(Paths.VpnStaging, Paths.Binaries));

    [Fact]
    public void TheOldHelperFolder_GoesWhenTheAppLivesElsewhere()
    {
        var app = Path.Combine(Path.GetTempPath(), "Users", "someone", "AppData", "Local", "Programs", "NetFluss");
        Assert.True(Paths.MayRemoveLegacyBinaries(app, _ => false));
    }

    [Fact]
    public void TheOldHelperFolder_StaysWhenItIsTheAppsOwn()
    {
        Assert.False(Paths.MayRemoveLegacyBinaries(Paths.LegacyRoot, _ => false));
        Assert.False(Paths.MayRemoveLegacyBinaries(Paths.LegacyRoot + Path.DirectorySeparatorChar, _ => false));
    }

    /// <summary>Run from somewhere else, but NetFluss is still installed in the old folder.</summary>
    [Fact]
    public void TheOldHelperFolder_StaysWhileAnAppIsInstalledThere()
    {
        var elsewhere = Path.Combine(Path.GetTempPath(), "Downloads", "NetFluss");
        var exe = Path.Combine(Paths.LegacyRoot, "NetFluss.exe");
        Assert.False(Paths.MayRemoveLegacyBinaries(elsewhere, path => string.Equals(path, exe, StringComparison.OrdinalIgnoreCase)));
    }

    [Theory]
    [InlineData("NetFluss", "NetFluss", true)]
    [InlineData("NetFluss/Helper", "NetFluss", true)]
    [InlineData("netfluss", "NetFluss", true)]
    [InlineData("NetFluss Helper", "NetFluss", false)]
    [InlineData("NetFlussX/Helper", "NetFluss", false)]
    [InlineData("NetFluss", "NetFluss/Helper", false)]
    public void IsSameOrInside(string path, string folder, bool expected)
    {
        static string Under(string relative) => Path.Combine(ProgramFiles, relative.Replace('/', Path.DirectorySeparatorChar));
        Assert.Equal(expected, HelperPaths.IsSameOrInside(Under(path), Under(folder)));
    }
}
