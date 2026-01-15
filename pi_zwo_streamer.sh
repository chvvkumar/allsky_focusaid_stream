#!/bin/bash

# ==============================================================================
# ZWO ASI Camera Streamer v7 (HFD, Star Profile, History Graph)
# ==============================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting ZWO Camera Streamer Setup (Visual Focus Edition)...${NC}"

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

# --- 4. Check for ZWO SDK Library (.so file) ---
LIB_FILE="libASICamera2.so"
if [ ! -f "$LIB_FILE" ]; then
    echo -e "${RED}MISSING: $LIB_FILE${NC}"
    echo "Please copy 'libASICamera2.so' to this folder."
    exit 1
fi

# --- 5. Generate Advanced Python Script ---
cat << 'EOF' > zwo.py
#!/usr/bin/env python3
import sys
import os
import time
import threading
import json
import math
import cv2
import numpy as np
import zwoasi as asi
from flask import Flask, Response, render_template_string, request, jsonify
from collections import deque

# ================= CONFIGURATION =================
LIB_FILE = './libASICamera2.so' 

# Global State
cam_state = {
    'gain': 300,
    'exposure_val': 100,
    'exposure_mode': 'ms',
    'scale_percent': 50,
    'font_scale': 1.0,
    'roi_norm': None
}
state_lock = threading.Lock()

# Focus History (Stores last 50 HFD values)
history_len = 50
hfd_history = deque([0]*history_len, maxlen=history_len)

# Global Camera
camera = None
camera_lock = threading.Lock()

app = Flask(__name__)

