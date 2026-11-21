# Fills this server folder from the modpack's own files without copying them, so they take no disk space twice and
# the server can't drift from the client. ServerPackCreator's start scripts then install the mod loader and run the
# server; this script never touches them. No admin rights needed. Nothing in it is specific to one modpack: what to
# link comes from its own section at the end of variables.txt, the file it shares with ServerPackCreator.
# Run it before the first start, and again after every change to the modpack (a pull, rebase or pack update writes
# new files, and the server's hard links would stay on the old ones).
#   libraries         junction to SHARED_LIBRARIES, or to the libraries\ of a launcher folder above the modpack (one
#                     with assets\ and libraries\, like Prism's), so what the loader's installer writes there is
#                     shared; with neither, left alone
#   mods              hard links to the modpack's mods, minus the ones matched by CLIENT_ONLY_MODS
#   LINK_FOLDERS      hard links to every file in these modpack folders. A server that rewrites one of these files in
#                     place changes the modpack's file too, and git shows it. Files only the server has are left alone.
#   COPY_FILES        files of those folders that are copied instead
$ErrorActionPreference = 'Stop'
$server = $PSScriptRoot
$client = [IO.Path]::GetDirectoryName($server)   # the modpack

# variables.txt, read the way ServerPackCreator's start.ps1 reads it
$varsFile = Join-Path $server 'variables.txt'
if (-not (Test-Path -LiteralPath $varsFile)) { throw "$varsFile is missing: generate it with ServerPackCreator (README.md)." }
$vars = Get-Content -Raw -LiteralPath $varsFile | ConvertFrom-StringData
$missing = @('LINK_FOLDERS', 'COPY_FILES', 'CLIENT_ONLY_MODS', 'SHARED_LIBRARIES' | Where-Object { -not $vars.ContainsKey($_) })
if ($missing) { throw "variables.txt has no $($missing -join ', '): ServerPackCreator wrote a new one, so copy the setup-server-files.ps1 section from the old one to its end (README.md)." }
function Get-List([string]$Name) { @(($vars[$Name].Trim().Trim('"', "'") -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
$LinkFolders = Get-List 'LINK_FOLDERS'
$CopyFiles = @(Get-List 'COPY_FILES' | ForEach-Object { $_ -replace '/', '\' })
$skip = Get-List 'CLIENT_ONLY_MODS'
$sharedSetting = $vars['SHARED_LIBRARIES'].Trim().Trim('"', "'")
Add-Type -Namespace Native -Name Fs -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool CreateHardLink(string link, string target, IntPtr security);
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint mode, uint flags, IntPtr template);
[DllImport("kernel32.dll", SetLastError = true)]
static extern bool GetFileInformationByHandle(Microsoft.Win32.SafeHandles.SafeFileHandle file, out Info info);
[StructLayout(LayoutKind.Sequential, Pack = 4)]
struct Info { public uint Attributes; public long Created, Accessed, Written; public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow; }
// Two hard links to the same file on disk give the same id.
public static string Id(string path) {
    using (var h = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
        Info i;
        if (h.IsInvalid || !GetFileInformationByHandle(h, out i)) return path;
        return i.Volume + ":" + i.IndexHigh + ":" + i.IndexLow;
    }
}
'@

function Link-File([string]$From, [string]$To) {
    # Makes $To a hard link to $From, unless it already is one; $true when it had to (re)link
    if (Test-Path -LiteralPath $To) {
        if ([Native.Fs]::Id($To) -eq [Native.Fs]::Id($From)) { return $false }
        [IO.File]::Delete($To)
    } else {
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($To))
    }
    if (-not [Native.Fs]::CreateHardLink($To, $From, [IntPtr]::Zero)) {
        throw "Could not hard-link $To (Windows error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    }
    return $true
}

# ServerPackCreator's start script deletes everything in CLEANUP (variables.txt) whenever the Minecraft or loader
# version changes, with Remove-Item -Recurse: through the libraries junction that would empty the launcher's shared
# libraries\, and a linked folder would be gone for that start.
$cleanup = @()
if ($vars.ContainsKey('CLEANUP')) { $cleanup = Get-List 'CLEANUP' }
$clash = @($cleanup | Where-Object { $_ -in (@('libraries', 'mods') + $LinkFolders) })
if ($clash) { throw "Remove $($clash -join ', ') from CLEANUP in variables.txt first (SPC_CLEANUP_SPC in the ServerPackCreator config): ServerPackCreator's start script would delete them." }

# libraries: shared with SHARED_LIBRARIES, else with the launcher folder above the modpack, if there is one
$shared = $null
if ($sharedSetting) {
    $shared = if ([IO.Path]::IsPathRooted($sharedSetting)) { $sharedSetting } else { [IO.Path]::GetFullPath((Join-Path $server $sharedSetting)) }
    if (-not (Test-Path -LiteralPath $shared -PathType Container)) { throw "SHARED_LIBRARIES in variables.txt is $shared, which isn't a folder." }
} else {
    $d = $client
    for ($i = 0; $i -lt 4 -and -not $shared; $i++) {
        $d = [IO.Path]::GetDirectoryName($d); if (-not $d) { break }
        if ((Test-Path -LiteralPath (Join-Path $d 'libraries')) -and (Test-Path -LiteralPath (Join-Path $d 'assets'))) { $shared = Join-Path $d 'libraries' }
    }
}
$libraries = Join-Path $server 'libraries'
if ($shared) {
    $shared = $shared.TrimEnd('\')
    $item = Get-Item -LiteralPath $libraries -Force -ErrorAction SilentlyContinue
    if ($item -and -not $item.LinkType) {
        # Installed here before: move over what the shared folder lacks, then share
        robocopy $libraries $shared /E /MOVE /XC /XN /XO /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Could not move $libraries into $shared" }
        if (Test-Path -LiteralPath $libraries) { [IO.Directory]::Delete($libraries, $true) }
        $item = $null
    }
    if (-not $item -or @($item.Target)[0].TrimEnd('\') -ne $shared) {
        if ($item) { cmd /c rmdir "$libraries" }   # rmdir removes only the junction; Remove-Item could empty its target
        cmd /c mklink /J "$libraries" "$shared" | Out-Null
    }
}

# mods: the modpack's, minus CLIENT_ONLY_MODS (entries may use * and ?, e.g. oculus-mc1.20.1-*.jar)
$mods = Join-Path $server 'mods'
[void][IO.Directory]::CreateDirectory($mods)
$want = @{}; $used = @{}; $left = 0; $new = 0
foreach ($jar in @(Get-ChildItem -LiteralPath (Join-Path $client 'mods') -Filter *.jar)) {
    $hit = $skip | Where-Object { $jar.Name -like $_ } | Select-Object -First 1
    if ($hit) { $used[$hit] = $true; $left++; continue }
    $want[$jar.Name] = $true
    if (Link-File $jar.FullName (Join-Path $mods $jar.Name)) { $new++ }
}
$removed = 0
foreach ($jar in @(Get-ChildItem -LiteralPath $mods -Filter *.jar)) {
    if (-not $want.ContainsKey($jar.Name)) { [IO.File]::Delete($jar.FullName); $removed++ }
}

# $LinkFolders: the modpack's version of every file it has
$files = 0; $newFiles = 0; $copied = 0
foreach ($folder in $LinkFolders) {
    $from = Join-Path $client $folder
    if (-not (Test-Path -LiteralPath $from)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $from -Recurse -File -Force) {
        $relative = $file.FullName.Substring($client.Length + 1)
        $to = Join-Path $server $relative
        if ($CopyFiles | Where-Object { $relative -like $_ }) {
            # A fresh copy when missing, still a link from before, or older than the modpack's
            if (-not (Test-Path -LiteralPath $to) -or [Native.Fs]::Id($to) -eq [Native.Fs]::Id($file.FullName) -or
                $file.LastWriteTimeUtc -gt [IO.File]::GetLastWriteTimeUtc($to)) {
                if (Test-Path -LiteralPath $to) { [IO.File]::Delete($to) } else { [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($to)) }
                [IO.File]::Copy($file.FullName, $to); $copied++
            }
        } else {
            $files++
            if (Link-File $file.FullName $to) { $newFiles++ }
        }
    }
}

"Mods: $($want.Count) linked ($new new, $removed removed, $left client-only left out). $($LinkFolders -join ', '): $files files linked ($newFiles new), $copied copied."
"libraries: $(if ($shared) { "-> $shared" } else { 'no SHARED_LIBRARIES and no launcher folder above the modpack, so the loader installs into this folder' })"
$stale = @($skip | Where-Object { -not $used.ContainsKey($_) })
if ($stale) { "CLIENT_ONLY_MODS entries that match no mod (remove or fix them): $($stale -join ', ')" }
