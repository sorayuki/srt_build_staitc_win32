using namespace System;
using namespace System.Diagnostics;
using namespace System.Text;
using namespace System.IO;
using namespace System.Text.RegularExpressions;
using namespace System.Collections.Generic;

if ($PWD.Provider.Name -eq 'FileSystem') {
    [System.IO.Directory]::SetCurrentDirectory($PWD)
}

function GetProcessOutput {
    param (
        [string]$app_file,
        [string[]]$app_args
    )
    
    $procinfo = New-Object ProcessStartInfo
    $procinfo.FileName = $app_file
    $procinfo.RedirectStandardOutput = $true
    $procinfo.Arguments = $app_args
    $procinfo.UseShellExecute = $false
    $proc = New-Object Process
    $proc.StartInfo = $procinfo
    $proc.Start()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $proc.Dispose()
    return $stdout
}
$regex = New-Object Regex("refs/tags/(v(\d+)\.(\d+)\.(\d+))")

function GetGitLatestRelease {
    param (
        [string]$repo
    )
    $srt_rels = [string](GetProcessOutput -app_file "git.exe" -app_args "ls-remote", $repo)
    $mat_results = $regex.Matches($srt_rels)
    
    $vernum = 0
    $verstr = ""

    for ($i = 0; $i -lt $mat_results.Count; $i++) {
        $curver = [int]::Parse($mat_results[$i].Groups[2].Value) * 10000 + [int]::Parse($mat_results[$i].Groups[3].Value) * 100 + [int]::Parse($mat_results[$i].Groups[4].Value)
        if ($curver -gt $vernum) {
            $vernum = $curver
            $verstr = $mat_results[$i].Groups[1].Value
        }
    }

    if ($vernum -eq 0) {
        $verstr = "master"
    }

    return $verstr
}

function CloneGitLatestRelease {
    param (
        [string]$repo,
        [string]$dir
    )

    if ([Directory]::Exists($dir) -eq $false) {
        $release_tag = (GetGitLatestRelease -repo $repo)
        (git clone --depth=1 -b $release_tag $repo $dir)
    }
}

if ([Directory]::Exists("dist") -eq $true) { [Directory]::Delete("dist", $true) }
[Directory]::CreateDirectory("dist")
[Directory]::CreateDirectory("dist/win32")
[Directory]::CreateDirectory("dist/x64")

CloneGitLatestRelease -repo "https://github.com/fwbuilder/pthreads4w.git" -dir "pthreads4w"
CloneGitLatestRelease -repo "https://github.com/ARMmbed/mbedtls.git" -dir "mbedtls"
CloneGitLatestRelease -repo "https://github.com/Haivision/srt.git" -dir "srt"

$bits_list = ("win32", "x64")
$buildtypes = ("Debug", "Release")

$vsdir = (Get-VSSetupInstance -All | Select-VSSetupInstance -Latest).InstallationPath

