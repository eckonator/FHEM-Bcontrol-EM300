################################################################################
# $Id: 73_BControl.pm 00001 2026-05-01 00:00:00Z markus $
#
# FHEM module for B-Control EM300 energy manager / Heizstab controller
# Fetches sensor data directly via the device's local HTTP API.
#
# Replaces: HTTPMOD + DOIF + AT setup from bcontrol.cfg
# Backward-compatible: all previous reading names are preserved.
#
# API: POST /start.php (cookie login) + GET /mum-webservice/unieq.php
#
# by Markus Eckert https://github.com/eckonator/
#
# This file is part of fhem.
# Fhem is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
################################################################################

package main;

use strict;
use warnings;
use HttpUtils;
use JSON;
use Time::HiRes qw(gettimeofday);
use POSIX       qw(strftime);
use URI::Escape qw(uri_escape);

my $BC_VERSION     = "1.0.0";
my $BC_DATA_PATH   = '/mum-webservice/unieq.php?method=GET&identifier=remaked&context=sensor';
my $BC_LOGIN_PATH  = '/start.php';

################################################################################
# Initialize
################################################################################

sub BControl_Initialize {
    my ($hash) = @_;
    $hash->{DefFn}    = \&BControl_Define;
    $hash->{UndefFn}  = \&BControl_Undef;
    $hash->{DeleteFn} = \&BControl_Delete;
    $hash->{SetFn}    = \&BControl_Set;
    $hash->{GetFn}    = \&BControl_Get;
    $hash->{AttrFn}   = \&BControl_Attr;
    $hash->{AttrList} =
        "interval " .
        "port " .
        "disable:1,0 " .
        "disabledForIntervals " .
        $readingFnAttributes;
    return;
}

################################################################################
# Define
################################################################################

sub BControl_Define {
    my ($hash, $def) = @_;
    my @a = split /\s+/, $def;
    return "Usage: define <name> BControl <ip> [<port>]" if @a < 3;

    my $name = $a[0];
    my $ip   = $a[2];
    my $port = $a[3] // 80;

    $hash->{IP}      = $ip;
    $hash->{PORT}    = $port;
    $hash->{VERSION} = $BC_VERSION;

    RemoveInternalTimer($hash);

    my ($err, $pw) = getKeyValue($name . '_password');
    if ($err || !defined $pw) {
        readingsSingleUpdate($hash, 'state',
            "Passwort setzen: set $name password <Passwort>  ODER: set $name nopassword", 1);
        return;
    }

    readingsSingleUpdate($hash, 'state', 'initializing', 1);
    InternalTimer(gettimeofday() + 2, \&BControl_Login, $hash);
    return;
}

################################################################################
# Undef
################################################################################

sub BControl_Undef {
    my ($hash, $name) = @_;
    RemoveInternalTimer($hash);
    return;
}

################################################################################
# Delete – remove stored password
################################################################################

sub BControl_Delete {
    my ($hash, $name) = @_;
    setKeyValue($name . '_password', undef);
    return;
}

################################################################################
# Set
################################################################################

sub BControl_Set {
    my ($hash, $name, $cmd, @args) = @_;

    if ($cmd eq 'password') {
        return "Usage: set $name password <Passwort>" unless @args;
        setKeyValue($name . '_password', join(' ', @args));
        Log3($name, 3, "$name: password stored");
        RemoveInternalTimer($hash);
        BControl_Login($hash);
        return;
    }

    if ($cmd eq 'nopassword') {
        setKeyValue($name . '_password', '');
        Log3($name, 3, "$name: configured without password");
        RemoveInternalTimer($hash);
        BControl_Login($hash);
        return;
    }

    if ($cmd eq 'update') {
        BControl_UpdateData($hash);
        return;
    }

    if ($cmd eq 'relogin') {
        $hash->{'.cookie'} = undef;
        RemoveInternalTimer($hash);
        BControl_Login($hash);
        return;
    }

    if ($cmd eq 'Boilertemperatur_soll') {
        return "Usage: set $name Boilertemperatur_soll <Grad>" unless @args;
        my $val = $args[0];
        return "Invalid temperature (0-99)" unless $val =~ /^\d+(\.\d+)?$/ && $val >= 0 && $val <= 99;
        BControl_SetTemperature($hash, $val);
        return;
    }

    my @opts = qw(password nopassword:noArg update:noArg relogin:noArg Boilertemperatur_soll);
    return "Unknown argument $cmd, choose one of " . join(' ', @opts);
}

################################################################################
# Get
################################################################################

