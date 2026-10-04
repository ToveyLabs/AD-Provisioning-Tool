#requires -Version 5.1
<#
.SYNOPSIS
    AD User Provisioning Tool - CSV provisioning and OU password maintenance.
.NOTES
    Requires Windows PowerShell 5.1, WinForms and the ActiveDirectory (RSAT) module.
    Preview mode is enabled by default. This script never changes execution policy.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:State = [pscustomobject]@{
    Connection = [pscustomobject]@{
        IsValidated = $false; Server = ''; Domain = ''; DomainDN = ''; UpnSuffix = ''
        Credential = $null; CredentialIdentity = 'Current Windows credentials'
        ValidatedAt = $null; PasswordPolicy = $null
    }
    CsvPath = ''; CsvRows = @(); CsvColumns = @(); Mappings = @{}
    PreparedPlan = $null; SelectedGroups = @(); ImportResults = @()
    ResetUsers = @(); ResetResults = @(); AuditRows = @(); Logs = New-Object System.Collections.ArrayList
}
$script:UI = @{}
$script:BusyTimer = $null

function Add-AuditLog {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $line = '{0:u} [{1}] {2}' -f (Get-Date), $Level, $Message
    [void]$script:State.Logs.Add($line)
    if ($script:UI.ContainsKey('LogBox') -and $script:UI.LogBox) {
        $script:UI.LogBox.AppendText($line + [Environment]::NewLine)
    }
}