# build pthreads
foreach ($bits in $bits_list) {
    Start-Process -WorkingDirectory "./pthreads4w" -Wait -NoNewWindow -FilePath "git.exe" -ArgumentList ("clean", "-xfd")
    if ($bits -eq "win32") { $varbits = "x86" }
    if ($bits -eq "x64") { $varbits = "x64" }

    $pt_header = [File]::ReadAllLines([string]"pthreads4w/pthread.h")
    $pt_newheader = New-Object List[string]
    foreach($x in $pt_header) {
        if ($x.Contains("#define") -eq $true) {
            if ($x.Contains(" __PTW32_VERSION ") -eq $true) {
                $pt_newheader.Add($x.Replace("__PTW32_VERSION", "PTW32_VERSION"))
            }
        }
        $pt_newheader.Add($x)
    }
    [File]::WriteAllLines([string]"pthreads4w/pthread.h", $pt_newheader)
    
    [File]::WriteAllLines([string]"pthreads4w/build.bat", [string[]]("call `"" + $vsdir + "\VC\Auxiliary\Build\vcvarsall.bat`" " + $varbits))
    [File]::AppendAllLines([string]"pthreads4w/build.bat", [string[]]("nmake VCE-static-debug VCE-static"))
    [File]::AppendAllLines([string]"pthreads4w/build.bat", [string[]]("nmake /I install"))
    Start-Process -WorkingDirectory "./pthreads4w" -Wait -NoNewWindow -FilePath "cmd.exe" -ArgumentList ("/c", "build.bat")
    [Directory]::Move("PTHREADS-BUILT", "dist/" + $bits + "/pthreads")
}

# build mbedtls
foreach ($bits in $bits_list) {
    foreach ($buildtype in $buildtypes) {
        Start-Process -WorkingDirectory "./mbedtls" -Wait -NoNewWindow -FilePath "git.exe" -ArgumentList ("clean", "-xfd")
        [File]::WriteAllLines([string]"mbedtls/build.bat", [string[]]("cmake -S . -B " + "build" + " -A " + $bits + " -DCMAKE_MSVC_RUNTIME_LIBRARY=`"MultiThreaded$<$<CONFIG:Debug>:Debug>`" -DCMAKE_BUILD_TYPE=" + $buildtype + " -DCMAKE_INSTALL_PREFIX=" + "../dist/" + $bits + "/" + $buildtype + " -DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF -DENABLE_SHARED=OFF -DENABLE_STATIC=ON"))
        [File]::AppendAllLines([string]"mbedtls/build.bat", [string[]]("cmake --build build --config " + $buildtype))
        [File]::AppendAllLines([string]"mbedtls/build.bat", [string[]]("cmake --install build --config " + $buildtype))
        Start-Process -WorkingDirectory "./mbedtls" -Wait -NoNewWindow -FilePath "cmd.exe" -ArgumentList ("/c", "build.bat")
    }
}

# build srt
foreach ($bits in $bits_list) {
    foreach ($buildtype in $buildtypes) {
        Start-Process -WorkingDirectory "./srt" -Wait -NoNewWindow -FilePath "git.exe" -ArgumentList ("clean", "-xfd")
        $mbedtlsdir = " -DMBEDTLS_PREFIX=../dist/" + $bits + "/" + $buildtype + "/mbedtls "
        $pthreaddir = " -DPTHREAD_INCLUDE_DIR=../dist/" + $bits + "/pthreads/include "
        $pthreaddir = $pthreaddir + " -DPTHREAD_LIBRARY=../dist/" + $bits + "/pthreads/lib/libpthreadVCE3"
        if ($buildtype -eq "Debug") {
            $pthreaddir = $pthreaddir + "d"
        }
        $pthreaddir = $pthreaddir + ".lib "

        [File]::WriteAllLines([string]"srt/build.bat", [string[]]("cmake -S . -B " + "build -A " + $bits + " -DCMAKE_CPP_FLAGS=`"-DPTW32_VERSION=1`" -DCMAKE_C_FLAGS=`"-DPTW32_VERSION=1`" -DCMAKE_MSVC_RUNTIME_LIBRARY=`"MultiThreaded$<$<CONFIG:Debug>:Debug>`" -DCMAKE_BUILD_TYPE=" + $buildtype + " -DCMAKE_INSTALL_PREFIX=" + "../dist/" + $bits + "/" + $buildtype + " -DENABLE_APPS=ON -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DUSE_ENCLIB=mbedtls" + $mbedtlsdir + $pthreaddir))
        [File]::AppendAllLines([string]"srt/build.bat", [string[]]("cmake --build build --config " + $buildtype))
        [File]::AppendAllLines([string]"srt/build.bat", [string[]]("cmake --install build --config " + $buildtype))
        Start-Process -WorkingDirectory "./srt" -Wait -NoNewWindow -FilePath "cmd.exe" -ArgumentList ("/c", "build.bat")
    }
}