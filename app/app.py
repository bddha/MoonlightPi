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
            match = re.match(r'Device (\S+) (.+)', line.strip())
            if match:
                address = match.group(1)
                name = match.group(2)
                
                # Jetzt versuchen, den Verbindungsstatus abzurufen
                status = "Unbekannt"
                try:
                    # Der info-Befehl kann ein Timeout haben, wenn das Gerät nicht erreichbar ist
                    info_result = subprocess.run(["sudo", "bluetoothctl", "info", address], capture_output=True, text=True, check=True, timeout=5)
                    info_lines = info_result.stdout.splitlines()
                    for info_line in info_lines:
                        if "Connected: yes" in info_line:
                            status = "Verbunden"
                            break
                        elif "Connected: no" in info_line:
                            status = "Nicht verbunden"
                            break
                except subprocess.CalledProcessError as info_e:
                    # Normal, wenn Gerät nicht aktiv oder nicht sichtbar ist
                    print(f"Warnung: Konnte Info für Gerät {address} nicht abrufen (Code {info_e.returncode}): {info_e.stderr.strip()}")
                    status = "Nicht verbunden (Info-Fehler)"
                except subprocess.TimeoutExpired:
                    print(f"Warnung: Info-Abruf für Gerät {address} hat Timeout erreicht.")
                    status = "Nicht verbunden (Info-Timeout)"
                except Exception as info_e:
                    print(f"Warnung: Unerwarteter Fehler beim Info-Abruf für {address}: {info_e}")
                    status = "Nicht verbunden (Fehler)"

                paired_devices_list.append({"address": address, "name": name, "status": status})
        
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