param
(
    [string]
    $projectAssetsPath,
    [string]
    $projectDependencies,
    [string]
    $dependencies,
    [string]
    $transitiveDependencies,
    [string]
    $strongNameKeyPath,
    [string]
    $ilAsmPath,
    [string]
    $ilDasmPath
)

# $projectAssetsPath = 'D:\git\RessurectIT.Extensions.DependencyInjection.DryIoc\src\RessurectIT.Extensions.DependencyInjection.DryIoc\obj\project.assets.json'
# $projectDependencies = 'NETStandard.Library;Microsoft.Extensions.DependencyInjection.Abstractions;Microsoft.Extensions.Configuration.Abstractions;Microsoft.Extensions.DependencyModel;DryIoc.dll;DryIoc.Microsoft.DependencyInjection;DryIoc.MefAttributedModel.dll;RessurectIT.NuGet.Deployment;RessurectIT.Extensions.Common'
# $dependencies = ''
# $transitiveDependencies = ''
# $strongNameKeyPath = '..\..\.include\RessurectIT.snk'
# $ilAsmPath = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\ilasm.exe'
# $ilDasmPath = 'ildasm'

$script:dependenciesPaths = @()
$script:transitiveDependenciesNames = @()
$script:strongNameKeyToken = $null

#returns keys for json object
function Get-ObjectMembers($obj)
{
    if(!$obj)
    {
        return @()
    }

    $obj | Get-Member -MemberType NoteProperty | % { $key = $_.Name; @{ Key = $_.Name; Value = $obj."$key"} }
}

#finds dependency version pair for dependency name
function Find-DepVer($deps, $depName)
{
    $depsVers = Get-ObjectMembers $deps
    $depsVers | Where-Object Key -like "$depName/*" | % { $_.Key }
}

#adds dependencies and transitive dependencies for specified dependency
function Resolve-UnsignedDependency($nugetPackagesPaths, $deps, $requestedDep)
{
    Write-Host "Resolving NuGet package '$requestedDep'"

    #no compile not dll or not requested dependency found
    if(!$requestedDep -or !$deps."$requestedDep".compile)
    {
        return $false
    }

    $dllPath = (Get-ObjectMembers $deps."$requestedDep".compile | % {$_.Key})

    #no dll extension
    if($dllPath -notlike "*.dll")
    {
        return $false
    }

    $path = $null

    foreach($nugetPath in $nugetPackagesPaths)
    {
        $path = Join-Path $nugetPath (Join-Path $requestedDep $dllPath)

        if(Test-Path $path)
        {
            break
        }
        else
        {
            $path = $null
        }
    }

    #no package dll found
    if(!$path)
    {
        throw "Unable to find dll for package '$requestedDep'"
    }

    Write-Host "Resolved dll on path '$path'"

    #already have strong name
    if([Reflection.AssemblyName]::GetAssemblyName($path).GetPublicKeyToken())
    {
        return $false
    }

    #processing dependencies
    Get-ObjectMembers $deps."$requestedDep".dependencies | % {
        #transitive dependency already registered
        if($_.Key -notin $script:transitiveDependenciesNames)
        {
            $tmp = Find-DepVer $deps $_.Key

            #resolving transitive dependency itself
            if((Resolve-UnsignedDependency $nugetPackagesPaths $deps $tmp))
            {
                #adding dependency as transitive dependency
                $script:transitiveDependenciesNames += $_.Key
            }
        }
    }

    #add this library path also to dependencies
    if($path -notin $script:dependenciesPaths)
    {
        $script:dependenciesPaths += $path
    }

    return $true
}

if((!$dependencies) -and ((!(Test-Path $projectAssetsPath)) -or (!$projectDependencies)))
{
    Write-Host "Nothing to process!"

    return 0
}

#set dependencies
if($dependencies)
{
    $script:dependenciesPaths += $dependencies.Split(';')
}

#set transitive dependencies
if($transitiveDependencies)
{
    $script:transitiveDependenciesNames += $transitiveDependencies.Split(';')
}

#process projects assets json
if($projectDependencies -and (Test-Path $projectAssetsPath))
{
    $projectDependenciesNames = $projectDependencies.Split(';')
    $projectAssetsJson = Get-Content $projectAssetsPath -Encoding UTF8 | ConvertFrom-Json
    $nugetPackagesPaths = Get-ObjectMembers $projectAssetsJson.packageFolders | % { $_.Key }

    Get-ObjectMembers $projectAssetsJson.targets | % { $_.Value } | % {
        $deps = $_

        $projectDependenciesNames | % {
            $reqDep = Find-DepVer $deps $_

            Resolve-UnsignedDependency $nugetPackagesPaths $deps $reqDep | Out-Null
        }
    }
}

#remove duplicates
$script:transitiveDependenciesNames = $script:transitiveDependenciesNames | Select-Object -uniq | % { [System.IO.Path]::GetFileNameWithoutExtension($_) }
$script:dependenciesPaths = $script:dependenciesPaths | Select-Object -uniq

$script:transitiveDependenciesNames | % { Write-Host "Transitive dependency that will be updated '$_'" }

$script:dependenciesPaths | % {
    $dir = [System.IO.Path]::GetDirectoryName($_)
    $signedDir = Join-Path $dir 'signed'
    $filename = [System.IO.Path]::GetFileNameWithoutExtension($_)
    $ilFilename = Join-Path $signedDir "$filename.il"
    $signedDll = Join-Path $signedDir "$filename.dll"

    Write-Host "Signing following dll '$_'"

    #create signed dir if does not exists
    New-Item $signedDir -ItemType Directory -ErrorAction SilentlyContinue

    #disassemble dll
    & $ilDasmPath "$_" /out:"$ilFilename"

    #il content
    $content = (Get-Content $ilFilename -Encoding UTF8 | Out-String).Trim()

    #strong name token created
    if($script:strongNameKeyToken)
    {
        #find extern assemblies that are not signed
        $script:transitiveDependenciesNames | % {
            $content = [System.Text.RegularExpressions.Regex]::Replace($content, "(\.assembly extern $_\s+{)(.*?})", "`${1}`n  .publickeytoken = ($($script:strongNameKeyToken))`${2}", [System.Text.RegularExpressions.RegexOptions]::Singleline)
        }

        #store updated il
        Set-Content $ilFilename -Encoding UTF8 -Value $content
    }

    #sign and assemble assembly
    & $ilAsmPath "$ilFilename" /dll /key="$strongNameKeyPath" /output="$signedDll"

    #store strong name token
    $script:strongNameKeyToken = [System.BitConverter]::ToString([Reflection.AssemblyName]::GetAssemblyName($signedDll).GetPublicKeyToken()).Replace("-", " ")

    #copy signed assemblly
    Copy-Item $signedDll $_ -Force -ErrorAction SilentlyContinue

    #remove signed dir
    Remove-Item $signedDir -Force -Recurse -ErrorAction SilentlyContinue
}

Write-Host "Signing completed!"