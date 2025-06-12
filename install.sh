#!/bin/bash

# --- Konfiguration ---
APP_DIR="/home/${USER}/moonlight-web-control"
# Dynamisch den Benutzernamen ermitteln, der das Skript mit sudo ausführt
# Falls nicht mit sudo ausgeführt, wird der aktuelle Benutzer verwendet
USER="${SUDO_USER:-$(whoami)}" 
PORT="5000"

echo "----------------------------------------------------------------------"
echo "Starte Installation für Moonlight Client und Web-App auf Raspberry Pi 5..."
echo "----------------------------------------------------------------------"

# --- 1. System aktualisieren ---
echo "----------------------------------------------------------------------"
echo "1# Aktualisiere Systempakete..."
echo "----------------------------------------------------------------------"

sudo apt update -y && sudo apt full-upgrade -y
if [ $? -ne 0 ]; then
    echo "Fehler: Systemaktualisierung fehlgeschlagen. Breche ab."
    exit 1
fi
echo "Systemaktualisierung abgeschlossen."

# --- 2. Moonlight Client installieren ---
echo "----------------------------------------------------------------------"
echo "2# Installiere Moonlight-embedded..."
echo "----------------------------------------------------------------------"

# Moonlight Repository hinzufügen
# Zuerst den GPG-Schlüssel für das Repository hinzufügen
curl -1sLf 'https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/setup.deb.sh' | distro=raspbian codename=$(lsb_release -cs) sudo -E bash

# Paketliste erneut aktualisieren und Moonlight installieren
sudo apt install -y moonlight-embedded
if [ $? -ne 0 ]; then
    echo "Fehler: Moonlight-Installation fehlgeschlagen. Breche ab."
    exit 1
fi
echo "Moonlight-embedded Installation abgeschlossen."

# --- 3. Python-Umgebung vorbereiten ---
echo "----------------------------------------------------------------------"
echo "3# Installiere Python3, pip und Flask/pybluez in einer virtuellen Umgebung..."
echo "----------------------------------------------------------------------"

# Installiere benötigte Pakete für venv und Bluetooth-Entwicklung
sudo apt install -y python3-venv bluetooth libbluetooth-dev
if [ $? -ne 0 ]; then
    echo "Fehler: Python/Bluetooth-Abhängigkeiten Installation fehlgeschlagen. Breche ab."
    exit 1
fi

# Erstelle das Anwendungsverzeichnis und setze Berechtigungen, bevor die venv erstellt wird
sudo mkdir -p "$APP_DIR"
sudo chown -R "$USER":"$USER" "$APP_DIR"

# Erstelle eine virtuelle Umgebung im Anwendungsverzeichnis
python3 -m venv "$APP_DIR/venv"
if [ $? -ne 0 ]; then
    echo "Fehler: Erstellen der virtuellen Umgebung fehlgeschlagen. Breche ab."
    exit 1
fi

# Aktiviere die virtuelle Umgebung und installiere Pakete darin
# (Diese Aktivierung ist temporär für dieses Skript)
source "$APP_DIR/venv/bin/activate"

# Nur Flask installieren, da pybluez entfernt wurde
pip install Flask
if [ $? -ne 0 ]; then
    echo "Fehler: Python-Paket (Flask) Installation in virtueller Umgebung fehlgeschlagen. Breche ab."
    exit 1
fi
echo "Python-Umgebung vorbereitet."

# Füge den Benutzer 'pi' zur 'bluetooth'-Gruppe hinzu für bessere Berechtigungen
sudo usermod -a -G bluetooth "$USER"
echo "Benutzer '$USER' wurde der 'bluetooth'-Gruppe hinzugefügt. Ein Neustart könnte für volle Wirkung erforderlich sein."

# --- 4. Web-App-Dateien einrichten ---
echo "----------------------------------------------------------------------"
echo "4# Richte Web-App-Verzeichnis und Dateien ein unter: $APP_DIR"
echo "----------------------------------------------------------------------"

sudo mkdir -p "$APP_DIR/static"
sudo chown -R "$USER":"$USER" "$APP_DIR/static"

# Erstelle app.py (Backend)
cat << EOF > "$APP_DIR/app.py"
import subprocess
import os
import re # Für reguläre Ausdrücke
import time # Für time.sleep

from flask import Flask, request, jsonify, send_from_directory # send_from_directory hinzugefügt

# Explizit das static_folder und template_folder setzen, da index.html direkt im static-Ordner liegt.
# In diesem Setup ist es einfacher, index.html als statische Datei zu behandeln.
app = Flask(__name__, static_folder='static')

