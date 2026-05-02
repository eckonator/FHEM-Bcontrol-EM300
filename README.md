# 73_BControl.pm

FHEM-Modul für den **B-Control EM300 Smart Heater** – holt Echtzeitdaten direkt über die lokale HTTP-API des Geräts, ohne Cloud-Account oder externen Proxy.

> Getestet mit: **B-Control EM300** mit angeschlossenem E.G.O. Smart Heater
> Entwickelt als Ersatz für das bisherige Setup: `HTTPMOD` + `DOIF` + `AT` aus `bcontrol.cfg`

---

## Inhalt

- [Funktionsweise](#funktionsweise)
- [Voraussetzungen](#voraussetzungen)
- [Installation](#installation)
- [Einrichtung](#einrichtung)
- [Attribute](#attribute)
- [Set-Befehle](#set-befehle)
- [Get-Befehle](#get-befehle)
- [Internals](#internals)
- [Readings](#readings)
- [Beispiel-Konfiguration](#beispiel-konfiguration)
- [Webapp](#webapp)
- [Hintergrund: API-Flow](#hintergrund-api-flow)

---

## Funktionsweise

Das Modul verbindet sich direkt mit der **lokalen HTTP-API** des B-Control EM300 im Heimnetz. Kein Cloud-Account, kein externer Proxy.

Der Ablauf:

```
POST /start.php (Cookie-Login) → GET /mum-webservice/consumption.php?meter_id=<n> → Readings schreiben
```

Die Authentifizierung erfolgt über ein **Cookie-Session**-Verfahren. Bei `"authentication":false` in der Antwort oder bei Verbindungsproblemen wird automatisch neu angemeldet.

---

## Voraussetzungen

- FHEM ab Version 6.x
- Perl-Module (alle Standard, meist vorhanden):
  - `JSON` (sonst: `apt install libjson-perl`)
  - `URI::Escape` (sonst: `apt install liburi-perl`)
- `HttpUtils` (FHEM-intern, immer vorhanden)
- B-Control EM300 im lokalen Netzwerk (HTTP Port 80)
- Meter-ID des Heizstabs (in der B-Control WebGUI einsehbar)

---

## Installation

1. `73_BControl.pm` in das FHEM-Modulverzeichnis kopieren:

```bash
cp 73_BControl.pm /opt/fhem/FHEM/
```

2. FHEM neu starten oder das Modul laden:

```
reload 73_BControl
```

3. *(Optional)* Webapp installieren:

```bash
cp -r www/bcontrol /opt/fhem/www/
```

---

## Einrichtung

### 1. Device anlegen

```
define BControl_EnergyManager BControl <ip> <meter_id> [<port>]
```

Die **Meter-ID** findet man in der B-Control WebGUI unter dem jeweiligen Zähler. Beispiel:

```
define BControl_EnergyManager BControl 192.168.178.115 4
```

### 2. Passwort setzen

Das Passwort wird **verschlüsselt** im internen FHEM-Schlüsselspeicher abgelegt und erscheint **nicht** in der `fhem.cfg`.

```
# Mit Passwort:
set BControl_EnergyManager password deinPasswort

# Ohne Passwort (B-Control WebGUI: "Anmeldung ohne Kennwort"):
set BControl_EnergyManager nopassword
```

### 3. Intervall konfigurieren

```
attr BControl_EnergyManager interval 60
```

---

## Attribute

| Attribut | Standard | Beschreibung |
|---|---|---|
| `interval` | `60` | Abfrage-Intervall in Sekunden |
| `port` | `80` | HTTP-Port des Geräts |
| `disable` | `0` | `1` = alle Abfragen deaktivieren |
| `disabledForIntervals` | – | Abfragen in Zeitbereichen deaktivieren, z.B. `23:00-06:00` |

---

## Set-Befehle

| Befehl | Beschreibung |
|---|---|
| `set <name> password <Passwort>` | Passwort verschlüsselt speichern und Login starten |
| `set <name> nopassword` | Login ohne Passwort konfigurieren |
| `set <name> update` | Sofortigen Datenabruf anstoßen |
| `set <name> relogin` | Session zurücksetzen und neu anmelden |

---

## Get-Befehle

| Befehl | Beschreibung |
|---|---|
| `get <name> update` | Sofortiger Datenabruf |
| `get <name> raw` | Rohe JSON-Antwort des Geräts ins FHEM-Log schreiben (Debug, verbose 1) |

---

## Internals

| Internal | Beschreibung |
|---|---|
| `API_LAST_MSG` | Letzter HTTP-Status-Code (200 = OK) |
| `API_LAST_RES` | Unix-Timestamp des letzten erfolgreichen Abrufs |
| `NEXT` | Zeitpunkt des nächsten geplanten Abrufs |
| `SOURCE` | API-Endpunkt |
| `VERSION` | Modulversion |
| `METER_ID` | Konfigurierte Meter-ID |

---

## Readings

| Reading | Einheit | Beschreibung |
|---|---|---|
| `power_W` | W | Aktuelle Leistungsaufnahme (aus Register `1-0:1.4.0*255`) |
| `energy_kWh` | kWh | Gesamtenergie seit Inbetriebnahme |
| `energy_Wh` | Wh | Gesamtenergie (Rohwert aus Register `1-0:1.8.0*255`) |
| `deviceState` | – | `online` (status=0) oder `status_N` |
| `meter_status` | – | Rohwert des Gerätestatus (0 = OK) |
| `is_smartheater` | 0/1 | Gerät identifiziert sich als Smart Heater |
| `meter_label` | – | Gerätebeschreibung (z.B. "E.G.O. Elektro-Geraetebau GmbH Smart Heater") |
| `meter_number` | – | Zählerseriennummer |
| `tariff` | EUR/kWh | Aktueller Stromtarif |
| `tariff_currency` | – | Währung (z.B. EUR) |
| `lastUpdate` | – | Zeitstempel des letzten erfolgreichen Abrufs |
| `state` | – | Zusammenfassung: `online \| 500 W \| 1411.2 kWh` |

---

## Beispiel-Konfiguration

```perl
# Device anlegen (meter_id aus B-Control WebGUI)
define BControl_EnergyManager BControl 192.168.178.115 4

# Passwort einmalig setzen – erscheint NICHT in fhem.cfg:
# set BControl_EnergyManager nopassword

attr BControl_EnergyManager alias B-Control EnergyManager Heizstab
attr BControl_EnergyManager interval 60

attr BControl_EnergyManager event-on-change-reading power_W,energy_kWh
attr BControl_EnergyManager DbLogExclude .*
attr BControl_EnergyManager DbLogInclude power_W,energy_kWh,deviceState
```

---

## Webapp

Unter `www/bcontrol/index.html` liegt eine vollständige Single-File-Webapp mit:

- **Heizstab-Stufen**: Visuelle Darstellung aktiver Heizstufen (500 W / 1000 W / 2000 W), aus der Gesamtleistung abgeleitet
- **Gesamtleistung**: Große Watt-Anzeige mit Arc-Gauge und automatischer W/kW-Umschaltung
- **Energie & Kosten**: Gesamtenergie (kWh) und Stromtarif
- **Verlaufs-Charts** (Tab): Leistungsverlauf (W) und Energie-Verlauf (kWh) aus DbLog

### Webapp installieren

```bash
cp -r www/bcontrol /opt/fhem/www/
```

Aufruf im Browser:

```
http://<fhem-ip>:8083/fhem/www/bcontrol/
```

Beim ersten Aufruf über das Einstellungs-Icon (⚙) konfigurieren:
- **FHEM URL**: z.B. `/fhem` (selber Host) oder `http://192.168.178.x:8083/fhem`
- **FHEM Device-Name**: `BControl_EnergyManager` (oder eigener Name)
- **DbLog Device-Name**: `DBLOG`

### Screenshots

| Live-Ansicht | Verlauf |
|:---:|:---:|
| ![Live-Ansicht](screenshots/webapp-live.png) | ![Verlauf](screenshots/webapp-verlauf.png) |

---

## Hintergrund: API-Flow

```
POST http://{ip}/start.php
  Body: password={pw}
  → Set-Cookie: PHPSESSID=…
  → JSON: { "authentication": true }

GET http://{ip}/mum-webservice/consumption.php?meter_id={n}
  Header: Cookie: PHPSESSID=…
  → JSON:
    {
      "authentication": true,
      "05_power": 0.5,                   ← kW (Prefix = meter_id+1, zweistellig)
      "05_energy": 1410.91,              ← kWh
      "05_status": 0,                    ← 0 = OK/online
      "05_meter_label": "E.G.O. ...",
      "05_meter_number": "41237558",
      "05_tariff": 0.1469,               ← EUR/kWh
      "is_smartheater": true,
      "registers": [
        {"register":"1-0:1.4.0*255","value":500},      ← aktuelle Leistung W
        {"register":"1-0:1.8.0*255","value":1410915}   ← Gesamtenergie Wh
      ]
    }
```

Der JSON-Key-Prefix (`05_`) ergibt sich aus `meter_id + 1`, zweistellig formatiert.
Beispiel: `meter_id=4` → Prefix `05_`.

Bei `"authentication": false` in der Antwort → automatischer Re-Login.

---

## Lizenz

GPL v2

## Autor

Markus Eckert · [github.com/eckonator](https://github.com/eckonator)

---

## Verwandte Module

- [73_Plenticore.pm](../FHEM-Plenticore/README.md) – FHEM-Modul für den Kostal Plenticore Wechselrichter
- [bcontrol-em300-hacs](https://github.com/ITTV-Tools/bcontrol-em300-hacs) – Home Assistant Integration (Basis der API-Analyse)
