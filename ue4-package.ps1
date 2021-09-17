# Packaging helper
# Bumps versions, builds, cooks, packages variants
# Put packageconfig.json in your project folder to configure
# See packageconfig_template.json
[CmdletBinding()] # Fail on unknown args
param (
    [string]$src,
    [switch]$major = $false,
    [switch]$minor = $false,
    [switch]$patch = $false,
    [switch]$hotfix = $false,
    # Explicit version to set
    [string]$version = "",
    # Force move tag
    [switch]$forcetag = $false,
    # Name of variant to build (optional, uses DefaultVariants from packageconfig.json if unspecified)
    [array]$variants,
    # Testing mode; skips clean checks, tags
    [switch]$test = $false,
    # Browse the output directory in file explorer after packaging
    [switch]$browse = $false,
    # VCS to use git, p4 or none. Defaults to git.
    [ValidateSet("git", "p4", "none")]
    [string]$vcs = "git",
    # If a VCS is used and the version was changed, use this flag to indicate that the change should be committed.
    [switch]$vcscommit = $false,
    # Dry-run; does nothing but report what *would* have happened
    [switch]$dryrun = $false,
    [switch]$help = $false
)

. $PSScriptRoot\inc\platform.ps1
. $PSScriptRoot\inc\packageconfig.ps1
. $PSScriptRoot\inc\projectversion.ps1
. $PSScriptRoot\inc\uproject.ps1
. $PSScriptRoot\inc\ueinstall.ps1
. $PSScriptRoot\inc\ueeditor.ps1
. $PSScriptRoot\inc\filetools.ps1


function Write-Usage {
    Write-Output "Steve's UE4 packaging tool"
    Write-Output "Usage:"
    Write-Output "  ue4-package.ps1 [-src:sourcefolder] [-major|-minor|-patch|-hotfix] [-force] [-variant=VariantName] [-test] [-dryrun]"
    Write-Output " "
    Write-Output "  -src          : Source folder (current folder if omitted), must contain packageconfig.json"
    Write-Output "  -major        : Increment major version i.e. [x++].0.0.0"
    Write-Output "  -minor        : Increment minor version i.e. x.[x++].0.0"
    Write-Output "  -patch        : Increment patch version i.e. x.x.[x++].0"
    Write-Output "  -hotfix       : Increment hotfix version i.e. x.x.x.[x++]"
    Write-Output "  -version      : Explicit version to set, i.e. 1.0.0.0"
    Write-Output "  -forcetag     : Move any existing version tag"
    Write-Output "  -variants Name1,Name2,Name3"
    Write-Output "                : Build only named variants instead of DefaultVariants from packageconfig.json"
    Write-Output "  -test         : Testing mode, separate builds, allow dirty working copy"
    Write-Output "  -browse       : After packaging, browse the output folder"
    Write-Output "  -vcs          : The VCS to use when modifying the version in ini file: git, p4 or none."
    Write-Output "  -vcscommit    : If the version ini was modified, commit the change via the vcs specified with -vcs."
    Write-Output "  -dryrun       : Don't perform any actual actions, just report on what you would do"
    Write-Output "  -help         : Print this help"
    Write-Output " "
    Write-Output "Environment Variables:"
    Write-Output "  You can set environment variables manually or via your system configuration:"
    Write-Output " "
    Write-Output "  UE4INSTALL   : Use a specific UE4 install."
    Write-Output "               : Default is to find one based on project version, under UE4ROOT"
    Write-Output "  UE4ROOT      : Parent folder of all binary UE4 installs (detects version). "
    Write-Output "               : Default C:\Program Files\Epic Games"
    Write-Output " "
}

if ($src.Length -eq 0) {
    $src = (Resolve-Path ".").Path
    Write-Verbose "-src not specified, assuming current directory"
}
else {
    $src = (Resolve-Path $src).Path
}

$ErrorActionPreference = "Stop"

if ($help) {
    Write-Usage
    Exit 0
}

Write-Output "~-~-~ UE4 Packaging Helper Start ~-~-~"

if ($test) {
    Write-Output "TEST MODE: No tagging, version bumping"
}

