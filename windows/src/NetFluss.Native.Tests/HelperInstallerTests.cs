// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using NetFluss.Service;
using Xunit;

namespace NetFluss.Native.Tests;

public class HelperInstallerTests
{
    [Theory]
    [InlineData("NetFluss.Service.exe")]
    [InlineData("NetFluss.Service.dll")]
    [InlineData("NetFluss.Core.dll")]
    [InlineData("NetFluss.Service.runtimeconfig.json")]
    [InlineData("NetFluss.Service.pdb")]
    [InlineData(@"de\NetFluss.Core.resources.dll")]
    [InlineData(@"zh-Hans\NetFluss.Core.resources.dll")]
    public void TheHelpersOwnFiles_AreCopied(string relative) => Assert.True(Installer.IsHelperFile(relative));

    [Theory]
    [InlineData("version.dll")]
    [InlineData("dbghelp.dll")]
    [InlineData("NetFluss.Service.bat")]
    [InlineData("NetFluss.cmd")]
    [InlineData(@"de\version.dll")]
    [InlineData(@"evil\NetFluss.Core.resources.dll")]
    [InlineData(@"de\NetFluss.Core.dll")]
    [InlineData(@"de\sub\NetFluss.Core.resources.dll")]
    public void AnythingElse_IsNot(string relative) => Assert.False(Installer.IsHelperFile(relative));
}