# Pfad zur Datei, in der die IP gespeichert wird
IP_FILE = os.path.join(os.path.dirname(__file__), 'server_ip.txt')

def read_ip():
    if os.path.exists(IP_FILE):
        try:
            with open(IP_FILE, 'r') as f:
                return f.read().strip()
        except IOError:
            return "NICHT_GESETZT"
    return "NICHT_GESETZT"

def write_ip(ip):
    try:
        with open(IP_FILE, 'w') as f:
            f.write(ip)
    except IOError as e:
        print(f"Fehler beim Schreiben der IP-Datei: {e}")

# Route für die Bereitstellung der index.html
@app.route('/')
def serve_index():
    # Flask bedient Dateien aus dem 'static' Ordner automatisch,
    # wenn die Route auf diesen Ordner zeigt.
    # Hier wird explizit die index.html aus dem 'static' Ordner zurückgegeben.
    return send_from_directory(app.static_folder, 'index.html')

@app.route('/api/get_ip', methods=['GET'])
def get_ip():
    current_ip = read_ip()
    return jsonify({"ip": current_ip})

@app.route('/api/set_ip', methods=['POST'])
def set_ip():
    new_ip = request.json.get('ip')
    if new_ip:
        write_ip(new_ip)
        return jsonify({"status": "success", "message": f"Game Server IP auf {new_ip} gesetzt."})
    return jsonify({"status": "error", "message": "Keine IP bereitgestellt."}), 400

@app.route('/api/start_stream', methods=['POST'])
def start_stream():
    current_ip = read_ip()
    if current_ip == "NICHT_GESETZT":
        return jsonify({"status": "error", "message": "Game Server IP ist nicht gesetzt."}), 400
    try:
        # Moonlight im Hintergrund starten
        # Verwenden Sie 'nohup' und '&', um den Prozess vom Terminal zu lösen
        subprocess.Popen(["nohup", "moonlight", "stream", current_ip, "-app", "Steam", ">/dev/null", "2>&1", "&"], preexec_fn=os.setsid)
        return jsonify({"status": "success", "message": f"Moonlight-Stream zu {current_ip} gestartet."})
    except Exception as e:
        return jsonify({"status": "error", "message": f"Fehler beim Starten des Streams: {str(e)}"}), 500

@app.route('/api/stop_stream', methods=['POST'])
def stop_stream():
    try:
        # Beendet alle Moonlight-Prozesse
        subprocess.run(["pkill", "-f", "moonlight"], check=True)
        return jsonify({"status": "success", "message": "Alle Moonlight-Streams beendet."})
    except subprocess.CalledProcessError:
        return jsonify({"status": "success", "message": "Keine Moonlight-Prozesse gefunden oder beendet."})
    except Exception as e:
        return jsonify({"status": "error", "message": f"Fehler beim Beenden des Streams: {str(e)}"}), 500

