using System.Diagnostics;
using System.IO.Compression;
using System.Net.Http.Json;
using System.Text.Json;
using System.Xml.Linq;

class Program
{
    private const string AppName    = "decompiler";
    private const string AppVersion = "1.0.0";
    private const string ObsoleteCutoff = "26.1";

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(10) };

    private static readonly bool Color =
        !Console.IsOutputRedirected
        && string.IsNullOrEmpty(Environment.GetEnvironmentVariable("NO_COLOR"))
        && !string.Equals(Environment.GetEnvironmentVariable("TERM"), "dumb",
            StringComparison.OrdinalIgnoreCase);

    private static int _step;

    static async Task<int> Main(string[] args)
    {
        if (args.Length == 1)
        {
            if (IsHelp(args[0]))    { PrintHelp();    return 0; }
            if (IsVersion(args[0])) { PrintVersion(); return 0; }
        }

        if (args.Length != 2)
        {
            WriteError(args.Length == 0
                ? "no arguments provided"
                : $"expected 2 arguments, got {args.Length}");
            Console.Error.WriteLine();
            Console.Error.WriteLine($"  {Dim("Usage:")} {AppName} <mod.jar> <minecraft_version>");
            Console.Error.WriteLine($"  {Dim("Try:")}   {AppName} --help");
            return 1;
        }

        string inputModJar = Path.GetFullPath(args[0]);
        string mcVersion   = args[1];

        if (!File.Exists(inputModJar))
        {
            WriteError($"input jar not found: {inputModJar}");
            return 1;
        }

        PrintBanner();

        string workDir = Path.Combine(Path.GetTempPath(), $"remap-{Guid.NewGuid():N}");
        Directory.CreateDirectory(workDir);

        try
        {
            await RunAsync(inputModJar, mcVersion, workDir);
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine();
            WriteError(ex.Message);
            return 1;
        }
        finally
        {
            try { Directory.Delete(workDir, true); } catch { }
        }
    }

    static async Task RunAsync(string inputModJar, string mcVersion, string workDir)
    {
        _step = 0;
        bool isLegacy = IsLegacyVersion(mcVersion);

        Info(isLegacy
            ? $"{Bold(mcVersion)} is a legacy (obfuscated) release – using Yarn mappings."
            : $"{Bold(mcVersion)} is an unobfuscated release – using Parchment mappings.");
        Console.WriteLine();

        string tinyRemapperJar     = await DownloadTinyRemapperAsync(workDir);
        string vineflowerJar       = await DownloadVineflowerAsync(workDir);
        string officialClientJar   = await DownloadMinecraftClientAsync(mcVersion, workDir);

        string remappedJar = Path.Combine(workDir, "mod-named.jar");

        if (isLegacy)
        {
            string mappingsTiny = await DownloadYarnMappingsAsync(mcVersion, workDir);

            string intermediaryClientJar = Path.Combine(workDir, "minecraft-intermediary.jar");
            Step("Remapping Minecraft client (official -> intermediary)...");
            await RunJavaAsync(
                "-cp", tinyRemapperJar,
                "net.fabricmc.tinyremapper.Main",
                officialClientJar,
                intermediaryClientJar,
                mappingsTiny,
                "official", "intermediary");

            await RemapModAsync(
                inputModJar,
                remappedJar,
                mappingsTiny,
                "intermediary", "named",
                intermediaryClientJar,
                tinyRemapperJar);
        }
        else
        {
            string? parchmentTiny = await DownloadParchmentMappingsAsync(mcVersion, workDir);

            if (parchmentTiny is not null)
            {
                await RemapModAsync(
                    inputModJar,
                    remappedJar,
                    parchmentTiny,
                    "official", "named",
                    officialClientJar,
                    tinyRemapperJar);
            }
            else
            {
                Warn("No Parchment Tiny mappings found; using official names only.");
                File.Copy(inputModJar, remappedJar, overwrite: true);
            }
        }

        string finalOutput = Path.Combine(
            Path.GetDirectoryName(inputModJar)!,
            Path.GetFileNameWithoutExtension(inputModJar) + "-src");

        if (Directory.Exists(finalOutput))
            Directory.Delete(finalOutput, true);

        Step("Decompiling with Vineflower...");
        await RunJavaAsync(
            "-jar", vineflowerJar,
            remappedJar,
            finalOutput);

        Console.WriteLine();
        Success($"Done. Source root: {Bold(finalOutput)}");
    }

    static async Task RemapModAsync(
        string inputJar,
        string outputJar,
        string mappingsFile,
        string fromNamespace,
        string toNamespace,
        string classpathJar,
        string tinyRemapperJar)
    {
        Step($"Remapping mod jar ({fromNamespace} -> {toNamespace})...");
        await RunJavaAsync(
            "-cp", tinyRemapperJar,
            "net.fabricmc.tinyremapper.Main",
            inputJar,
            outputJar,
            mappingsFile,
            fromNamespace, toNamespace,
            classpathJar,
            "--fixPackageAccess",
            "--ignoreConflicts");
    }

    static bool IsLegacyVersion(string mcVersion)
    {
        var current = ParseVersion(mcVersion);
        var cutoff  = ParseVersion(ObsoleteCutoff);

        for (int i = 0; i < Math.Min(current.Length, cutoff.Length); i++)
        {
            if (current[i] < cutoff[i]) return true;
            if (current[i] > cutoff[i]) return false;
        }

        return current.Length < cutoff.Length;
    }

    static int[] ParseVersion(string v) =>
        v.Split('.', StringSplitOptions.RemoveEmptyEntries)
         .Select(p => int.TryParse(p, out var n) ? n : 0)
         .ToArray();

    static async Task<string> DownloadMinecraftClientAsync(string mcVersion, string workDir)
    {
        Step($"Resolving Minecraft {mcVersion} client jar...");
        var manifest = await Http.GetFromJsonAsync<JsonElement>(
            "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json");

        var versionEntry = manifest.GetProperty("versions")
            .EnumerateArray()
            .FirstOrDefault(v => v.GetProperty("id").GetString() == mcVersion);

        if (versionEntry.ValueKind == JsonValueKind.Undefined)
            throw new InvalidOperationException($"Minecraft version not found: {mcVersion}");

        string versionUrl = versionEntry.GetProperty("url").GetString()!;
        var versionJson = await Http.GetFromJsonAsync<JsonElement>(versionUrl);
        string clientUrl = versionJson.GetProperty("downloads")
            .GetProperty("client")
            .GetProperty("url")
            .GetString()!;

        string dest = Path.Combine(workDir, "client.jar");
        await DownloadFileAsync(clientUrl, dest);
        return dest;
    }

    static async Task<string> DownloadYarnMappingsAsync(string mcVersion, string workDir)
    {
        Step($"Resolving Yarn mappings for {mcVersion}...");
        var metadata = XDocument.Load(
            "https://maven.fabricmc.net/net/fabricmc/yarn/maven-metadata.xml");

        string latest = metadata.Descendants("version")
            .Select(e => e.Value)
            .Where(v => v.StartsWith($"{mcVersion}+build."))
            .OrderByDescending(v => v)
            .FirstOrDefault()
            ?? throw new InvalidOperationException($"No Yarn mappings found for {mcVersion}");

        string url = $"https://maven.fabricmc.net/net/fabricmc/yarn/{latest}/yarn-{latest}-mergedv2.jar";
        string yarnJar = Path.Combine(workDir, "yarn.jar");
        await DownloadFileAsync(url, yarnJar);

        string tinyPath = Path.Combine(workDir, "mappings.tiny");
        using var archive = ZipFile.OpenRead(yarnJar);
        var entry = archive.GetEntry("mappings/mappings.tiny")
            ?? throw new InvalidOperationException("mappings/mappings.tiny not found in Yarn jar");
        entry.ExtractToFile(tinyPath, true);
        return tinyPath;
    }

    static async Task<string?> DownloadParchmentMappingsAsync(string mcVersion, string workDir)
    {
        Step($"Resolving Parchment mappings for {mcVersion}...");

        string metadataUrl =
            $"https://maven.parchmentmc.org/org/parchmentmc/data/parchment-{mcVersion}/maven-metadata.xml";

        XDocument metadata;
        try
        {
            metadata = XDocument.Load(metadataUrl);
        }
        catch
        {
            return null;
        }

        string latestVersion = metadata.Descendants("version")
            .Select(e => e.Value)
            .OrderByDescending(v => v)
            .FirstOrDefault()
            ?? string.Empty;

        if (string.IsNullOrEmpty(latestVersion))
            return null;

        string artifactUrl =
            $"https://maven.parchmentmc.org/org/parchmentmc/data/parchment-{mcVersion}/{latestVersion}/parchment-{mcVersion}-{latestVersion}.zip";

        string zipPath = Path.Combine(workDir, "parchment.zip");
        await DownloadFileAsync(artifactUrl, zipPath);

        string extractDir = Path.Combine(workDir, "parchment");
        ZipFile.ExtractToDirectory(zipPath, extractDir, overwriteFiles: true);

        return Directory
            .EnumerateFiles(extractDir, "*.tiny", SearchOption.AllDirectories)
            .FirstOrDefault();
    }

    static async Task<string> DownloadTinyRemapperAsync(string workDir)
    {
        Step("Resolving tiny-remapper...");
        var metadata = XDocument.Load(
            "https://maven.fabricmc.net/net/fabricmc/tiny-remapper/maven-metadata.xml");

        string latest = metadata.Descendants("version")
            .Select(e => e.Value)
            .OrderByDescending(v => v)
            .First();

        string url = $"https://maven.fabricmc.net/net/fabricmc/tiny-remapper/{latest}/tiny-remapper-{latest}-fat.jar";
        string dest = Path.Combine(workDir, "tiny-remapper.jar");
        await DownloadFileAsync(url, dest);
        return dest;
    }

    static async Task<string> DownloadVineflowerAsync(string workDir)
    {
        Step("Resolving Vineflower...");
        var metadata = XDocument.Load(
            "https://repo1.maven.org/maven2/org/vineflower/vineflower/maven-metadata.xml");

        string latest = metadata.Descendants("version")
            .Select(e => e.Value)
            .OrderByDescending(v => v)
            .First();

        string url = $"https://repo1.maven.org/maven2/org/vineflower/vineflower/{latest}/vineflower-{latest}.jar";
        string dest = Path.Combine(workDir, "vineflower.jar");
        await DownloadFileAsync(url, dest);
        return dest;
    }

    static async Task DownloadFileAsync(string url, string dest)
    {
        using var response = await Http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
        response.EnsureSuccessStatusCode();
        await using var file = File.Create(dest);
        await response.Content.CopyToAsync(file);
    }

    static async Task RunJavaAsync(params string[] arguments)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "java",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var arg in arguments)
            psi.ArgumentList.Add(arg);

        using var process = Process.Start(psi)
            ?? throw new InvalidOperationException("Failed to start java");

        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();

        if (!string.IsNullOrWhiteSpace(await stdout))
            Console.Write(await stdout);
        if (!string.IsNullOrWhiteSpace(await stderr))
            Console.Error.Write(await stderr);

        if (process.ExitCode != 0)
            throw new InvalidOperationException($"Java exited with code {process.ExitCode}");
    }

    static bool IsHelp(string a)    => a is "-h" or "--help"    or "help";
    static bool IsVersion(string a) => a is "-v" or "--version" or "version";

    static string Ansi(string code, string s) => Color ? $"\x1b[{code}m{s}\x1b[0m" : s;

    static string Bold(string s)   => Ansi("1", s);
    static string Dim(string s)    => Ansi("2", s);
    static string Cyan(string s)   => Ansi("36", s);
    static string Green(string s)  => Ansi("32", s);
    static string Yellow(string s) => Ansi("33", s);
    static string Red(string s)    => Ansi("31", s);

    static void Info(string msg)    => Console.WriteLine($"  {Cyan("•")} {msg}");
    static void Step(string msg)    => Console.WriteLine($"  {Cyan($"[{++_step}]")} {msg}");
    static void Success(string msg) => Console.WriteLine($"  {Green("✓")} {msg}");
    static void Warn(string msg)    => Console.WriteLine($"  {Yellow("!")} {msg}");

    static void WriteError(string msg) =>
        Console.Error.WriteLine($"  {Red("✗ error:")} {msg}");

    static void PrintBanner()
    {
        string rule = new string('─', 58);
        Console.WriteLine();
        Console.WriteLine($"  {Dim(rule)}");
        Console.WriteLine($"  {Bold(AppName)} {Dim(AppVersion)}");
        Console.WriteLine($"  {Dim("Decompile Minecraft mod JARs into readable Java source.")}");
        Console.WriteLine($"  {Dim(rule)}");
        Console.WriteLine();
    }

    static void PrintVersion()
    {
        Console.WriteLine($"{AppName} {AppVersion}");
    }

    static void PrintHelp()
    {
        Console.WriteLine($"{Bold(AppName)} {Dim(AppVersion)}");
        Console.WriteLine($"{Dim("Decompile Minecraft mod JARs into readable Java source.")}");
        Console.WriteLine();

        Console.WriteLine($"{Bold("USAGE")}");
        Console.WriteLine($"  {AppName} <mod.jar> <minecraft_version>");
        Console.WriteLine();

        Console.WriteLine($"{Bold("ARGUMENTS")}");
        HelpLine("<mod.jar>",            "Path to the mod JAR file to decompile.");
        HelpLine("<minecraft_version>",  "Target Minecraft version (e.g. 1.21.1).");
        Console.WriteLine();

        Console.WriteLine($"{Bold("OPTIONS")}");
        HelpLine("-h, --help",     "Print this help message and exit.");
        HelpLine("-v, --version",  "Print version information and exit.");
        Console.WriteLine();

        Console.WriteLine($"{Bold("ENVIRONMENT")}");
        HelpLine("NO_COLOR",       "Disable colored output when set.");
        HelpLine("TERM",           "Respects TERM=dumb for plain output.");
        Console.WriteLine();

        Console.WriteLine($"{Bold("EXAMPLES")}");
        Console.WriteLine($"  {Dim("$")} {AppName} ./mymod.jar 1.21.1");
        Console.WriteLine($"  {Dim("$")} {AppName} ./mymod.jar 1.19.4");
        Console.WriteLine();
    }

    static void HelpLine(string label, string description) =>
        Console.WriteLine($"  {Bold(label.PadRight(26))} {Dim(description)}");
}
