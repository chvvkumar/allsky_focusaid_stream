#!/bin/bash

# ==============================================================================
# ZWO ASI Camera Streamer v9 (UI Graph, Text Size, Graph Height)
# ==============================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting ZWO Camera Streamer Setup (v9)...${NC}"

# --- 1. System Dependencies Check ---
if ! dpkg -s libopencv-dev >/dev/null 2>&1; then
    echo "Installing system libraries..."
    sudo apt update && sudo apt install -y libopencv-dev python3-opencv
fi

# --- 2. Virtual Environment Setup ---
VENV_DIR="venv"
if [[ "$VIRTUAL_ENV" == "" ]]; then
    if [ -d "$VENV_DIR" ]; then
        source "$VENV_DIR/bin/activate"
    else
        python3 -m venv "$VENV_DIR"
        source "$VENV_DIR/bin/activate"
    fi
fi

# --- 3. Install Python Dependencies ---
pip install --upgrade pip
pip install zwoasi flask opencv-python-headless numpy

# --- 4. Check for ZWO SDK Library ---
LIB_FILE="libASICamera2.so"
if [ ! -f "$LIB_FILE" ]; then
    echo -e "${RED}MISSING: $LIB_FILE${NC}"
    exit 1
fi

# --- 5. Generate Advanced Python Script ---
cat << 'EOF' > zwo.py
#!/usr/bin/env python3
import sys, os, time, threading, json, math
from collections import deque
import cv2
import numpy as np
import zwoasi as asi
from flask import Flask, Response, render_template_string, request, jsonify

# ================= CONFIGURATION =================
LIB_FILE = './libASICamera2.so' 

# Global State
cam_state = {
    'gain': 300,
    'exposure_val': 100,
    'exposure_mode': 'ms',
    'roi_norm': None,
    'font_scale': 1.0,      # Text Size
    'graph_height': 60      # Profile Graph Height (px)
}
state_lock = threading.Lock()