function Show-Message {
    param([string]$Text, [string]$Title = 'AD User Provisioning Tool',
          [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information)
    [void][System.Windows.Forms.MessageBox]::Show($script:UI.Form, $Text, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK, $Icon)
}

function Set-Status { param([string]$Text) $script:UI.Status.Text = $Text; [System.Windows.Forms.Application]::DoEvents() }

function Get-ADCommonParameters {
    if (-not $script:State.Connection.IsValidated) { throw 'No currently validated Active Directory connection.' }
    $p = @{ Server = $script:State.Connection.Server; ErrorAction = 'Stop' }
    if ($null -ne $script:State.Connection.Credential) { $p.Credential = $script:State.Connection.Credential }
    return $p
}

function Invoke-ADConnectionValidation {
    param([string]$Server, [System.Management.Automation.PSCredential]$Credential)
    Import-Module ActiveDirectory -ErrorAction Stop
    $p = @{ Server = $Server; ErrorAction = 'Stop' }
    if ($null -ne $Credential) { $p.Credential = $Credential }
    $domain = Get-ADDomain @p
    $policy = Get-ADDefaultDomainPasswordPolicy @p
    return [pscustomobject]@{ Domain = $domain; Policy = $policy }
}

function Test-CurrentADConnection {
    if (-not $script:State.Connection.IsValidated) { return $false }
    try {
        $p = Get-ADCommonParameters
        $domain = Get-ADDomain @p
        if ($domain.DNSRoot -ne $script:State.Connection.Domain) { throw 'The validated domain changed.' }
        $script:State.Connection.ValidatedAt = Get-Date
        return $true
    } catch {
        Disconnect-ADConnection
        Add-AuditLog "Connection validation failed: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Update-ConnectionBanner {
    if ($script:State.Connection.IsValidated) {
        $script:UI.ConnectionStatus.Text = 'CONNECTED'
        $script:UI.ConnectionStatus.ForeColor = [System.Drawing.Color]::DarkGreen
        $script:UI.ConnectionDetail.Text = '{0} via {1}' -f $script:State.Connection.Domain, $script:State.Connection.Server
        $script:UI.CredentialDetail.Text = $script:State.Connection.CredentialIdentity
        $script:UI.DisconnectButton.Enabled = $true
        $script:UI.ConnectButton.Text = 'Reconnect'
    } else {
        $script:UI.ConnectionStatus.Text = 'DISCONNECTED'
        $script:UI.ConnectionStatus.ForeColor = [System.Drawing.Color]::DarkRed
        $script:UI.ConnectionDetail.Text = 'No validated AD connection'
        $script:UI.CredentialDetail.Text = 'Current Windows credentials'
        $script:UI.DisconnectButton.Enabled = $false
        $script:UI.ConnectButton.Text = 'Connect'
    }
    Update-ModeBanner
}

function Update-ModeBanner {
    if ($script:UI.PreviewMode.Checked) {
        $script:UI.ModeLabel.Text = 'PREVIEW - no AD changes'
        $script:UI.ModeLabel.ForeColor = [System.Drawing.Color]::DarkBlue
    } else {
        $script:UI.ModeLabel.Text = 'LIVE - AD changes enabled'
        $script:UI.ModeLabel.ForeColor = [System.Drawing.Color]::DarkRed
    }
}

function Disconnect-ADConnection {
    $script:State.Connection.IsValidated = $false
    $script:State.Connection.Server = ''
    $script:State.Connection.Domain = ''
    $script:State.Connection.DomainDN = ''
    $script:State.Connection.UpnSuffix = ''
    $script:State.Connection.Credential = $null
    $script:State.Connection.CredentialIdentity = 'Current Windows credentials'
    $script:State.Connection.ValidatedAt = $null
    $script:State.Connection.PasswordPolicy = $null
    Invalidate-PreparedPlan 'AD connection changed.'
    Invalidate-ResetSelection 'AD connection changed.'
    if ($script:UI.ContainsKey('ConnectionStatus')) { Update-ConnectionBanner }
}

function Show-ConnectDialog {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Connect to Active Directory'; $f.StartPosition = 'CenterParent'; $f.Size = '520,285'
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $t = New-Object System.Windows.Forms.TableLayoutPanel
    $t.Dock = 'Fill'; $t.Padding = New-Object System.Windows.Forms.Padding(14); $t.ColumnCount = 2; $t.RowCount = 6
    [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute',145)))
    [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent',100)))
    $server = New-Object System.Windows.Forms.TextBox; $server.Dock='Fill'; $server.Text = if ($env:USERDNSDOMAIN) { $env:USERDNSDOMAIN } else { '' }
    $alternate = New-Object System.Windows.Forms.CheckBox; $alternate.Text='Use alternate credentials'; $alternate.AutoSize=$true
    $user = New-Object System.Windows.Forms.TextBox; $user.Dock='Fill'; $user.Enabled=$false
    $pass = New-Object System.Windows.Forms.TextBox; $pass.Dock='Fill'; $pass.UseSystemPasswordChar=$true; $pass.Enabled=$false
    $note = New-Object System.Windows.Forms.Label; $note.Text='Username may be DOMAIN\username or user@domain.example.'; $note.Dock='Fill'; $note.AutoSize=$true
    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel; $buttons.FlowDirection='RightToLeft'; $buttons.Dock='Fill'
    $ok=New-Object System.Windows.Forms.Button; $ok.Text='Connect'; $ok.DialogResult='OK'; $ok.AutoSize=$true
    $cancel=New-Object System.Windows.Forms.Button; $cancel.Text='Cancel'; $cancel.DialogResult='Cancel'; $cancel.AutoSize=$true
    [void]$buttons.Controls.Add($ok); [void]$buttons.Controls.Add($cancel)
    $labels=@('Domain controller or domain:','','Username:','Password:','','')
    $controls=@($server,$alternate,$user,$pass,$note,$buttons)
    for($i=0;$i -lt $controls.Count;$i++){ $l=New-Object System.Windows.Forms.Label; $l.Text=$labels[$i]; $l.AutoSize=$true; $l.Anchor='Left'; [void]$t.Controls.Add($l,0,$i); [void]$t.Controls.Add($controls[$i],1,$i) }
    $alternate.Add_CheckedChanged({ $user.Enabled=$alternate.Checked; $pass.Enabled=$alternate.Checked })
    $f.AcceptButton=$ok; $f.CancelButton=$cancel; $f.Controls.Add($t)
    try {
        if ($f.ShowDialog($script:UI.Form) -ne 'OK') { return }
        if ([string]::IsNullOrWhiteSpace($server.Text)) { Show-Message 'Enter a domain or domain controller.' 'Connection' 'Warning'; return }
        $cred=$null; $identity='Current Windows credentials'
        if ($alternate.Checked) {
            $identity=$user.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($identity) -or [string]::IsNullOrEmpty($pass.Text)) { Show-Message 'Enter both the alternate username and password.' 'Connection' 'Warning'; return }
            if (($identity -notmatch '^[^\\]+\\[^\\]+$') -and ($identity -notmatch '^[^@\s]+@[^@\s]+$')) { Show-Message 'Use DOMAIN\username or a UPN such as user@domain.example.' 'Connection' 'Warning'; return }
            $secure=ConvertTo-SecureString -String $pass.Text -AsPlainText -Force
            $cred=New-Object System.Management.Automation.PSCredential($identity,$secure)
        }
        Set-Status 'Validating the AD connection...'
        $validated=Invoke-ADConnectionValidation -Server $server.Text.Trim() -Credential $cred
        $script:State.Connection.IsValidated=$true
        $script:State.Connection.Server=$server.Text.Trim()
        $script:State.Connection.Domain=$validated.Domain.DNSRoot
        $script:State.Connection.DomainDN=$validated.Domain.DistinguishedName
        $script:State.Connection.UpnSuffix=$validated.Domain.DNSRoot
        $script:State.Connection.Credential=$cred
        $script:State.Connection.CredentialIdentity=$identity
        $script:State.Connection.ValidatedAt=Get-Date
        $script:State.Connection.PasswordPolicy=$validated.Policy
        if ([string]::IsNullOrWhiteSpace($script:UI.UpnSuffix.Text)) { $script:UI.UpnSuffix.Text=$validated.Domain.DNSRoot }
        Update-ConnectionBanner
        Invalidate-PreparedPlan 'AD connection changed.'
        Invalidate-ResetSelection 'AD connection changed.'
        Add-AuditLog "Validated connection to $($validated.Domain.DNSRoot) using $identity."
        Set-Status 'Connected.'
    } catch {
        Disconnect-ADConnection
        Show-Message "Connection failed:`r`n$($_.Exception.Message)" 'Connection failed' 'Error'
        Set-Status 'Connection failed.'
    } finally {
        $pass.Clear(); $f.Dispose()
    }
}

function Get-CryptoIndex {
    param([int]$Maximum)
    if ($Maximum -le 0) { throw 'Maximum must be positive.' }
    $rng=[System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes=New-Object byte[] 4
        $limit=[uint32]::MaxValue - ([uint32]::MaxValue % [uint32]$Maximum)
        do { $rng.GetBytes($bytes); $value=[BitConverter]::ToUInt32($bytes,0) } while ($value -ge $limit)
        return [int]($value % [uint32]$Maximum)
    } finally { $rng.Dispose() }
}

function New-SecurePassword {
    param([ValidateRange(6,128)][int]$Length=6)
    $upper='ABCDEFGHJKLMNPQRSTUVWXYZ'; $lower='abcdefghijkmnopqrstuvwxyz'; $digits='23456789'; $special='!@#$%_-+='
    $chars=New-Object System.Collections.Generic.List[char]
    foreach($set in @($upper,$lower,$digits,$special)){ $chars.Add($set[(Get-CryptoIndex $set.Length)]) }
    $all=$upper+$lower+$digits+$special
    while($chars.Count -lt $Length){ $chars.Add($all[(Get-CryptoIndex $all.Length)]) }
    for($i=$chars.Count-1;$i -gt 0;$i--){ $j=Get-CryptoIndex ($i+1); $tmp=$chars[$i]; $chars[$i]=$chars[$j]; $chars[$j]=$tmp }
    return -join $chars.ToArray()
}

function Test-PasswordAgainstPolicy {
    param([string]$Password)
    $minimum=6; $complex=$true
    if ($script:State.Connection.PasswordPolicy) {
        $minimum=[Math]::Max(6,[int]$script:State.Connection.PasswordPolicy.MinPasswordLength)
        $complex=[bool]$script:State.Connection.PasswordPolicy.ComplexityEnabled
    }
    $problems=New-Object System.Collections.Generic.List[string]
    if ($Password.Length -lt $minimum) { $problems.Add("Password must be at least $minimum characters.") }
    if ($complex) {
        $classes=0; if($Password -cmatch '[A-Z]'){$classes++}; if($Password -cmatch '[a-z]'){$classes++}; if($Password -match '[0-9]'){$classes++}; if($Password -match '[^A-Za-z0-9]'){$classes++}
        if($classes -lt 3){$problems.Add('Password does not satisfy the practical complexity check (three of four character classes).')}
    }
    return $problems.ToArray()
}

function Escape-LdapFilterValue {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return $Value.Replace('\','\5c').Replace('*','\2a').Replace('(','\28').Replace(')','\29').Replace(([string][char]0),'\00')
}

function Invalidate-PreparedPlan {
    param([string]$Reason='Settings changed.')
    if ($null -ne $script:State.PreparedPlan) {
        foreach($row in $script:State.PreparedPlan.Rows){$row.Password=$null}
        $script:State.PreparedPlan.Settings.CustomPassword=$null
        Add-AuditLog "Prepared import invalidated: $Reason" 'WARN'
    }
    $script:State.PreparedPlan=$null
    if ($script:UI.ContainsKey('RunImport')) { $script:UI.RunImport.Enabled=$false }
}

function Invalidate-ResetSelection {
    param([string]$Reason='Password-maintenance settings changed.')
    if($script:State.ResetUsers.Count -gt 0){Add-AuditLog "Password-maintenance selection invalidated: $Reason" 'WARN'}
    $script:State.ResetUsers=@()
    if($script:UI.ContainsKey('ResetGrid') -and $script:UI.ResetGrid){$script:UI.ResetGrid.DataSource=$null}
    if($script:UI.ContainsKey('ResetCount') -and $script:UI.ResetCount){$script:UI.ResetCount.Text='Exactly 0 account(s) selected'}
}

function New-Label { param([string]$Text) $x=New-Object System.Windows.Forms.Label; $x.Text=$Text; $x.AutoSize=$true; $x.Anchor='Left'; return $x }
function New-Button { param([string]$Text) $x=New-Object System.Windows.Forms.Button; $x.Text=$Text; $x.AutoSize=$true; $x.Margin=New-Object System.Windows.Forms.Padding(4); return $x }
function New-Group { param([string]$Text) $x=New-Object System.Windows.Forms.GroupBox; $x.Text=$Text; $x.Dock='Fill'; $x.AutoSize=$false; $x.Padding=New-Object System.Windows.Forms.Padding(8); return $x }
function New-Grid {
    $g=New-Object System.Windows.Forms.DataGridView; $g.Dock='Fill'; $g.AllowUserToAddRows=$false; $g.AllowUserToDeleteRows=$false
    $g.AutoGenerateColumns=$true; $g.AutoSizeColumnsMode='DisplayedCells'; $g.SelectionMode='FullRowSelect'; $g.MultiSelect=$false
    $g.BackgroundColor=[System.Drawing.Color]::White; return $g
}

function ConvertTo-BindableList {
    param([object[]]$Items)
    $list=New-Object System.Collections.ArrayList
    foreach($item in @($Items)){[void]$list.Add($item)}
    Write-Output -NoEnumerate $list
}

function Select-ADObjectDialog {
    param([ValidateSet('Container','Group')][string]$Kind)
    if (-not (Test-CurrentADConnection)) { Show-Message 'Connect to Active Directory first.' 'AD connection required' 'Warning'; return $null }
    try {
        $p=Get-ADCommonParameters
        if($Kind -eq 'Group') { $items=@(Get-ADGroup -Filter * @p | Sort-Object Name | Select-Object Name,DistinguishedName) }
        else {
            $p.SearchBase=$script:State.Connection.DomainDN; $p.SearchScope='Subtree'; $p.LDAPFilter='(|(objectClass=organizationalUnit)(objectClass=container))'
            $items=@(Get-ADObject @p -Properties CanonicalName | Sort-Object CanonicalName | Select-Object Name,DistinguishedName,CanonicalName)
        }
        $f=New-Object System.Windows.Forms.Form; $f.Text="Select AD $Kind"; $f.Size='850,560'; $f.StartPosition='CenterParent'
        $layout=New-Object System.Windows.Forms.TableLayoutPanel; $layout.Dock='Fill'; $layout.RowCount=3; $layout.ColumnCount=1
        [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute',38))); [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent',100))); [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute',45)))
        $filter=New-Object System.Windows.Forms.TextBox; $filter.Dock='Fill'
        $grid=New-Grid; $grid.ReadOnly=$true; $grid.DataSource=ConvertTo-BindableList $items
        $buttons=New-Object System.Windows.Forms.FlowLayoutPanel; $buttons.Dock='Fill'; $buttons.FlowDirection='RightToLeft'
        $ok=New-Button 'Select'; $ok.DialogResult='OK'; $cancel=New-Button 'Cancel'; $cancel.DialogResult='Cancel'; $buttons.Controls.AddRange(@($ok,$cancel))
        $filter.Add_TextChanged({
            $needle=$filter.Text
            $filtered=if([string]::IsNullOrWhiteSpace($needle)){$items}else{@($items|Where-Object{$_.Name -like "*$needle*" -or $_.DistinguishedName -like "*$needle*"})}
            $grid.DataSource=ConvertTo-BindableList @($filtered)
        })
        $grid.Add_CellDoubleClick({if($grid.CurrentRow){$f.DialogResult='OK';$f.Close()}})
        $layout.Controls.Add($filter,0,0);$layout.Controls.Add($grid,0,1);$layout.Controls.Add($buttons,0,2);$f.Controls.Add($layout);$f.AcceptButton=$ok;$f.CancelButton=$cancel
        $result=$null; if($f.ShowDialog($script:UI.Form) -eq 'OK' -and $grid.CurrentRow){$result=$grid.CurrentRow.DataBoundItem}
        $f.Dispose(); return $result
    } catch { Show-Message "Could not load AD objects:`r`n$($_.Exception.Message)" 'AD browse error' 'Error'; return $null }
}

function Show-GroupSelector {
    if (-not (Test-CurrentADConnection)) { Show-Message 'Connect to Active Directory first.' 'AD connection required' 'Warning'; return }
    try {
        $p=Get-ADCommonParameters; $groups=@(Get-ADGroup -Filter * @p | Sort-Object Name)
        $f=New-Object System.Windows.Forms.Form; $f.Text='Select security groups';$f.Size='700,550';$f.StartPosition='CenterParent'
        $cl=New-Object System.Windows.Forms.CheckedListBox;$cl.Dock='Fill';$cl.CheckOnClick=$true
        $selectedGroupDNs=@($script:State.SelectedGroups|ForEach-Object{$_.DistinguishedName})
        foreach($g in $groups){$idx=$cl.Items.Add($g);if($selectedGroupDNs -contains $g.DistinguishedName){$cl.SetItemChecked($idx,$true)}}
        $cl.DisplayMember='Name'
        $buttons=New-Object System.Windows.Forms.FlowLayoutPanel;$buttons.Dock='Bottom';$buttons.Height=44;$buttons.FlowDirection='RightToLeft'
        $ok=New-Button 'Use selected groups';$ok.DialogResult='OK';$cancel=New-Button 'Cancel';$cancel.DialogResult='Cancel';$buttons.Controls.AddRange(@($ok,$cancel));$f.Controls.Add($cl);$f.Controls.Add($buttons)
        if($f.ShowDialog($script:UI.Form) -eq 'OK'){$chosen=New-Object System.Collections.Generic.List[object];foreach($item in $cl.CheckedItems){[void]$chosen.Add($item)};$script:State.SelectedGroups=@($chosen.ToArray());$script:UI.GroupSummary.Text=if($script:State.SelectedGroups.Count){@($script:State.SelectedGroups|ForEach-Object{$_.Name}) -join '; '}else{'None'};Invalidate-PreparedPlan 'Group selection changed.'}
        $f.Dispose()
    }catch{Show-Message "Could not load groups:`r`n$($_.Exception.Message)" 'Group selection' 'Error'}
}

function Import-CsvFile {
    $d=New-Object System.Windows.Forms.OpenFileDialog;$d.Filter='CSV files (*.csv)|*.csv|All files (*.*)|*.*'
    if($d.ShowDialog($script:UI.Form) -ne 'OK'){$d.Dispose();return}
    try{
        $rows=@(Import-Csv -LiteralPath $d.FileName -ErrorAction Stop)
        if($rows.Count -eq 0){throw 'The CSV contains no data rows.'}
        $columns=@($rows[0].PSObject.Properties.Name)
        if($columns.Count -eq 0){throw 'The CSV has no column headers.'}
        $script:State.CsvPath=$d.FileName;$script:State.CsvRows=$rows;$script:State.CsvColumns=$columns
        $script:UI.CsvPath.Text=$d.FileName;$script:UI.CsvPreview.DataSource=ConvertTo-BindableList $rows
        foreach($entry in $script:UI.MapControls.GetEnumerator()){
            $entry.Value.Items.Clear();[void]$entry.Value.Items.Add('(not mapped)');foreach($c in $columns){[void]$entry.Value.Items.Add($c)}
            $patterns=switch($entry.Key){'FirstName'{'^(first.?name|given.?name|forename)$'}'LastName'{'^(last.?name|surname|family.?name)$'}'EmployeeID'{'^(student.?id|employee.?id|id)$'}'Email'{'^(email|email.?address)$'}'YearGroup'{'^(year|year.?group)$'}'FormGroup'{'^(form|form.?group|tutor.?group)$'}'Department'{'^department$'}'Title'{'^(title|job.?title|position)$'}'Office'{'^(office|location|room)$'}'Telephone'{'^(telephone|phone|office.?phone)$'}}
            $guess=$columns|Where-Object{$_ -match $patterns}|Select-Object -First 1
            $entry.Value.SelectedItem=if($guess){$guess}else{'(not mapped)'}
        }
        Invalidate-PreparedPlan 'A new CSV was loaded.';Add-AuditLog "Loaded CSV '$($d.FileName)' with $($rows.Count) rows.";Set-Status 'CSV loaded. Review column mappings.'
    }catch{Show-Message "CSV load failed:`r`n$($_.Exception.Message)" 'CSV error' 'Error'}finally{$d.Dispose()}
}

function Get-MappedValue { param($Row,[string]$Key,[hashtable]$Mapping) $column=$Mapping[$Key];if([string]::IsNullOrWhiteSpace($column)){return ''};$prop=$Row.PSObject.Properties[$column];if($null -eq $prop -or $null -eq $prop.Value){return ''};return $prop.Value.ToString().Trim() }
function ConvertTo-SamFragment { param([string]$Value) if($null -eq $Value){return ''};return (($Value.Normalize([Text.NormalizationForm]::FormD).ToCharArray()|Where-Object{[Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark'}) -join '' -replace '[^A-Za-z0-9._-]','').ToLowerInvariant() }

function New-Username {
    param([string]$First,[string]$Last,[string]$EmployeeID,[string]$Email,[string]$Format)
    $f=ConvertTo-SamFragment $First;$l=ConvertTo-SamFragment $Last;$id=ConvertTo-SamFragment $EmployeeID
    $name=switch($Format){'First.Last'{"$f.$l"}'First initial + last'{if($f){$f.Substring(0,1)+$l}else{''}}'First + last'{"$f$l"}'Employee/student ID'{$id}'Email prefix'{if($Email -match '^([^@]+)@') {ConvertTo-SamFragment $matches[1]}else{''}}default{"$f.$l"}}
    if($name.Length -gt 20){$name=$name.Substring(0,20)};return $name.Trim('.','-','_')
}

function Get-CurrentMapping {
    $m=@{};foreach($entry in $script:UI.MapControls.GetEnumerator()){$m[$entry.Key]=if($entry.Value.SelectedItem -and $entry.Value.SelectedItem.ToString() -ne '(not mapped)'){$entry.Value.SelectedItem.ToString()}else{''}}
    return $m
}

function Get-ImportSettingsSnapshot {
    return [pscustomobject]@{
        CreatedAt=Get-Date;CsvPath=$script:State.CsvPath;Mapping=Get-CurrentMapping;UsernameFormat=$script:UI.UsernameFormat.SelectedItem.ToString()
        TargetOU=$script:UI.TargetOU.Text.Trim();UpnSuffix=$script:UI.UpnSuffix.Text.Trim();PasswordMode=$script:UI.ImportPasswordMode.SelectedItem.ToString()
        PasswordLength=[int]$script:UI.ImportPasswordLength.Value;CustomPassword=$script:UI.ImportCustomPassword.Text
        ForceChange=[bool]$script:UI.ImportForceChange.Checked;Groups=@($script:State.SelectedGroups|ForEach-Object{[pscustomobject]@{Name=$_.Name;DistinguishedName=$_.DistinguishedName}})
        SetHomeAttributes=[bool]$script:UI.SetHomeAttributes.Checked;HomeRoot=$script:UI.HomeRoot.Text.TrimEnd('\');HomeDrive=$script:UI.HomeDrive.Text.Trim()
    }
}

function Test-ImportTargetPreflight {
    param($Settings,[switch]$RequireConnection)
    $errors=New-Object System.Collections.Generic.List[string]
    if($RequireConnection -and -not (Test-CurrentADConnection)){$errors.Add('A currently validated AD connection is required.') ;return $errors.ToArray()}
    if($script:State.Connection.IsValidated){
        $p=Get-ADCommonParameters
        try{$null=Get-ADObject -Identity $Settings.TargetOU @p}catch{$errors.Add("Target OU/container is invalid or inaccessible: $($Settings.TargetOU)")}
        foreach($g in $Settings.Groups){try{$null=Get-ADGroup -Identity $g.DistinguishedName @p}catch{$errors.Add("Group is missing or inaccessible: $($g.Name)")}}
    }elseif(-not $RequireConnection){$errors.Add('Offline preview: AD existence, OU and group checks were not performed.')}
    if($Settings.SetHomeAttributes){if($Settings.HomeRoot -notmatch '^\\\\[^\\]+\\[^\\]+'){$errors.Add('Home-folder root must be a UNC path such as \\server\users.')};if($Settings.HomeDrive -notmatch '^[A-Z]:$'){$errors.Add('Home drive must look like H:.')}}
    return $errors.ToArray()
}

function Prepare-ImportPlan {
    if($script:State.CsvRows.Count -eq 0){Show-Message 'Load a CSV first.' 'Prepare import' 'Warning';return}
    $settings=Get-ImportSettingsSnapshot
    if([string]::IsNullOrWhiteSpace($settings.Mapping.FirstName) -or [string]::IsNullOrWhiteSpace($settings.Mapping.LastName)){Show-Message 'Map both First name and Last name.' 'Prepare import' 'Warning';return}
    if([string]::IsNullOrWhiteSpace($settings.TargetOU)){Show-Message 'Choose or enter a target OU/container.' 'Prepare import' 'Warning';return}
    if([string]::IsNullOrWhiteSpace($settings.UpnSuffix)){Show-Message 'Enter the full UPN suffix, for example example.org.' 'Prepare import' 'Warning';return}
    if($settings.PasswordMode -eq 'Custom fixed password'){$pwProblems=@(Test-PasswordAgainstPolicy $settings.CustomPassword);if($pwProblems.Count){Show-Message ($pwProblems -join "`r`n") 'Password validation' 'Warning';return}}
    $preflight=@(Test-ImportTargetPreflight $settings)
    $plan=New-Object System.Collections.Generic.List[object];$seen=@{};$index=0
    Set-Status 'Validating CSV rows...'
    foreach($row in $script:State.CsvRows){
        $index++;$first=Get-MappedValue $row 'FirstName' $settings.Mapping;$last=Get-MappedValue $row 'LastName' $settings.Mapping
        $id=Get-MappedValue $row 'EmployeeID' $settings.Mapping;$email=Get-MappedValue $row 'Email' $settings.Mapping
        $username=New-Username $first $last $id $email $settings.UsernameFormat;$status='Ready';$reasons=New-Object System.Collections.Generic.List[string]
        if([string]::IsNullOrWhiteSpace($first)){$status='Invalid';$reasons.Add('First name is blank.')}
        if([string]::IsNullOrWhiteSpace($last)){$status='Invalid';$reasons.Add('Last name is blank.')}
        if([string]::IsNullOrWhiteSpace($username)){$status='Invalid';$reasons.Add('A username could not be generated.')}
        if($username -and $seen.ContainsKey($username)){$status='Invalid';$reasons.Add("Duplicate username in CSV (also row $($seen[$username])).") }elseif($username){$seen[$username]=$index}
        if($email -and $email -notmatch '^[^@\s]+@[^@\s]+$'){if($status -eq 'Ready'){$status='Warning'};$reasons.Add('Email address format looks invalid.')}
        if($script:State.Connection.IsValidated -and $username -and $status -ne 'Invalid'){
            try{$p=Get-ADCommonParameters;$escaped=Escape-LdapFilterValue $username;$existing=Get-ADUser -LDAPFilter "(sAMAccountName=$escaped)" @p;if($existing){$status='Already exists';$reasons.Add('sAMAccountName already exists in AD.')}}catch{if($status -eq 'Ready'){$status='Warning'};$reasons.Add("AD lookup failed: $($_.Exception.Message)")}
        }elseif(-not $script:State.Connection.IsValidated -and $status -eq 'Ready'){$status='Warning';$reasons.Add('Offline preview; AD existence was not checked.')}
        $password=if($settings.PasswordMode -eq 'Custom fixed password'){$settings.CustomPassword}else{New-SecurePassword $settings.PasswordLength}
        $plan.Add([pscustomobject]@{
            Include=($status -in @('Ready','Warning'));Row=$index;Status=$status;Reason=($reasons -join ' ');Username=$username;DisplayName=("$first $last").Trim();FirstName=$first;LastName=$last
            EmployeeID=$id;Email=$email;YearGroup=Get-MappedValue $row 'YearGroup' $settings.Mapping;FormGroup=Get-MappedValue $row 'FormGroup' $settings.Mapping
            Department=Get-MappedValue $row 'Department' $settings.Mapping;Title=Get-MappedValue $row 'Title' $settings.Mapping;Office=Get-MappedValue $row 'Office' $settings.Mapping
            Telephone=Get-MappedValue $row 'Telephone' $settings.Mapping;Password=$password
        })
    }
    $script:State.Mappings=$settings.Mapping;$script:State.PreparedPlan=[pscustomobject]@{Settings=$settings;Rows=$plan.ToArray();Preflight=$preflight}
    $script:UI.PlanGrid.DataSource=ConvertTo-BindableList $script:State.PreparedPlan.Rows
    foreach($column in $script:UI.PlanGrid.Columns){$column.ReadOnly=($column.Name -ne 'Include')}
    if($script:UI.PlanGrid.Columns['Password']){$script:UI.PlanGrid.Columns['Password'].Visible=$false}
    $script:UI.RunImport.Enabled=$true;Update-ImportSummary;Apply-ImportFilter
    Add-AuditLog "Prepared immutable import plan with $($plan.Count) rows."
    Set-Status 'Import plan prepared. Review statuses and inclusions.'
}

function Update-ImportSummary {
    if($null -eq $script:State.PreparedPlan){$script:UI.ImportSummary.Text='Ready: 0 | Warning: 0 | Invalid: 0 | Already exists: 0';return}
    $rows=$script:State.PreparedPlan.Rows;$script:UI.ImportSummary.Text='Ready: {0} | Warning: {1} | Invalid: {2} | Already exists: {3} | Included: {4}' -f @($rows|Where-Object Status -eq 'Ready').Count,@($rows|Where-Object Status -eq 'Warning').Count,@($rows|Where-Object Status -eq 'Invalid').Count,@($rows|Where-Object Status -eq 'Already exists').Count,@($rows|Where-Object Include).Count
}

function Apply-ImportFilter {
    if($null -eq $script:State.PreparedPlan){return};$filter=$script:UI.StatusFilter.SelectedItem.ToString();$rows=if($filter -eq 'All'){$script:State.PreparedPlan.Rows}else{@($script:State.PreparedPlan.Rows|Where-Object Status -eq $filter)};$script:UI.PlanGrid.DataSource=ConvertTo-BindableList @($rows)
}

function Invoke-LiveImportPreflight {
    param($Plan)
    $blocking=New-Object System.Collections.Generic.List[string]
    foreach($x in @(Test-ImportTargetPreflight $Plan.Settings -RequireConnection)){$blocking.Add($x)}
    if($blocking.Count){return $blocking.ToArray()}
    $p=Get-ADCommonParameters
    foreach($row in @($Plan.Rows|Where-Object Include)){
        if($row.Status -in @('Invalid','Already exists')){$blocking.Add("Row $($row.Row) ($($row.Username)) is $($row.Status).") ;continue}
        try{$escaped=Escape-LdapFilterValue $row.Username;$u=Get-ADUser -LDAPFilter "(sAMAccountName=$escaped)" @p;if($u){$blocking.Add("Username now exists: $($row.Username)")}}catch{$blocking.Add("Could not verify $($row.Username): $($_.Exception.Message)")}
    }
    return $blocking.ToArray()
}

function Invoke-OneImportRow {
    param($Row,$Settings,[bool]$Preview)
    if($Preview){return [pscustomobject]@{Username=$Row.Username;DisplayName=$Row.DisplayName;Status='PREVIEW';Message="Would create in $($Settings.TargetOU)"}}
    try{
        $p=Get-ADCommonParameters;$userParams=@{SamAccountName=$Row.Username;Name=$Row.DisplayName;GivenName=$Row.FirstName;Surname=$Row.LastName;DisplayName=$Row.DisplayName;UserPrincipalName="$($Row.Username)@$($Settings.UpnSuffix)";AccountPassword=(ConvertTo-SecureString $Row.Password -AsPlainText -Force);Enabled=$true;ChangePasswordAtLogon=$Settings.ForceChange;Path=$Settings.TargetOU}
        foreach($pair in @(@('EmployeeID','EmployeeID'),@('Email','EmailAddress'),@('Department','Department'),@('Title','Title'),@('Office','Office'),@('Telephone','OfficePhone'))){if(-not [string]::IsNullOrWhiteSpace($Row.($pair[0]))){$userParams[$pair[1]]=$Row.($pair[0])}}
        if($Row.YearGroup){$userParams.Description="Year group: $($Row.YearGroup)"}
        $newUser=New-ADUser @userParams @p -PassThru
        $messages=New-Object System.Collections.Generic.List[string];$messages.Add('User created.')
        foreach($g in $Settings.Groups){try{Add-ADGroupMember -Identity $g.DistinguishedName -Members $newUser @p;$messages.Add("Added to $($g.Name).") }catch{$messages.Add("GROUP ERROR [$($g.Name)]: $($_.Exception.Message)")}}
        if($Settings.SetHomeAttributes){
            $home='{0}\{1}' -f $Settings.HomeRoot,$Row.Username
            try{Set-ADUser -Identity $newUser -HomeDrive $Settings.HomeDrive -HomeDirectory $home @p;$messages.Add("Home attributes set: $home") }catch{$messages.Add("HOME ATTRIBUTE ERROR: $($_.Exception.Message)")}
        }
        return [pscustomobject]@{Username=$Row.Username;DisplayName=$Row.DisplayName;Status=$(if($messages -match 'ERROR'){'PARTIAL'}else{'CREATED'});Message=$messages -join ' '}
    }catch{return [pscustomobject]@{Username=$Row.Username;DisplayName=$Row.DisplayName;Status='ERROR';Message=$_.Exception.Message}}
}

function Invoke-ImportTimerTick {
    param([System.Windows.Forms.Timer]$Sender)
    $context=$Sender.Tag
    if($null -eq $context){$Sender.Stop();return}
    if($context.Queue.Count -gt 0){
        $row=$context.Queue.Dequeue()
        $result=Invoke-OneImportRow $row $context.Plan.Settings $context.Preview
        $script:State.ImportResults+=,$result
        [void]$script:UI.ImportResults.Rows.Add($result.Username,$result.DisplayName,$result.Status,$result.Message)
        $context.Done++
        Set-Status "Import $($context.Done) of $($context.Total)..."
        return
    }
    $Sender.Stop()
    $plan=$context.Plan;$preview=$context.Preview;$mode=$context.Mode;$done=$context.Done
    $Sender.Tag=$null;$Sender.Dispose();$script:BusyTimer=$null;$script:UI.RunImport.Enabled=$true
    Add-AuditLog "Import operation completed in $mode mode: $done processed."
    Set-Status "Import complete: $done processed."
    if(-not $preview){Export-SuccessfulImportPasswords $plan $script:State.ImportResults}
    foreach($row in $plan.Rows){$row.Password=$null}
    $script:UI.ImportCustomPassword.Clear()
}

function Start-Import {
    if($null -eq $script:State.PreparedPlan){Show-Message 'Prepare and validate the import first.' 'Import' 'Warning';return}
    $preview=[bool]$script:UI.PreviewMode.Checked;$plan=$script:State.PreparedPlan;$included=@($plan.Rows|Where-Object Include)
    if($included.Count -eq 0){Show-Message 'No rows are included.' 'Import' 'Warning';return}
    if(-not $preview){$blocking=@(Invoke-LiveImportPreflight $plan);if($blocking.Count){Show-Message ("Live preflight blocked the import:`r`n- "+($blocking -join "`r`n- ")) 'Preflight failed' 'Error';return}}
    $mode=if($preview){'PREVIEW (no AD changes)'}else{'LIVE'};$answer=[System.Windows.Forms.MessageBox]::Show($script:UI.Form,"Mode: $mode`r`nDomain: $($script:State.Connection.Domain)`r`nTarget: $($plan.Settings.TargetOU)`r`nIncluded users: $($included.Count)`r`n`r`nContinue?",'Confirm import','YesNo',$(if($preview){'Question'}else{'Warning'}));if($answer -ne 'Yes'){return}
    $script:State.ImportResults=@();$queue=New-Object System.Collections.Queue;foreach($r in $included){$queue.Enqueue($r)}
    $script:UI.ImportResults.Rows.Clear();$script:UI.RunImport.Enabled=$false
    $timer=New-Object System.Windows.Forms.Timer;$timer.Interval=50;$script:BusyTimer=$timer
    $timer.Tag=[pscustomobject]@{Queue=$queue;Plan=$plan;Preview=$preview;Mode=$mode;Total=$queue.Count;Done=0}
    $timer.Add_Tick({param($sender,$eventArgs) Invoke-ImportTimerTick $sender});$timer.Start()
}

function Export-ImportResults {
    if($script:State.ImportResults.Count -eq 0){Show-Message 'There are no import results to export.' 'Export' 'Warning';return}
    $d=New-Object System.Windows.Forms.SaveFileDialog;$d.Filter='CSV files (*.csv)|*.csv';$d.FileName='AD_Import_Results_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmmss')
    if($d.ShowDialog($script:UI.Form) -eq 'OK'){$script:State.ImportResults|Export-Csv -LiteralPath $d.FileName -NoTypeInformation -Encoding UTF8;Add-AuditLog "Exported password-free import results to '$($d.FileName)'."};$d.Dispose()
}

function Export-SuccessfulImportPasswords {
    param($Plan,$Results)
    $createdNames=@($Results|Where-Object{$_.Status -in @('CREATED','PARTIAL')}|ForEach-Object Username)
    $credentials=@($Plan.Rows|Where-Object{$createdNames -contains $_.Username}|Select-Object Username,DisplayName,Password)
    if($credentials.Count -eq 0){return}
    $answer=[System.Windows.Forms.MessageBox]::Show($script:UI.Form,"$($credentials.Count) user account(s) were created.`r`n`r`nTheir initial passwords can be exported to a sensitive plaintext CSV. Save only to an approved secure location. Export now?",'Sensitive initial-password export','YesNo','Warning')
    if($answer -ne 'Yes'){Add-AuditLog 'Operator declined the initial-password export.' 'WARN';return}
    $d=New-Object System.Windows.Forms.SaveFileDialog;$d.Filter='CSV files (*.csv)|*.csv';$d.FileName='AD_Initial_Passwords_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmmss')
    if($d.ShowDialog($script:UI.Form) -eq 'OK'){
        $credentials|Export-Csv -LiteralPath $d.FileName -NoTypeInformation -Encoding UTF8
        $protection=Protect-SensitiveFileAcl $d.FileName
        Add-AuditLog "Sensitive initial-password CSV exported. $($protection.Message)" $(if($protection.Succeeded){'INFO'}else{'WARN'})
        Show-Message "Initial-password CSV saved.`r`n`r`n$($protection.Message)" 'Sensitive export' $(if($protection.Succeeded){'Information'}else{'Warning'})
    }else{Add-AuditLog 'Operator cancelled the initial-password export.' 'WARN'}
    $d.Dispose()
}

function Load-ResetUsers {
    if([string]::IsNullOrWhiteSpace($script:UI.ResetOU.Text)){Show-Message 'Choose an OU or container first.' 'Password maintenance' 'Warning';return}
    if(-not (Test-CurrentADConnection)){Show-Message 'A validated AD connection is required to load users.' 'Password maintenance' 'Warning';return}
    try{
        Set-Status 'Loading users from Active Directory...';$p=Get-ADCommonParameters;$p.SearchBase=$script:UI.ResetOU.Text.Trim();$p.SearchScope=if($script:UI.ResetScope.SelectedIndex -eq 0){'OneLevel'}else{'Subtree'}
        $users=@(Get-ADUser -Filter * @p -Properties DisplayName,Enabled,AdminCount,SamAccountName,DistinguishedName)
        $pattern=$script:UI.ServiceFilter.Text.Trim();$list=New-Object System.Collections.Generic.List[object]
        foreach($u in $users){
            $reason='';$include=$true
            if(-not $u.Enabled){$reason='Disabled account';$include=$false}
            elseif([int]$u.AdminCount -eq 1 -or $u.SID.Value -match '-500$'){$reason='Protected/admin account';$include=$false}
            elseif($pattern){try{if($u.SamAccountName -match $pattern -or $u.DisplayName -match $pattern){$reason='Matches service-account exclusion filter';$include=$false}}catch{throw "Service-account filter is not a valid regular expression: $pattern"}}
            $list.Add([pscustomobject]@{Include=$include;Username=$u.SamAccountName;DisplayName=$u.DisplayName;Enabled=[bool]$u.Enabled;DistinguishedName=$u.DistinguishedName;ExclusionReason=$reason})
        }
        $script:State.ResetUsers=@($list.ToArray());$script:UI.ResetGrid.DataSource=ConvertTo-BindableList $script:State.ResetUsers
        foreach($column in $script:UI.ResetGrid.Columns){$column.ReadOnly=($column.Name -ne 'Include')}
        Update-ResetCount
        Add-AuditLog "Loaded $($list.Count) password-maintenance candidates from '$($script:UI.ResetOU.Text)'.";Set-Status 'Password-maintenance user list loaded.'
    }catch{Show-Message "Could not load users:`r`n$($_.Exception.Message)" 'Password maintenance' 'Error';Set-Status 'User load failed.'}
}

function Update-ResetCount {
    if($script:UI.ContainsKey('ResetGrid')){$script:UI.ResetGrid.EndEdit()}
    $count=@($script:State.ResetUsers|Where-Object Include).Count
    $script:UI.ResetCount.Text="Exactly $count account(s) selected"
}

function Show-TypedResetConfirmation {
    param([int]$Count,[string]$OU,[string]$Scope,[string]$Domain)
    $required="RESET $Count USERS";$f=New-Object System.Windows.Forms.Form;$f.Text='Confirm live password reset';$f.Size='620,300';$f.StartPosition='CenterParent';$f.FormBorderStyle='FixedDialog';$f.MaximizeBox=$false
    $layout=New-Object System.Windows.Forms.TableLayoutPanel;$layout.Dock='Fill';$layout.Padding=New-Object System.Windows.Forms.Padding(14);$layout.RowCount=4;$layout.ColumnCount=1
    $warning=New-Object System.Windows.Forms.Label;$warning.AutoSize=$true;$warning.MaximumSize='560,0';$warning.Text="WARNING: This will change passwords in Active Directory.`r`n`r`nDomain: $Domain`r`nOU/container: $OU`r`nScope: $Scope`r`nExact user count: $Count`r`n`r`nType $required to continue:"
    $typed=New-Object System.Windows.Forms.TextBox;$typed.Dock='Top'
    $hint=New-Object System.Windows.Forms.Label;$hint.AutoSize=$true;$hint.ForeColor=[Drawing.Color]::DarkRed
    $buttons=New-Object System.Windows.Forms.FlowLayoutPanel;$buttons.Dock='Fill';$buttons.FlowDirection='RightToLeft';$ok=New-Button 'Reset passwords';$ok.DialogResult='OK';$ok.Enabled=$false;$cancel=New-Button 'Cancel';$cancel.DialogResult='Cancel';$buttons.Controls.AddRange(@($ok,$cancel))
    $typed.Add_TextChanged({$ok.Enabled=($typed.Text -ceq $required);$hint.Text=if($ok.Enabled){'Confirmation matched.'}else{'Confirmation does not match.'}})
    $layout.Controls.Add($warning,0,0);$layout.Controls.Add($typed,0,1);$layout.Controls.Add($hint,0,2);$layout.Controls.Add($buttons,0,3);$f.Controls.Add($layout);$f.AcceptButton=$ok;$f.CancelButton=$cancel
    $confirmed=($f.ShowDialog($script:UI.Form) -eq 'OK' -and $typed.Text -ceq $required);$typed.Clear();$f.Dispose();return $confirmed
}

function Invoke-OnePasswordReset {
    param($User,[string]$Password,[bool]$ForceChange,[bool]$Unlock,[bool]$Preview)
    if($Preview){return [pscustomobject]@{Username=$User.Username;DisplayName=$User.DisplayName;Status='PREVIEW';Message='Would reset to a unique/generated or specified password.';PasswordReset=$false;Password=$null}}
    $resetSucceeded=$false;$messages=New-Object System.Collections.Generic.List[string]
    try{
        $p=Get-ADCommonParameters;$secure=ConvertTo-SecureString $Password -AsPlainText -Force
        Set-ADAccountPassword -Identity $User.DistinguishedName -Reset -NewPassword $secure @p;$resetSucceeded=$true;$messages.Add('Password reset succeeded.')
        if($ForceChange){try{Set-ADUser -Identity $User.DistinguishedName -ChangePasswordAtLogon $true @p;$messages.Add('Change at next logon enabled.')}catch{$messages.Add("CHANGE-FLAG ERROR: $($_.Exception.Message)")}}
        if($Unlock){try{Unlock-ADAccount -Identity $User.DistinguishedName @p;$messages.Add('Account unlocked.')}catch{$messages.Add("UNLOCK ERROR: $($_.Exception.Message)")}}
        return [pscustomobject]@{Username=$User.Username;DisplayName=$User.DisplayName;Status=$(if($messages -match 'ERROR'){'PARTIAL'}else{'SUCCESS'});Message=$messages -join ' ';PasswordReset=$true;Password=$Password}
    }catch{return [pscustomobject]@{Username=$User.Username;DisplayName=$User.DisplayName;Status='FAILED';Message=$_.Exception.Message;PasswordReset=$resetSucceeded;Password=$(if($resetSucceeded){$Password}else{$null})}}
}

function Protect-SensitiveFileAcl {
    param([string]$Path)
    try{
        $identity=[System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $acl=Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true,$false)
        foreach($rule in @($acl.Access)){$null=$acl.RemoveAccessRuleAll($rule)}
        $rule=New-Object System.Security.AccessControl.FileSystemAccessRule($identity,'FullControl','Allow')
        $acl.AddAccessRule($rule);Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        return [pscustomobject]@{Succeeded=$true;Message="NTFS permissions restricted to $identity."}
    }catch{return [pscustomobject]@{Succeeded=$false;Message="Could not restrict NTFS permissions: $($_.Exception.Message)"}}
}

function Export-SuccessfulResetPasswords {
    param($Results)
    $successful=@($Results|Where-Object PasswordReset)
    if($successful.Count -eq 0){return}
    $warning=[System.Windows.Forms.MessageBox]::Show($script:UI.Form,"$($successful.Count) password reset(s) succeeded.`r`n`r`nThe export contains highly sensitive plaintext passwords. Save it only to an approved secure location. Export now?",'Sensitive password export','YesNo','Warning')
    if($warning -ne 'Yes'){Add-AuditLog 'Operator declined the sensitive password export.' 'WARN';return}
    $d=New-Object System.Windows.Forms.SaveFileDialog;$d.Filter='CSV files (*.csv)|*.csv';$d.FileName='AD_Reset_Passwords_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmmss')
    if($d.ShowDialog($script:UI.Form) -eq 'OK'){
        $successful|Select-Object Username,DisplayName,Password|Export-Csv -LiteralPath $d.FileName -NoTypeInformation -Encoding UTF8
        $protection=Protect-SensitiveFileAcl $d.FileName
        Add-AuditLog "Sensitive password CSV exported. $($protection.Message)" $(if($protection.Succeeded){'INFO'}else{'WARN'})
        Show-Message "Password CSV saved.`r`n`r`n$($protection.Message)" 'Sensitive export' $(if($protection.Succeeded){'Information'}else{'Warning'})
    }else{Add-AuditLog 'Operator cancelled the sensitive password export.' 'WARN'};$d.Dispose()
}

function Export-ResetAudit {
    param($AuditRows)
    if($AuditRows.Count -eq 0){return}
    $d=New-Object System.Windows.Forms.SaveFileDialog;$d.Filter='CSV files (*.csv)|*.csv';$d.FileName='AD_Password_Reset_Audit_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmmss')
    if($d.ShowDialog($script:UI.Form) -eq 'OK'){$AuditRows|Export-Csv -LiteralPath $d.FileName -NoTypeInformation -Encoding UTF8;Add-AuditLog "Password-free reset audit exported to '$($d.FileName)'."}else{Add-AuditLog 'Operator cancelled the password-free audit export.' 'WARN'};$d.Dispose()
}

function Invoke-PasswordResetTimerTick {
    param([System.Windows.Forms.Timer]$Sender)
    $context=$Sender.Tag
    if($null -eq $context){$Sender.Stop();return}
    if($context.Queue.Count -gt 0){
        $user=$context.Queue.Dequeue()
        $password=if($context.Mode -eq 'Custom fixed password'){$context.FixedPassword}else{New-SecurePassword $context.Length}
        $result=Invoke-OnePasswordReset $user $password $context.ForceChange $context.Unlock $context.Preview
        $script:State.ResetResults+=,$result
        [void]$script:UI.ResetResults.Rows.Add($result.Username,$result.DisplayName,$result.Status,$result.Message)
        $script:State.AuditRows+=,[pscustomobject]@{
            Timestamp=(Get-Date).ToString('o');Operator=$context.Operator;Domain=$context.Domain;OU=$context.OU;Username=$result.Username
            Action=$(if($context.Preview){'Preview password reset'}else{'Password reset'});Result="$($result.Status): $($result.Message)"
        }
        $password=$null;$context.Done++
        Set-Status "Password maintenance $($context.Done) of $($context.Total)..."
        return
    }
    $Sender.Stop()
    $preview=$context.Preview;$done=$context.Done;$context.FixedPassword=$null
    $Sender.Tag=$null;$Sender.Dispose();$script:BusyTimer=$null;$script:UI.RunReset.Enabled=$true
    Add-AuditLog "Password-maintenance operation finished: $done processed; preview=$preview."
    Set-Status "Password maintenance complete: $done processed."
    if(-not $preview){Export-SuccessfulResetPasswords $script:State.ResetResults}
    Export-ResetAudit $script:State.AuditRows
    foreach($result in $script:State.ResetResults){$result.Password=$null}
    $script:UI.ResetCustomPassword.Clear()
}

function Start-PasswordReset {
    $script:UI.ResetGrid.EndEdit();$selected=@($script:State.ResetUsers|Where-Object Include);if($selected.Count -eq 0){Show-Message 'No accounts are included.' 'Password maintenance' 'Warning';return}
    $preview=[bool]$script:UI.PreviewMode.Checked;$mode=$script:UI.ResetPasswordMode.SelectedItem.ToString();$length=[int]$script:UI.ResetPasswordLength.Value;$fixed=$script:UI.ResetCustomPassword.Text
    if($mode -eq 'Custom fixed password'){$problems=@(Test-PasswordAgainstPolicy $fixed);if($problems.Count){Show-Message ($problems -join "`r`n") 'Password validation' 'Warning';return};$ack=[System.Windows.Forms.MessageBox]::Show($script:UI.Form,'Using one fixed password for multiple accounts materially increases risk. Continue?','Fixed password warning','YesNo','Warning');if($ack -ne 'Yes'){return}}
    if(-not $preview){if(-not (Test-CurrentADConnection)){Show-Message 'A currently validated AD connection is required for a live reset.' 'Connection required' 'Error';return};$scope=$script:UI.ResetScope.SelectedItem.ToString();if(-not (Show-TypedResetConfirmation $selected.Count $script:UI.ResetOU.Text $scope $script:State.Connection.Domain)){return}}
    else{$answer=[System.Windows.Forms.MessageBox]::Show($script:UI.Form,"Preview password reset for exactly $($selected.Count) account(s)? No AD changes will be made.",'Confirm preview','YesNo','Question');if($answer -ne 'Yes'){return}}
    $script:State.ResetResults=@();$script:State.AuditRows=@();$script:UI.ResetResults.Rows.Clear();$queue=New-Object System.Collections.Queue;foreach($u in $selected){$queue.Enqueue($u)}
    $operator=[System.Security.Principal.WindowsIdentity]::GetCurrent().Name;$domain=$script:State.Connection.Domain;$ou=$script:UI.ResetOU.Text;$force=[bool]$script:UI.ResetForceChange.Checked;$unlock=[bool]$script:UI.ResetUnlock.Checked
    $timer=New-Object System.Windows.Forms.Timer;$timer.Interval=50;$script:BusyTimer=$timer;$script:UI.RunReset.Enabled=$false
    $timer.Tag=[pscustomobject]@{Queue=$queue;Mode=$mode;Length=$length;FixedPassword=$fixed;ForceChange=$force;Unlock=$unlock;Preview=$preview;Operator=$operator;Domain=$domain;OU=$ou;Total=$queue.Count;Done=0}
    $fixed=$null
    $timer.Add_Tick({param($sender,$eventArgs) Invoke-PasswordResetTimerTick $sender});$timer.Start()
}

function Export-GeneralLog {
    $d=New-Object System.Windows.Forms.SaveFileDialog;$d.Filter='Log files (*.log)|*.log|Text files (*.txt)|*.txt';$d.FileName='AD_Provisioning_Audit_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss')
    if($d.ShowDialog($script:UI.Form) -eq 'OK'){$encoding=New-Object Text.UTF8Encoding($true);[IO.File]::WriteAllLines($d.FileName,[string[]]$script:State.Logs,$encoding)};$d.Dispose()
}

function Build-ConnectionBanner {
    $panel=New-Object System.Windows.Forms.TableLayoutPanel;$panel.Dock='Fill';$panel.Padding=New-Object System.Windows.Forms.Padding(8);$panel.ColumnCount=7;$panel.RowCount=2;$panel.BackColor=[Drawing.Color]::FromArgb(240,244,248)
    foreach($w in @(120,240,240,100,100,100)){[void]$panel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',$w)))};[void]$panel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
    $script:UI.ConnectionStatus=New-Label 'DISCONNECTED';$script:UI.ConnectionStatus.Font=New-Object Drawing.Font('Segoe UI',9,[Drawing.FontStyle]::Bold)
    $script:UI.ConnectionDetail=New-Label 'No validated AD connection';$script:UI.CredentialDetail=New-Label 'Current Windows credentials'
    $script:UI.ConnectButton=New-Button 'Connect';$script:UI.DisconnectButton=New-Button 'Disconnect';$script:UI.DisconnectButton.Enabled=$false
    $script:UI.PreviewMode=New-Object Windows.Forms.CheckBox;$script:UI.PreviewMode.Text='Preview mode';$script:UI.PreviewMode.Checked=$true;$script:UI.PreviewMode.AutoSize=$true
    $script:UI.ModeLabel=New-Label 'PREVIEW - no AD changes';$script:UI.ModeLabel.Font=New-Object Drawing.Font('Segoe UI',9,[Drawing.FontStyle]::Bold)
    $panel.Controls.Add((New-Label 'Connection'),0,0);$panel.Controls.Add((New-Label 'Domain / server'),1,0);$panel.Controls.Add((New-Label 'Credential identity'),2,0)
    $panel.Controls.Add($script:UI.ConnectionStatus,0,1);$panel.Controls.Add($script:UI.ConnectionDetail,1,1);$panel.Controls.Add($script:UI.CredentialDetail,2,1);$panel.Controls.Add($script:UI.ConnectButton,3,1);$panel.Controls.Add($script:UI.DisconnectButton,4,1);$panel.Controls.Add($script:UI.PreviewMode,5,1);$panel.Controls.Add($script:UI.ModeLabel,6,1)
    $script:UI.ConnectButton.Add_Click({Show-ConnectDialog});$script:UI.DisconnectButton.Add_Click({Disconnect-ADConnection;Add-AuditLog 'Disconnected from Active Directory.';Set-Status 'Disconnected.'})
    $script:UI.PreviewMode.Add_CheckedChanged({Update-ModeBanner})
    return $panel
}

function Build-MappingGroup {
    $group=New-Group '2. Map Columns';$table=New-Object Windows.Forms.TableLayoutPanel;$table.Dock='Fill';$table.AutoSize=$false;$table.ColumnCount=4;$table.RowCount=5
    [void]$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',115)));[void]$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',50)));[void]$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',115)));[void]$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',50)))
    1..5|ForEach-Object{[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',34)))}
    $fields=[ordered]@{FirstName='First name *';LastName='Last name *';EmployeeID='Student/employee ID';Email='Email address';YearGroup='Year group';FormGroup='Form/tutor group';Department='Department';Title='Title';Office='Office/location';Telephone='Telephone number'}
    $script:UI.MapControls=@{};$i=0;foreach($pair in $fields.GetEnumerator()){$row=[math]::Floor($i/2);$col=($i%2)*2;$combo=New-Object Windows.Forms.ComboBox;$combo.DropDownStyle='DropDownList';$combo.Dock='Fill';[void]$combo.Items.Add('(not mapped)');$combo.SelectedIndex=0;$combo.Add_SelectedIndexChanged({Invalidate-PreparedPlan 'Column mapping changed.'});$script:UI.MapControls[$pair.Key]=$combo;$table.Controls.Add((New-Label $pair.Value),$col,$row);$table.Controls.Add($combo,$col+1,$row);$i++}
    $group.Controls.Add($table);return $group
}

function Build-ImportTab {
    $tab=New-Object Windows.Forms.TabPage;$tab.Text='Import Users'
    $split=New-Object Windows.Forms.SplitContainer;$split.Dock='Fill';$split.Orientation='Vertical';$script:UI.ImportSplit=$split
    $split.Add_SizeChanged({
        $current=$script:UI.ImportSplit
        if($current.Width -gt 900){
            $desired=[Math]::Max(500,[Math]::Min(650,[int]($current.Width*0.42)))
            if($desired -ge $current.Panel1MinSize -and $desired -le ($current.Width-$current.Panel2MinSize-$current.SplitterWidth)){$current.SplitterDistance=$desired}
        }
    })
    $left=New-Object Windows.Forms.Panel;$left.Dock='Fill';$left.AutoScroll=$true;$left.Padding=New-Object System.Windows.Forms.Padding(6)
    $leftTable=New-Object Windows.Forms.TableLayoutPanel;$leftTable.Dock='Top';$leftTable.AutoSize=$false;$leftTable.Height=693;$leftTable.ColumnCount=1;$leftTable.RowCount=3
    foreach($style in @(@('Absolute',78),@('Absolute',205),@('Absolute',410))){[void]$leftTable.RowStyles.Add((New-Object Windows.Forms.RowStyle($style[0],$style[1])))}
    $fileGroup=New-Group '1. Select CSV';$fileLayout=New-Object Windows.Forms.TableLayoutPanel;$fileLayout.Dock='Fill';$fileLayout.AutoSize=$false;$fileLayout.ColumnCount=2;$fileLayout.RowCount=1;[void]$fileLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)));[void]$fileLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',115)))
    $script:UI.CsvPath=New-Object Windows.Forms.TextBox;$script:UI.CsvPath.ReadOnly=$true;$script:UI.CsvPath.Dock='Fill';$browse=New-Button 'Browse CSV...';$browse.Add_Click({Import-CsvFile});$fileLayout.Controls.Add($script:UI.CsvPath,0,0);$fileLayout.Controls.Add($browse,1,0);$fileGroup.Controls.Add($fileLayout)
    $mapping=Build-MappingGroup
    $config=New-Group '3. Configure Accounts';$ct=New-Object Windows.Forms.TableLayoutPanel;$ct.Dock='Fill';$ct.AutoSize=$false;$ct.ColumnCount=3;$ct.RowCount=11;[void]$ct.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',155)));[void]$ct.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)));[void]$ct.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',95)));1..11|ForEach-Object{[void]$ct.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',34)))}
    $script:UI.UsernameFormat=New-Object Windows.Forms.ComboBox;$script:UI.UsernameFormat.DropDownStyle='DropDownList';$script:UI.UsernameFormat.Items.AddRange(@('First.Last','First initial + last','First + last','Employee/student ID','Email prefix'));$script:UI.UsernameFormat.SelectedIndex=0;$script:UI.UsernameFormat.Dock='Fill'
    $script:UI.TargetOU=New-Object Windows.Forms.TextBox;$script:UI.TargetOU.Dock='Fill';$ouBrowse=New-Button 'Browse...';$ouBrowse.Add_Click({$x=Select-ADObjectDialog 'Container';if($x){$script:UI.TargetOU.Text=$x.DistinguishedName}})
    $script:UI.UpnSuffix=New-Object Windows.Forms.TextBox;$script:UI.UpnSuffix.Dock='Fill'
    $script:UI.ImportPasswordMode=New-Object Windows.Forms.ComboBox;$script:UI.ImportPasswordMode.DropDownStyle='DropDownList';$script:UI.ImportPasswordMode.Items.AddRange(@('Unique secure password','Custom fixed password'));$script:UI.ImportPasswordMode.SelectedIndex=0;$script:UI.ImportPasswordMode.Dock='Fill'
    $script:UI.ImportPasswordLength=New-Object Windows.Forms.NumericUpDown;$script:UI.ImportPasswordLength.Minimum=6;$script:UI.ImportPasswordLength.Maximum=128;$script:UI.ImportPasswordLength.Value=16
    $pwPanel=New-Object Windows.Forms.FlowLayoutPanel;$pwPanel.AutoSize=$true;$pwPanel.Dock='Fill';$script:UI.ImportCustomPassword=New-Object Windows.Forms.TextBox;$script:UI.ImportCustomPassword.UseSystemPasswordChar=$true;$script:UI.ImportCustomPassword.Width=190;$show=New-Object Windows.Forms.CheckBox;$show.Text='Show';$show.AutoSize=$true;$show.Add_CheckedChanged({param($sender,$eventArgs)$script:UI.ImportCustomPassword.UseSystemPasswordChar=-not $sender.Checked});$pwPanel.Controls.AddRange(@($script:UI.ImportCustomPassword,$show))
    $script:UI.ImportForceChange=New-Object Windows.Forms.CheckBox;$script:UI.ImportForceChange.Text='Force password change at next logon';$script:UI.ImportForceChange.Checked=$true;$script:UI.ImportForceChange.AutoSize=$true
    $groupPanel=New-Object Windows.Forms.FlowLayoutPanel;$groupPanel.AutoSize=$true;$groupPanel.Dock='Fill';$groupButton=New-Button 'Select groups...';$script:UI.GroupSummary=New-Label 'None';$groupPanel.Controls.AddRange(@($groupButton,$script:UI.GroupSummary));$groupButton.Add_Click({Show-GroupSelector})
    $script:UI.SetHomeAttributes=New-Object Windows.Forms.CheckBox;$script:UI.SetHomeAttributes.Text='Set home-folder attributes';$script:UI.SetHomeAttributes.AutoSize=$true
    $script:UI.HomeRoot=New-Object Windows.Forms.TextBox;$script:UI.HomeRoot.Text='\\fileserver\users';$script:UI.HomeRoot.Dock='Fill';$script:UI.HomeDrive=New-Object Windows.Forms.TextBox;$script:UI.HomeDrive.Text='H:';$script:UI.HomeDrive.Width=50
    $rows=@(@('Username format',$script:UI.UsernameFormat,$null),@('Target OU/container',$script:UI.TargetOU,$ouBrowse),@('Full UPN suffix',$script:UI.UpnSuffix,$null),@('Password option',$script:UI.ImportPasswordMode,$null),@('Password length',$script:UI.ImportPasswordLength,$null),@('Custom password',$pwPanel,$null),@('Password behavior',$script:UI.ImportForceChange,$null),@('Security groups',$groupPanel,$null),@('Home-folder option',$script:UI.SetHomeAttributes,$null),@('Home root (UNC)',$script:UI.HomeRoot,$null),@('Home drive',$script:UI.HomeDrive,$null))
    for($i=0;$i -lt $rows.Count;$i++){$ct.Controls.Add((New-Label $rows[$i][0]),0,$i);$ct.Controls.Add($rows[$i][1],1,$i);if($rows[$i][2]){$ct.Controls.Add($rows[$i][2],2,$i)}};$config.Controls.Add($ct)
    foreach($c in @($script:UI.UsernameFormat,$script:UI.TargetOU,$script:UI.UpnSuffix,$script:UI.ImportPasswordMode,$script:UI.ImportPasswordLength,$script:UI.ImportCustomPassword,$script:UI.ImportForceChange,$script:UI.SetHomeAttributes,$script:UI.HomeRoot,$script:UI.HomeDrive)){if($c -is [Windows.Forms.TextBox]){$c.Add_TextChanged({Invalidate-PreparedPlan 'Import setting changed.'})}elseif($c -is [Windows.Forms.ComboBox]){$c.Add_SelectedIndexChanged({Invalidate-PreparedPlan 'Import setting changed.'})}elseif($c -is [Windows.Forms.CheckBox]){$c.Add_CheckedChanged({Invalidate-PreparedPlan 'Import setting changed.'})}else{$c.Add_ValueChanged({Invalidate-PreparedPlan 'Import setting changed.'})}}
    $leftTable.Controls.Add($fileGroup,0,0);$leftTable.Controls.Add($mapping,0,1);$leftTable.Controls.Add($config,0,2);$left.Controls.Add($leftTable);$split.Panel1.Controls.Add($left)
    $right=New-Object Windows.Forms.TableLayoutPanel;$right.Dock='Fill';$right.Padding=New-Object System.Windows.Forms.Padding(6);$right.RowCount=7;$right.ColumnCount=1;foreach($style in @(@('Absolute',170),@('Absolute',42),@('Absolute',35),@('Percent',58),@('Absolute',35),@('Percent',42),@('Absolute',42))){[void]$right.RowStyles.Add((New-Object Windows.Forms.RowStyle($style[0],$style[1])))}
    $previewGroup=New-Object Windows.Forms.GroupBox;$previewGroup.Text='CSV preview / analysis';$previewGroup.Dock='Fill';$script:UI.CsvPreview=New-Grid;$script:UI.CsvPreview.ReadOnly=$true;$previewGroup.Controls.Add($script:UI.CsvPreview)
    $actions=New-Object Windows.Forms.FlowLayoutPanel;$actions.Dock='Fill';$prepare=New-Button '4. Validate and Preview';$script:UI.StatusFilter=New-Object Windows.Forms.ComboBox;$script:UI.StatusFilter.DropDownStyle='DropDownList';$script:UI.StatusFilter.Items.AddRange(@('All','Ready','Warning','Invalid','Already exists'));$script:UI.StatusFilter.SelectedIndex=0;$script:UI.StatusFilter.Add_SelectedIndexChanged({Apply-ImportFilter});$actions.Controls.AddRange(@($prepare,(New-Label 'Show:'),$script:UI.StatusFilter));$prepare.Add_Click({Prepare-ImportPlan})
    $script:UI.ImportSummary=New-Label 'Ready: 0 | Warning: 0 | Invalid: 0 | Already exists: 0';$script:UI.PlanGrid=New-Grid;$script:UI.PlanGrid.Add_CellValueChanged({Update-ImportSummary});$script:UI.PlanGrid.Add_CurrentCellDirtyStateChanged({if($script:UI.PlanGrid.IsCurrentCellDirty){$script:UI.PlanGrid.CommitEdit('Commit')}})
    $resultLabel=New-Label '5. Import and Results';$script:UI.ImportResults=New-Grid;$script:UI.ImportResults.AutoGenerateColumns=$false;foreach($def in @(@('Username','Username',120),@('Name','Name',150),@('Status','Status',90),@('Message','Message',420))){$col=New-Object Windows.Forms.DataGridViewTextBoxColumn;$col.HeaderText=$def[0];$col.Name=$def[1];$col.Width=$def[2];[void]$script:UI.ImportResults.Columns.Add($col)}
    $bottom=New-Object Windows.Forms.FlowLayoutPanel;$bottom.Dock='Fill';$script:UI.RunImport=New-Button 'Run Import';$script:UI.RunImport.Enabled=$false;$export=New-Button 'Export Results';$bottom.Controls.AddRange(@($script:UI.RunImport,$export));$script:UI.RunImport.Add_Click({Start-Import});$export.Add_Click({Export-ImportResults})
    $right.Controls.Add($previewGroup,0,0);$right.Controls.Add($actions,0,1);$right.Controls.Add($script:UI.ImportSummary,0,2);$right.Controls.Add($script:UI.PlanGrid,0,3);$right.Controls.Add($resultLabel,0,4);$right.Controls.Add($script:UI.ImportResults,0,5);$right.Controls.Add($bottom,0,6);$split.Panel2.Controls.Add($right);$tab.Controls.Add($split);return $tab
}

