# Localization (English / Hungarian). Language: settings.json "Language" = auto | en | hu

$script:Strings = @{
    en = @{
        AppName             = 'Docker Runner Autoscaler'
        # autoscaler
        Started             = 'started {0}'
        ScaledUp            = '{0} scaled up: {1} -> {2}'
        StoppedIdle         = '{0} stopped: {1} idle runner(s)'
        StopWaiting         = '{0} scale-down waiting: surplus runners are busy'
        ErrNoCompose        = 'docker-compose.yml not found in {0}'
        ErrNoDockerCli      = 'docker command not found - is Docker Desktop installed?'
        ErrDockerDown       = 'Docker is not reachable: {0}'
        ErrEmptyInfo        = 'empty response from docker info'
        # console
        ConsoleTitle        = '=== {0} ==='
        ModeAuto            = '    Mode: AUTOMATIC'
        ModeManual          = '    Mode: manual'
        Stale               = '    Warning: autoscaler has not updated for {0} s!'
        Starting            = '  The autoscaler is starting, wait a few seconds...'
        Error               = '  Error: {0}'
        Running             = '  Running:     {0}'
        Busy                = '  Busy:        {0}'
        Idle                = '  Idle:        {0}'
        Target              = '  Target:      {0}'
        TargetPending       = '{0}  (Enter: apply)'
        Recommended         = '  Recommended: {0}   ({1} CPU, {2} GB RAM)'
        OverCpu             = '  Warning: more runners than CPU threads'
        OverIdeal           = '  Above recommended: big jobs may run out of memory'
        DownIn              = '  {0} runner(s) will stop in {1} s'
        LastAction          = '  Last action: {0}'
        KeyHelp                = '  Up/Down: target   A: recommended   Enter: apply   M: auto/manual   Q: quit'
        KeysError           = '  Q: quit'
        MsgManual           = 'Manual mode, target: {0}'
        MsgAuto             = 'Automatic mode enabled.'
        # tray
        TrayOpen            = 'Open console'
        TrayAuto            = 'Automatic mode'
        TrayUpdate          = 'Check for updates'
        TrayVersion         = 'Version {0}'
        TrayExit            = 'Exit (stops autoscaling)'
        TrayTip             = 'Runners: {0} (busy {1}) | {2}{3}'
        TrayTipDown         = ' | stop in {0}s'
        TrayModeAuto        = 'auto'
        TrayModeManual      = 'manual'
        TrayNoResponse      = 'Autoscaler starting / not responding'
        TrayErr             = 'Error: {0}'
        # updater
        UpdAvailable        = 'Update available: {0} -> {1}. Installing...'
        UpdDone             = 'Updated to {0}. Restarting...'
        UpdNone             = 'You are on the latest version ({0}).'
        UpdFailed           = 'Update failed: {0}'
        UpdChecksum         = 'checksum mismatch'
        UpdNoAsset          = 'release has no package asset'
    }
    hu = @{
        AppName             = 'Docker Runner Autoscaler'
        Started             = 'elindult {0}'
        ScaledUp            = '{0} felskálázás: {1} -> {2}'
        StoppedIdle         = '{0} leállítva: {1} tétlen runner'
        StopWaiting         = '{0} leállítás vár: a fölösleges runnerek dolgoznak'
        ErrNoCompose        = 'Nem található docker-compose.yml itt: {0}'
        ErrNoDockerCli      = 'A docker parancs nem található - telepítve van a Docker Desktop?'
        ErrDockerDown       = 'A Docker nem érhető el: {0}'
        ErrEmptyInfo        = 'üres válasz a docker info-tól'
        ConsoleTitle        = '=== {0} ==='
        ModeAuto            = '    Mód: AUTOMATIKUS'
        ModeManual          = '    Mód: kézi'
        Stale               = '    Figyelem: az autoscaler {0} mp óta nem frissített!'
        Starting            = '  Az autoscaler indul, várj pár másodpercet...'
        Error               = '  Hiba: {0}'
        Running             = '  Futó:        {0}'
        Busy                = '  Dolgozik:    {0}'
        Idle                = '  Tétlen:      {0}'
        Target              = '  Cél:         {0}'
        TargetPending       = '{0}  (Enter: alkalmaz)'
        Recommended         = '  Ajánlott:    {0}   ({1} CPU, {2} GB RAM)'
        OverCpu             = '  Figyelem: több runner, mint CPU szál'
        OverIdeal           = '  Az ajánlott fölött: nagy jobok kevés memóriát kaphatnak'
        DownIn              = '  {0} runner leállítása {1} mp múlva'
        LastAction          = '  Utolsó művelet: {0}'
        KeyHelp                = '  Fel/Le: cél   A: ajánlott   Enter: alkalmaz   M: auto/kézi   Q: kilép'
        KeysError           = '  Q: kilép'
        MsgManual           = 'Kézi mód, cél: {0}'
        MsgAuto             = 'Automatikus mód bekapcsolva.'
        TrayOpen            = 'Konzol megnyitása'
        TrayAuto            = 'Automatikus mód'
        TrayUpdate          = 'Frissítés keresése'
        TrayVersion         = 'Verzió: {0}'
        TrayExit            = 'Kilépés (a skálázás leáll)'
        TrayTip             = 'Runner: {0} (dolg. {1}) | {2}{3}'
        TrayTipDown         = ' | leáll: {0}mp'
        TrayModeAuto        = 'auto'
        TrayModeManual      = 'kézi'
        TrayNoResponse      = 'Autoscaler indul / nem válaszol'
        TrayErr             = 'Hiba: {0}'
        UpdAvailable        = 'Új verzió: {0} -> {1}. Telepítés...'
        UpdDone             = 'Frissítve: {0}. Újraindítás...'
        UpdNone             = 'A legfrissebb verzió fut ({0}).'
        UpdFailed           = 'Frissítési hiba: {0}'
        UpdChecksum         = 'ellenőrzőösszeg eltérés'
        UpdNoAsset          = 'a kiadásban nincs telepítőcsomag'
    }
}

function Set-Language([string]$lang) {
    if (-not $lang -or $lang -eq 'auto') {
        $lang = if ((Get-Culture).TwoLetterISOLanguageName -eq 'hu') { 'hu' } else { 'en' }
    }
    $script:Lang = if ($script:Strings.ContainsKey($lang)) { $lang } else { 'en' }
}

# T 'Key' arg1 arg2 ...  -> localized, formatted string
function T([string]$Key) {
    $fmt = $script:Strings[$script:Lang][$Key]
    if (-not $fmt) { $fmt = $script:Strings['en'][$Key] }
    if (-not $fmt) { return $Key }
    if ($args.Count) { $fmt -f $args } else { $fmt }
}

Set-Language 'auto'
