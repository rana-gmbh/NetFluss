// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Diagnostics;
using NetFluss.Core;
using Xunit;

namespace NetFluss.Core.Tests;

/// <summary>macOS 2.7.2: a system command that never finishes must not hang what waits on it.</summary>
public class ProcessWaitTests
{
    private static Process Start(string arguments) => Process.Start(new ProcessStartInfo
    {
        FileName = Path.Combine(Environment.SystemDirectory, "cmd.exe"),
        Arguments = arguments,
        CreateNoWindow = true,
        UseShellExecute = false,
    })!;

    [Fact]
    public async Task AQuickCommand_Finishes()
    {
        if (!OperatingSystem.IsWindows())
        {
            return; // cmd.exe is the subject; the Core tests also run elsewhere.
        }

        using var process = Start("/d /c exit 3");

        Assert.True(await ProcessWait.ForExitAsync(process, TimeSpan.FromSeconds(30)));
        Assert.Equal(3, process.ExitCode);
    }

    [Fact]
    public async Task AStuckCommand_IsAbandonedAndEnded()
    {
        if (!OperatingSystem.IsWindows())
        {
            return; // cmd.exe is the subject; the Core tests also run elsewhere.
        }

        using var process = Start("/d /c ping -n 30 127.0.0.1 >nul");

        var watch = Stopwatch.StartNew();
        Assert.False(await ProcessWait.ForExitAsync(process, TimeSpan.FromMilliseconds(300)));
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(10));
        Assert.True(process.WaitForExit(5000));
    }
}
