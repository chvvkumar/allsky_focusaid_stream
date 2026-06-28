#!/bin/bash

# ==============================================================================
# ZWO ASI Camera Streamer v4 (Microsecond Precision + Floating UI)
# ==============================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting ZWO Camera Streamer Setup (Precision Edition)...${NC}"

# --- 1. System Dependencies Check ---
echo -e "\n${YELLOW}[Step 1] Checking system dependencies...${NC}"
if ! dpkg -s libopencv-dev >/dev/null 2>&1; then
    echo "Installing system libraries (requires sudo)..."
    sudo apt update
    sudo apt install -y libopencv-dev python3-opencv
else
    echo "System libraries look good."
fi

# --- 2. Virtual Environment Setup ---
echo -e "\n${YELLOW}[Step 2] Configuring Python Virtual Environment...${NC}"

VENV_DIR="venv"

if [[ "$VIRTUAL_ENV" != "" ]]; then
    echo -e "Using active virtual environment: $VIRTUAL_ENV"
else
    if [ -d "$VENV_DIR" ]; then
        echo "Found existing '$VENV_DIR'. Activating..."
        source "$VENV_DIR/bin/activate"
    else
        echo "Creating new virtual environment..."
        python3 -m venv "$VENV_DIR"
        source "$VENV_DIR/bin/activate"
    fi
fi

# --- 3. Install Python Dependencies ---
echo -e "\n${YELLOW}[Step 3] Installing Python libraries...${NC}"
pip install --upgrade pip
pip install zwoasi flask opencv-python-headless

# --- 4. Check for ZWO SDK Library (.so file) ---
echo -e "\n${YELLOW}[Step 4] Checking for ZWO SDK Library...${NC}"
LIB_FILE="libASICamera2.so"

if [ ! -f "$LIB_FILE" ]; then
    echo -e "${RED}MISSING: $LIB_FILE${NC}"
    echo "----------------------------------------------------------------"
    echo "ACTION REQUIRED:"
    echo "1. Download 'ASI SDK for Linux' from ZWO website."
    echo "2. Copy 'lib/armv8/libASICamera2.so' into this folder: $(pwd)"
    echo "----------------------------------------------------------------"
    read -p "Have you placed the .so file here? (y/n): " file_ready
    if [[ "$file_ready" != "y" ]]; then exit 1; fi
else
    echo -e "${GREEN}Found $LIB_FILE.${NC}"
fi

# --- 5. Generate Advanced Python Script ---
echo -e "\n${YELLOW}[Step 5] Generating 'zwo.py' with Microsecond Controls...${NC}"

cat << 'EOF' > zwo.py
#!/usr/bin/env python3
import sys
import os
import time
import threading
import json

try:
    import cv2
    import zwoasi as asi
    from flask import Flask, Response, render_template_string, request, jsonify
except ImportError as e:
    print(f"Missing libraries: {e}")
    sys.exit(1)

# ================= CONFIGURATION =================
LIB_FILE = './libASICamera2.so' 

# Global State for Camera Settings
cam_state = {
    'gain': 300,
    'exposure_val': 100,  # Value for the slider
    'exposure_mode': 'ms', # 'ms' or 'us'
    'scale_percent': 50,  
    'flip': False
}
state_lock = threading.Lock()

app = Flask(__name__)

