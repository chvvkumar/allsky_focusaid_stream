#!/bin/bash

# ==============================================================================
# ZWO ASI Camera Streamer v6 (Zoom, Daylight Mode, Configurable Text)
# ==============================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting ZWO Camera Streamer Setup (Zoom Edition)...${NC}"

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
pip install zwoasi flask opencv-python-headless numpy

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
echo -e "\n${YELLOW}[Step 5] Generating 'zwo.py' with Zoom & Daylight Support...${NC}"

cat << 'EOF' > zwo.py
#!/usr/bin/env python3
import sys
import os
import time
import threading
import json
import math

try:
    import cv2
    import numpy as np
    import zwoasi as asi
    from flask import Flask, Response, render_template_string, request, jsonify
except ImportError as e:
    print(f"Missing libraries: {e}")
    sys.exit(1)

# ================= CONFIGURATION =================
LIB_FILE = './libASICamera2.so' 

# Global State
cam_state = {
    'gain': 300,
    'exposure_val': 100,
    'exposure_mode': 'ms',
    'scale_percent': 50,
    'font_scale': 1.0,  # New: Text Size
    'roi_norm': None
}
state_lock = threading.Lock()

# Global Camera
camera = None
camera_lock = threading.Lock()

app = Flask(__name__)

# ================= HTML TEMPLATE =================
HTML_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
    <title>ZWO Focus Aid</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <style>
        body { 
            font-family: -apple-system, system-ui, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            background: #000; 
            margin: 0; 
            padding: 0; 
            overflow: hidden; 
            touch-action: none; 
        }
        
        /* Viewport limits what we see */
        #viewport {
            position: fixed;
            top: 0; left: 0; right: 0; bottom: 0;
            display: flex;
            align-items: center;
            justify-content: center;
            background: #111;
            overflow: hidden;
        }

        /* The container that gets Transformed (Zoom/Pan) */
        #transform-layer {
            position: relative;
            transform-origin: center center;
            transition: transform 0.1s ease-out;
            will-change: transform;
        }

        /* The Video Feed */
        #video-feed { 
            display: block;
            max-width: 100vw; 
            max-height: 100vh; 
            object-fit: contain;
            pointer-events: none; /* Let clicks pass to interaction layer */
        }
        
        /* The Interaction Layer (Captures Clicks/Drags) */
        #interaction-layer {
            position: absolute;
            top: 0; left: 0; right: 0; bottom: 0;
            z-index: 10;
        }

        /* Selection Box */
        #selection-box {
            position: absolute;
            border: 2px dashed rgba(255, 0, 0, 0.9);
            background: rgba(255, 0, 0, 0.2);
            display: none;
            z-index: 20;
            pointer-events: none;
        }

        /* UI Layer */
        #ui-layer {
            position: fixed;
            top: 10px; left: 10px;
            z-index: 100;
            width: 320px;
            max-width: 95vw;
            pointer-events: none; 
        }

        .controls { 
            pointer-events: auto;
            background: rgba(20, 20, 20, 0.85);
            backdrop-filter: blur(8px);
            padding: 15px; 
            border-radius: 12px; 
            color: #eee;
            border: 1px solid rgba(255,255,255,0.1);
            display: none;
            max-height: 80vh;
            overflow-y: auto;
        }

        #toggle-btn {
            pointer-events: auto;
            background: rgba(211, 47, 47, 0.9);
            color: white; border: none; padding: 10px 15px;
            border-radius: 20px; font-weight: bold; cursor: pointer;
        }

        /* Mode Switcher */
        .mode-switch {
            display: flex; background: #333; border-radius: 6px; margin-bottom: 15px;
        }
        .mode-switch button {
            flex: 1; padding: 8px; border: none; background: transparent; color: #888; cursor: pointer; border-radius: 6px; font-weight: bold;
        }
        .mode-switch button.active { background: #d32f2f; color: white; }

        /* Form Elements */
        .control-group { margin-bottom: 12px; }
        label { display: flex; justify-content: space-between; font-size: 12px; color: #ccc; margin-bottom: 4px; }
        .val-display { color: #d32f2f; font-weight: bold; font-family: monospace; }
        
        input[type=range] { width: 100%; height: 6px; background: #444; border-radius: 3px; -webkit-appearance: none; }
        input[type=range]::-webkit-slider-thumb { -webkit-appearance: none; width: 18px; height: 18px; background: #d32f2f; border-radius: 50%; }

    </style>
</head>
<body>

    <div id="viewport">
        <div id="transform-layer">
            <img id="video-feed" src="/video_feed">
            <div id="interaction-layer">
                <div id="selection-box"></div>
            </div>
        </div>
    </div>

    <div id="ui-layer">
        <button id="toggle-btn" onclick="toggleUI()">Settings</button>
        
        <div class="controls" id="control-panel">
            <div style="display:flex; justify-content:space-between; margin-bottom:10px;">
                <strong>CAMERA CONTROLS</strong>
                <button onclick="toggleUI()" style="background:none; border:none; color:#fff; font-size:18px;">&times;</button>
            </div>

            <div class="control-group">
                <label>Digital Zoom <span id="val-zoom" class="val-display">1.0x</span></label>
                <input type="range" id="rng-zoom" min="10" max="40" value="10" 
                       oninput="updateZoom(this.value)">
            </div>

            <div class="control-group">
                <label>Gain <span id="val-gain" class="val-display">300</span></label>
                <input type="range" id="rng-gain" min="0" max="600" value="300" 
                       oninput="updateVal('gain', this.value)" onchange="sendSettings()">
            </div>

            <div class="mode-switch">
                <button id="mode-ms" class="active" onclick="setExpMode('ms')">Milliseconds</button>
                <button id="mode-us" onclick="setExpMode('us')">Microseconds</button>
            </div>

            <div class="control-group">
                <label>Exposure Time <span id="val-exp" class="val-display">100</span></label>
                <input type="range" id="rng-exp" min="1" max="5000" value="100" 
                       oninput="updateVal('exp', this.value)" onchange="sendSettings()">
            </div>
            
            <hr style="border-color: #333; margin: 15px 0;">
            
            <div class="control-group">
                <label style="margin-bottom: 8px;">Interaction Mode</label>
                <div style="display: flex; gap: 10px;">
                    <button class="tool-btn-inline active" id="btn-select" onclick="setTool('select')" style="flex: 1; padding: 10px; background: #d32f2f; color: white; border: none; border-radius: 6px; cursor: pointer; font-weight: bold;">
                        ◻ Select Star
                    </button>
                    <button class="tool-btn-inline" id="btn-pan" onclick="setTool('pan')" style="flex: 1; padding: 10px; background: #444; color: white; border: none; border-radius: 6px; cursor: pointer; font-weight: bold;">
                        ✋ Pan Image
                    </button>
                </div>
            </div>
            
            <hr style="border-color: #333; margin: 15px 0;">

            <div class="control-group">
                <label>FWHM Text Size <span id="val-font" class="val-display">1.0</span></label>
                <input type="range" id="rng-font" min="5" max="30" value="10" 
                       oninput="updateVal('font', this.value)" onchange="sendSettings()">
            </div>
            
            <div style="font-size: 11px; color: #888; margin-top: 10px;">
                Double-tap video to clear FWHM box.
            </div>
        </div>
    </div>

    <script>
        const layer = document.getElementById('interaction-layer');
        const transformLayer = document.getElementById('transform-layer');
        const selBox = document.getElementById('selection-box');
        
        // State
        let currentTool = 'select'; // 'select' or 'pan'
        let zoomLevel = 1.0;
        let panX = 0, panY = 0;
        
        let startX, startY;
        let isDragging = false;
        
        // Event Listeners
        layer.addEventListener('touchstart', handleStart, {passive: false});
        layer.addEventListener('mousedown', handleStart);
        
        layer.addEventListener('touchmove', handleMove, {passive: false});
        layer.addEventListener('mousemove', handleMove);
        
        layer.addEventListener('touchend', handleEnd);
        layer.addEventListener('mouseup', handleEnd);
        
        layer.addEventListener('dblclick', clearSelection);

        // --- Interaction Logic ---
        function setTool(t) {
            currentTool = t;
            const selectBtn = document.getElementById('btn-select');
            const panBtn = document.getElementById('btn-pan');
            
            if(t === 'select') {
                selectBtn.style.background = '#d32f2f';
                panBtn.style.background = '#444';
                layer.style.cursor = 'crosshair';
            } else {
                selectBtn.style.background = '#444';
                panBtn.style.background = '#d32f2f';
                layer.style.cursor = 'grab';
            }
        }

        function updateZoom(val) {
            zoomLevel = val / 10.0;
            document.getElementById('val-zoom').innerText = zoomLevel.toFixed(1) + 'x';
            applyTransform();
        }

        function applyTransform() {
            transformLayer.style.transform = `scale(${zoomLevel}) translate(${panX}px, ${panY}px)`;
        }

        function handleStart(e) {
            e.preventDefault();
            const pt = getPoint(e);
            startX = pt.x;
            startY = pt.y;
            isDragging = true;

            if(currentTool === 'select') {
                // Reset box visual relative to the zoomed layer
                const rect = layer.getBoundingClientRect(); // Get current zoomed coords
                
                // We need click coordinates relative to the LAYER, not the SCREEN
                // Luckily, layer is child of transform-layer, so offsetX/Y works well with mouse
                // But touch is trickier.
                
                // Simple approach: Calculate relative to client, apply inverse later? 
                // Actually, standard visual feedback:
                selBox.style.display = 'block';
                selBox.style.width = '0px';
                selBox.style.height = '0px';
                
                // We place the box using client coordinates initially for simplicity, 
                // but since the parent is transformed, we must be careful.
                // EASIER: Calculate Offset relative to the interaction-layer directly.
                
                let local = getLocalCoords(e);
                selBox.dataset.ox = local.x;
                selBox.dataset.oy = local.y;
                selBox.style.left = local.x + 'px';
                selBox.style.top = local.y + 'px';
            }
        }

        function handleMove(e) {
            if(!isDragging) return;
            e.preventDefault();
            const pt = getPoint(e);

            if(currentTool === 'pan') {
                const dx = (pt.x - startX) / zoomLevel;
                const dy = (pt.y - startY) / zoomLevel;
                panX += dx;
                panY += dy;
                startX = pt.x; // reset for next delta
                startY = pt.y;
                applyTransform();
            } else {
                // Select Mode
                let local = getLocalCoords(e);
                let ox = parseFloat(selBox.dataset.ox);
                let oy = parseFloat(selBox.dataset.oy);
                
                let w = Math.abs(local.x - ox);
                let h = Math.abs(local.y - oy);
                let l = Math.min(local.x, ox);
                let t = Math.min(local.y, oy);
                
                selBox.style.width = w + 'px';
                selBox.style.height = h + 'px';
                selBox.style.left = l + 'px';
                selBox.style.top = t + 'px';
            }
        }

        function handleEnd(e) {
            if(!isDragging) return;
            isDragging = false;
            
            if(currentTool === 'select') {
                const w = parseFloat(selBox.style.width);
                const h = parseFloat(selBox.style.height);
                const l = parseFloat(selBox.style.left);
                const t = parseFloat(selBox.style.top);
                
                selBox.style.display = 'none';
                if(w < 10 || h < 10) return;

                // Normalize based on the layer size (which matches the image size)
                // Note: layer.offsetWidth is the un-zoomed internal size, which is what we want!
                const totalW = layer.offsetWidth;
                const totalH = layer.offsetHeight;

                const roi = {
                    x: l / totalW,
                    y: t / totalH,
                    w: w / totalW,
                    h: h / totalH
                };
                
                fetch('/update_roi', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify(roi)
                });
            }
        }

        function getPoint(e) {
            if(e.touches) return {x: e.touches[0].clientX, y: e.touches[0].clientY};
            return {x: e.clientX, y: e.clientY};
        }

        function getLocalCoords(e) {
            // Returns coordinates relative to the un-zoomed element space
            const rect = layer.getBoundingClientRect();
            const pt = getPoint(e);
            
            // Map screen pixels to element pixels taking Zoom into account
            const relX = (pt.x - rect.left) / zoomLevel;
            const relY = (pt.y - rect.top) / zoomLevel;
            
            return {x: relX, y: relY};
        }
        
        // --- Settings Logic ---
        let settings = {gain: 300, exp: 100, font: 10};
        let expMode = 'ms';

        function toggleUI() {
            const p = document.getElementById('control-panel');
            const b = document.getElementById('toggle-btn');
            const show = p.style.display === 'none';
            p.style.display = show ? 'block' : 'none';
            b.style.display = show ? 'none' : 'block';
        }

        function setExpMode(m) {
            expMode = m;
            document.getElementById('mode-ms').classList.toggle('active', m==='ms');
            document.getElementById('mode-us').classList.toggle('active', m==='us');
            
            const rng = document.getElementById('rng-exp');
            if(m === 'ms') {
                rng.max = 5000;
                rng.value = Math.max(1, rng.value); // keep value if valid
                document.getElementById('val-exp').innerText = rng.value + ' ms';
            } else {
                rng.max = 2000; // Allow up to 2000us
                rng.value = 100; // Reset to safe us value
                document.getElementById('val-exp').innerText = rng.value + ' µs';
            }
            sendSettings();
        }

        function updateVal(k, v) {
            if(k === 'font') {
                document.getElementById('val-'+k).innerText = (v/10.0).toFixed(1);
            } else {
                document.getElementById('val-'+k).innerText = v + (k==='exp' ? (expMode==='ms'?' ms':' µs') : '');
            }
            
            if(k === 'gain') settings.gain = parseInt(v);
            if(k === 'exp') settings.exp = parseInt(v);
            if(k === 'font') settings.font = parseInt(v);
        }

        function sendSettings() {
            fetch('/update_settings', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({
                    gain: settings.gain, 
                    exposure_val: settings.exp,
                    exposure_mode: expMode,
                    font_scale: settings.font / 10.0
                })
            });
        }
        
        function clearSelection() {
            selBox.style.display = 'none';
            fetch('/update_roi', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({clear: true})
            });
        }
        
        // Init
        document.getElementById('control-panel').style.display = 'none';
    </script>
</body>
</html>
"""

# ================= IMAGE PROCESSING =================

def calculate_fwhm(roi_img):
    try:
        minVal, maxVal, minLoc, maxLoc = cv2.minMaxLoc(roi_img)
        threshold_val = maxVal - (maxVal - minVal) * 0.5
        if threshold_val < 0: threshold_val = 0
        
        h, w = roi_img.shape
        cx, cy = maxLoc
        win_radius = 15
        
        x1 = max(0, cx - win_radius)
        x2 = min(w, cx + win_radius)
        y1 = max(0, cy - win_radius)
        y2 = min(h, cy + win_radius)
        
        star_cutout = roi_img[y1:y2, x1:x2].astype(float)
        star_cutout -= np.mean(star_cutout)
        star_cutout[star_cutout < 0] = 0
        
        m = cv2.moments(star_cutout)
        if m['m00'] == 0: return 0.0
        
        mu20 = m['mu20'] / m['m00']
        mu02 = m['mu02'] / m['m00']
        sigma = (math.sqrt(abs(mu20)) + math.sqrt(abs(mu02))) / 2.0
        return round(2.355 * sigma, 2)
    except:
        return 0.0

def init_camera():
    global camera
    with camera_lock:
        if camera is not None:
            return True
            
        lib_path = os.path.abspath(LIB_FILE)
        try:
            asi.init(lib_path)
        except Exception as e:
            print(f"ASI Init: {e}")
            return False
            
        if asi.get_num_cameras() == 0:
            print("No cameras detected")
            return False

        camera = asi.Camera(0)
        try:
            camera.set_control_value(asi.ASI_BANDWIDTHOVERLOAD, 40)
            camera.set_control_value(asi.ASI_HIGH_SPEED_MODE, 1)
            camera.start_video_capture()
            print(f"Camera initialized: {camera.get_camera_property()['Name']}")
            return True
        except Exception as e:
            print(f"Camera setup error: {e}")
            camera = None
            return False

def generate_frames():
    global camera
    
    if not init_camera():
        yield b"Error: Camera initialization failed"
        return

    applied_gain = -1
    applied_exp = -1

    while True:
        with state_lock:
            gain = cam_state['gain']
            exp_val = cam_state['exposure_val']
            exp_mode = cam_state['exposure_mode']
            font_s = cam_state['font_scale']
            roi_def = cam_state['roi_norm']
        
        # Apply Controls
        try:
            if gain != applied_gain:
                camera.set_control_value(asi.ASI_GAIN, gain)
                applied_gain = gain
            
            # Exposure Calc
            target_us = exp_val * 1000 if exp_mode == 'ms' else exp_val
            if target_us < 1: target_us = 1 # Hardware safety
            
            if target_us != applied_exp:
                camera.set_control_value(asi.ASI_EXPOSURE, target_us)
                applied_exp = target_us
        except:
            pass

        # Capture
        try:
            # Timeout buffer: convert us to ms, add 500ms safety
            to_ms = int(target_us / 1000) + 500
            frame = camera.capture_video_frame(timeout=to_ms)
        except:
            time.sleep(0.01)
            continue

        # Process
        gray_frame = frame
        color_frame = frame
        cam_props = camera.get_camera_property()
        
        if cam_props['IsColorCam']:
            color_frame = cv2.cvtColor(frame, cv2.COLOR_BAYER_RG2RGB)
            gray_frame = cv2.cvtColor(color_frame, cv2.COLOR_RGB2GRAY)
        else:
            color_frame = cv2.cvtColor(frame, cv2.COLOR_GRAY2RGB)

        # FWHM Overlay
        if roi_def:
            h, w = gray_frame.shape
            rx = int(roi_def['x'] * w)
            ry = int(roi_def['y'] * h)
            rw = int(roi_def['w'] * w)
            rh = int(roi_def['h'] * h)
            
            if rw > 5 and rh > 5:
                # Calc FWHM
                roi_gray = gray_frame[ry:ry+rh, rx:rx+rw]
                fwhm_val = calculate_fwhm(roi_gray)
                
                # Draw Box
                cv2.rectangle(color_frame, (rx, ry), (rx+rw, ry+rh), (0, 255, 0), 2)
                
                # Draw Text
                label = f"FWHM: {fwhm_val} px"
                
                # Dynamic Font/Box Sizing
                thickness = 2
                (t_w, t_h), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, font_s, thickness)
                
                cv2.rectangle(color_frame, (rx, ry-t_h-10), (rx+t_w+10, ry), (0, 255, 0), -1)
                cv2.putText(color_frame, label, (rx+5, ry-5), 
                           cv2.FONT_HERSHEY_SIMPLEX, font_s, (0, 0, 0), thickness)

        ret, buffer = cv2.imencode('.jpg', color_frame, [int(cv2.IMWRITE_JPEG_QUALITY), 80])
        frame_bytes = buffer.tobytes()
        
        yield (b'--frame\r\n'
               b'Content-Type: image/jpeg\r\n\r\n' + frame_bytes + b'\r\n')

# ================= ROUTES =================

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
        if 'font_scale' in data: cam_state['font_scale'] = float(data['font_scale'])
    return jsonify({"status": "ok"})

@app.route('/update_roi', methods=['POST'])
def update_roi():
    data = request.json
    with state_lock:
        if 'clear' in data and data['clear']:
            cam_state['roi_norm'] = None
        else:
            cam_state['roi_norm'] = {
                'x': float(data['x']),
                'y': float(data['y']),
                'w': float(data['w']),
                'h': float(data['h'])
            }
    return jsonify({"status": "ok"})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, threaded=True)
EOF

chmod +x zwo.py
echo "Advanced script 'zwo.py' created."

# --- 6. Launch ---
echo -e "\n${GREEN}[Step 6] Launching Camera Stream...${NC}"
python zwo.py