# Focus History (Last 50 HFD readings)
hfd_history = deque(maxlen=50)

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
        body { font-family: -apple-system, sans-serif; background: #000; margin: 0; overflow: hidden; touch-action: none; }
        
        #viewport { position: fixed; top: 0; left: 0; right: 0; bottom: 0; display: flex; align-items: center; justify-content: center; background: #111; overflow: hidden; }
        #transform-layer { position: relative; transform-origin: center center; transition: transform 0.1s ease-out; will-change: transform; }
        #video-feed { display: block; max-width: 100vw; max-height: 100vh; object-fit: contain; pointer-events: none; }
        
        #interaction-layer { position: absolute; top: 0; left: 0; right: 0; bottom: 0; z-index: 10; }
        #selection-box { position: absolute; border: 2px dashed rgba(0, 255, 0, 0.9); background: rgba(0, 255, 0, 0.1); display: none; z-index: 20; pointer-events: none; }

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
        
        .tool-btn { flex: 1; padding: 10px; border: none; border-radius: 6px; cursor: pointer; font-weight: bold; color: white; }

        /* History Graph Canvas */
        #graph-container { background: #111; border: 1px solid #444; border-radius: 4px; margin-bottom: 15px; padding: 5px; }
        canvas { width: 100%; height: 100px; display: block; }

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
            
            <div id="graph-container">
                <div style="font-size:10px; color:#888; margin-bottom:2px;">Focus History (Lower is Better)</div>
                <canvas id="historyGraph"></canvas>
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
            
            <hr style="border-color: #333; margin: 15px 0;">

            <div class="control-group">
                <label>Overlay Text Size <span id="val-font" class="val-display">1.0</span></label>
                <input type="range" id="rng-font" min="5" max="30" value="10" oninput="updateVal('font', this.value)" onchange="sendSettings()">
            </div>

            <div class="control-group">
                <label>Profile Graph Height <span id="val-gheight" class="val-display">60px</span></label>
                <input type="range" id="rng-gheight" min="20" max="200" value="60" oninput="updateVal('gheight', this.value)" onchange="sendSettings()">
            </div>
            
            <hr style="border-color: #333; margin: 15px 0;">
            
            <div class="control-group">
                <label style="margin-bottom: 8px;">Interaction Mode</label>
                <div style="display: flex; gap: 10px;">
                    <button class="tool-btn" id="btn-select" onclick="setTool('select')" style="background: #d32f2f;">◻ Select Star</button>
                    <button class="tool-btn" id="btn-pan" onclick="setTool('pan')" style="background: #444;">✋ Pan Image</button>
                </div>
            </div>
            
            <div style="font-size: 11px; color: #888; margin-top: 10px;">
                Double-tap video to clear selection.
            </div>
        </div>
    </div>

    <script>
        const layer = document.getElementById('interaction-layer');
        const transformLayer = document.getElementById('transform-layer');
        const selBox = document.getElementById('selection-box');
        
        let currentTool = 'select';
        let zoomLevel = 1.0;
        let panX = 0, panY = 0;
        let startX, startY;
        let isDragging = false;
        
        // --- Graphing Logic ---
        const canvas = document.getElementById('historyGraph');
        const ctx = canvas.getContext('2d');
        
        function drawGraph(data) {
            // Resize canvas internal buffer to match display
            canvas.width = canvas.offsetWidth;
            canvas.height = canvas.offsetHeight;
            const w = canvas.width;
            const h = canvas.height;
            
            ctx.clearRect(0, 0, w, h);
            
            if(data.length < 2) return;
            
            const maxVal = Math.max(...data, 10);
            const minVal = Math.min(...data); // Optional: scale from 0 or min? using 0 for HFD is safer
            
            ctx.beginPath();
            ctx.strokeStyle = '#00e5ff';
            ctx.lineWidth = 2;
            
            data.forEach((val, i) => {
                const x = (i / (data.length - 1)) * w;
                // Invert Y so 0 is at bottom
                const y = h - ((val / (maxVal * 1.1)) * h); 
                if (i===0) ctx.moveTo(x, y);
                else ctx.lineTo(x, y);
            });
            ctx.stroke();
            
            // Draw current value text
            ctx.fillStyle = '#fff';
            ctx.font = '12px sans-serif';
            ctx.fillText(data[data.length-1].toFixed(2), w - 40, 15);
        }
        
        function fetchStatus() {
            if(document.getElementById('control-panel').style.display === 'none') return;
            
            fetch('/get_status')
                .then(r => r.json())
                .then(d => {
                    if(d.history) drawGraph(d.history);
                });
        }
        setInterval(fetchStatus, 1000);

        // --- Interaction Logic ---
        layer.addEventListener('touchstart', handleStart, {passive: false});
        layer.addEventListener('mousedown', handleStart);
        layer.addEventListener('touchmove', handleMove, {passive: false});
        layer.addEventListener('mousemove', handleMove);
        layer.addEventListener('touchend', handleEnd);
        layer.addEventListener('mouseup', handleEnd);
        layer.addEventListener('dblclick', clearSelection);

        function setTool(t) {
            currentTool = t;
            document.getElementById('btn-select').style.background = t==='select'?'#d32f2f':'#444';
            document.getElementById('btn-pan').style.background = t==='pan'?'#d32f2f':'#444';
            layer.style.cursor = t==='select'?'crosshair':'grab';
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
            startX = pt.x; startY = pt.y;
            isDragging = true;

            if(currentTool === 'select') {
                selBox.style.display = 'block';
                selBox.style.width = '0px'; selBox.style.height = '0px';
                let local = getLocalCoords(e);
                selBox.dataset.ox = local.x; selBox.dataset.oy = local.y;
                selBox.style.left = local.x + 'px'; selBox.style.top = local.y + 'px';
            }
        }

        function handleMove(e) {
            if(!isDragging) return;
            e.preventDefault();
            const pt = getPoint(e);

            if(currentTool === 'pan') {
                panX += (pt.x - startX) / zoomLevel;
                panY += (pt.y - startY) / zoomLevel;
                startX = pt.x; startY = pt.y;
                applyTransform();
            } else {
                let local = getLocalCoords(e);
                let ox = parseFloat(selBox.dataset.ox);
                let oy = parseFloat(selBox.dataset.oy);
                selBox.style.width = Math.abs(local.x - ox) + 'px';
                selBox.style.height = Math.abs(local.y - oy) + 'px';
                selBox.style.left = Math.min(local.x, ox) + 'px';
                selBox.style.top = Math.min(local.y, oy) + 'px';
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

                const roi = {
                    x: l / layer.offsetWidth,
                    y: t / layer.offsetHeight,
                    w: w / layer.offsetWidth,
                    h: h / layer.offsetHeight
                };
                fetch('/update_roi', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(roi)});
            }
        }

        function getPoint(e) { return e.touches ? {x:e.touches[0].clientX, y:e.touches[0].clientY} : {x:e.clientX, y:e.clientY}; }
        
        function getLocalCoords(e) {
            const rect = layer.getBoundingClientRect();
            const pt = getPoint(e);
            return {x: (pt.x - rect.left)/zoomLevel, y: (pt.y - rect.top)/zoomLevel};
        }
        
        // Settings Logic
        let settings = {gain: 300, exp: 100, font: 10, gheight: 60};
        let expMode = 'ms';

        function toggleUI() {
            const p = document.getElementById('control-panel');
            const b = document.getElementById('toggle-btn');
            const show = p.style.display === 'none';
            p.style.display = show ? 'block' : 'none';
            b.style.display = show ? 'none' : 'block';
            
            // Trigger graph fetch immediately on open
            if(show) fetchStatus();
        }

        function setExpMode(m) {
            expMode = m;
            document.getElementById('mode-ms').classList.toggle('active', m==='ms');
            document.getElementById('mode-us').classList.toggle('active', m==='us');
            const rng = document.getElementById('rng-exp');
            if(m === 'ms') { rng.max = 5000; rng.value = Math.max(1, rng.value); document.getElementById('val-exp').innerText = rng.value + ' ms'; } 
            else { rng.max = 2000; rng.value = 100; document.getElementById('val-exp').innerText = rng.value + ' µs'; }
            sendSettings();
        }

        function updateVal(k, v) {
            if(k === 'font') document.getElementById('val-'+k).innerText = (v/10.0).toFixed(1);
            else if(k === 'gheight') document.getElementById('val-'+k).innerText = v + 'px';
            else document.getElementById('val-'+k).innerText = v + (k==='exp' ? (expMode==='ms'?' ms':' µs') : '');
            
            if(k === 'gain') settings.gain = parseInt(v);
            if(k === 'exp') settings.exp = parseInt(v);
            if(k === 'font') settings.font = parseInt(v);
            if(k === 'gheight') settings.gheight = parseInt(v);
        }

        function sendSettings() {
            fetch('/update_settings', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({
                    gain: settings.gain, 
                    exposure_val: settings.exp,
                    exposure_mode: expMode,
                    font_scale: settings.font / 10.0,
                    graph_height: settings.gheight
                })
            });
        }
        
        function clearSelection() {
            selBox.style.display = 'none';
            fetch('/update_roi', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({clear: true})});
        }
        
        document.getElementById('control-panel').style.display = 'none';
    </script>