if (([bool]$major + [bool]$minor + [bool]$patch + [bool]$hotfix) -gt 1) {
    Write-Output "ERROR: Can't set more than one of major/minor/patch/hotfix at the same time!"
    Print-Usage
    Exit 5
}
$keepversion = $true
if (($major -or $minor -or $patch -or $hotfix)) {
    $keepversion = $false
}
# Trim leading and trailing spaces from version
$version = $version.Trim()
if ($version.Length -gt 0) {
    $setVersion = $true
    $keepversion = $false
}
else {
    $setVersion = $false
}

if (($major -or $minor -or $patch -or $hotfix) -and $setVersion) {
    Write-Output  "ERROR: Can't set version at the same time as major/minor/patch/hotfix!"
    Print-Usage
    Exit 5
}

# Detect Git
if ($vcs -eq "git") {
    if ($src -ne ".") { Push-Location $src }
    $isGit = Test-Path ".git"
    if ($src -ne ".") { Pop-Location }
}
else {
    $isGit = $false
}

# Check working copy is clean (Git only)
if (-not $test -and $isGit) {
    if ($src -ne ".") { Push-Location $src }

    if (Test-Path ".git") {
        git diff --no-patch --exit-code
        if ($LASTEXITCODE -ne 0) {
            Write-Output "Working copy is not clean (unstaged changes)"
            if ($dryrun) {
                Write-Output "dryrun: Continuing but this will fail without -dryrun"
            } else {
                Exit $LASTEXITCODE
            }
        }
        git diff --no-patch --cached --exit-code
        if ($LASTEXITCODE -ne 0) {
            Write-Output "Working copy is not clean (staged changes)"
            if ($dryrun) {
                Write-Output "dryrun: Continuing but this will fail without -dryrun"
            } else {
                Exit $LASTEXITCODE
            }
        }
    }
    if ($src -ne ".") { Pop-Location }
}


