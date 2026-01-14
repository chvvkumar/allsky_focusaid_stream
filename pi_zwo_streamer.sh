#!/bin/bash

# ==============================================================================
# ZWO ASI Camera Streamer v5 (Touch ROI + FWHM Metrics)
# ==============================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting ZWO Camera Streamer Setup (Focus Aid Edition)...${NC}"

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
# numpy is usually pulled in by opencv-python-headless, but we ensure it here
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
echo -e "\n${YELLOW}[Step 5] Generating 'zwo.py' with Touch ROI & FWHM...${NC}"

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
    'roi_norm': None  # format: {'x':0.1, 'y':0.1, 'w':0.2, 'h':0.2} (Normalized 0.0-1.0)
}
state_lock = threading.Lock()

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
            touch-action: none; /* Disable browser zooming/scrolling */
        }
        
        /* Container ensuring proper layering */
        #viewport {
            position: fixed;
            top: 0; left: 0; right: 0; bottom: 0;
            display: flex;
            align-items: center;
            justify-content: center;
            background: #000;
        }

        /* The Camera Feed */
        #video-feed { 
            max-width: 100%; 
            max-height: 100%; 
            object-fit: contain; /* Crucial: maintains aspect ratio */
            user-select: none;
            -webkit-user-select: none;
        }
        
        /* The Selection Overlay Canvas */
        #interaction-layer {
            position: absolute;
            top: 0; left: 0; right: 0; bottom: 0;
            z-index: 10;
            cursor: crosshair;
        }

        /* Selection Box (Visual only during drag) */
        #selection-box {
            position: fixed;
            border: 2px dashed rgba(255, 0, 0, 0.8);
            background: rgba(255, 0, 0, 0.1);
            display: none;
            pointer-events: none; /* Let clicks pass through */
            z-index: 20;
        }

        /* UI Controls Layer */
        #ui-layer {
            position: fixed;
            top: 10px; left: 10px;
            z-index: 100;
            width: 300px;
            max-width: 90vw;
            pointer-events: none; /* Let touches pass through to canvas */
        }

        .controls { 
            pointer-events: auto; /* Re-enable clicks for buttons */
            background: rgba(20, 20, 20, 0.85);
            backdrop-filter: blur(8px);
            padding: 15px; 
            border-radius: 12px; 
            color: #eee;
            border: 1px solid rgba(255,255,255,0.1);
            display: none; /* Hidden by default */
        }

        #toggle-btn {
            pointer-events: auto;
            background: rgba(211, 47, 47, 0.9);
            color: white; border: none; padding: 10px 15px;
            border-radius: 20px; font-weight: bold; cursor: pointer;
        }

        /* Form Elements */
        .control-group { margin-bottom: 12px; }
        label { display: flex; justify-content: space-between; font-size: 13px; color: #ccc; margin-bottom: 5px; }
        .val-display { color: #d32f2f; font-weight: bold; font-family: monospace; }
        input[type=range] { width: 100%; height: 6px; background: #444; border-radius: 3px; -webkit-appearance: none; }
        input[type=range]::-webkit-slider-thumb { -webkit-appearance: none; width: 18px; height: 18px; background: #d32f2f; border-radius: 50%; }

    </style>
</head>
<body>

    <div id="viewport">
        <img id="video-feed" src="/video_feed" draggable="false">
        <div id="interaction-layer"></div>
    </div>
    
    <div id="selection-box"></div>

    <div id="ui-layer">
        <button id="toggle-btn" onclick="toggleUI()">Settings</button>
        <div class="controls" id="control-panel">
            <div style="display:flex; justify-content:space-between; margin-bottom:10px;">
                <strong>CAMERA SETTINGS</strong>
                <button onclick="toggleUI()" style="background:none; border:none; color:#fff; font-size:18px;">&times;</button>
            </div>
            
            <div class="control-group">
                <label>Gain <span id="val-gain" class="val-display">300</span></label>
                <input type="range" id="rng-gain" min="0" max="600" value="300" 
                       oninput="updateVal('gain', this.value)" onchange="sendSettings()">
            </div>

            <div class="control-group">
                <label>Exposure <span id="val-exp" class="val-display">100 ms</span></label>
                <input type="range" id="rng-exp" min="1" max="5000" value="100" 
                       oninput="updateVal('exp', this.value)" onchange="sendSettings()">
            </div>
            
            <div style="font-size: 11px; color: #888; margin-top: 10px;">
                Double-tap video to clear selection.
            </div>
        </div>
    </div>

    <script>
        const videoImg = document.getElementById('video-feed');
        const touchLayer = document.getElementById('interaction-layer');
        const selBox = document.getElementById('selection-box');
        
        let startX, startY;
        let isDragging = false;
        
        // Touch & Mouse Handlers
        touchLayer.addEventListener('touchstart', handleStart, {passive: false});
        touchLayer.addEventListener('mousedown', handleStart);
        
        touchLayer.addEventListener('touchmove', handleMove, {passive: false});
        touchLayer.addEventListener('mousemove', handleMove);
        
        touchLayer.addEventListener('touchend', handleEnd);
        touchLayer.addEventListener('mouseup', handleEnd);
        
        // Double tap/click to clear
        touchLayer.addEventListener('dblclick', clearSelection);
        let lastTap = 0;
        touchLayer.addEventListener('touchend', function(e) {
            let currentTime = new Date().getTime();
            let tapLength = currentTime - lastTap;
            if (tapLength < 500 && tapLength > 0) {
                clearSelection();
                e.preventDefault();
            }
            lastTap = currentTime;
        });

        function handleStart(e) {
            e.preventDefault(); // Prevent scrolling
            const pt = getPoint(e);
            startX = pt.x;
            startY = pt.y;
            isDragging = true;
            
            selBox.style.left = startX + 'px';
            selBox.style.top = startY + 'px';
            selBox.style.width = '0px';
            selBox.style.height = '0px';
            selBox.style.display = 'block';
        }

        function handleMove(e) {
            if(!isDragging) return;
            e.preventDefault();
            const pt = getPoint(e);
            
            const currentX = pt.x;
            const currentY = pt.y;
            
            const width = Math.abs(currentX - startX);
            const height = Math.abs(currentY - startY);
            const left = Math.min(currentX, startX);
            const top = Math.min(currentY, startY);

            selBox.style.width = width + 'px';
            selBox.style.height = height + 'px';
            selBox.style.left = left + 'px';
            selBox.style.top = top + 'px';
        }

        function handleEnd(e) {
            if(!isDragging) return;
            isDragging = false;
            
            // Calculate final geometry
            const rect = selBox.getBoundingClientRect();
            selBox.style.display = 'none'; // Hide visual box, let backend draw it

            // Minimum size filter (avoid accidental tiny clicks)
            if(rect.width < 10 || rect.height < 10) return;

            // Normalize coordinates relative to the actual displayed image
            sendROI(rect.left, rect.top, rect.width, rect.height);
        }

        function getPoint(e) {
            if(e.touches) return {x: e.touches[0].clientX, y: e.touches[0].clientY};
            return {x: e.clientX, y: e.clientY};
        }

        function sendROI(screenX, screenY, screenW, screenH) {
            // Get the geometry of the image element itself
            const imgRect = videoImg.getBoundingClientRect();
            
            // Note: object-fit: contain creates "black bars" inside the img element.
            // We need to calculate the *actual* rendered image dimensions.
            
            const natW = videoImg.naturalWidth || 1920;
            const natH = videoImg.naturalHeight || 1080;
            const dispW = imgRect.width;
            const dispH = imgRect.height;
            
            const natRatio = natW / natH;
            const dispRatio = dispW / dispH;
            
            let renderW, renderH, offsetX, offsetY;
            
            if (dispRatio > natRatio) {
                // Image is pillarboxed (black bars on sides)
                renderH = dispH;
                renderW = dispH * natRatio;
                offsetX = (dispW - renderW) / 2;
                offsetY = 0;
            } else {
                // Image is letterboxed (black bars top/bottom)
                renderW = dispW;
                renderH = dispW / natRatio;
                offsetX = 0;
                offsetY = (dispH - renderH) / 2;
            }
            
            // Calculate Normalized Coordinates (0.0 to 1.0) relative to the ACTIVE image area
            // 1. Shift screen coord to be relative to the image element
            let relX = screenX - imgRect.left;
            let relY = screenY - imgRect.top;
            
            // 2. Subtract the black bar offsets
            relX -= offsetX;
            relY -= offsetY;
            
            // 3. Normalize
            const normX = relX / renderW;
            const normY = relY / renderH;
            const normW = screenW / renderW;
            const normH = screenH / renderH;
            
            // 4. Clamp (in case drag went outside image)
            const roi = {
                x: Math.max(0, Math.min(1, normX)),
                y: Math.max(0, Math.min(1, normY)),
                w: Math.min(1 - normX, normW),
                h: Math.min(1 - normY, normH)
            };

            fetch('/update_roi', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify(roi)
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
        
        // Settings Logic
        let settings = {gain: 300, exp: 100};
        function toggleUI() {
            const p = document.getElementById('control-panel');
            const b = document.getElementById('toggle-btn');
            const show = p.style.display === 'none';
            p.style.display = show ? 'block' : 'none';
            b.style.display = show ? 'none' : 'block';
        }
        function updateVal(k, v) {
            document.getElementById('val-'+k).innerText = v;
            settings[k] = parseInt(v);
        }
        function sendSettings() {
            fetch('/update_settings', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({gain: settings.gain, exposure_val: settings.exp})
            });
        }
        document.getElementById('control-panel').style.display = 'none';
    </script>
</body>
</html>
"""

# ================= IMAGE PROCESSING =================

def calculate_fwhm(roi_img):
    """
    Calculates FWHM of the brightest star in the ROI.
    Uses Standard Deviation of pixel distribution.
    FWHM = 2.355 * sigma
    """
    try:
        # 1. Basic Stats
        minVal, maxVal, minLoc, maxLoc = cv2.minMaxLoc(roi_img)
        
        # Noise floor heuristic: max - (max-min)*0.5
        threshold_val = maxVal - (maxVal - minVal) * 0.5
        if threshold_val < 0: threshold_val = 0
        
        # 2. Extract a small window around the peak to isolate the star
        # If we use the whole ROI, noise affects the sigma calculation too much
        h, w = roi_img.shape
        cx, cy = maxLoc
        win_radius = 15 # 30x30px window around peak
        
        x1 = max(0, cx - win_radius)
        x2 = min(w, cx + win_radius)
        y1 = max(0, cy - win_radius)
        y2 = min(h, cy + win_radius)
        
        star_cutout = roi_img[y1:y2, x1:x2]
        
        # 3. Calculate Moments to find sigma (width)
        # Subtract background to reduce noise influence
        star_float = star_cutout.astype(float)
        star_float -= np.mean(star_float) # Remove DC offset
        star_float[star_float < 0] = 0
        
        m = cv2.moments(star_float)
        if m['m00'] == 0: return 0.0
        
        # Centroids
        ctx = m['m10'] / m['m00']
        cty = m['m01'] / m['m00']
        
        # Central Moments (Variance)
        mu20 = m['mu20'] / m['m00'] # variance x
        mu02 = m['mu02'] / m['m00'] # variance y
        
        # Sigma = sqrt(variance)
        sigma_x = math.sqrt(abs(mu20))
        sigma_y = math.sqrt(abs(mu02))
        
        # Average sigma
        sigma = (sigma_x + sigma_y) / 2.0
        
        # FWHM conversion
        fwhm = 2.355 * sigma
        return round(fwhm, 2)
        
    except Exception as e:
        # print(e)
        return 0.0

def generate_frames():
    # --- Camera Init ---
    lib_path = os.path.abspath(LIB_FILE)
    try:
        asi.init(lib_path)
    except:
        pass
        
    if asi.get_num_cameras() == 0:
        yield b"Error: No Camera Found"
        return

    camera = asi.Camera(0)
    camera.set_control_value(asi.ASI_BANDWIDTHOVERLOAD, 40)
    camera.set_control_value(asi.ASI_HIGH_SPEED_MODE, 1)
    camera.start_video_capture()

    applied_gain = -1
    applied_exp = -1

    while True:
        # 1. Thread-safe settings read
        with state_lock:
            gain = cam_state['gain']
            exp_ms = cam_state['exposure_val']
            roi_def = cam_state['roi_norm'] # Copy ROI definition
        
        # 2. Apply Camera Controls
        try:
            if gain != applied_gain:
                camera.set_control_value(asi.ASI_GAIN, gain)
                applied_gain = gain
            
            exp_us = exp_ms * 1000
            if exp_us != applied_exp:
                camera.set_control_value(asi.ASI_EXPOSURE, exp_us)
                applied_exp = exp_us
        except:
            pass

        # 3. Capture
        try:
            frame = camera.capture_video_frame(timeout=exp_ms + 500)
        except:
            time.sleep(0.01)
            continue

        # 4. Processing
        # Convert Bayer to Grayscale for FWHM (more accurate intensity)
        # Convert to RGB for display
        gray_frame = frame # If Mono
        color_frame = frame
        
        cam_props = camera.get_camera_property()
        if cam_props['IsColorCam']:
            color_frame = cv2.cvtColor(frame, cv2.COLOR_BAYER_RG2RGB)
            gray_frame = cv2.cvtColor(color_frame, cv2.COLOR_RGB2GRAY)
        else:
            color_frame = cv2.cvtColor(frame, cv2.COLOR_GRAY2RGB)
            gray_frame = frame

        # 5. ROI & FWHM Logic
        if roi_def:
            h, w = gray_frame.shape
            
            # Convert Normalized (0-1) to Pixels
            rx = int(roi_def['x'] * w)
            ry = int(roi_def['y'] * h)
            rw = int(roi_def['w'] * w)
            rh = int(roi_def['h'] * h)
            
            # Safety checks
            if rw > 5 and rh > 5 and rx >= 0 and ry >= 0 and (rx+rw) <= w and (ry+rh) <= h:
                # Crop for calculation
                roi_gray = gray_frame[ry:ry+rh, rx:rx+rw]
                
                # Calculate FWHM
                fwhm_val = calculate_fwhm(roi_gray)
                
                # Draw on Output Frame (Green Box)
                cv2.rectangle(color_frame, (rx, ry), (rx+rw, ry+rh), (0, 255, 0), 2)
                
                # Draw Text Background
                label = f"FWHM: {fwhm_val} px"
                cv2.rectangle(color_frame, (rx, ry-25), (rx+160, ry), (0, 255, 0), -1)
                cv2.putText(color_frame, label, (rx+5, ry-7), 
                           cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 0), 2)
        
        # 6. Encode
        # Resize for streaming bandwidth if needed (optional, keeping full res for now)
        # h, w = color_frame.shape[:2]
        # if w > 1280:
        #    color_frame = cv2.resize(color_frame, (1280, 720))

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
    return jsonify({"status": "ok"})

@app.route('/update_roi', methods=['POST'])
def update_roi():
    data = request.json
    with state_lock:
        if 'clear' in data and data['clear']:
            cam_state['roi_norm'] = None
            print("ROI Cleared")
        else:
            cam_state['roi_norm'] = {
                'x': float(data['x']),
                'y': float(data['y']),
                'w': float(data['w']),
                'h': float(data['h'])
            }
            print(f"ROI Updated: {cam_state['roi_norm']}")
    return jsonify({"status": "ok"})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, threaded=True)
EOF

chmod +x zwo.py
echo "Advanced script 'zwo.py' created."

# --- 6. Launch ---
echo -e "\n${GREEN}[Step 6] Launching Camera Stream...${NC}"
python zwo.py