################################################################################
# $Id: 73_BControl.pm 00003 2026-05-03 00:00:00Z markus $
#
# FHEM module for the E.G.O. Smart Heater via B-Control energy manager
# (compatible with B-Control EM210, EM300 and similar models)
# Fetches sensor data directly via the device's local HTTP API.
#
# API: POST /start.php (cookie login)
#      GET  /mum-webservice/consumption.php?meter_id=<n>
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

my $BC_VERSION    = "2.0.0";
my $BC_LOGIN_PATH = '/start.php';

# meter_id → JSON key prefix: meter_id=4 → "05_" (meter_id+1, zero-padded)
sub BC_Prefix { return sprintf('%02d_', ($_[0] // 4) + 1) }
sub BC_DataPath { return '/mum-webservice/consumption.php?meter_id=' . ($_[0] // 4) }

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
    return "Usage: define <name> BControl <ip> <meter_id> [<port>]" if @a < 4;

    my $name     = $a[0];
    my $ip       = $a[2];
    my $meter_id = $a[3];
    my $port     = $a[4] // 80;

    return "meter_id must be a number" unless $meter_id =~ /^\d+$/;

    $hash->{IP}       = $ip;
    $hash->{METER_ID} = $meter_id;
    $hash->{PORT}     = $port;
    $hash->{VERSION}  = $BC_VERSION;

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
# Undef / Delete
################################################################################

sub BControl_Undef {
    my ($hash, $name) = @_;
    RemoveInternalTimer($hash);
    return;
}

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

    my @opts = qw(password nopassword:noArg update:noArg relogin:noArg);
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
        InternalTimer(gettimeofday() + ($val // 60), \&BControl_UpdateData, $hash);
    }
    return;
}

################################################################################
# Internal helpers
################################################################################

sub BC_SetOfflineReadings {
    my ($hash, $err, $code) = @_;
    if (!$code || $code == 0) {
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, 'deviceState', 'offline');
        readingsBulkUpdate($hash, 'power_W',     '0');
        readingsBulkUpdate($hash, 'state',       'heaterOffline');
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
    my $h = "Accept: application/json";
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

sub BC_ParseCookie {
    my ($headers) = @_;
    return undef unless defined $headers;
    if ($headers =~ /Set-Cookie:\s*([^;\r\n]+)/i) {
        return $1;
    }
    return undef;
}

################################################################################
# Login – POST /start.php
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

    HttpUtils_NonblockingGet({
        url      => BC_BaseURL($hash) . $BC_LOGIN_PATH,
        timeout  => 15,
        hash     => $hash,
        method   => 'POST',
        header   => "Content-Type: application/x-www-form-urlencoded\r\nAccept: application/json",
        data     => 'password=' . uri_escape($pw),
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

    my $cookie = BC_ParseCookie($param->{httpheader});
    if (!$cookie) {
        Log3($name, 4, "$name: no Set-Cookie in login response – proceeding without cookie");
        $hash->{'.cookie'} = '';
    } else {
        $hash->{'.cookie'} = $cookie;
        Log3($name, 4, "$name: session cookie obtained");
    }

    my $json;
    eval { $json = JSON->new->utf8->decode($data) if $data && $data =~ /^\{/; };
    if ($json && defined $json->{authentication} && !$json->{authentication}) {
        Log3($name, 1, "$name: authentication rejected – wrong password?");
        readingsSingleUpdate($hash, 'state', 'login error: wrong password', 1);
        return;
    }

    Log3($name, 3, "$name: login successful");
    BControl_UpdateData($hash);
}

################################################################################
# UpdateData – GET consumption endpoint
################################################################################

sub BControl_UpdateData {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    return if BC_IsDisabled($hash);
    RemoveInternalTimer($hash, \&BControl_UpdateData);

    unless (defined $hash->{'.cookie'}) {
        BControl_Login($hash);
        return;
    }

    my $url = BC_BaseURL($hash) . BC_DataPath($hash->{METER_ID});
    Log3($name, 5, "$name: fetching $url");

    HttpUtils_NonblockingGet({
        url      => $url,
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
        Log3($name, 2, "$name: JSON parse error: $@  data=[$data]");
        readingsSingleUpdate($hash, 'state', 'json error', 1);
        BC_ScheduleUpdate($hash);
        return;
    }

    if (defined $json->{authentication} && !$json->{authentication}) {
        Log3($name, 3, "$name: session expired – re-login");
        $hash->{'.cookie'} = undef;
        BControl_Login($hash);
        return;
    }

    eval { BC_WriteReadings($hash, $json); };
    if ($@) {
        Log3($name, 2, "$name: BC_WriteReadings error: $@");
        readingsSingleUpdate($hash, 'state', 'internal error', 1);
    }
    BC_ScheduleUpdate($hash);
}

################################################################################
# WriteReadings – map JSON → FHEM readings
#
# JSON structure (consumption.php?meter_id=4, prefix "05_"):
#   authentication, meter_id, is_smartheater
#   05_power         – current power in kW
#   05_energy        – total energy in kWh
#   05_status        – 0 = OK
#   05_meter_label   – device description
#   05_meter_number  – meter serial
#   sum_power        – total power of all meters [kW]
#   registers        – array: [{register, value}, ...]
#                      "1-0:1.4.0*255" = active power [W]
#                      "1-0:1.8.0*255" = total energy [Wh]
################################################################################

sub BC_WriteReadings {
    my ($hash, $j) = @_;
    my $name   = $hash->{NAME};
    my $mid    = $hash->{METER_ID};
    my $prefix = BC_Prefix($mid);          # e.g. "05_"

    # Pull active-power register value [W] – most accurate source
    my $power_w = undef;
    my $energy_wh = undef;
    if (ref($j->{registers}) eq 'ARRAY') {
        for my $reg (@{$j->{registers}}) {
            next unless ref($reg) eq 'HASH';
            if (($reg->{register} // '') =~ /1-0:1\.4\.0/) {
                $power_w   = $reg->{value};
            }
            if (($reg->{register} // '') =~ /1-0:1\.8\.0/) {
                $energy_wh = $reg->{value};
            }
        }
    }
    # Fallback: 05_power is in kW
    $power_w //= ($j->{"${prefix}power"} // 0) * 1000;

    my $status        = $j->{"${prefix}status"}       // -1;
    my $energy_kwh    = $j->{"${prefix}energy"}        // 0;
    my $label         = $j->{"${prefix}meter_label"}   // '';
    my $meter_nr      = $j->{"${prefix}meter_number"}  // '';
    my $is_heater     = $j->{is_smartheater}           ? 1 : 0;
    my $lastresponse  = $j->{"${prefix}lastresponse"}  // '';

    # status=0 means OK/online for the smart heater
    my $dev_state = ($status == 0) ? 'online' : "status_$status";

    # No register data: BControl has not received any live measurement from the
    # heater (typical after a BControl restart while the heater is offline).
    # A connected-but-idle heater would still deliver registers with value 0.
    if ($dev_state eq 'online' && ref($j->{registers}) ne 'ARRAY') {
        Log3($name, 3, "$name: heater offline – registers=null (no live data from heater)");
        $dev_state = 'offline';
    }

    # Stale-data detection: when the heater loses power the B-Control stays reachable
    # but freezes 05_lastresponse and holds the last power reading.
    # If the heater heartbeat hasn't advanced since the previous poll and power is
    # non-zero, the reading is stale and the heater is effectively offline.
    if ($dev_state eq 'online'
        && $lastresponse ne ''
        && ($hash->{'.lastresponse'} // '') ne ''
        && $lastresponse eq $hash->{'.lastresponse'}
        && $power_w > 0) {
        Log3($name, 3, "$name: heater offline – 05_lastresponse frozen at $lastresponse (stale ${power_w}W)");
        $dev_state = 'offline';
    }
    $hash->{'.lastresponse'} = $lastresponse;

    readingsBeginUpdate($hash);

    readingsBulkUpdate($hash, 'deviceState',    $dev_state);
    readingsBulkUpdate($hash, 'power_W',        sprintf('%.0f', $power_w));
    readingsBulkUpdate($hash, 'energy_kWh',     sprintf('%.3f', $energy_kwh));
    readingsBulkUpdate($hash, 'meter_status',   $status);
    readingsBulkUpdate($hash, 'is_smartheater', $is_heater);
    readingsBulkUpdate($hash, 'meter_label',    $label)        if $label;
    readingsBulkUpdate($hash, 'meter_number',   $meter_nr)     if $meter_nr;
    readingsBulkUpdate($hash, 'lastresponse',   $lastresponse) if $lastresponse ne '';

    if (defined $energy_wh) {
        readingsBulkUpdate($hash, 'energy_Wh', sprintf('%.3f', $energy_wh));
    }

    # Tariff / cost info
    readingsBulkUpdate($hash, 'tariff',          $j->{"${prefix}tariff"}          // '')
        if defined $j->{"${prefix}tariff"};
    readingsBulkUpdate($hash, 'tariff_currency', $j->{"${prefix}tariff_currency"} // '')
        if defined $j->{"${prefix}tariff_currency"};

    my $ts = strftime('%Y-%m-%d %H:%M:%S', localtime());
    readingsBulkUpdate($hash, 'lastUpdate', $ts);

    readingsEndUpdate($hash, 1);

    # State string – use plain 'heaterOffline' for all non-online cases so that
    # notify rules can match it uniformly; deviceState carries the specific reason.
    my $state = ($dev_state eq 'online')
        ? "online | ${power_w} W | ${energy_kwh} kWh"
        : 'heaterOffline';
    readingsSingleUpdate($hash, 'state', $state, 1);

    $hash->{API_LAST_RES} = int(gettimeofday());
    my $interval = AttrVal($name, 'interval', 60);
    $hash->{NEXT}   = FmtDateTime(gettimeofday() + $interval);
    $hash->{SOURCE} = BC_BaseURL($hash) . BC_DataPath($mid);

    Log3($name, 4, "$name: readings updated – $dev_state ${power_w}W ${energy_kwh}kWh");
}

################################################################################
# GetRaw – raw JSON dump for debugging
################################################################################

sub BControl_GetRaw {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $url  = BC_BaseURL($hash) . BC_DataPath($hash->{METER_ID});

    Log3($name, 1, "$name: GetRaw URL   : $url");
    Log3($name, 1, "$name: GetRaw cookie: " . ($hash->{'.cookie'} // '(undef)'));

    HttpUtils_NonblockingGet({
        url      => $url,
        timeout  => 15,
        hash     => $hash,
        method   => 'GET',
        header   => BC_Headers($hash),
        callback => sub {
            my ($p, $e, $d) = @_;
            my $code = $p->{code} // 'n/a';
            Log3($name, 1, "$name: GetRaw HTTP  : $code");
            Log3($name, 1, "$name: GetRaw ERR   : $e") if $e;
            Log3($name, 1, "$name: GetRaw BODY  : " . (defined $d && $d ne '' ? $d : '(empty)'));
        },
    });
}

1;

=pod
=item device
=item summary FHEM module for E.G.O. Smart Heater via B-Control energy manager
=item summary_DE FHEM-Modul für den E.G.O. Smart Heater über B-Control Energiemanager

=begin html

<a name="BControl"></a>
<h3>BControl SmartHeater</h3>

<p>Reads live data from an <b>E.G.O. Smart Heater</b> via the local HTTP API of a
<b>B-Control energy manager</b> (compatible with EM210, EM300 and similar models).
API endpoint: <code>/mum-webservice/consumption.php</code>.</p>

<a name="BControldefine"></a>
<b>Define</b>
<ul>
  <code>define &lt;name&gt; BControl &lt;ip&gt; &lt;meter_id&gt; [&lt;port&gt;]</code><br><br>
  <table>
    <tr><td><code>ip</code></td><td>IP address of the B-Control energy manager</td></tr>
    <tr><td><code>meter_id</code></td><td>Meter ID as shown in the B-Control web UI (e.g. 4)</td></tr>
    <tr><td><code>port</code></td><td>HTTP port (default: 80)</td></tr>
  </table>
  <br>Example: <code>define Heizstab BControl 192.168.178.115 4</code>
</ul>

<a name="BControlset"></a>
<b>Set</b>
<ul>
  <li><code>password &lt;pw&gt;</code> &ndash; store password and trigger login</li>
  <li><code>nopassword</code> &ndash; login without password</li>
  <li><code>update</code> &ndash; immediate data refresh</li>
  <li><code>relogin</code> &ndash; reset session and re-authenticate</li>
</ul>

<a name="BControlget"></a>
<b>Get</b>
<ul>
  <li><code>update</code> &ndash; immediate data refresh</li>
  <li><code>raw</code> &ndash; dump raw JSON to FHEM log (verbose 1)</li>
</ul>

<a name="BControlattr"></a>
<b>Attributes</b>
<ul>
  <li><code>interval</code> &ndash; poll interval in seconds (default: 60)</li>
  <li><code>port</code> &ndash; HTTP port override</li>
  <li><code>disable</code> &ndash; disable polling</li>
  <li><code>disabledForIntervals</code> &ndash; pause polling in time ranges</li>
</ul>

<a name="BControlreadings"></a>
<b>Readings</b>
<ul>
  <li><code>power_W</code> &ndash; current power consumption (W)</li>
  <li><code>energy_kWh</code> &ndash; total energy (kWh)</li>
  <li><code>energy_Wh</code> &ndash; total energy (Wh, from register)</li>
  <li><code>deviceState</code> &ndash; online / offline / status_N</li>
  <li><code>meter_status</code> &ndash; raw status value (0 = OK)</li>
  <li><code>is_smartheater</code> &ndash; 1 if device identifies as smart heater</li>
  <li><code>lastresponse</code> &ndash; heater heartbeat token (05_lastresponse); changes every poll while the heater is active, frozen when the heater loses power &ndash; used internally to detect stale readings</li>
  <li><code>meter_label</code> &ndash; device description</li>
  <li><code>meter_number</code> &ndash; meter serial number</li>
  <li><code>tariff</code> &ndash; current tariff (EUR/kWh)</li>
  <li><code>lastUpdate</code> &ndash; timestamp of last successful fetch</li>
</ul>

=end html

=cut