try {
    # Import config & project settings
    $config = Read-Package-Config -srcfolder:$src
    $projfile = Get-Uproject-Filename -srcfolder:$src -config:$config
    $proj = Read-Uproject $projfile
    $ueVersion = Get-UE-Version $proj
    $ueinstall = Get-UE-Install $ueVersion

    $chosenVariantNames = $config.DefaultVariants
    if ($variants) {
        $chosenVariantNames = $variants
    }
    # TODO support overriding default variants with args
    $chosenVariants = $config.Variants | Where-Object { $chosenVariantNames -contains $_.Name }

    if ($chosenVariants.Count -ne $chosenVariantNames.Count) {
        $unmatchedVariants = $chosenVariantNames | Where-Object { $chosenVariants.Name -notcontains $_ } 
        Write-Warning "Unknown variant(s) ignored: $($unmatchedVariants -join ", ")"
    }

    $foundmaps = Find-Files -startDir:$(Join-Path $src "Content") -pattern:*.umap -includeByDefault:$config.CookAllMaps -includeBaseNames:$config.MapsIncluded -excludeBaseNames:$config.MapsExcluded

    $maps = $foundmaps.BaseNames

    $mapsdesc = $maps ? $maps -join ", " : "Default (Project Settings)"

    Write-Output ""
    Write-Output "Project File    : $projfile"
    Write-Output "UE Version      : $ueVersion"
    Write-Output "UE Install      : $ueinstall"
    Write-Output "Output Folder   : $($config.OutputDir)"
    Write-Output "Zipped Folder   : $($config.ZipDir)"
    Write-Output ""
    Write-Output "Chosen Variants : $chosenVariantNames"
    Write-Output "Maps to Cook    : $mapsdesc"
    Write-Output ""

    if (-not $dryrun)
    {
        $editorprojname = [System.IO.Path]::GetFileNameWithoutExtension($projfile)
        Close-UE-Editor $editorprojname $dryrun
    }

    $versionNumber = $null
    $currentVersionNumber = Get-Project-Version $src
    # If -version is set but the value matches the current version, set keepversion
    if ($setVersion -and $currentVersionNumber -eq $version) {
        Write-Verbose "Current version ($currentVersionNumber) matches -version $version, not changing version."
        $keepversion = $true
    }

    if ($keepversion) {
        $versionNumber = $currentVersionNumber
    } else {
        # Bump up version, passthrough options
        if ($src -ne ".") { Push-Location $src }
        try {
            if (-not $dryrun) {
                $verIniFile = Get-Project-Version-Ini-Filename $src

                switch ($vcs) {
                    "git" {
                        if ($setVersion) {                        
                            $versionNumber = Set-Project-Version -srcfolder:$src -version:$version
                        }
                        else {
                            $versionNumber = Increment-Project-Version -srcfolder:$src -major:$major -minor:$minor -patch:$patch -hotfix:$hotfix
                        }
                        git add "$($verIniFile)"
                        if ($LASTEXITCODE -ne 0) { Exit $LASTEXITCODE }
                        if ($vcscommit) {
                            git commit -m "Set Version to $versionNumber"
                            if ($LASTEXITCODE -ne 0) { Exit $LASTEXITCODE }
                        }
                    }
                    "p4" {
                        # We cannot modify the file until it is checked out, so do dry run here to get the new version number for the changelist description
                        if ($setVersion) {                        
                            $versionNumber = $version
                        }
                        else {
                            $versionNumber = Increment-Project-Version -srcfolder:$src -major:$major -minor:$minor -patch:$patch -hotfix:$hotfix -dryrun:$true
                        }
                        $p4change = Write-Output "Change: new `nDescription: Set Version to $versionNumber" | p4 change -i | Select-String -Pattern "Change ([0-9]+)"
                        if ($LASTEXITCODE -ne 0) { Exit $LASTEXITCODE }
                        $p4change = $p4change.Matches[0].Groups[1].Value
                        p4 edit -c $p4change "$($verIniFile)"
                        $txtFile = (Join-Path "$src" DistBuildVersion.txt)
                        p4 edit -c $p4change "$($txtFile)"
                        if ($LASTEXITCODE -ne 0) { Exit $LASTEXITCODE }
                        # Actually increment the version
                        if ($setVersion) {                        
                            Set-Project-Version -srcfolder:$src -version:$version
                        }
                        else {
                            $versionNumber = Increment-Project-Version -srcfolder:$src -major:$major -minor:$minor -patch:$patch -hotfix:$hotfix
                        }
                        if ($vcscommit) {
                            p4 submit -c $p4change
                            if ($LASTEXITCODE -ne 0) { Exit $LASTEXITCODE }
                        }
                    }
                    "none" {
                        if ($setVersion) {                        
                            $versionNumber = Set-Project-Version -srcfolder:$src -version:$version
                        }
                        else {
                            $versionNumber = Increment-Project-Version -srcfolder:$src -major:$major -minor:$minor -patch:$patch -hotfix:$hotfix
                        }
                    }
                    Default {
                        Write-Output "-vcs has an unexpected value: $vcs"
                        Exit 5
                    }
                }
            }
            else {
                if ($setVersion) {                        
                    $versionNumber = $version
                }
                else {
                    $versionNumber = Increment-Project-Version -srcfolder:$src -major:$major -minor:$minor -patch:$patch -hotfix:$hotfix -dryrun:$true
                }
            }
        }
        catch {
            Write-Output $_.Exception.Message
            Exit 6
        }
        finally {
            if ($src -ne ".") { Pop-Location }
        }
    }
    # Keep test builds separate
    if ($test) {
        $versionNumber = "$versionNumber-test"
    }
    Write-Output "Next version will be: $versionNumber"

    # For tagging release
    # We only need to grab the main version once
    if ($vcs -eq "git" -and $vcscommit -and ((-not $keepversion) -or $forcetag)) {
        $forcearg = ""
        if ($forcetag) {
            $forcearg = "-f"
        }
        if (-not $test -and -not $dryrun) {
            if ($src -ne ".") { Push-Location $src }
            git tag $forcearg -a $versionNumber -m "Automated release tag"
            if ($LASTEXITCODE -ne 0) { Exit $LASTEXITCODE }
            if ($src -ne ".") { Pop-Location }
        }
    }

    $ueEditorCmd = Join-Path $ueinstall "Engine/Binaries/Win64/UE4Editor-Cmd$exeSuffix"
    $runUAT = Join-Path $ueinstall "Engine/Build/BatchFiles/RunUAT$batchSuffix"


    foreach ($var in $chosenVariants) {

        $outDir = Get-Package-Dir -config:$config -versionNumber:$versionNumber -variantName:$var.Name

        $argList = [System.Collections.ArrayList]@()
        $argList.Add("-ScriptsForProject=`"$projfile`"") > $null
        $argList.Add("BuildCookRun") > $null
        $argList.Add("-nocompileeditor") > $null
        #$argList.Add("-installed")  > $null # don't think we need this, seems to be detected
        $argList.Add("-nop4") > $null
        $argList.Add("-project=`"$projfile`"") > $null
        $argList.Add("-cook") > $null
        $argList.Add("-stage") > $null
        $argList.Add("-archive") > $null
        $argList.Add("-archivedirectory=`"$($outDir)`"") > $null
        $argList.Add("-package") > $null
        $argList.Add("-ue4exe=`"$ueEditorCmd`"") > $null
        if ($config.UsePak) {
            $argList.Add("-pak") > $null
        }
        $argList.Add("-prereqs") > $null
        $argList.Add("-nodebuginfo") > $null
        $argList.Add("-build") > $null
        $argList.Add("-target=$($config.Target)") > $null
        $argList.Add("-clientconfig=$($var.Configuration)") > $null
        $argList.Add("-targetplatform=$($var.Platform)") > $null
        $argList.Add("-utf8output") > $null
        if ($maps.Count) {
            $argList.Add("-Map=$($maps -join "+")") > $null
        }
        if ($var.Cultures) {
            $argList.Add("-cookcultures=$($var.Cultures -join "+")") > $null
        }
        $argList.Add($var.ExtraBuildArguments) > $null

        Write-Output "Building variant:  $($var.Name)"

        if ($dryrun) {
            Write-Output ""
            Write-Output "Would have run:"
            Write-Output "> $runUAT $($argList -join " ")"
            Write-Output ""

        } else {            
            $proc = Start-Process $runUAT $argList -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -ne 0) {
                throw "RunUAT failed!"
            }

        }

        if ($var.Zip) {
            if ($dryrun) {
                Write-Output "Would have compressed $outdir to $(Join-Path $config.ZipDir "$($config.Target)_$($versionNumber)_$($var.Name).zip")"
            } else {
                # We zip all subfolders of the out dir separately
                # Since there may be multiple build dirs in the case of server & client builds
                # E.g. WindowsNoEditor vs WindowsServer
                # BUT we omit the folder name in the zip if there's only one, for brevity         
                $subdirs = @(Get-ChildItem $outdir)
                $multipleBuilds = ($subdirs.Count > 1)
                $subdirs | ForEach-Object {
                    $zipsrc = "$($_.FullName)\*" # excludes folder name, compress contents
                    $subdirSuffix = ""
                    if ($multipleBuilds) {
                        # Only include "WindowsNoEditor" etc part if there's a need to disambiguate
                        $subdirSuffix = "_$($_.BaseName)"
                    }
                    $zipdst = Join-Path $config.ZipDir "$($config.Target)_$($versionNumber)_$($var.Name)$subdirSuffix.zip"

                    New-Item -ItemType Directory -Path $config.ZipDir -Force > $null
                    Write-Output "Compressing to $zipdst"
                    Compress-Archive -Path $zipsrc -DestinationPath $zipdst
                }

            }
        }
    }

    if ($browse -and -not $dryrun) {
        Invoke-Item $(Join-Path $config.OutputDir $versionNumber)
    }

}
catch {
    Write-Output $_.Exception.Message
    Write-Output "~-~-~ UE4 Packaging Helper FAILED ~-~-~"
    Exit 9
}

Write-Output "~-~-~ UE4 Packaging Helper Completed OK ~-~-~"