</body>
</html>
"""

# ================= PROCESSING ALGORITHMS =================

def calculate_hfd(roi_img):
    try:
        # Hot pixel safety blur
        blurred = cv2.GaussianBlur(roi_img, (3, 3), 0)
        minVal, maxVal, minLoc, maxLoc = cv2.minMaxLoc(blurred)
        
        if maxVal < 5: return 0.0, maxLoc

        # Median Background Subtraction
        bg = np.median(roi_img)
        star_data = roi_img.astype(float) - bg
        star_data[star_data < 0] = 0
        
        # Centroid
        m = cv2.moments(star_data)
        if m['m00'] == 0: return 0.0, maxLoc
        cx = m['m10'] / m['m00']
        cy = m['m01'] / m['m00']
        
        # HFD Calc
        h, w = roi_img.shape
        y_indices, x_indices = np.indices((h, w))
        distances = np.sqrt((x_indices - cx)**2 + (y_indices - cy)**2)
        
        total_flux = np.sum(star_data)
        weighted_flux = np.sum(star_data * distances)
        
        if total_flux == 0: return 0.0, (cx, cy)
        return round((weighted_flux / total_flux) * 2.0, 2), (cx, cy)
    except:
        return 0.0, (0,0)

def draw_overlays(frame, roi_img, hfd_val, centroid, rect_offset, state):
    rx, ry, rw, rh = rect_offset
    cx_local, cy_local = centroid
    font_s = state.get('font_scale', 1.0)
    g_h = state.get('graph_height', 60)
    
    # 1. HFD Box & Label
    cv2.rectangle(frame, (rx, ry), (rx+rw, ry+rh), (0, 255, 0), 1)
    label = f"HFD: {hfd_val:.2f}"
    
    thickness = 2
    (tw, th), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, font_s, thickness)
    
    cv2.rectangle(frame, (rx, ry-th-6), (rx+tw+6, ry), (0, 0, 0), -1)
    cv2.putText(frame, label, (rx+3, ry-5), cv2.FONT_HERSHEY_SIMPLEX, font_s, (0, 255, 0), thickness)

    # 2. Star Profile Graph (Bottom Left of ROI)
    iy = int(cy_local)
    if iy >= 0 and iy < roi_img.shape[0]:
        row_data = roi_img[iy, :]
        g_w = rw
        g_x, g_y = rx, ry + rh + 5
        
        cv2.rectangle(frame, (g_x, g_y), (g_x+g_w, g_y+g_h), (0,0,0), -1)
        
        # Plot
        pts = []
        # Normalizing to max value in the row to fill the graph height
        row_max = np.max(row_data)
        scale_max = row_max if row_max > 0 else 255
        
        for x, val in enumerate(row_data):
            px = int(g_x + (x/len(row_data))*g_w)
            py = int((g_y + g_h) - (val/scale_max)*g_h)
            pts.append((px, py))
            
        if len(pts) > 1:
            cv2.polylines(frame, [np.array(pts)], False, (0, 255, 255), 1)
        
        cv2.putText(frame, "Profile", (g_x+2, g_y+10), cv2.FONT_HERSHEY_PLAIN, 0.8, (150,150,150), 1)

# ================= VIDEO LOOP =================

def generate_frames():
    global camera
    
    # Init Camera
    if not camera:
        try:
            asi.init(LIB_FILE)
            if asi.get_num_cameras() > 0:
                camera = asi.Camera(0)
                camera.set_control_value(asi.ASI_HIGH_SPEED_MODE, 1)
                camera.start_video_capture()
        except: pass

    if not camera:
        yield b'Error: No Camera'
        return

    applied_gain = -1
    applied_exp = -1

    while True:
        with state_lock:
            # Create a local copy of state to avoid locking during processing
            current_state = cam_state.copy()
            
        gain = current_state['gain']
        exp_val = current_state['exposure_val']
        exp_mode = current_state['exposure_mode']
        roi_def = current_state['roi_norm']
        
        # Apply Controls
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

        # Capture
        try:
            to_ms = int(target_us / 1000) + 500
            frame = camera.capture_video_frame(timeout=to_ms)
        except: continue
        
        # Convert Color
        if len(frame.shape) == 2:
            color_frame = cv2.cvtColor(frame, cv2.COLOR_GRAY2RGB)
        else:
            color_frame = cv2.cvtColor(frame, cv2.COLOR_BAYER_RG2RGB)

        # HFD Processing
        if roi_def:
            h, w, _ = color_frame.shape
            rx = int(roi_def['x'] * w)
            ry = int(roi_def['y'] * h)
            rw = int(roi_def['w'] * w)
            rh = int(roi_def['h'] * h)
            
            if rw > 10 and rh > 10 and rx+rw < w and ry+rh < h:
                roi_gray = frame[ry:ry+rh, rx:rx+rw] if len(frame.shape)==2 else cv2.cvtColor(color_frame[ry:ry+rh, rx:rx+rw], cv2.COLOR_RGB2GRAY)
                
                hfd, cent = calculate_hfd(roi_gray)
                hfd_history.append(hfd)
                
                # Pass full state (containing font_scale and graph_height)
                draw_overlays(color_frame, roi_gray, hfd, cent, (rx, ry, rw, rh), current_state)

        ret, buffer = cv2.imencode('.jpg', color_frame)
        yield (b'--frame\r\nContent-Type: image/jpeg\r\n\r\n' + buffer.tobytes() + b'\r\n')

# ================= ROUTES =================
@app.route('/')
def index(): return render_template_string(HTML_TEMPLATE)

@app.route('/video_feed')
def video_feed(): return Response(generate_frames(), mimetype='multipart/x-mixed-replace; boundary=frame')

@app.route('/get_status')
def get_status():
    # Return graph data for the UI
    return jsonify({
        'history': list(hfd_history)
    })

@app.route('/update_settings', methods=['POST'])
def update_settings():
    d = request.json
    with state_lock:
        if 'gain' in d: cam_state['gain'] = int(d['gain'])
        if 'exposure_val' in d: cam_state['exposure_val'] = int(d['exposure_val'])
        if 'exposure_mode' in d: cam_state['exposure_mode'] = str(d['exposure_mode'])
        if 'font_scale' in d: cam_state['font_scale'] = float(d['font_scale'])
        if 'graph_height' in d: cam_state['graph_height'] = int(d['graph_height'])
    return jsonify({"status":"ok"})

@app.route('/update_roi', methods=['POST'])
def update_roi():
    d = request.json
    with state_lock:
        if 'clear' in d: cam_state['roi_norm'] = None
        else: cam_state['roi_norm'] = {
            'x': float(d['x']), 'y': float(d['y']),
            'w': float(d['w']), 'h': float(d['h'])
        }
    return jsonify({"status":"ok"})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, threaded=True)
EOF

chmod +x zwo.py
python zwo.py