sub BControl_Get {
    my ($hash, $name, $cmd) = @_;
    if ($cmd eq 'update') {
        BControl_UpdateData($hash);
        return;
    }
    if ($cmd eq 'raw') {
        BControl_GetRaw($hash);
        return;
    }
    return "Unknown argument $cmd, choose one of update:noArg raw:noArg";
}

################################################################################
# Attr
################################################################################

sub BControl_Attr {
    my ($cmd, $name, $attr, $val) = @_;
    my $hash = $defs{$name};
    return unless $hash;

    if ($attr eq 'disable') {
        if ($cmd eq 'set' && $val) {
            RemoveInternalTimer($hash);
            readingsSingleUpdate($hash, 'state', 'disabled', 1);
        } else {
            InternalTimer(gettimeofday() + 1, \&BControl_Login, $hash);
        }
    }
    if ($attr eq 'interval' && $cmd eq 'set') {
        RemoveInternalTimer($hash, \&BControl_UpdateData);
        InternalTimer(gettimeofday() + ($val // 60),
            \&BControl_UpdateData, $hash);
    }
    return;
}

################################################################################
# Internal helpers
################################################################################

# Set readings when device is unreachable (no power / network down)
sub BC_SetOfflineReadings {
    my ($hash, $err, $code) = @_;
    if (!$code || $code == 0) {
        # No HTTP response at all → device is off (inverter cut power)
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, 'deviceState',        'offline');
        readingsBulkUpdate($hash, 'Heizstab_500W',       'off');
        readingsBulkUpdate($hash, 'Heizstab_1000W',      'off');
        readingsBulkUpdate($hash, 'Heizstab_2000W',      'off');
        readingsBulkUpdate($hash, 'Heizstab_Total_Watt', '0');
        readingsBulkUpdate($hash, 'state',               'heaterOffline');
        readingsEndUpdate($hash, 1);
    } else {
        readingsSingleUpdate($hash, 'state', "error: HTTP $code", 1);
    }
    return;
}