@app.route('/api/scan_bluetooth', methods=['GET'])
def scan_bluetooth():
    devices_list = []
    scan_process = None # Variable zur Speicherung des Scan-Prozesses
    try:
        # 1. Sicherstellen, dass Bluetooth-Scan nicht bereits läuft und beenden
        # check=False, da es nicht schlimm ist, wenn scan off fehlschlägt (z.B. weil kein Scan läuft)
        subprocess.run(["sudo", "bluetoothctl", "scan", "off"], capture_output=True, text=True, timeout=5, check=False)
        print("Bluetooth scan off attempted before new scan.")

        # 2. Starte den Bluetooth-Scan im Hintergrund mit subprocess.Popen
        # Das Sudo-Passwort muss über die /etc/sudoers-Konfiguration behandelt werden
        print("Starting bluetooth scan in background...")
        scan_process = subprocess.Popen(["sudo", "bluetoothctl", "scan", "on"], 
                                        stdout=subprocess.PIPE, # stdout erfassen
                                        stderr=subprocess.PIPE, # stderr erfassen
                                        text=True)
        # Kurze Wartezeit, um sicherzustellen, dass der Scan gestartet ist und um erste Geräte zu entdecken
        time.sleep(8) # Kann angepasst werden, je nachdem wie lange gescannt werden soll

        # 3. Rufe die Liste der Geräte ab
        print("Retrieving device list...")
        # Hier verwenden wir check=True, da 'devices' immer funktionieren sollte, wenn bluetoothctl läuft
        # und der Scan gestartet ist. Timeout, um Hängenbleiben zu verhindern.
        devices_result = subprocess.run(["sudo", "bluetoothctl", "devices"], capture_output=True, text=True, check=True, timeout=10)
        
        # Parse die Ausgabe
        lines = devices_result.stdout.splitlines()
        for line in lines:
            # Beispielformat: Device XX:XX:XX:XX:XX:XX DeviceName
            match = re.match(r'Device (\S+) (.+)', line.strip())
            if match:
                address = match.group(1)
                name = match.group(2)
                devices_list.append({"address": address, "name": name})
        
        print(f"Discovered devices: {devices_list}")
        return jsonify({"status": "success", "devices": devices_list})
    
    except subprocess.CalledProcessError as e:
        # Fangt Fehler ab, wenn ein bluetoothctl-Befehl fehlschlägt (z.B. Berechtigungsprobleme)
        error_output = e.stderr or e.stdout
        print(f"CalledProcessError in scan_bluetooth: Command '{e.cmd}' returned {e.returncode} - {error_output}")
        return jsonify({"status": "error", "message": f"Bluetooth-Befehl fehlgeschlagen: {error_output}. Berechtigungen prüfen."}), 500
    
    except subprocess.TimeoutExpired as e:
        # Dieser Block fängt Timeouts von `subprocess.run` (z.B. `devices` Befehl) ab.
        # Der `scan on` Befehl sollte nicht hier landen, da er mit Popen behandelt wird.
        error_output = e.stderr or e.stdout or "No output before timeout"
        print(f"TimeoutExpired in scan_bluetooth for command {e.cmd}: {error_output}")
        return jsonify({"status": "error", "message": f"Bluetooth-Operation hat Timeout erreicht: {error_output}."}), 500
    
    except Exception as e:
        # Allgemeine Fehlerbehandlung für andere Python-Fehler
        print(f"Unerwarteter Fehler im Bluetooth-Scan-Endpunkt: {e}")
        return jsonify({"status": "error", "message": f"Unerwarteter Fehler beim Bluetooth-Scan: {str(e)}. Überprüfen Sie die Server-Logs."}), 500
    finally:
        # Sicherstellen, dass der Scan-Prozess beendet wird, falls er gestartet wurde
        if scan_process:
            print("Terminating bluetooth scan process...")
            scan_process.terminate() # Sende SIGTERM
            try:
                scan_process.wait(timeout=5) # Warte, bis der Prozess beendet ist
                print("Bluetooth scan process terminated.")
            except subprocess.TimeoutExpired:
                scan_process.kill() # Wenn terminate nicht reicht, sende SIGKILL
                print("Bluetooth scan process killed.")
        
        # Zusätzlich explizit scan off senden, falls der Prozess nicht sauber beendet wurde
        # check=False, da es nicht schlimm ist, wenn es fehlschlägt
        subprocess.run(["sudo", "bluetoothctl", "scan", "off"], capture_output=True, text=True, timeout=5, check=False)
        print("Final bluetooth scan off attempted.")

@app.route('/api/get_paired_devices', methods=['GET'])
def get_paired_devices():
    paired_devices_list = []
    try:
        # Führt 'bluetoothctl devices Paired' aus, um nur gekoppelte Geräte zu listen
        # 'check=True' lässt subprocess.CalledProcessError auslösen, wenn der Befehl fehlschlägt
        paired_result = subprocess.run(["sudo", "bluetoothctl", "devices", "Paired"], capture_output=True, text=True, check=True, timeout=10)
        
        lines = paired_result.stdout.splitlines()
        for line in lines:
            # Beispielformat: Device XX:XX:XX:XX:XX:XX DeviceName
            match = re.match(r'Device (\S+) (.+)', line.strip())
            if match:
                address = match.group(1)
                name = match.group(2)
                # Optionale Prüfung des Verbindungsstatus (komplexer, erfordert 'info <addr>')
                # Für Einfachheit wird hier nur "Paired" als Status betrachtet,
                # da bluetoothctl devices Paired ja nur gekoppelte listet.
                paired_devices_list.append({"address": address, "name": name, "status": "Gekoppelt"})
        
        print(f"Paired devices: {paired_devices_list}")
        return jsonify({"status": "success", "devices": paired_devices_list})
    except subprocess.CalledProcessError as e:
        error_output = e.stderr or e.stdout
        print(f"CalledProcessError in get_paired_devices: Command '{e.cmd}' returned {e.returncode} - {error_output}")
        return jsonify({"status": "error", "message": f"Fehler beim Abrufen gekoppelter Geräte: {error_output}. Berechtigungen prüfen."}), 500
    except subprocess.TimeoutExpired as e:
        error_output = e.stderr or e.stdout or "No output before timeout"
        print(f"TimeoutExpired in get_paired_devices for command {e.cmd}: {error_output}")
        return jsonify({"status": "error", "message": f"Abruf gekoppelter Geräte hat Timeout erreicht: {error_output}."}), 500
    except Exception as e:
        print(f"Unerwarteter Fehler im get_paired_devices-Endpunkt: {e}")
        return jsonify({"status": "error", "message": f"Unerwarteter Fehler beim Abrufen gekoppelter Geräte: {str(e)}. Überprüfen Sie die Server-Logs."}), 500

