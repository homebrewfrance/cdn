$LogFile = "C:\Drivers\install_log.txt"
$DriversRoot = "C:\Drivers"
$BTRoot = Join-Path $DriversRoot "BluetoothLE"
$XboxRoot = Join-Path $DriversRoot "XboxBT"
$SevenZipCandidates = @("C:\Program Files\7-Zip\7z.exe","C:\Program Files (x86)\7-Zip\7z.exe")
$patternsToMatch = @("bthle","bthleenum","bthledevice","xboxgip","xboxgipsynthetic","xb1usb","xbox")

function Show-Banner {
    Clear-Host
    Write-Host "=========================================================================================" -ForegroundColor Cyan
    Write-Host "  ____ _____ _____ _       " -ForegroundColor Cyan
    Write-Host " | __ )_   _|  ___(_)_  __ " -ForegroundColor Cyan
    Write-Host " |  _ \ | | | |_  | \ \/ / " -ForegroundColor Cyan
    Write-Host " | |_) || | |  _| | |>  <  " -ForegroundColor Cyan
    Write-Host " |____/ |_| |_|   |_/_/\_\ " -ForegroundColor Cyan
    Write-Host "                           " -ForegroundColor Cyan
    Write-Host "                     [ For Windows 10 IoT Enterprise LTSC 2021 ]                         " -ForegroundColor Yellow
    Write-Host "=========================================================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Log($s, $color = "White"){ 
    $t = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    "$t`t$s" | Out-File -FilePath $LogFile -Append
    switch ($color) {
        "Green"  { Write-Host "[+] $s" -ForegroundColor Green }
        "Red"    { Write-Host "[!] $s" -ForegroundColor Red }
        "Yellow" { Write-Host "[-] $s" -ForegroundColor Yellow }
        "Blue"   { Write-Host "[i] $s" -ForegroundColor Cyan }
        default  { Write-Host "    $s" -ForegroundColor Gray }
    }
}

function Ensure-Admin { 
    if(-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){ 
        Show-Banner
        Log "!!!ERREUR FATALE!!! : Ce script doit etre execute en tant qu'Administrateur." "Red"
        Write-Host "`nPressez une touche pour quitter..." -ForegroundColor Yellow
        $null = [Console]::ReadKey()
        exit 1 
    } 
}

Ensure-Admin
Show-Banner

Remove-Item -Force -ErrorAction SilentlyContinue $LogFile
Log "Demarrage du script de restauration." "Blue"

$SevenZip = $SevenZipCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $SevenZip) { 
    Log "!!!ERREUR!!! 7-Zip introuvable. Installez 7-Zip puis relancez." "Red"
    exit 1 
}
Log "7-Zip detecte : $SevenZip" "Green"

