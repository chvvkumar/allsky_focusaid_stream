#!/bin/bash

# ==============================================================================
# ZWO ASI Camera Streamer (v14.0 - Debayered stream, focus metrics removed)
# ==============================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting ZWO Camera Streamer Setup (v14.0)...${NC}"

# --- 1. System Dependencies ---
if ! dpkg -s libopencv-dev >/dev/null 2>&1; then
    echo "Installing system libraries..."
    sudo apt update && sudo apt install -y libopencv-dev python3-opencv
fi

# --- 2. Virtual Environment ---
VENV_DIR="venv"
if [[ "$VIRTUAL_ENV" == "" ]]; then
    if [ -d "$VENV_DIR" ]; then
        source "$VENV_DIR/bin/activate"
    else
        python3 -m venv "$VENV_DIR"
        source "$VENV_DIR/bin/activate"
    fi
fi

# --- 3. Python Dependencies ---
pip install --upgrade pip
pip install zwoasi flask opencv-python-headless numpy

# --- 4. Check Library ---
LIB_FILE="libASICamera2.so"
if [ ! -f "$LIB_FILE" ]; then
    echo -e "${RED}MISSING: $LIB_FILE${NC}"
    exit 1
fi

# --- 5. Generate Python Script ---
cat << 'EOF' > zwo.py
#!/usr/bin/env python3
import os, threading, signal
import cv2
import zwoasi as asi
from flask import Flask, Response, render_template_string, request, jsonify

# ================= CONFIGURATION =================
LIB_FILE = './libASICamera2.so'

# Global State
cam_state = {
    'gain': 300,
    'exposure_val': 100,
    'exposure_mode': 'ms',
}
state_lock = threading.Lock()

camera = None
app = Flask(__name__)

# ZWO reports the Bayer pattern of the sensor's top-left 2x2 block.
# OpenCV names its conversion by the 2x2 block starting at pixel (1,1),
# so the mapping is deliberately "crossed".
# Keys are ASI_BAYER_PATTERN enum values (zwoasi misnames 3 as ASI_BAYER_RB).
BAYER_TO_CV = {
    0: cv2.COLOR_BAYER_BG2BGR,  # ASI_BAYER_RG, sensor RGGB
    1: cv2.COLOR_BAYER_RG2BGR,  # ASI_BAYER_BG, sensor BGGR
    2: cv2.COLOR_BAYER_GB2BGR,  # ASI_BAYER_GR, sensor GRBG
    3: cv2.COLOR_BAYER_GR2BGR,  # ASI_BAYER_GB, sensor GBRG
}