@app.route('/api/remove_device', methods=['POST'])
def remove_device():
    device_address = request.json.get('address')
    if not device_address:
        return jsonify({"status": "error", "message": "Keine Geräteadresse bereitgestellt."}), 400
    try:
        print(f"Attempting to remove Bluetooth device: {device_address}")
        result = subprocess.run(["sudo", "bluetoothctl", "remove", device_address], capture_output=True, text=True)
        if result.returncode == 0:
            print(f"Successfully removed {device_address}: {result.stdout.strip()}")
            return jsonify({"status": "success", "message": f"Gerät {device_address} erfolgreich entfernt."})
        else:
            error_output = result.stderr.strip() or result.stdout.strip() or "Unbekannter Fehler"
            print(f"Failed to remove {device_address} (Return Code {result.returncode}): {error_output}")
            return jsonify({"status": "error", "message": f"Fehler beim Entfernen von {device_address}: {error_output}"}), 500
    except Exception as e:
        print(f"Unerwarteter Fehler beim Entfernen von {device_address}: {e}")
        return jsonify({"status": "error", "message": f"Fehler beim Entfernen von {device_address}: {str(e)}. Überprüfen Sie die Server-Logs."}), 500

@app.route('/api/connect_bluetooth', methods=['POST'])
def connect_bluetooth():
    device_address = request.json.get('address')
    if not device_address:
        return jsonify({"status": "error", "message": "Keine Geräteadresse bereitgestellt."}), 400
    try:
        print(f"Attempting to connect to Bluetooth device: {device_address}")

        # Prüfen, ob das Gerät bereits als vertrauenswürdig eingestuft ist
        trusted = False
        try:
            info_result = subprocess.run(["sudo", "bluetoothctl", "info", device_address], capture_output=True, text=True, check=True, timeout=5)
            if "Trusted: yes" in info_result.stdout:
                trusted = True
        except Exception as e:
            print(f"Warnung: Konnte Trusted-Status für {device_address} nicht abrufen: {e}")
            # Fortfahren, auch wenn Info fehlschlägt, versuchen zu vertrauen

        if not trusted:
            print(f"Device {device_address} not trusted, attempting to trust...")
            trust_result = subprocess.run(["sudo", "bluetoothctl", "trust", device_address], capture_output=True, text=True)
            if trust_result.returncode == 0:
                print(f"Successfully trusted {device_address}.")
            else:
                error_output = trust_result.stderr.strip() or trust_result.stdout.strip() or "Unbekannter Fehler beim Vertrauen"
                print(f"Failed to trust {device_address}: {error_output}")
                # Nicht abbrechen, versuchen trotzdem zu verbinden, aber den Fehler loggen/zurückgeben
                # Sie könnten hier entscheiden, ob Sie einen Fehler zurückgeben oder nur eine Warnung loggen
                # Für jetzt: loggen und fortfahren
        
        # Verbindung herstellen
        result = subprocess.run(["sudo", "bluetoothctl", "connect", device_address], capture_output=True, text=True)
        if result.returncode == 0:
            print(f"Successfully attempted connection to {device_address}: {result.stdout.strip()}")
            return jsonify({"status": "success", "message": f"Verbindungsversuch zu {device_address} gestartet."})
        else:
            error_output = result.stderr.strip() or result.stdout.strip() or "Unbekannter Fehler"
            print(f"Failed to connect to {device_address} (Return Code {result.returncode}): {error_output}")
            return jsonify({"status": "error", "message": f"Fehler beim Verbinden mit {device_address}: {error_output}"}), 500
    except Exception as e:
        print(f"Unerwarteter Fehler beim Verbinden von {device_address}: {e}")
        return jsonify({"status": "error", "message": f"Fehler beim Verbinden mit {device_address}: {str(e)}. Stellen Sie sicher, dass das Gerät gepaart ist und die Berechtigungen stimmen."}), 500

if __name__ == '__main__':
    # PORT wird aus Umgebungsvariable gelesen oder Standardwert verwendet
    port = int(os.environ.get('PORT', 5000)) 
    app.run(host='0.0.0.0', port=port)