function Build-PasswordTab {
    $tab=New-Object Windows.Forms.TabPage;$tab.Text='Password Maintenance';$layout=New-Object Windows.Forms.TableLayoutPanel;$layout.Dock='Fill';$layout.Padding=New-Object System.Windows.Forms.Padding(8);$layout.ColumnCount=1;$layout.RowCount=6;foreach($style in @(@('Absolute',150),@('Absolute',40),@('Percent',55),@('Absolute',150),@('Absolute',45),@('Percent',45))){[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle($style[0],$style[1])))}
    $source=New-Object Windows.Forms.GroupBox;$source.Text='OU Password Reset - select and load accounts';$source.Dock='Fill';$st=New-Object Windows.Forms.TableLayoutPanel;$st.Dock='Fill';$st.ColumnCount=3;$st.RowCount=4;[void]$st.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',180)));[void]$st.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)));[void]$st.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',120)));foreach($height in @(30,30,30,38)){[void]$st.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height)))}
    $script:UI.ResetOU=New-Object Windows.Forms.TextBox;$script:UI.ResetOU.Dock='Fill';$browse=New-Button 'Browse...';$browse.Add_Click({$x=Select-ADObjectDialog 'Container';if($x){$script:UI.ResetOU.Text=$x.DistinguishedName}})
    $script:UI.ResetScope=New-Object Windows.Forms.ComboBox;$script:UI.ResetScope.DropDownStyle='DropDownList';$script:UI.ResetScope.Items.AddRange(@('Selected container only','Include child OUs'));$script:UI.ResetScope.SelectedIndex=0
    $script:UI.ServiceFilter=New-Object Windows.Forms.TextBox;$script:UI.ServiceFilter.Dock='Fill';$script:UI.ServiceFilter.Text='(?i)^(svc|service)[._-]|service account'
    $script:UI.ResetOU.Add_TextChanged({Invalidate-ResetSelection 'OU/container changed.'});$script:UI.ResetScope.Add_SelectedIndexChanged({Invalidate-ResetSelection 'Search scope changed.'});$script:UI.ServiceFilter.Add_TextChanged({Invalidate-ResetSelection 'Service-account filter changed.'})
    $load=New-Button 'Load proposed users';$load.Add_Click({Load-ResetUsers})
    $st.Controls.Add((New-Label 'OU/container'),0,0);$st.Controls.Add($script:UI.ResetOU,1,0);$st.Controls.Add($browse,2,0);$st.Controls.Add((New-Label 'Search scope'),0,1);$st.Controls.Add($script:UI.ResetScope,1,1);$st.Controls.Add((New-Label 'Service-account exclusion regex'),0,2);$st.Controls.Add($script:UI.ServiceFilter,1,2);$st.Controls.Add($load,2,3);$source.Controls.Add($st)
    $script:UI.ResetCount=New-Label 'Exactly 0 account(s) selected';$script:UI.ResetCount.Font=New-Object Drawing.Font('Segoe UI',10,[Drawing.FontStyle]::Bold)
    $script:UI.ResetGrid=New-Grid;$script:UI.ResetGrid.Add_CellValueChanged({Update-ResetCount});$script:UI.ResetGrid.Add_CurrentCellDirtyStateChanged({if($script:UI.ResetGrid.IsCurrentCellDirty){$script:UI.ResetGrid.CommitEdit('Commit')}})
    $options=New-Object Windows.Forms.GroupBox;$options.Text='Password options';$options.Dock='Fill';$ot=New-Object Windows.Forms.TableLayoutPanel;$ot.Dock='Fill';$ot.ColumnCount=4;$ot.RowCount=3;[void]$ot.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',170)));[void]$ot.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',50)));[void]$ot.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',170)));[void]$ot.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',50)));foreach($height in @(34,40,45)){[void]$ot.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height)))}
    $script:UI.ResetPasswordMode=New-Object Windows.Forms.ComboBox;$script:UI.ResetPasswordMode.DropDownStyle='DropDownList';$script:UI.ResetPasswordMode.Items.AddRange(@('Unique secure password per user (recommended)','Custom fixed password'));$script:UI.ResetPasswordMode.SelectedIndex=0;$script:UI.ResetPasswordLength=New-Object Windows.Forms.NumericUpDown;$script:UI.ResetPasswordLength.Minimum=6;$script:UI.ResetPasswordLength.Maximum=128;$script:UI.ResetPasswordLength.Value=16
    $resetPwPanel=New-Object Windows.Forms.FlowLayoutPanel;$resetPwPanel.AutoSize=$true;$script:UI.ResetCustomPassword=New-Object Windows.Forms.TextBox;$script:UI.ResetCustomPassword.UseSystemPasswordChar=$true;$script:UI.ResetCustomPassword.Width=190;$show=New-Object Windows.Forms.CheckBox;$show.Text='Show';$show.AutoSize=$true;$show.Add_CheckedChanged({param($sender,$eventArgs)$script:UI.ResetCustomPassword.UseSystemPasswordChar=-not $sender.Checked});$resetPwPanel.Controls.AddRange(@($script:UI.ResetCustomPassword,$show))
    $script:UI.ResetForceChange=New-Object Windows.Forms.CheckBox;$script:UI.ResetForceChange.Text='Force change at next logon';$script:UI.ResetForceChange.Checked=$true;$script:UI.ResetForceChange.AutoSize=$true;$script:UI.ResetUnlock=New-Object Windows.Forms.CheckBox;$script:UI.ResetUnlock.Text='Unlock account (optional)';$script:UI.ResetUnlock.Checked=$false;$script:UI.ResetUnlock.AutoSize=$true
    $ot.Controls.Add((New-Label 'Password strategy'),0,0);$ot.Controls.Add($script:UI.ResetPasswordMode,1,0);$ot.Controls.Add((New-Label 'Length (minimum 6)'),2,0);$ot.Controls.Add($script:UI.ResetPasswordLength,3,0);$ot.Controls.Add((New-Label 'Custom fixed password'),0,1);$ot.Controls.Add($resetPwPanel,1,1);$ot.Controls.Add($script:UI.ResetForceChange,2,1);$ot.Controls.Add($script:UI.ResetUnlock,3,1);$warn=New-Label 'Fixed passwords are risky. Preview never changes AD. Passwords are never written to the ordinary audit log.';$warn.ForeColor=[Drawing.Color]::DarkRed;$ot.Controls.Add($warn,0,2);$ot.SetColumnSpan($warn,4);$options.Controls.Add($ot)
    $actions=New-Object Windows.Forms.FlowLayoutPanel;$actions.Dock='Fill';$script:UI.RunReset=New-Button 'Preview / Run Password Reset';$actions.Controls.Add($script:UI.RunReset);$script:UI.RunReset.Add_Click({Start-PasswordReset})
    $script:UI.ResetResults=New-Grid;$script:UI.ResetResults.AutoGenerateColumns=$false;foreach($def in @(@('Username','Username',130),@('Name','Name',170),@('Status','Status',100),@('Result','Result',520))){$c=New-Object Windows.Forms.DataGridViewTextBoxColumn;$c.HeaderText=$def[0];$c.Name=$def[1];$c.Width=$def[2];[void]$script:UI.ResetResults.Columns.Add($c)}
    $layout.Controls.Add($source,0,0);$layout.Controls.Add($script:UI.ResetCount,0,1);$layout.Controls.Add($script:UI.ResetGrid,0,2);$layout.Controls.Add($options,0,3);$layout.Controls.Add($actions,0,4);$layout.Controls.Add($script:UI.ResetResults,0,5);$tab.Controls.Add($layout);return $tab
}