$IsoRoot = (Get-PSDrive -PSProvider FileSystem | Where-Object { Test-Path (Join-Path $_.Root 'sources\install.wim') } | Select-Object -First 1).Root
if (-not $IsoRoot) {
    Write-Host ""
    Write-Host "Entrez la lettre du lecteur ISO contenant sources\install.wim (ex: E:)" -ForegroundColor Yellow
    $input = Read-Host "   (Ou laissez vide pour annuler)"
    if ([string]::IsNullOrWhiteSpace($input)) { 
        Log "Lettre ISO non fournie. Abandon du script." "Red"
        exit 1 
    }
    $IsoRoot = $input.TrimEnd('\')
}
$WimFile = Join-Path $IsoRoot "sources\install.wim"
if (-not (Test-Path $WimFile)) { 
    Log "!!!ERREUR!!! install.wim introuvable dans $WimFile" "Red"
    exit 1 
}
Log "Fichier source trouve : $WimFile" "Green"

Log "Nettoyage et preparation de l'espace de travail ($DriversRoot)..." "Blue"
if (Test-Path $DriversRoot) { Remove-Item -Recurse -Force $DriversRoot -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $BTRoot -Force | Out-Null
New-Item -ItemType Directory -Path $XboxRoot -Force | Out-Null

Log "Calcul et attribution des droits de securite (icacls)..." "Blue"
icacls $DriversRoot /grant "Administrators:(OI)(CI)F" /T | Out-Null

Log "Analyse de l'image Windows (Listing du DriverStore)..." "Blue"
$wimList = & $SevenZip l $WimFile 2>&1
$repoLines = $wimList | Select-String -Pattern "DriverStore\\FileRepository" | ForEach-Object { $_.ToString().Trim() } | Select-Object -Unique
if (-not $repoLines) { 
    Log "Aucune entree FileRepository trouvee dans le WIM de destination." "Red"
    exit 1 
}

$repoNames = $repoLines | ForEach-Object {
    if ($_ -match "DriverStore\\FileRepository\\([^\\]+)"){ $matches[1] } else { $null }
} | Where-Object { $_ } | Select-Object -Unique

$targetRepoNames = $repoNames | Where-Object { $n = $_; $patternsToMatch | ForEach-Object { if ($n -like "*$_*") { return $true } }; $false } | Select-Object -Unique
if (-not $targetRepoNames) {
    Log "!!!ERREUR!!! Aucun dossier correspondant aux pilotes recherches n'a ete trouve." "Red"
    exit 1
}

Log "Dossiers cibles identifies dans le WIM :" "Yellow"
$targetRepoNames | ForEach-Object { Log "  -> $_" "Gray" }

Write-Host ""
Log "Extraction des pilotes via 7-Zip..." "Blue"
$totalTargets = $targetRepoNames.Count
$current = 0

foreach ($name in $targetRepoNames) {
    $current++
    $percent = [Math]::Round(($current / $totalTargets) * 100)
    Write-Progress -Activity "Extraction des pilotes originaux" -Status "Extraction de : $name" -PercentComplete $percent
    
    $pattern = "1\Windows\System32\DriverStore\FileRepository\$name\*"
    Log "-> Extrait [$current/$totalTargets] : $name" "Gray"
    & $SevenZip x $WimFile -o"$DriversRoot" $pattern -y -aoa 2>&1 | Out-File -FilePath $LogFile -Append
}
Write-Progress -Activity "Extraction" -Completed

Log "Organisation et tri des dossiers extraits..." "Blue"
$extractedPkgDirs = Get-ChildItem -Path $DriversRoot -Directory | Where-Object { $_.Name -in $targetRepoNames }
foreach ($d in $extractedPkgDirs) {
    if ($d.Name -match "bthle|bthleenum|bthledevice") {
        $dest = Join-Path $BTRoot $d.Name
    } else {
        $dest = Join-Path $XboxRoot $d.Name
    }
    Move-Item -Path $d.FullName -Destination $dest -Force
}

Log "Verification de l'integrite des fichiers (.inf, .sys)..." "Blue"
$found = Get-ChildItem -Path $DriversRoot -Recurse -Include *.inf,*.sys,*.cat -ErrorAction SilentlyContinue
if (-not $found) { 
    Log "!!!ERREUR FATALE!!! : Aucun fichier .inf/.sys trouve apres l'extraction." "Red"
    exit 1 
}

$pkgDirs = Get-ChildItem -Path $DriversRoot -Recurse -Directory | Where-Object { (Get-ChildItem -Path $_.FullName -Filter *.inf -ErrorAction SilentlyContinue).Count -gt 0 }
if (-not $pkgDirs) { 
    Log "Aucun package valide contenant un fichier .inf n'a ete localise." "Red"
    exit 1 
}

Write-Host ""
Log "Injection et installation forcee des pilotes dans Windows..." "Yellow"
foreach ($pkg in $pkgDirs) {
    Log "Package detecte : $($pkg.Name)" "Blue"
    $infFiles = Get-ChildItem -Path $pkg.FullName -Filter *.inf -ErrorAction SilentlyContinue
    foreach ($inf in $infFiles) {
        Log "  Installation de : $($inf.Name)..." "Gray"
        $out = pnputil /add-driver "`"$($inf.FullName)`"" /install 2>&1
        $out | Out-File -FilePath $LogFile -Append
        
        if ($LASTEXITCODE -eq 0) {
            Log "    REUSSI" "Green"
        } else {
            Log "    ECHEC direct. Tentative via methode globale..." "Yellow"
            $pattern = Join-Path $pkg.FullName "*.inf"
            $out2 = pnputil /add-driver "`"$pattern`"" /install 2>&1
            $out2 | Out-File -FilePath $LogFile -Append
            if ($LASTEXITCODE -eq 0) { 
                Log "    REUSSI (Methode globale)" "Green" 
            } else { 
                Log "    ECHEC CRITIQUE pour ce dossier." "Red" 
            }
        }
    }
}

Write-Host ""
Log "Analyse finale des journaux..." "Blue"
$errors = Select-String -Path $LogFile -Pattern "ECHEC"
if ($errors) {
    Log "!!!ERREUR!!! Certains pilotes n'ont pas pu s'installer automatiquement :" "Red"
    $errors | ForEach-Object { Log "  $_" "Red" }
} else {
    Log "Tous les pilotes ont ete injectes avec succes !" "Green"
}

Write-Host ""
Write-Host "=========================================================================================" -ForegroundColor Cyan
Write-Host "                                     SCRIPT TERMINE                                      " -ForegroundColor Gold
Write-Host "=========================================================================================" -ForegroundColor Cyan
Write-Host " Log complet disponible ici : $LogFile" -ForegroundColor Gray
Write-Host ""
Write-Host " En cas de peripherique inconnu persistant :" -ForegroundColor Yellow
Write-Host " 1. Ouvrez le [Gestionnaire de peripheriques]." -ForegroundColor White
Write-Host " 2. Clic droit sur le peripherique en alerte -> [Mettre a jour le pilote]." -ForegroundColor White
Write-Host " 3. Choisissez [Parcourir mon ordinateur] et ciblez :" -ForegroundColor White
Write-Host "    $DriversRoot" -ForegroundColor Green
Write-Host " 4. Cochez bien [Inclure les sous-dossiers] puis validez." -ForegroundColor White
Write-Host "=========================================================================================" -ForegroundColor Cyan
Write-Host ""