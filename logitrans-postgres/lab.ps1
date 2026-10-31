param([ValidateSet('Start','Test','Status','Stop','Restart')][string]$Action='Start')
$ErrorActionPreference='Stop'
Set-Location $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding($false)
function DC([string[]]$Arguments) {
    $ErrorActionPreference='Continue'
    $result = & docker compose @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($result -join "`n") }
    return ($result -join "`n")
}
function SQL([string]$Node,[string]$Query) {
    $ErrorActionPreference='Continue'
    $result = $Query | & docker compose exec -T -u postgres -e 'PGOPTIONS=-c statement_timeout=15000' $Node psql -XqAt -v ON_ERROR_STOP=1 -d logitrans 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($result -join "`n") }
    return ($result -join "`n").Trim()
}
function Await([scriptblock]$Condition,[string]$Description,[int]$Seconds=90) {
    $deadline=(Get-Date).AddSeconds($Seconds)
    $last=''
    do {
        try { if (& $Condition) { return }; $last='condition false' } catch { $last=$_.Exception.Message }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw "Timeout: $Description ($last)"
}
function Ready {
    foreach($node in @('central-db','regional-db','bi-db')) {
        Await { (SQL $node 'SELECT 1') -eq '1' } "$node available"
    }
}
function Snapshot {
    $null=SQL 'central-db' 'SELECT pg_log_standby_snapshot()'
}
function Setup {
    if (!(Test-Path .env)) { Copy-Item .env.example .env }
    if (!(Test-Path .secrets)) { $null=New-Item .secrets -ItemType Directory }
    foreach($name in @('admin','physical','logical')) {
        if (!(Test-Path ".secrets/$name")) {
            $bytes=New-Object byte[] 32
            $rng=[System.Security.Cryptography.RandomNumberGenerator]::Create()
            $rng.GetBytes($bytes); $rng.Dispose()
            [IO.File]::WriteAllText((Join-Path $PSScriptRoot ".secrets/$name"),([BitConverter]::ToString($bytes).Replace('-','').ToLower()),$utf8)
        }
    }
    # Restrict local credentials to this Windows account and SYSTEM.
    $account=[System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $null=& icacls .secrets /inheritance:r /grant:r "${account}:(OI)(CI)F" 'SYSTEM:(OI)(CI)F' 2>&1
    if($LASTEXITCODE -ne 0) { throw 'Could not secure .secrets ACL' }
    DC @('up','-d','--wait','--wait-timeout','180') | Write-Host
    Ready
    Await { (SQL 'regional-db' "SELECT count(*) FROM pg_publication_tables WHERE pubname='pub_empleados'") -eq '1' } 'publication replayed'
    # CREATE SUBSCRIPTION and its initial sync may wait on a snapshot from the primary.
    $proc=New-Object System.Diagnostics.Process
    $proc.StartInfo.FileName='docker'
    $proc.StartInfo.Arguments='compose exec -T -u postgres bi-db bash /lab/subscribe.sh'
    $proc.StartInfo.UseShellExecute=$false
    $proc.StartInfo.CreateNoWindow=$true
    $proc.StartInfo.RedirectStandardOutput=$true
    $proc.StartInfo.RedirectStandardError=$true
    $null=$proc.Start()
    $deadline=(Get-Date).AddSeconds(120)
    do {
        Snapshot
        if($proc.HasExited) { break }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    if(!$proc.HasExited) { $proc.Kill(); throw 'Subscription creation exceeded 120 seconds; inspect slot state before retrying' }
    $proc.WaitForExit()
    $proc.StandardOutput.ReadToEnd() | Set-Content evidencias/subscription.stdout.txt
    $proc.StandardError.ReadToEnd() | Set-Content evidencias/subscription.stderr.txt
    if($proc.ExitCode -ne 0) { throw 'Subscription creation failed: inspect evidence (no connection string is printed)' }
    Await { Snapshot; (SQL 'bi-db' "SELECT count(*) FROM pg_subscription_rel WHERE srsubstate='r'") -eq '1' } 'initial copy ready' 120
}
function Check([string]$Id,[scriptblock]$Body) {
    try { & $Body; Write-Host "PASS $Id"; $script:results += "PASS $Id" }
    catch { Write-Host "FAIL $Id : $($_.Exception.Message)"; $script:results += "FAIL $Id : $($_.Exception.Message)"; $script:failures++ }
}
function Assert([bool]$Value,[string]$Message) { if(!$Value) { throw $Message } }
function Replicated([int]$Id,[string]$Expected) {
    foreach($node in @('regional-db','bi-db')) {
        Await { (SQL $node "SELECT nombre||'|'||departamento||'|'||salario FROM empleados WHERE id_empleado=$Id") -eq $Expected } "$node employee $Id = $Expected"
        $script:results += "Verified $node empleados[$Id] = $Expected"
    }
}
function TestLab {
    $script:results=@(); $script:failures=0
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    $marker='TEST_'+[Guid]::NewGuid().ToString('N')
    $script:employee=0; $script:delivery=0
    Check 'A versions and availability' {
        Ready
        $versions=@('central-db','regional-db','bi-db') | ForEach-Object { SQL $_ 'SHOW server_version' }
        Assert (($versions | Select-Object -Unique).Count -eq 1) "Different versions: $versions"
        Assert ($versions[0].StartsWith('18.')) "Expected PostgreSQL 18: $versions"
        $script:results += "Versions: $($versions -join ', ')"
    }
    Check 'B recovery roles' {
        Assert ((SQL 'central-db' 'SELECT pg_is_in_recovery()') -eq 'f') 'Primary in recovery'
        Assert ((SQL 'regional-db' 'SELECT pg_is_in_recovery()') -eq 't') 'Regional not a standby'
    }
    Check 'C physical WAL streaming' {
        Await { (SQL 'central-db' "SELECT count(*) FROM pg_stat_replication WHERE application_name='regional-db' AND state='streaming' AND client_addr='172.30.84.3'") -eq '1' } 'physical sender'
        Assert ((SQL 'regional-db' "SELECT count(*) FROM pg_stat_wal_receiver WHERE status='streaming' AND slot_name='regional_physical' AND sender_host='central-db' AND flushed_lsn IS NOT NULL") -eq '1') 'WAL receiver absent'
    }
    Check 'D INSERT and initial copy' {
        foreach($n in @('regional-db','bi-db')) { Await { (SQL $n "SELECT nombre||'|'||departamento||'|'||salario FROM empleados WHERE id_empleado=1") -eq 'Ana Mora|Operaciones|1250000' } 'seed exact values' }
        $script:employee=[int](SQL 'central-db' "INSERT INTO empleados(nombre,departamento,salario) VALUES ('$marker','Pruebas',1234.56) RETURNING id_empleado")
        Replicated $employee "$marker|Pruebas|1234.56"
        $script:results += "Employee ID=$employee marker=$marker"
    }
    Check 'E UPDATE exact values' {
        Assert ($employee -gt 0) 'Insert prerequisite failed'
        $null=SQL 'central-db' "UPDATE empleados SET departamento='Validado', salario=9876.54 WHERE id_empleado=$employee"
        Replicated $employee "$marker|Validado|9876.54"
    }
    Check 'G delivery only physical' {
        Assert ($employee -gt 0) 'Insert prerequisite failed'
        $script:delivery=[int](SQL 'central-db' "INSERT INTO entregas(fecha,destino,id_empleado) VALUES ('2026-10-30','$marker',$employee) RETURNING id_entrega").Split("`n")[0]
        Await { (SQL 'regional-db' "SELECT fecha||'|'||destino||'|'||id_empleado FROM entregas WHERE id_entrega=$delivery") -eq "2026-10-30|$marker|$employee" } 'delivery exact values'
        $script:results += "Verified regional-db entregas[$delivery] = 2026-10-30|$marker|$employee"
    }
    Check 'H BI has no entregas' { Assert ((SQL 'bi-db' "SELECT to_regclass('public.entregas') IS NULL") -eq 't') 'entregas exists in BI' }
    Check 'I real logical source and publication' {
        foreach($n in @('central-db','regional-db')) {
            Assert ((SQL $n "SELECT string_agg(schemaname||'.'||tablename,',') FROM pg_publication_tables WHERE pubname='pub_empleados'") -eq 'public.empleados') 'Wrong publication tables'
        }
        Assert ((SQL 'bi-db' "SELECT subenabled AND subpublications=ARRAY['pub_empleados']::text[] AND subconninfo LIKE 'host=regional-db port=5432 %' AND subslotname='bi_empleados' FROM pg_subscription WHERE subname='sub_empleados'") -eq 't') 'Wrong subscriber connection'
        Await { (SQL 'regional-db' "SELECT count(*) FROM pg_stat_replication r JOIN pg_replication_slots s ON s.active_pid=r.pid WHERE s.slot_name='bi_empleados' AND s.slot_type='logical' AND s.plugin='pgoutput' AND NOT s.synced AND r.client_addr='172.30.84.4' AND r.application_name='bi-empleados'") -eq '1' } 'BI connected to regional logical slot'
        Assert ((SQL 'central-db' "SELECT count(*) FROM pg_replication_slots WHERE slot_type='logical'") -eq '0') 'Unexpected logical slot on primary'
    }
    Check 'J roles privileges SCRAM HBA configuration' {
        Assert ((SQL 'central-db' "SELECT count(*) FROM pg_authid WHERE rolname IN ('repl_fisica','repl_logica') AND rolcanlogin AND rolreplication AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolbypassrls AND rolpassword LIKE 'SCRAM-SHA-256$%'") -eq '2') 'Replication roles not restricted/SCRAM'
        Assert ((SQL 'central-db' "SELECT has_table_privilege('repl_logica','empleados','SELECT') AND NOT has_table_privilege('repl_logica','entregas','SELECT') AND NOT has_table_privilege('repl_logica','empleados','INSERT') AND NOT has_schema_privilege('repl_logica','public','CREATE')") -eq 't') 'Excessive or missing privileges'
        foreach($n in @('central-db','regional-db','bi-db')) {
            Assert ((SQL $n "SELECT current_setting('password_encryption')='scram-sha-256' AND current_setting('wal_level')='logical' AND current_setting('max_wal_senders')::int>=10 AND current_setting('max_replication_slots')::int>=10") -eq 't') "$n parameters"
            Assert ((SQL $n "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL OR auth_method IN ('trust','md5')") -eq '0') "$n insecure/invalid HBA"
        }
        Assert ((SQL 'central-db' "SELECT count(*) FROM pg_hba_file_rules WHERE type='host' AND database=ARRAY['replication'] AND user_name=ARRAY['repl_fisica'] AND address='172.30.84.3' AND netmask='255.255.255.255' AND auth_method='scram-sha-256'") -eq '1') 'Physical HBA'
        Assert ((SQL 'regional-db' "SELECT count(*) FROM pg_hba_file_rules WHERE type='host' AND database=ARRAY['logitrans'] AND user_name=ARRAY['repl_logica'] AND address='172.30.84.4' AND netmask='255.255.255.255' AND auth_method='scram-sha-256'") -eq '1') 'Logical HBA'
        Assert ((SQL 'regional-db' "SELECT current_setting('hot_standby_feedback')='on' AND current_setting('primary_slot_name')='regional_physical'") -eq 't') 'Standby feedback/slot'
    }
    Check 'K standby rejects SQL writes' {
        Assert ((SQL 'regional-db' 'SHOW transaction_read_only') -eq 'on') 'Not read only'
        $denied=$false
        try { $null=SQL 'regional-db' 'BEGIN; CREATE TABLE public.must_never_exist(id int); ROLLBACK;' } catch { $denied=$_.Exception.Message -match 'read-only' }
        Assert $denied 'CREATE TABLE was not rejected as read-only'
        Assert ((SQL 'regional-db' "SELECT to_regclass('public.must_never_exist') IS NULL") -eq 't') 'Unexpected table'
    }
    Check 'L restart persistence and renewed replication' {
        Assert ($employee -gt 0 -and $delivery -gt 0) 'Persistence prerequisites missing'
        DC @('restart') | Write-Host
        Ready
        Replicated $employee "$marker|Validado|9876.54"
        Assert ((SQL 'central-db' "SELECT destino FROM entregas WHERE id_entrega=$delivery") -eq $marker) 'Primary persistence'
        Await { (SQL 'regional-db' "SELECT destino FROM entregas WHERE id_entrega=$delivery") -eq $marker } 'Standby persistence'
        $null=SQL 'central-db' "UPDATE empleados SET salario=9999.99 WHERE id_empleado=$employee"
        Replicated $employee "$marker|Validado|9999.99"
    }
    Check 'F DELETE replicated after restart' {
        Assert ($employee -gt 0) 'Insert prerequisite failed'
        $null=SQL 'central-db' "DELETE FROM entregas WHERE id_entrega=$delivery AND destino='$marker'; DELETE FROM empleados WHERE id_empleado=$employee AND nombre='$marker';"
        foreach($n in @('central-db','regional-db','bi-db')) {
            Await { (SQL $n "SELECT NOT EXISTS(SELECT 1 FROM empleados WHERE id_empleado=$employee)") -eq 't' } "$n employee deletion"
            $script:results += "Verified $n empleados[$employee] absent after DELETE"
        }
        Await { (SQL 'regional-db' "SELECT NOT EXISTS(SELECT 1 FROM entregas WHERE id_entrega=$delivery)") -eq 't' } 'delivery deletion'
    }
    Check 'FINAL subscription healthy and physical link restored' {
        Await { (SQL 'bi-db' "SELECT count(*) FROM pg_stat_subscription WHERE subname='sub_empleados' AND worker_type='apply' AND pid IS NOT NULL AND received_lsn IS NOT NULL") -eq '1' } 'apply worker'
        Assert ((SQL 'bi-db' "SELECT apply_error_count=0 AND sync_error_count=0 FROM pg_stat_subscription_stats WHERE subname='sub_empleados'") -eq 't') 'Subscription errors recorded'
        Assert ((SQL 'regional-db' 'SELECT pg_is_in_recovery()') -eq 't') 'Standby changed role'
        Assert ((SQL 'central-db' "SELECT count(*) FROM pg_stat_replication WHERE state='streaming' AND application_name='regional-db'") -eq '1') 'Physical stream not restored'
        Assert ((SQL 'bi-db' "SELECT to_regclass('public.entregas') IS NULL") -eq 't') 'BI separation'
    }
    $script:results += "Completed $(Get-Date -Format o); failures=$failures"
    $script:results | Set-Content "evidencias/tests-$stamp.txt" -Encoding UTF8
    Collect $stamp
    if($failures -gt 0) { throw "$failures failed checks; see evidencias/tests-$stamp.txt" }
}
function Collect([string]$Stamp) {
    DC @('ps') | Set-Content "evidencias/containers-$Stamp.txt" -Encoding UTF8
    foreach($n in @('central-db','regional-db','bi-db')) {
        # Conninfo is deliberately omitted. Password hashes are deliberately omitted.
        $queries=@('SELECT version(),pg_is_in_recovery();',
          'SELECT name,setting FROM pg_settings WHERE name IN (''wal_level'',''max_wal_senders'',''max_replication_slots'',''password_encryption'',''hot_standby_feedback'',''primary_slot_name'',''transaction_read_only'');',
          'SELECT rolname,rolcanlogin,rolreplication,rolsuper,rolcreatedb,rolcreaterole FROM pg_roles WHERE rolname LIKE ''repl_%'';',
          'SELECT * FROM pg_hba_file_rules;',
          'SELECT slot_name,slot_type,plugin,active,restart_lsn,confirmed_flush_lsn,invalidation_reason,synced FROM pg_replication_slots;',
          'SELECT application_name,client_addr,state,sent_lsn,write_lsn,flush_lsn,replay_lsn FROM pg_stat_replication;',
          'SELECT status,sender_host,slot_name,flushed_lsn FROM pg_stat_wal_receiver;',
          'SELECT * FROM pg_publication_tables;',
          'SELECT * FROM empleados ORDER BY id_empleado;',
          'SELECT subname,subenabled,subslotname,subpublications,split_part(subconninfo,'' password='',1) AS safe_endpoint FROM pg_subscription;',
          'SELECT * FROM pg_stat_subscription_stats;',
          'SELECT to_regclass(''public.entregas'');')
        $out=foreach($q in $queries) { "> $q"; SQL $n $q }
        $out | Set-Content "evidencias/state-$n-$Stamp.txt" -Encoding UTF8
        DC @('logs','--no-color','--timestamps',$n) | Set-Content "evidencias/log-$n-$Stamp.txt" -Encoding UTF8
    }
}
switch($Action) {
    Start { Setup; TestLab }
    Test { Ready; TestLab }
    Status { DC @('ps'); Collect (Get-Date -Format 'yyyyMMdd-HHmmss') }
    Stop { DC @('stop') }
    Restart { DC @('restart'); Ready }
}