EOF

# Erstelle index.html (Frontend) im 'static'-Verzeichnis
cat << 'EOF' > "$APP_DIR/static/index.html"
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Moonlight Pi Steuerung</title>
    <!-- Tailwind CSS CDN für einfache Styling -->
    <script src="https://cdn.tailwindcss.com"></script>
    <style>
        body {
            font-family: 'Inter', sans-serif;
            background-color: #f3f4f6; /* Leichter grauer Hintergrund */
            display: flex;
            justify-content: center;
            align-items: center;
            min-height: 100vh;
            margin: 0;
            padding: 20px;
        }
        .container {
            background-color: #ffffff;
            padding: 32px;
            border-radius: 12px;
            box-shadow: 0 4px 10px rgba(0, 0, 0, 0.1);
            width: 100%;
            max-width: 600px;
        }
        h1 {
            color: #1f2937; /* Dunkler Text */
            font-size: 2.25rem; /* Helle Überschrift */
            font-weight: 700;
            margin-bottom: 24px;
            text-align: center;
        }
        h2 {
            color: #374151;
            font-size: 1.5rem;
            font-weight: 600;
            margin-top: 24px;
            margin-bottom: 16px;
        }
        label {
            display: block;
            margin-bottom: 8px;
            font-weight: 500;
            color: #4b5563;
        }
        input[type="text"] {
            width: 100%;
            padding: 12px;
            border: 1px solid #d1d5db;
            border-radius: 8px;
            margin-bottom: 16px;
            box-sizing: border-box; /* Padding in der Breite berücksichtigen */
        }
        button {
            padding: 12px 20px;
            background-color: #3b82f6; /* Blauer Button */
            color: white;
            border: none;
            border-radius: 8px;
            cursor: pointer;
            font-weight: 600;
            transition: background-color 0.2s ease-in-out;
            margin-right: 12px;
            margin-bottom: 12px;
        }
        button:hover {
            background-color: #2563eb; /* Dunklerer Blauton beim Hover */
        }
        .btn-red {
            background-color: #ef4444; /* Roter Button für Stop */
        }
        .btn-red:hover {
            background-color: #dc2626;
        }
        .btn-delete {
            background-color: #ef4444; /* Roter Button für Löschen */
        }
        .btn-delete:hover {
            background-color: #dc2626;
        }
        .info-text {
            color: #4b5563;
            margin-top: 8px;
            font-size: 0.9rem;
        }
        .message-box {
            padding: 12px;
            border-radius: 8px;
            margin-top: 20px;
            font-weight: 500;
        }
        .message-success {
            background-color: #d1fae5; /* Grüner Hintergrund für Erfolg */
            color: #065f46; /* Grüner Text */
            border: 1px solid #34d399;
        }
        .message-error {
            background-color: #fee2e2; /* Roter Hintergrund für Fehler */
            color: #991b1b; /* Roter Text */
            border: 1px solid #ef4444;
        }
        .bluetooth-list {
            margin-top: 16px;
            background-color: #f9fafb;
            padding: 16px;
            border-radius: 8px;
            border: 1px solid #e5e7eb;
        }
        .bluetooth-device-item {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 12px 0;
            border-bottom: 1px solid #e5e7eb;
        }
        .bluetooth-device-item:last-child {
            border-bottom: none;
        }
        .bluetooth-device-item span {
            color: #374151;
        }
        .bluetooth-device-item button {
            margin-right: 0;
            padding: 8px 16px;
            font-size: 0.875rem;
            margin-bottom: 0;
        }
        .device-status {
            font-size: 0.85rem;
            color: #6b7280;
            margin-left: 10px;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Moonlight Pi Steuerung</h1>

        <div id="message" class="message-box hidden"></div>

        <section>
            <h2>Game Server IP</h2>
            <label for="gameServerIpInput">IP-Adresse des Game Servers:</label>
            <input type="text" id="gameServerIpInput" placeholder="z.B. 192.168.1.100" class="focus:ring-2 focus:ring-blue-500 focus:border-transparent">
            <button onclick="saveGameServerIp()">IP speichern</button>
            <p class="info-text">Aktuelle IP: <span id="currentIpDisplay">Laden...</span></p>
        </section>

        <section>
            <h2>Moonlight Stream</h2>
            <button onclick="startMoonlightStream()">Stream starten (Standard: Steam)</button>
            <button class="btn-red" onclick="stopMoonlightStream()">Stream beenden</button>
            <p class="info-text">Startet den Moonlight-Stream zur aktuell gespeicherten IP-Adresse.</p>
        </section>

        <section>
            <h2>Gepaarte Bluetooth Geräte</h2>
            <button onclick="fetchPairedDevices()">Gekoppelte Geräte anzeigen</button>
            <p class="info-text">Zeigt alle mit diesem Pi gekoppelten Bluetooth-Geräte an.</p>
            <div id="pairedDevicesList" class="bluetooth-list">
                <p>Noch keine gekoppelten Geräte geladen.</p>
            </div>
        </section>

        <section>
            <h2>Bluetooth Geräte suchen</h2>
            <button onclick="scanBluetoothDevices()">Neue Geräte scannen</button>
            <p class="info-text">Sucht nach verfügbaren Bluetooth-Geräten in der Nähe, um sie zu koppeln.</p>
            <div id="bluetoothDevicesList" class="bluetooth-list">
                <p>Noch keine Geräte gescannt.</p>
            </div>
        </section>
    </div>

    <script>
        const messageDiv = document.getElementById('message');
        const gameServerIpInput = document.getElementById('gameServerIpInput');
        const currentIpDisplay = document.getElementById('currentIpDisplay');
        const bluetoothDevicesList = document.getElementById('bluetoothDevicesList');
        const pairedDevicesList = document.getElementById('pairedDevicesList');

        // Funktion zur Anzeige von Nachrichten
        function showMessage(msg, type = 'info') {
            messageDiv.innerText = msg;
            messageDiv.classList.remove('hidden', 'message-success', 'message-error');
            if (type === 'success') {
                messageDiv.classList.add('message-success');
            } else if (type === 'error') {
                messageDiv.classList.add('message-error');
            }
            // Nachricht nach 5 Sekunden ausblenden
            setTimeout(() => {
                messageDiv.classList.add('hidden');
            }, 5000);
        }

        // Aktuelle IP vom Backend abrufen
        async function fetchCurrentIp() {
            try {
                const response = await fetch('/api/get_ip');
                if (!response.ok) {
                    throw new Error(`HTTP error! status: ${response.status}`);
                }
                const data = await response.json();
                currentIpDisplay.innerText = data.ip || 'Nicht gesetzt';
                gameServerIpInput.value = data.ip || '';
                // showMessage('Aktuelle IP geladen.', 'success'); // Weniger Meldungen beim Start
            } catch (error) {
                console.error('Fehler beim Abrufen der IP:', error);
                currentIpDisplay.innerText = 'Fehler beim Laden';
                showMessage('Konnte IP nicht laden: ' + error.message, 'error');
            }
        }

        // Game Server IP speichern
        async function saveGameServerIp() {
            const ip = gameServerIpInput.value.trim();
            if (!ip) {
                showMessage('Bitte geben Sie eine gültige IP-Adresse ein.', 'error');
                return;
            }

            try {
                const response = await fetch('/api/set_ip', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ ip: ip })
                });
                if (!response.ok) {
                    throw new Error(`HTTP error! status: ${response.status}`);
                }
                const data = await response.json();
                if (data.status === 'success') {
                    showMessage(data.message, 'success');
                    fetchCurrentIp(); // Aktualisiere Anzeige nach Speichern
                } else {
                    showMessage(data.message, 'error');
                }
            } catch (error) {
                showMessage('Fehler beim Speichern der IP: ' + error.message, 'error');
            }
        }

        // Moonlight Stream starten
        async function startMoonlightStream() {
            const ip = currentIpDisplay.innerText;
            if (ip === 'Nicht gesetzt' || ip === 'Fehler beim Laden') {
                showMessage('Bitte zuerst eine Game Server IP speichern.', 'error');
                return;
            }
            try {
                const response = await fetch('/api/start_stream', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ app: 'Steam' }) // Oder 'Desktop', etc.
                });
                if (!response.ok) {
                    throw new Error(`HTTP error! status: ${response.status}`);
                }
                const data = await response.json();
                if (data.status === 'success') {
                    showMessage(data.message, 'success');
                } else {
                    showMessage(data.message, 'error');
                }
            } catch (error) {
                showMessage('Fehler beim Starten des Streams: ' + error.message, 'error');
            }
        }

        // Moonlight Stream beenden
        async function stopMoonlightStream() {
            try {
                const response = await fetch('/api/stop_stream', {
                    method: 'POST'
                });
                if (!response.ok) {
                    throw new Error(`HTTP error! status: ${response.status}`);
                }
                const data = await response.json();
                if (data.status === 'success') {
                    showMessage(data.message, 'success');
                } else {
                    showMessage(data.message, 'error');
                }
            } catch (error) {
                showMessage('Fehler beim Beenden des Streams: ' + error.message, 'error');
            }
        }

        // Bluetooth Geräte scannen (für neue Geräte)
        async function scanBluetoothDevices() {
            bluetoothDevicesList.innerHTML = '<p>Scanne nach Geräten...</p>';
            showMessage('Starte Bluetooth-Scan, bitte warten...', 'info');
            try {
                const response = await fetch('/api/scan_bluetooth');
                if (!response.ok) {
                    throw new Error(`HTTP error! status: ${response.status}`);
                }
                const data = await response.json();
                if (data.status === 'success') {
                    displayBluetoothDevices(data.devices);
                    showMessage('Bluetooth-Scan erfolgreich. Gefundene Geräte:', 'success');
                } else {
                    showMessage(data.message, 'error');
                    bluetoothDevicesList.innerHTML = `<p>${data.message}</p>`;
                }
            } catch (error) {
                showMessage('Fehler beim Bluetooth-Scan: ' + error.message, 'error');
                bluetoothDevicesList.innerHTML = `<p>Fehler beim Scannen: ${error.message}</p>`;
            }
        }

        // Gefundene Bluetooth-Geräte anzeigen (nach Scan)
        function displayBluetoothDevices(devices) {
            bluetoothDevicesList.innerHTML = '';
            if (devices.length === 0) {
                bluetoothDevicesList.innerHTML = '<p>Keine Bluetooth-Geräte gefunden.</p>';
                return;
            }
            devices.forEach(device => {
                const div = document.createElement('div');
                div.className = 'bluetooth-device-item';
                div.innerHTML = `
                    <span>${device.name || 'Unbekanntes Gerät'} (${device.address})</span>
                    <button onclick="connectBluetoothDevice('${device.address}')">Verbinden</button>`;
                bluetoothDevicesList.appendChild(div);
            });
        }

        // Bluetooth Gerät verbinden
        async function connectBluetoothDevice(address) {
            showMessage(`Versuche Verbindung zu ${address}...`, 'info');
            try {
                const response = await fetch('/api/connect_bluetooth', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ address: address })
                });
                if (!response.ok) {
                    throw new Error(`HTTP error! status: ${response.status}`);
                }
                const data = await response.json();
                if (data.status === 'success') {
                    showMessage(data.message, 'success');
                    fetchPairedDevices(); // Gekoppelte Geräte aktualisieren
                } else {
                    showMessage(data.message, 'error');
                }
            } catch (error) {
                showMessage('Fehler beim Verbinden des Geräts: ' + error.message, 'error');
            }
        }

        // Gekoppelte Bluetooth Geräte abrufen
        async function fetchPairedDevices() {
            pairedDevicesList.innerHTML = '<p>Lade gekoppelte Geräte...</p>';
            try {
                const response = await fetch('/api/get_paired_devices');
                if (!response.ok) {
                    throw new Error(`HTTP error! status: ${response.status}`);
                }
                const data = await response.json();
                if (data.status === 'success') {
                    displayPairedDevices(data.devices);
                    // showMessage('Gekoppelte Geräte geladen.', 'success'); // Weniger Meldungen beim Start
                } else {
                    showMessage(data.message, 'error');
                    pairedDevicesList.innerHTML = `<p>${data.message}</p>`;
                }
            } catch (error) {
                showMessage('Fehler beim Abrufen gekoppelter Geräte: ' + error.message, 'error');
                pairedDevicesList.innerHTML = `<p>Fehler beim Laden gekoppelter Geräte: ${error.message}</p>`;
            }
        }

        // Gekoppelte Bluetooth Geräte anzeigen
        function displayPairedDevices(devices) {
            pairedDevicesList.innerHTML = '';
            if (devices.length === 0) {
                pairedDevicesList.innerHTML = '<p>Keine gekoppelten Bluetooth-Geräte gefunden.</p>';
                return;
            }
            devices.forEach(device => {
                const div = document.createElement('div');
                div.className = 'bluetooth-device-item';
                div.innerHTML = `
                    <span>${device.name || 'Unbekanntes Gerät'} (${device.address})</span>
                    <span class="device-status">Status: ${device.status}</span>
                    <button class="btn-delete" onclick="removePairedDevice('${device.address}')">Löschen</button>`;
                pairedDevicesList.appendChild(div);
            });
        }

        // Gekoppeltes Bluetooth Gerät entfernen
        async function removePairedDevice(address) {
            if (!confirm(`Soll Gerät ${address} wirklich entfernt werden?`)) { // Temporär, ersetzen durch Custom Modal
                return;
            }
            showMessage(`Versuche Gerät ${address} zu entfernen...`, 'info');
            try {
                const response = await fetch('/api/remove_device', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ address: address })
                });
                if (!response.ok) {
                    throw new Error(`HTTP error! status: ${response.status}`);
                }
                const data = await response.json();
                if (data.status === 'success') {
                    showMessage(data.message, 'success');
                    fetchPairedDevices(); // Gekoppelte Geräte aktualisieren
                } else {
                    showMessage(data.message, 'error');
                }
            } catch (error) {
                showMessage('Fehler beim Entfernen des Geräts: ' + error.message, 'error');
            }
        }


        // Initial beim Laden der Seite die aktuelle IP und gekoppelte Geräte abrufen
        document.addEventListener('DOMContentLoaded', () => {
            fetchCurrentIp();
            fetchPairedDevices();
        });
    </script>