sub BC_BaseURL {
    my ($hash) = @_;
    my $port = AttrVal($hash->{NAME}, 'port', $hash->{PORT} // 80);
    return "http://$hash->{IP}:$port";
}

sub BC_Headers {
    my ($hash) = @_;
    my $h = "Content-Type: application/x-www-form-urlencoded\r\nAccept: application/json";
    $h   .= "\r\nCookie: " . $hash->{'.cookie'} if $hash->{'.cookie'};
    return $h;
}

sub BC_IsDisabled {
    my ($hash) = @_;
    return IsDisabled($hash->{NAME});
}

sub BC_ScheduleRetry {
    my ($hash) = @_;
    my $delay = AttrVal($hash->{NAME}, 'interval', 60) * 3;
    RemoveInternalTimer($hash, \&BControl_Login);
    InternalTimer(gettimeofday() + $delay, \&BControl_Login, $hash);
}

sub BC_ScheduleUpdate {
    my ($hash) = @_;
    my $delay = AttrVal($hash->{NAME}, 'interval', 60);
    RemoveInternalTimer($hash, \&BControl_UpdateData);
    InternalTimer(gettimeofday() + $delay, \&BControl_UpdateData, $hash);
}

# Parse the first usable Set-Cookie value from response headers
sub BC_ParseCookie {
    my ($headers) = @_;
    return undef unless defined $headers;
    if ($headers =~ /Set-Cookie:\s*([^;\r\n]+)/i) {
        return $1;
    }
    return undef;
}

################################################################################
# Login – POST /start.php to obtain session cookie
################################################################################

sub BControl_Login {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    return if BC_IsDisabled($hash);
    RemoveInternalTimer($hash, \&BControl_Login);

    my ($err, $pw) = getKeyValue($name . '_password');
    if ($err || !defined $pw) {
        readingsSingleUpdate($hash, 'state',
            "Passwort setzen: set $name password <Passwort>  ODER: set $name nopassword", 1);
        return;
    }
    $pw //= '';

    Log3($name, 4, "$name: BControl login – POST $BC_LOGIN_PATH");
    readingsSingleUpdate($hash, 'state', 'connecting', 1);

    my $body = 'password=' . uri_escape($pw);

    HttpUtils_NonblockingGet({
        url      => BC_BaseURL($hash) . $BC_LOGIN_PATH,
        timeout  => 15,
        hash     => $hash,
        method   => 'POST',
        header   => "Content-Type: application/x-www-form-urlencoded\r\nAccept: application/json",
        data     => $body,
        callback => \&BControl_LoginCb,
    });
}

sub BControl_LoginCb {
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    my $code = $param->{code} // 0;

    if ($err || ($code >= 400 && $code != 0)) {
        Log3($name, 2, "$name: login error (HTTP $code): " . ($err // $data));
        BC_SetOfflineReadings($hash, $err, $code);
        BC_ScheduleRetry($hash);
        return;
    }

    # Parse session cookie from response headers
    my $cookie = BC_ParseCookie($param->{httpheader});
    if (!$cookie) {
        # Some B-Control firmware versions return no cookie but accept requests anyway
        Log3($name, 4, "$name: no Set-Cookie in login response – proceeding without cookie");
    } else {
        $hash->{'.cookie'} = $cookie;
        Log3($name, 4, "$name: session cookie obtained");
    }

    # Check if login JSON confirms authentication
    my $json;
    eval { $json = JSON->new->utf8->decode($data) if $data && $data =~ /^\{/; };
    if ($json && defined $json->{authentication} && !$json->{authentication}) {
        Log3($name, 1, "$name: authentication rejected by device – wrong password?");
        readingsSingleUpdate($hash, 'state', 'login error: wrong password', 1);
        return;
    }

    # Store serial / version if provided at login
    if ($json) {
        $hash->{SERIAL}      = $json->{serial}      if $json->{serial};
        $hash->{APP_VERSION} = $json->{app_version} if $json->{app_version};
    }

    Log3($name, 3, "$name: login successful");
    BControl_UpdateData($hash);
}

################################################################################
# UpdateData – GET sensor endpoint
################################################################################

sub BControl_UpdateData {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    return if BC_IsDisabled($hash);
    RemoveInternalTimer($hash, \&BControl_UpdateData);

    unless ($hash->{'.cookie'}) {
        BControl_Login($hash);
        return;
    }

    Log3($name, 5, "$name: fetching sensor data");

    HttpUtils_NonblockingGet({
        url      => BC_BaseURL($hash) . $BC_DATA_PATH,
        timeout  => 15,
        hash     => $hash,
        method   => 'GET',
        header   => BC_Headers($hash),
        callback => \&BControl_UpdateDataCb,
    });
}

sub BControl_UpdateDataCb {
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    my $code = $param->{code} // 0;

    $hash->{API_LAST_MSG} = $code;

    if ($err || ($code >= 400 && $code != 0)) {
        Log3($name, 2, "$name: data fetch error (HTTP $code): " . ($err // ''));
        BC_SetOfflineReadings($hash, $err, $code);
        $hash->{'.cookie'} = undef;
        BC_ScheduleRetry($hash);
        return;
    }

    my $json;
    eval { $json = JSON->new->utf8->decode($data); };
    if ($@ || ref($json) ne 'HASH') {
        Log3($name, 2, "$name: JSON parse error: $@");
        readingsSingleUpdate($hash, 'state', 'json error', 1);
        BC_ScheduleUpdate($hash);
        return;
    }

    # Re-auth check
    if (defined $json->{authentication} && !$json->{authentication}) {
        Log3($name, 3, "$name: session expired – re-login");
        $hash->{'.cookie'} = undef;
        BControl_Login($hash);
        return;
    }

    BC_WriteReadings($hash, $json);
    BC_ScheduleUpdate($hash);
}

################################################################################
# WriteReadings – map JSON keys → FHEM readings
################################################################################

sub BC_WriteReadings {
    my ($hash, $j) = @_;
    my $name = $hash->{NAME};

    # Helper: value or default
    my $v = sub { defined $j->{$_[0]} ? $j->{$_[0]} : ($_[1] // '') };

    readingsBeginUpdate($hash);

    # ── Backward-compatible readings (identical to previous HTTPMOD setup) ────
    readingsBulkUpdate($hash, 'Heizstab_500W',          $v->('meters_01_switches_01_state', 'off'));
    readingsBulkUpdate($hash, 'Heizstab_1000W',         $v->('meters_01_switches_02_state', 'off'));
    readingsBulkUpdate($hash, 'Heizstab_2000W',         $v->('meters_01_switches_03_state', 'off'));
    readingsBulkUpdate($hash, 'Heizstab_Total_Watt',    $v->('meters_01_registers_01_value', '0'));
    readingsBulkUpdate($hash, 'Boilertemperatur_ist',   $v->('meters_01_temperatur_boiler',  '0'));
    readingsBulkUpdate($hash, 'Boilertemperatur_soll',  $v->('meters_01_user_temperatur_nominal', '0'));

    # ── Device state ──────────────────────────────────────────────────────────
    my $dev_state = $v->('meters_01_state', 'unknown');
    readingsBulkUpdate($hash, 'deviceState', $dev_state);

    # ── Extended power meter readings (EM300 energy measurement) ─────────────
    # Active power per phase + total [W]
    for my $suffix (qw(total L1 L2 L3)) {
        my $key = "meters_01_total_active_power_$suffix";
        $key    = "meters_01_total_active_power" if $suffix eq 'total';
        readingsBulkUpdate($hash, "Power_$suffix", sprintf('%.2f', $v->($key, 0)))
            if defined $j->{$key};
    }

    # Voltage per phase [V]
    for my $ph (1..3) {
        my $key = "meters_01_voltage_L${ph}N";
        readingsBulkUpdate($hash, "Voltage_L$ph", sprintf('%.2f', $v->($key, 0)))
            if defined $j->{$key};
    }

    # Current per phase [A]
    for my $ph (1..3) {
        my $key = "meters_01_current_L$ph";
        readingsBulkUpdate($hash, "Current_L$ph", sprintf('%.3f', $v->($key, 0)))
            if defined $j->{$key};
    }

    # Frequency [Hz] and Power Factor
    readingsBulkUpdate($hash, 'Frequency',    sprintf('%.2f', $v->('meters_01_frequency', 0)))
        if defined $j->{'meters_01_frequency'};
    readingsBulkUpdate($hash, 'PowerFactor',  sprintf('%.3f', $v->('meters_01_power_factor', 0)))
        if defined $j->{'meters_01_power_factor'};

    # Total energy [Wh → kWh]
    for my $key (grep { /total_energy/ } keys %$j) {
        my $rname = $key;
        $rname =~ s/^meters_01_//;
        $rname =~ s/[^a-zA-Z0-9_]/_/g;
        readingsBulkUpdate($hash, $rname, sprintf('%.3f', ($j->{$key} // 0) / 1000));
    }

    my $ts = strftime('%Y-%m-%d %H:%M:%S', localtime());
    readingsBulkUpdate($hash, 'lastUpdate', $ts);

    readingsEndUpdate($hash, 1);

    # ── State string ──────────────────────────────────────────────────────────
    my $total_w = $v->('meters_01_registers_01_value',       '0');
    my $b_ist   = $v->('meters_01_temperatur_boiler',        '0');
    my $b_soll  = $v->('meters_01_user_temperatur_nominal',  '0');
    my $sw500   = $v->('meters_01_switches_01_state',        'off');
    my $sw1000  = $v->('meters_01_switches_02_state',        'off');
    my $sw2000  = $v->('meters_01_switches_03_state',        'off');

    my $state = ($dev_state eq 'online')
        ? "Verbrauch: $total_w W | Boilertemp. Soll: $b_soll °C | "
          . "Boilertemp. Ist: $b_ist °C | "
          . "Heizer 500 W: $sw500 | Heizer 1000 W: $sw1000 | Heizer 2000 W: $sw2000"
        : 'heaterOffline';

    readingsSingleUpdate($hash, 'state', $state, 1);

    $hash->{API_LAST_RES} = int(gettimeofday());
    my $interval = AttrVal($name, 'interval', 60);
    $hash->{NEXT}   = FmtDateTime(gettimeofday() + $interval);
    $hash->{SOURCE} = BC_BaseURL($hash) . $BC_DATA_PATH;

    Log3($name, 5, "$name: readings updated – deviceState=$dev_state Heizstab=${total_w}W Boiler=${b_ist}°C/${b_soll}°C");
}

################################################################################
# SetTemperature – write nominal boiler temperature
################################################################################

sub BControl_SetTemperature {
    my ($hash, $temp) = @_;
    my $name = $hash->{NAME};

    # Try the SET endpoint first; fall back to POST with JSON body if needed
    my $url  = BC_BaseURL($hash) .
               '/mum-webservice/unieq.php?method=SET&identifier=remaked&context=sensor';

    Log3($name, 3, "$name: setting Boilertemperatur_soll = $temp");

    HttpUtils_NonblockingGet({
        url      => $url,
        timeout  => 10,
        hash     => $hash,
        method   => 'POST',
        header   => "Content-Type: application/json\r\nAccept: application/json"
                  . "\r\nCookie: " . ($hash->{'.cookie'} // ''),
        data     => JSON->new->utf8->encode(
                        { meters_01_user_temperatur_nominal => "$temp" }
                    ),
        callback => sub {
            my ($p, $e, $d) = @_;
            my $c = $p->{code} // 0;
            if ($e || ($c >= 400 && $c != 0)) {
                Log3($name, 2, "$name: SetTemperature failed (HTTP $c): " . ($e // ''));
            } else {
                Log3($name, 3, "$name: SetTemperature OK ($temp °C)");
                readingsSingleUpdate($hash, 'Boilertemperatur_soll', $temp, 1);
            }
        },
    });
}

################################################################################
# GetRaw – fetch raw JSON for debugging
################################################################################

sub BControl_GetRaw {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    HttpUtils_NonblockingGet({
        url      => BC_BaseURL($hash) . $BC_DATA_PATH,
        timeout  => 15,
        hash     => $hash,
        method   => 'GET',
        header   => BC_Headers($hash),
        callback => sub {
            my ($p, $e, $d) = @_;
            Log3($name, 1, "$name: RAW response: " . ($e // $d // '(empty)'));
        },
    });
}

1;

=pod
=item device
=item summary FHEM module for B-Control EM300 energy manager / Heizstab controller
=item summary_DE FHEM-Modul für den B-Control EM300 Energiemanager / Heizstab

=begin html

<a name="BControl"></a>
<h3>BControl</h3>

<p>Fetches sensor data from a <b>B-Control EM300</b> energy manager directly
via its local HTTP API. Replaces the previous <code>HTTPMOD + DOIF + AT</code>
setup with a single native module.</p>

<p>All previous reading names are preserved so that existing DbLog definitions
and SVG plots continue to work without any changes.</p>

<p><b>Requirements:</b> only standard Perl modules (<code>JSON</code>,
<code>URI::Escape</code>) and FHEM's built-in <code>HttpUtils</code>.</p>

<a name="BControldefine"></a>
<b>Define</b>
<ul>
  <code>define &lt;name&gt; BControl &lt;ip&gt; [&lt;port&gt;]</code><br><br>
  <table>
    <tr><td><code>ip</code></td><td>IP address or hostname of the B-Control device</td></tr>
    <tr><td><code>port</code></td><td>HTTP port (default: 80)</td></tr>
  </table>
</ul>

<a name="BControlset"></a>
<b>Set</b>
<ul>
  <li><code>password &lt;pw&gt;</code> &ndash; store password encrypted and trigger login</li>
  <li><code>nopassword</code> &ndash; configure login without a password (B-Control WebGUI: "Anmeldung ohne Kennwort")</li>
  <li><code>update</code> &ndash; immediate data refresh</li>
  <li><code>relogin</code> &ndash; reset session and re-authenticate</li>
  <li><code>Boilertemperatur_soll &lt;°C&gt;</code> &ndash; set nominal boiler temperature (0–99 °C)</li>
</ul>

<a name="BControlget"></a>
<b>Get</b>
<ul>
  <li><code>update</code> &ndash; immediate data refresh</li>
  <li><code>raw</code> &ndash; dump raw JSON response to FHEM log (debug)</li>
</ul>

<a name="BControlattr"></a>
<b>Attributes</b>
<ul>
  <li><code>interval</code> &ndash; poll interval in seconds (default: 60)</li>
  <li><code>port</code> &ndash; HTTP port override (default: 80)</li>
  <li><code>disable</code> &ndash; disable all polling (1/0)</li>
  <li><code>disabledForIntervals</code> &ndash; pause polling in time ranges, e.g. <code>00:00-06:00</code></li>
</ul>

<a name="BControlreadings"></a>
<b>Readings</b>
<ul>
  <li><code>Heizstab_500W</code> &ndash; 500 W stage state (on/off)</li>
  <li><code>Heizstab_1000W</code> &ndash; 1000 W stage state (on/off)</li>
  <li><code>Heizstab_2000W</code> &ndash; 2000 W stage state (on/off)</li>
  <li><code>Heizstab_Total_Watt</code> &ndash; total heater power (W)</li>
  <li><code>Boilertemperatur_ist</code> &ndash; current boiler temperature (°C)</li>
  <li><code>Boilertemperatur_soll</code> &ndash; target boiler temperature (°C)</li>
  <li><code>deviceState</code> &ndash; device state from meters_01_state (online/offline)</li>
  <li><code>Power_L1 / L2 / L3 / total</code> &ndash; active power per phase and total (W)</li>
  <li><code>Voltage_L1 / L2 / L3</code> &ndash; phase voltage (V)</li>
  <li><code>Current_L1 / L2 / L3</code> &ndash; phase current (A)</li>
  <li><code>Frequency</code> &ndash; grid frequency (Hz)</li>
  <li><code>PowerFactor</code> &ndash; power factor</li>
  <li><code>lastUpdate</code> &ndash; timestamp of last successful fetch</li>
</ul>

=end html

=cut