# ================= HTML TEMPLATE =================
HTML_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
    <title>ZWO Live View</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <style>
        body { 
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            background: #000; 
            margin: 0; 
            padding: 0; 
            overflow: hidden; /* Prevent scrolling */
        }
        
        /* Full Screen Video */
        #video-container { 
            position: fixed;
            top: 0; left: 0; right: 0; bottom: 0;
            display: flex; 
            align-items: center; 
            justify-content: center;
            z-index: 1;
        }
        img { 
            width: 100%; 
            height: 100%; 
            object-fit: contain; 
        }
        
        /* Floating UI Layer */
        #ui-layer {
            position: fixed;
            top: 10px;
            left: 10px;
            z-index: 100;
            width: 320px;
            max-width: 95vw;
        }

        /* Toggle Button (Visible when minimized) */
        #toggle-btn {
            background: rgba(211, 47, 47, 0.9);
            color: white;
            border: none;
            padding: 10px 15px;
            border-radius: 20px;
            font-weight: bold;
            cursor: pointer;
            box-shadow: 0 4px 6px rgba(0,0,0,0.3);
            display: none;
        }

        /* Control Panel */
        .controls { 
            background: rgba(20, 20, 20, 0.85);
            backdrop-filter: blur(8px);
            padding: 15px; 
            border-radius: 12px; 
            color: #eee;
            box-shadow: 0 8px 32px rgba(0,0,0,0.5);
            border: 1px solid rgba(255,255,255,0.1);
            transition: opacity 0.3s ease;
        }

        /* Header */
        .panel-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 15px;
            border-bottom: 1px solid rgba(255,255,255,0.1);
            padding-bottom: 10px;
        }
        .panel-title { font-weight: bold; font-size: 14px; text-transform: uppercase; letter-spacing: 1px; color: #aaa; }
        .close-btn { background: none; border: none; color: #fff; font-size: 20px; cursor: pointer; }

        /* General Inputs */
        .control-group { margin-bottom: 15px; }
        label { display: flex; justify-content: space-between; font-size: 13px; margin-bottom: 8px; color: #ccc; }
        .val-display { color: #d32f2f; font-weight: bold; font-family: monospace; }
        
        input[type=range] { 
            width: 100%; 
            height: 6px; 
            background: #444; 
            border-radius: 3px; 
            outline: none; 
            -webkit-appearance: none;
        }
        input[type=range]::-webkit-slider-thumb {
            -webkit-appearance: none;
            width: 18px; height: 18px;
            background: #d32f2f;
            border-radius: 50%;
            cursor: pointer;
        }

        /* Mode Toggles */
        .mode-toggle {
            display: flex;
            background: #333;
            border-radius: 6px;
            padding: 2px;
            margin-bottom: 10px;
        }
        .mode-btn {
            flex: 1;
            padding: 6px;
            border: none;
            background: transparent;
            color: #888;
            font-size: 12px;
            cursor: pointer;
            border-radius: 4px;
        }
        .mode-btn.active {
            background: #555;
            color: white;
            font-weight: bold;
        }

        /* Resolution Grid */
        .res-grid { display: grid; grid-template-columns: repeat(5, 1fr); gap: 5px; }
        .res-btn { 
            padding: 8px 0; font-size: 11px; border: none; border-radius: 4px; 
            background: #333; color: #aaa; cursor: pointer; 
        }
        .res-btn.active { background: #d32f2f; color: white; font-weight: bold; }

    </style>
</head>
<body>

    <div id="video-container">
        <img src="/video_feed" alt="Waiting for stream...">
    </div>

    <div id="ui-layer">
        <button id="toggle-btn" onclick="toggleUI()">Settings</button>

        <div class="controls" id="control-panel">
            <div class="panel-header">
                <span class="panel-title">ZWO Control</span>
                <button class="close-btn" onclick="toggleUI()">&times;</button>
            </div>
            
            <!-- Resolution -->
            <div class="control-group">
                <label>Resolution</label>
                <div class="res-grid">
                    <button onclick="setScale(100)" id="btn-100" class="res-btn">100%</button>
                    <button onclick="setScale(75)" id="btn-75" class="res-btn">75%</button>
                    <button onclick="setScale(50)" id="btn-50" class="res-btn">50%</button>
                    <button onclick="setScale(25)" id="btn-25" class="res-btn">25%</button>
                    <button onclick="setScale(10)" id="btn-10" class="res-btn">10%</button>
                </div>
            </div>

            <!-- Gain -->
            <div class="control-group">
                <label>Gain <span id="val-gain" class="val-display">300</span></label>
                <input type="range" id="rng-gain" min="0" max="600" value="300" 
                       oninput="updateUI('gain', this.value)" onchange="sendSettings()">
            </div>

            <!-- Exposure -->
            <div class="control-group">
                <label>Exposure Time <span id="val-exp" class="val-display">100 ms</span></label>
                
                <!-- Unit Toggle -->
                <div class="mode-toggle">
                    <button class="mode-btn active" id="mode-ms" onclick="setExpMode('ms')">Milliseconds (Standard)</button>
                    <button class="mode-btn" id="mode-us" onclick="setExpMode('us')">Microseconds (Fast)</button>
                </div>

                <input type="range" id="rng-exp" min="1" max="5000" step="1" value="100" 
                       oninput="updateUI('exp', this.value)" onchange="sendSettings()">
            </div>
            
        </div>
    </div>

    <script>
        // State
        let currentSettings = { gain: 300, exposure_val: 100, exposure_mode: 'ms', scale_percent: 50 };
        let uiVisible = true;

        function toggleUI() {
            uiVisible = !uiVisible;
            document.getElementById('control-panel').style.display = uiVisible ? 'block' : 'none';
            document.getElementById('toggle-btn').style.display = uiVisible ? 'none' : 'block';
        }

        function updateUI(key, val) {
            if(key === 'gain') {
                document.getElementById('val-gain').innerText = val;
                currentSettings.gain = parseInt(val);
            }
            if(key === 'exp') {
                document.getElementById('val-exp').innerText = val + ' ' + currentSettings.exposure_mode;
                currentSettings.exposure_val = parseInt(val);
            }
        }

        function setExpMode(mode) {
            currentSettings.exposure_mode = mode;
            
            const slider = document.getElementById('rng-exp');
            const btnMs = document.getElementById('mode-ms');
            const btnUs = document.getElementById('mode-us');

            if(mode === 'ms') {
                // Standard Range: 1ms to 5000ms
                slider.min = 1; 
                slider.max = 5000;
                slider.value = 100; // Reset to safe default
                btnMs.classList.add('active');
                btnUs.classList.remove('active');
            } else {
                // Microsecond Range: 1us to 1000us
                slider.min = 1;
                slider.max = 1000;
                slider.value = 500;
                btnMs.classList.remove('active');
                btnUs.classList.add('active');
            }
            
            updateUI('exp', slider.value);
            sendSettings();
        }

        function setScale(percent) {
            currentSettings.scale_percent = percent;
            document.querySelectorAll('.res-btn').forEach(b => b.classList.remove('active'));
            document.getElementById('btn-' + percent).classList.add('active');
            sendSettings();
        }

        function sendSettings() {
            fetch('/update_settings', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify(currentSettings)
            });
        }

        // Init
        document.getElementById('btn-50').classList.add('active');
    </script>
</body>
</html>
"""

# ================= CAMERA LOGIC =================

def get_camera():
    lib_path = os.path.abspath(LIB_FILE)
    try:
        asi.init(lib_path)
    except Exception as e:
        print(f"Lib Error: {e}")
        return None

    if asi.get_num_cameras() == 0:
        return None

    try:
        c = asi.Camera(0)
        c.set_control_value(asi.ASI_BANDWIDTHOVERLOAD, 40)
        try:
            c.set_control_value(asi.ASI_HIGH_SPEED_MODE, 1)
        except:
            pass
        c.start_video_capture()
        return c
    except:
        return None

def generate_frames():
    camera = get_camera()
    if not camera:
        yield b"Error: No Camera"
        return

    cam_info = camera.get_camera_property()
    
    applied_gain = -1
    applied_exp = -1

    while True:
        # 1. READ SETTINGS
        with state_lock:
            target_gain = cam_state['gain']
            exp_val = cam_state['exposure_val']
            exp_mode = cam_state['exposure_mode']
            scale = cam_state['scale_percent'] / 100.0
        
        # Calculate Microseconds
        if exp_mode == 'ms':
            target_exp_us = exp_val * 1000
        else:
            target_exp_us = exp_val  # Direct Microseconds (1-1000)

        # 2. APPLY HARDWARE SETTINGS
        try:
            if target_gain != applied_gain:
                camera.set_control_value(asi.ASI_GAIN, target_gain)
                applied_gain = target_gain
            
            if target_exp_us != applied_exp:
                camera.set_control_value(asi.ASI_EXPOSURE, target_exp_us)
                applied_exp = target_exp_us
        except Exception as e:
            print(f"Control Error: {e}")

        # 3. CAPTURE
        try:
            # Calculate safe timeout in MS
            # Exposure (us) / 1000 = ms. Add 500ms buffer.
            timeout_ms = int((target_exp_us / 1000) + 500)
            frame = camera.capture_video_frame(timeout=timeout_ms)
        except Exception as e:
            time.sleep(0.01)
            continue

        # 4. PROCESS IMAGE
        if cam_info['IsColorCam']:
            image = cv2.cvtColor(frame, cv2.COLOR_BAYER_RG2RGB)
        else:
            image = frame

        if scale != 1.0:
            width = int(image.shape[1] * scale)
            height = int(image.shape[0] * scale)
            image = cv2.resize(image, (width, height), interpolation=cv2.INTER_LINEAR)

        ret, buffer = cv2.imencode('.jpg', image, [int(cv2.IMWRITE_JPEG_QUALITY), 80])
        if not ret: continue

        frame_bytes = buffer.tobytes()
        yield (b'--frame\r\n'
               b'Content-Type: image/jpeg\r\n\r\n' + frame_bytes + b'\r\n')

# ================= WEB ROUTES =================

@app.route('/')
def index():
    return render_template_string(HTML_TEMPLATE)

@app.route('/video_feed')
def video_feed():
    return Response(generate_frames(), mimetype='multipart/x-mixed-replace; boundary=frame')

@app.route('/update_settings', methods=['POST'])
def update_settings():
    data = request.json
    with state_lock:
        if 'gain' in data: cam_state['gain'] = int(data['gain'])
        if 'exposure_val' in data: cam_state['exposure_val'] = int(data['exposure_val'])
        if 'exposure_mode' in data: cam_state['exposure_mode'] = str(data['exposure_mode'])
        if 'scale_percent' in data: cam_state['scale_percent'] = int(data['scale_percent'])
    return jsonify({"status": "ok", "received": data})

if __name__ == '__main__':
    print("\n------------------------------------------------")
    print(" ZWO WEB CONTROLLER STARTED")
    print("------------------------------------------------")
    print(" Control Panel: http://<YOUR_PI_IP>:5000")
    print("------------------------------------------------\n")
    app.run(host='0.0.0.0', port=5000, threaded=True)
EOF

chmod +x zwo.py
echo "Advanced script 'zwo.py' created."

# --- 6. Launch ---
echo -e "\n${GREEN}[Step 6] Launching Camera Stream...${NC}"
python zwo.py