</body>
</html>
EOF

echo "Web-App-Dateien erstellt."

# --- 5. Systemd-Dienst konfigurieren ---
echo "----------------------------------------------------------------------"
echo "5# Richte Systemd-Dienst für die Web-App ein..."
echo "----------------------------------------------------------------------"

SERVICE_FILE="/etc/systemd/system/moonlight-web-control.service"

# Verwende tee, um die Datei mit Root-Rechten zu erstellen
sudo tee "$SERVICE_FILE" >/dev/null << EOF
[Unit]
Description=Moonlight Web Control App
After=network.target bluetooth.service

[Service]
User=$USER
WorkingDirectory=$APP_DIR
# Übergebe PORT als Umgebungsvariable an die Python-App
Environment="PORT=$PORT" 
ExecStart=$APP_DIR/venv/bin/python3 $APP_DIR/app.py
Restart=always
# Um stdout/stderr in den Journal-Logs zu sehen:
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable moonlight-web-control.service
if [ $? -ne 0 ]; then
    echo "Fehler: Aktivieren des Systemd-Dienstes fehlgeschlagen. Breche ab."
    exit 1
fi
echo "Systemd-Dienst eingerichtet und aktiviert."

# --- 6. Web-App starten ---
echo "----------------------------------------------------------------------"
echo "6# Starte Moonlight Web Control App..."
echo "----------------------------------------------------------------------"