function Build-LogsTab {
    $tab=New-Object Windows.Forms.TabPage;$tab.Text='Logs & Settings';$layout=New-Object Windows.Forms.TableLayoutPanel;$layout.Dock='Fill';$layout.Padding=New-Object System.Windows.Forms.Padding(8);$layout.RowCount=3;$layout.ColumnCount=1;foreach($style in @(@('Absolute',85),@('Percent',100),@('Absolute',45))){[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle($style[0],$style[1])))}
    $info=New-Label "Runtime requirements: Windows PowerShell 5.1, WinForms, and the Microsoft ActiveDirectory module (RSAT).`r`nPreview mode is the default. This program does not change execution policy and ordinary logs never include passwords."
    $script:UI.LogBox=New-Object Windows.Forms.TextBox;$script:UI.LogBox.Dock='Fill';$script:UI.LogBox.Multiline=$true;$script:UI.LogBox.ScrollBars='Both';$script:UI.LogBox.ReadOnly=$true;$script:UI.LogBox.Font=New-Object Drawing.Font('Consolas',9)
    $buttons=New-Object Windows.Forms.FlowLayoutPanel;$buttons.Dock='Fill';$export=New-Button 'Export audit log...';$clear=New-Button 'Clear displayed log';$buttons.Controls.AddRange(@($export,$clear));$export.Add_Click({Export-GeneralLog});$clear.Add_Click({$script:UI.LogBox.Clear()})
    $layout.Controls.Add($info,0,0);$layout.Controls.Add($script:UI.LogBox,0,1);$layout.Controls.Add($buttons,0,2);$tab.Controls.Add($layout);return $tab
}