# ================= HTML TEMPLATE =================
HTML_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
    <title>ZWO Stream</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <style>
        body { font-family: -apple-system, sans-serif; background: #000; margin: 0; overflow: hidden; touch-action: none; }

        #viewport { position: fixed; top: 0; left: 0; right: 0; bottom: 0; display: flex; align-items: center; justify-content: center; background: #111; overflow: hidden; }
        #transform-layer { position: relative; transform-origin: center center; transition: transform 0.1s ease-out; will-change: transform; }
        #video-feed { display: block; max-width: 100vw; max-height: 100vh; object-fit: contain; pointer-events: none; }

        #zoom-controls { position: fixed; bottom: 15px; right: 15px; z-index: 100; display: flex; flex-direction: column; gap: 8px; align-items: center; }
        #zoom-controls button {
            pointer-events: auto; width: 48px; height: 48px; border-radius: 50%;
            border: 1px solid rgba(255,255,255,0.15); background: rgba(20,20,20,0.9);
            backdrop-filter: blur(8px); color: #eee; font-size: 24px; font-weight: bold;
            cursor: pointer; line-height: 1; display: flex; align-items: center; justify-content: center;
        }
        #zoom-controls button:active { background: rgba(211,47,47,0.9); }
        #zoom-label { pointer-events: none; font-size: 11px; color: #d32f2f; font-weight: bold; font-family: monospace; background: rgba(20,20,20,0.9); border-radius: 10px; padding: 2px 8px; }

        #ui-layer { position: fixed; top: 10px; left: 10px; z-index: 100; width: 340px; max-width: 95vw; pointer-events: none; }

        .controls {
            pointer-events: auto; background: rgba(20, 20, 20, 0.9); backdrop-filter: blur(8px);
            padding: 15px; border-radius: 12px; color: #eee; border: 1px solid rgba(255,255,255,0.1);
            display: none; max-height: 85vh; overflow-y: auto;
        }

        #toggle-btn {
            pointer-events: auto; background: rgba(211, 47, 47, 0.9); color: white; border: none;
            padding: 10px 15px; border-radius: 20px; font-weight: bold; cursor: pointer;
        }

        .mode-switch { display: flex; background: #333; border-radius: 6px; margin-bottom: 15px; }
        .mode-switch button { flex: 1; padding: 8px; border: none; background: transparent; color: #888; cursor: pointer; border-radius: 6px; font-weight: bold; }
        .mode-switch button.active { background: #d32f2f; color: white; }

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
                <input type="range" id="rng-zoom" min="10" max="100" value="10" oninput="updateZoom(this.value)">
            </div>

            <div class="control-group">
                <label>Gain <span id="val-gain" class="val-display">300</span></label>
                <input type="range" id="rng-gain" min="0" max="600" value="300" oninput="updateVal('gain', this.value)" onchange="sendSettings()">
            </div>

            <div class="mode-switch">
                <button id="mode-ms" class="active" onclick="setExpMode('ms')">Milliseconds</button>
                <button id="mode-us" onclick="setExpMode('us')">Microseconds</button>
            </div>

            <div class="control-group">
                <label>Exposure Time <span id="val-exp" class="val-display">100</span></label>
                <input type="range" id="rng-exp" min="1" max="5000" value="100" oninput="updateVal('exp', this.value)" onchange="sendSettings()">
            </div>
        </div>
    </div>

    <!-- Floating Zoom Controls -->
    <div id="zoom-controls">
        <button onclick="stepZoom(5)" title="Zoom in" aria-label="Zoom in">+</button>
        <div id="zoom-label">1.0x</div>
        <button onclick="stepZoom(-5)" title="Zoom out" aria-label="Zoom out">&minus;</button>
        <button onclick="resetZoom()" title="Reset zoom" aria-label="Reset zoom" style="font-size:20px;">&#10227;</button>
    </div>

    <script>
        const transformLayer = document.getElementById('transform-layer');
        let zoomLevel = 1.0;
        let panX = 0, panY = 0;

        function applyTransform() {
            transformLayer.style.transform = `translate(${panX}px, ${panY}px) scale(${zoomLevel})`;
        }

        function clampPan() {
            const r = document.getElementById('video-feed').getBoundingClientRect();
            const maxX = Math.max(0, (r.width - window.innerWidth) / 2);
            const maxY = Math.max(0, (r.height - window.innerHeight) / 2);
            panX = Math.max(-maxX, Math.min(maxX, panX));
            panY = Math.max(-maxY, Math.min(maxY, panY));
        }

        function updateZoom(val) {
            zoomLevel = val / 10.0;
            const label = zoomLevel.toFixed(1) + 'x';
            document.getElementById('val-zoom').innerText = label;
            document.getElementById('zoom-label').innerText = label;
            document.getElementById('rng-zoom').value = val;
            clampPan();
            applyTransform();
        }

        function stepZoom(delta) {
            const v = Math.max(10, Math.min(100, parseInt(document.getElementById('rng-zoom').value) + delta));
            updateZoom(v);
        }

        function resetZoom() { panX = 0; panY = 0; updateZoom(10); }

        // Drag-to-pan (touch + mouse) when zoomed in
        (function() {
            const vp = document.getElementById('viewport');
            let dragging = false, startX, startY, startPanX, startPanY;

            vp.addEventListener('pointerdown', (e) => {
                if (zoomLevel <= 1.0) return;
                dragging = true;
                startX = e.clientX; startY = e.clientY;
                startPanX = panX; startPanY = panY;
                transformLayer.style.transition = 'none';
                vp.setPointerCapture(e.pointerId);
            });

            vp.addEventListener('pointermove', (e) => {
                if (!dragging) return;
                panX = startPanX + (e.clientX - startX);
                panY = startPanY + (e.clientY - startY);
                clampPan();
                applyTransform();
            });

            function endDrag() {
                if (!dragging) return;
                dragging = false;
                transformLayer.style.transition = '';
            }
            vp.addEventListener('pointerup', endDrag);
            vp.addEventListener('pointercancel', endDrag);
        })();

        // Settings Logic
        let settings = {gain: 300, exp: 100};
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
            if(m === 'ms') { rng.max = 5000; rng.value = Math.max(1, rng.value); document.getElementById('val-exp').innerText = rng.value + ' ms'; }
            else { rng.max = 2000; rng.value = 100; document.getElementById('val-exp').innerText = rng.value + ' µs'; }
            settings.exp = parseInt(rng.value);
            sendSettings();
        }

        function updateVal(k, v) {
            document.getElementById('val-'+k).innerText = v + (k==='exp' ? (expMode==='ms'?' ms':' µs') : '');
            if(k === 'gain') settings.gain = parseInt(v);
            if(k === 'exp') settings.exp = parseInt(v);
        }

        function sendSettings() {
            fetch('/update_settings', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({
                    gain: settings.gain,
                    exposure_val: settings.exp,
                    exposure_mode: expMode
                })
            });
        }

        document.getElementById('control-panel').style.display = 'none';
    </script>
</body>
</html>
"""

# ================= VIDEO LOOP =================

def generate_frames():
    global camera
    bayer_code = None
    if not camera:
        try:
            asi.init(LIB_FILE)
            if asi.get_num_cameras() > 0:
                camera = asi.Camera(0)
                camera.set_control_value(asi.ASI_HIGH_SPEED_MODE, 1)
                camera.set_image_type(asi.ASI_IMG_RAW8)
                camera.start_video_capture()
        except: pass

    if not camera:
        yield b'Error: No Camera'
        return

    props = camera.get_camera_property()
    if props.get('IsColorCam'):
        bayer_code = BAYER_TO_CV.get(props.get('BayerPattern'), cv2.COLOR_BAYER_BG2BGR)

    applied_gain = -1
    applied_exp = -1

    while True:
        with state_lock:
            current_state = cam_state.copy()

        gain = current_state['gain']
        exp_val = current_state['exposure_val']
        exp_mode = current_state['exposure_mode']

        try:
            if gain != applied_gain:
                camera.set_control_value(asi.ASI_GAIN, gain)
                applied_gain = gain

            target_us = exp_val * 1000 if exp_mode == 'ms' else exp_val
            target_us = max(1, target_us)

            if target_us != applied_exp:
                camera.set_control_value(asi.ASI_EXPOSURE, target_us)
                applied_exp = target_us
        except: pass

        try:
            to_ms = int(target_us / 1000) + 500
            frame = camera.capture_video_frame(timeout=to_ms)
        except: continue

        # RAW8 frame is a 2D Bayer mosaic on colour cameras; debayer to BGR for JPEG.
        if bayer_code is not None and frame.ndim == 2:
            frame = cv2.cvtColor(frame, bayer_code)

        ret, buffer = cv2.imencode('.jpg', frame)
        yield (b'--frame\r\nContent-Type: image/jpeg\r\n\r\n' + buffer.tobytes() + b'\r\n')

# ================= ROUTES =================
@app.route('/')
def index(): return render_template_string(HTML_TEMPLATE)

@app.route('/video_feed')
def video_feed(): return Response(generate_frames(), mimetype='multipart/x-mixed-replace; boundary=frame')

@app.route('/update_settings', methods=['POST'])
def update_settings():
    d = request.json
    with state_lock:
        if 'gain' in d: cam_state['gain'] = int(d['gain'])
        if 'exposure_val' in d: cam_state['exposure_val'] = int(d['exposure_val'])
        if 'exposure_mode' in d: cam_state['exposure_mode'] = str(d['exposure_mode'])
    return jsonify({"status":"ok"})

def _shutdown(signum, frame):
    print("\nShutting down...")
    try:
        if camera:
            camera.stop_video_capture()
            camera.close()
    except Exception:
        pass
    os._exit(0)

if __name__ == '__main__':
    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)
    app.run(host='0.0.0.0', port=5000, threaded=True)
EOF

chmod +x zwo.py
python zwo.py