sudo systemctl start moonlight-web-control.service
if [ $? -ne 0 ]; then
    echo "Fehler: Starten des Systemd-Dienstes fehlgeschlagen. Bitte manuell überprüfen: sudo systemctl status moonlight-web-control.service"
    exit 1
fi
echo "Moonlight Web Control App erfolgreich gestartet!"

# --- Abschlussanweisungen ---
echo "----------------------------------------------------------------------"
echo "Installation abgeschlossen!"
echo ""
echo "Um die Web-App zu erreichen, öffnen Sie einen Browser auf einem Gerät in Ihrem Netzwerk"
echo "und navigieren Sie zu der IP-Adresse Ihres Raspberry Pi, gefolgt von Port $PORT:"
echo "   http://<Ihre_Raspberry_Pi_IP>:$PORT"
echo ""
echo "Nächste Schritte:"
echo "1.  **Moonlight Pairing:** Bevor Sie streamen können, müssen Sie Ihren Raspberry Pi mit Ihrem Game Server pairen."
echo "    Führen Sie dazu einmalig im Terminal Ihres Raspberry Pi aus:"
echo "    moonlight pair <IP_IHRES_GAME_SERVERS>"
echo "    Folgen Sie den Anweisungen, um den angezeigten PIN auf Ihrem Gaming-PC einzugeben."
echo "2.  **Bluetooth-Berechtigungen:** Die Bluetooth-Steuerung (insbesondere 'Verbinden') kann erweiterte Berechtigungen erfordern."
echo "    Wenn das Verbinden nicht funktioniert, stellen Sie sicher, dass Ihr Benutzer die notwendigen Rechte hat."
echo "    Für fortgeschrittene Szenarien (z.B. Pairing direkt aus der App) müssten Sie eventuell"
echo "    spezifische sudo-Regeln in /etc/sudoers hinzufügen (z.B. 'pi ALL=NOPASSWD: /usr/bin/bluetoothctl')."
echo "    Seien Sie dabei extrem vorsichtig, da dies ein Sicherheitsrisiko darstellen kann!"
echo "3.  **Neustart:** Ein Neustart des Raspberry Pi kann helfen, alle Änderungen (insbesondere die Bluetooth-Gruppenzugehörigkeit)"
echo "    vollständig anzuwenden: sudo reboot"
echo ""
echo "Viel Spaß beim Streamen!"