function Build-MainForm {
    $form=New-Object Windows.Forms.Form;$form.Text='AD User Provisioning Tool';$form.StartPosition='CenterScreen';$form.Size='1400,900';$form.MinimumSize='1100,720';$form.Font=New-Object Drawing.Font('Segoe UI',9);$form.AutoScaleMode='Dpi';$script:UI.Form=$form
    $root=New-Object Windows.Forms.TableLayoutPanel;$root.Dock='Fill';$root.RowCount=3;$root.ColumnCount=1;foreach($style in @(@('Absolute',78),@('Percent',100),@('Absolute',28))){[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle($style[0],$style[1])))}
    $banner=Build-ConnectionBanner;$tabs=New-Object Windows.Forms.TabControl;$tabs.Dock='Fill';$tabs.TabPages.Add((Build-ImportTab));$tabs.TabPages.Add((Build-PasswordTab));$tabs.TabPages.Add((Build-LogsTab));$script:UI.Status=New-Label 'Ready. Preview mode is enabled.';$script:UI.Status.Dock='Fill';$script:UI.Status.BorderStyle='Fixed3D'
    $root.Controls.Add($banner,0,0);$root.Controls.Add($tabs,0,1);$root.Controls.Add($script:UI.Status,0,2);$form.Controls.Add($root)
    $form.Add_FormClosing({
        if($script:BusyTimer){
            $context=$script:BusyTimer.Tag
            if($context -and $context.PSObject.Properties['FixedPassword']){$context.FixedPassword=$null}
            if($context -and $context.PSObject.Properties['Plan']){foreach($row in $context.Plan.Rows){$row.Password=$null}}
            $script:BusyTimer.Stop();$script:BusyTimer.Tag=$null;$script:BusyTimer.Dispose();$script:BusyTimer=$null
        }
        $script:UI.ImportCustomPassword.Clear();$script:UI.ResetCustomPassword.Clear();$script:State.Connection.Credential=$null
    })
    Update-ConnectionBanner;Add-AuditLog 'Application started in Preview mode.';return $form
}

$mainForm=Build-MainForm
try { [void]$mainForm.ShowDialog() }
finally {
    if($script:BusyTimer){$script:BusyTimer.Stop();$script:BusyTimer.Dispose()}
    $script:State.Connection.Credential=$null
    $mainForm.Dispose()
}