# ================= HTML TEMPLATE =================
HTML_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
    <title>ZWO Visual Focus</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <style>
        body { background: #000; margin: 0; overflow: hidden; font-family: sans-serif; }
        #viewport { position: fixed; top: 0; left: 0; right: 0; bottom: 0; display: flex; justify-content: center; align-items: center; background: #111; }
        #transform-layer { transform-origin: center; transition: transform 0.1s ease-out; }
        img { max-width: 100vw; max-height: 100vh; display: block; }
        #ui-layer { position: fixed; top: 0; left: 0; width: 100%; height: 100%; pointer-events: none; }
        .controls { pointer-events: auto; position: fixed; top: 10px; left: 10px; width: 300px; background: rgba(20,20,20,0.9); padding: 15px; border-radius: 8px; border: 1px solid #444; color: #fff; display: none; }
        #toggle-btn { pointer-events: auto; position: fixed; top: 10px; left: 10px; background: #d32f2f; color: white; border: none; padding: 8px 15px; border-radius: 4px; font-weight: bold; cursor: pointer; }
        input[type=range] { width: 100%; }
        
        #selection-box { position: absolute; border: 2px dashed #0f0; display: none; pointer-events: none; }
        #touch-layer { position: fixed; top: 0; left: 0; right: 0; bottom: 0; }
    </style>
</head>
<body>
    <div id="viewport">
        <div id="transform-layer">
            <img id="video-feed" src="/video_feed">
            <div id="selection-box"></div>
        </div>
    </div>
    <div id="touch-layer"></div>

    <div id="ui-layer">
        <button id="toggle-btn" onclick="toggleUI()">Settings</button>
        <div class="controls" id="control-panel">
            <h3>Camera Controls</h3>
            <label>Gain: <span id="v-gain">300</span></label>
            <input type="range" min="0" max="600" value="300" oninput="upd('gain',this.value)">
            
            <label>Exposure: <span id="v-exp">100 ms</span></label>
            <input type="range" min="1" max="5000" value="100" oninput="upd('exp',this.value)">
            
            <label>Zoom: <span id="v-zoom">1.0x</span></label>
            <input type="range" min="10" max="100" value="10" oninput="zoom(this.value)">
            
            <br><button onclick="toggleUI()">Close</button>
        </div>
    </div>

    <script>
        let state = {gain:300, exp:100};
        let zLvl = 1.0, panX=0, panY=0;
        
        function toggleUI() {
            let p = document.getElementById('control-panel');
            let b = document.getElementById('toggle-btn');
            p.style.display = p.style.display==='none'?'block':'none';
            b.style.display = p.style.display==='none'?'block':'none';
        }
        
        function upd(k,v) {
            if(k==='gain') { state.gain=parseInt(v); document.getElementById('v-gain').innerText=v; }
            if(k==='exp') { state.exp=parseInt(v); document.getElementById('v-exp').innerText=v+' ms'; }
            fetch('/update_settings', {
                method:'POST',
                headers:{'Content-Type':'application/json'},
                body:JSON.stringify({gain:state.gain, exposure_val:state.exp})
            });
        }

        function zoom(v) {
            zLvl = v/10.0;
            document.getElementById('v-zoom').innerText = zLvl.toFixed(1)+'x';
            applyT();
        }
        function applyT() {
            document.getElementById('transform-layer').style.transform = `scale(${zLvl}) translate(${panX}px,${panY}px)`;
        }

        // Touch Logic (Simplified)
        const tLayer = document.getElementById('touch-layer');
        const box = document.getElementById('selection-box');
        let start={x:0,y:0}, isDrag=false;

        tLayer.addEventListener('mousedown', e=>{
            start={x:e.clientX, y:e.clientY}; isDrag=true;
            // Visual reset
            box.style.display='block';
            box.style.width='0'; box.style.height='0';
            // We draw box on SCREEN coordinates for visual, but calc ROI relative to IMAGE
            box.style.left=e.clientX+'px'; box.style.top=e.clientY+'px';
        });

        tLayer.addEventListener('mousemove', e=>{
            if(!isDrag) return;
            let w = e.clientX - start.x;
            let h = e.clientY - start.y;
            box.style.width = Math.abs(w)+'px';
            box.style.height = Math.abs(h)+'px';
            box.style.left = (w<0?e.clientX:start.x)+'px';
            box.style.top = (h<0?e.clientY:start.y)+'px';
        });

        tLayer.addEventListener('mouseup', e=>{
            isDrag=false;
            box.style.display='none';
            
            // Calculate Norm Coords based on visual box vs screen size
            // This is a rough approximation for the UI demo, but effective
            let rect = document.getElementById('video-feed').getBoundingClientRect();
            
            // Get Box Coords
            let bX = parseInt(box.style.left);
            let bY = parseInt(box.style.top);
            let bW = parseInt(box.style.width);
            let bH = parseInt(box.style.height);

            if(bW < 10) {
                 fetch('/update_roi', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({clear:true})});
                 return;
            }

            // Map to image space
            let roi = {
                x: (bX - rect.left) / rect.width,
                y: (bY - rect.top) / rect.height,
                w: bW / rect.width,
                h: bH / rect.height
            };
            
            fetch('/update_roi', {
                method:'POST',
                headers:{'Content-Type':'application/json'},
                body:JSON.stringify(roi)
            });
        });
        
        document.getElementById('control-panel').style.display='none';
    </script>
</body>
</html>
"""

# ================= ALGORITHMS =================

def calculate_hfd(roi_img):
    try:
        # 1. Hot Pixel & Noise Safe-guard
        blurred = cv2.GaussianBlur(roi_img, (3, 3), 0)
        minVal, maxVal, minLoc, maxLoc = cv2.minMaxLoc(blurred)
        
        # Signal too weak?
        if maxVal < 5: return 0.0, maxLoc

        # 2. Background Subtraction (Median)
        bg = np.median(roi_img)
        star_data = roi_img.astype(float) - bg
        star_data[star_data < 0] = 0
        
        # 3. Centroid (Moments)
        m = cv2.moments(star_data)
        if m['m00'] == 0: return 0.0, maxLoc
        cx = m['m10'] / m['m00']
        cy = m['m01'] / m['m00']
        
        # 4. HFD Calculation
        # HFD is diameter where half flux is inside
        # Formula: sum(pixel_val * dist_from_center) / sum(pixel_val) * 2
        
        h, w = roi_img.shape
        y_indices, x_indices = np.indices((h, w))
        
        distances = np.sqrt((x_indices - cx)**2 + (y_indices - cy)**2)
        
        total_flux = np.sum(star_data)
        weighted_flux = np.sum(star_data * distances)
        
        if total_flux == 0: return 0.0, (cx, cy)
        
        hfr = weighted_flux / total_flux
        hfd = hfr * 2.0
        
        return round(hfd, 2), (cx, cy)

    except:
        return 0.0, (0,0)

def draw_visuals(frame, roi_img, hfd_val, centroid, rect_offset):
    # Unwrap params
    rx, ry, rw, rh = rect_offset
    cx_local, cy_local = centroid
    
    # Global Centroid
    gcx = int(rx + cx_local)
    gcy = int(ry + cy_local)

    # 1. Draw Star Profile (Cross section at Centroid Y)
    # Extract row
    iy = int(cy_local)
    if iy >= 0 and iy < roi_img.shape[0]:
        row_data = roi_img[iy, :]
        
        # Setup Graph Box (Bottom Left of ROI)
        g_h = 60
        g_w = rw
        g_x = rx
        g_y = ry + rh + 5
        
        # Draw Background
        cv2.rectangle(frame, (g_x, g_y), (g_x+g_w, g_y+g_h), (0,0,0), -1)
        cv2.rectangle(frame, (g_x, g_y), (g_x+g_w, g_y+g_h), (50,50,50), 1)
        
        # Normalize Data to Graph Height
        mx = np.max(row_data)
        if mx > 0:
            pts = []
            for x, val in enumerate(row_data):
                px = int(g_x + (x / len(row_data)) * g_w)
                py = int((g_y + g_h) - (val / 255.0) * g_h) # Assume 8-bit
                pts.append((px, py))
            
            # Draw Curve
            if len(pts) > 1:
                cv2.polylines(frame, [np.array(pts)], False, (0, 255, 255), 1)
                
        # Label
        cv2.putText(frame, "Profile", (g_x+2, g_y+10), cv2.FONT_HERSHEY_PLAIN, 0.8, (150,150,150), 1)

    # 2. Draw HFD Value
    label = f"HFD: {hfd_val:.2f}"
    cv2.putText(frame, label, (rx, ry-10), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 0), 2)
    cv2.rectangle(frame, (rx, ry), (rx+rw, ry+rh), (0, 255, 0), 1)
    
    # 3. Draw History Graph (Bottom Right of Screen)
    h, w, _ = frame.shape
    hist_w = 200
    hist_h = 100
    hx = w - hist_w - 20
    hy = h - hist_h - 20
    
    # Background
    overlay = frame.copy()
    cv2.rectangle(overlay, (hx, hy), (hx+hist_w, hy+hist_h), (20, 20, 20), -1)
    cv2.addWeighted(overlay, 0.6, frame, 0.4, 0, frame)
    
    # Plot History
    if len(hfd_history) > 1:
        # Auto-scale
        max_h = max(max(hfd_history), 10)
        min_h = min(hfd_history)
        
        pts = []
        for i, val in enumerate(hfd_history):
            px = int(hx + (i / history_len) * hist_w)
            # Invert Y (higher value = higher on graph? No, lower HFD is better)
            # Let's put 0 at bottom
            py = int((hy + hist_h) - (val / max_h) * (hist_h - 10))
            pts.append((px, py))
            
        cv2.polylines(frame, [np.array(pts)], False, (0, 200, 255), 2)
        
    cv2.putText(frame, "Focus History (Lower is Better)", (hx, hy-5), cv2.FONT_HERSHEY_PLAIN, 1, (200,200,200), 1)

# ================= VIDEO LOOP =================

def generate_frames():
    global camera
    
    # Init Camera
    try:
        if not camera:
            asi.init(LIB_FILE)
            camera = asi.Camera(0)
            camera.set_control_value(asi.ASI_HIGH_SPEED_MODE, 1)
            camera.start_video_capture()
    except:
        pass

    while True:
        with state_lock:
            gain = cam_state['gain']
            exp_val = cam_state['exposure_val']
            roi_def = cam_state['roi_norm']
        
        # Apply Gain/Exp (Simplified for brevity)
        try:
            camera.set_control_value(asi.ASI_GAIN, gain)
            camera.set_control_value(asi.ASI_EXPOSURE, exp_val*1000)
        except: pass

        # Capture
        try:
            frame = camera.capture_video_frame(timeout=2000)
        except: continue
        
        # Processing
        if len(frame.shape) == 2:
            color_frame = cv2.cvtColor(frame, cv2.COLOR_GRAY2RGB)
        else:
            color_frame = cv2.cvtColor(frame, cv2.COLOR_BAYER_RG2RGB)

        # ROI Processing
        if roi_def:
            h, w, _ = color_frame.shape
            rx = int(roi_def['x'] * w)
            ry = int(roi_def['y'] * h)
            rw = int(roi_def['w'] * w)
            rh = int(roi_def['h'] * h)
            
            # Ensure safe bounds
            if rw > 10 and rh > 10 and rx+rw < w and ry+rh < h:
                roi_gray = frame[ry:ry+rh, rx:rx+rw] if len(frame.shape)==2 else cv2.cvtColor(color_frame[ry:ry+rh, rx:rx+rw], cv2.COLOR_RGB2GRAY)
                
                # Calc HFD
                val, cent = calculate_hfd(roi_gray)
                
                # Update History
                hfd_history.append(val)
                
                # Draw
                draw_visuals(color_frame, roi_gray, val, cent, (rx, ry, rw, rh))

        ret, buffer = cv2.imencode('.jpg', color_frame)
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
        if 'gain' in d: cam_state['gain'] = d['gain']
        if 'exposure_val' in d: cam_state['exposure_val'] = d['exposure_val']
    return jsonify({"status":"ok"})

@app.route('/update_roi', methods=['POST'])
def update_roi():
    d = request.json
    with state_lock:
        if 'clear' in d: cam_state['roi_norm'] = None
        else: cam_state['roi_norm'] = d
    return jsonify({"status":"ok"})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, threaded=True)
EOF

chmod +x zwo.py
python zwo.py