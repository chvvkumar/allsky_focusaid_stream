#!/bin/bash

# ==============================================================================
# ZWO ASI Camera Streamer - Automated Setup & Launcher
# ==============================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting ZWO Camera Streamer Setup...${NC}"

# --- 1. System Dependencies Check ---
echo -e "\n${YELLOW}[Step 1] Checking system dependencies...${NC}"
# We need these for the camera to communicate via USB properly on Linux
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
CREATE_VENV=false

# Check if we are already inside a venv
if [[ "$VIRTUAL_ENV" != "" ]]; then
    echo -e "You are already inside a virtual environment: $VIRTUAL_ENV"
    read -p "Do you want to use this existing environment? (y/n): " use_existing
    if [[ "$use_existing" != "y" ]]; then
        echo -e "${RED}Please deactivate your current venv and run this script again.${NC}"
        exit 1
    fi
else
    # We are not in a venv, check if directory exists
    if [ -d "$VENV_DIR" ]; then
        echo "Found existing '$VENV_DIR' directory."
        read -p "Do you want to use it? (y/n): " use_dir
        if [[ "$use_dir" == "y" ]]; then
            source "$VENV_DIR/bin/activate"
        else
            echo "Please remove the existing '$VENV_DIR' folder or choose a different location."
            exit 1
        fi
    else
        read -p "Create a new virtual environment ('venv')? (y/n): " create_new
        if [[ "$create_new" == "y" ]]; then
            python3 -m venv "$VENV_DIR"
            source "$VENV_DIR/bin/activate"
            echo "Virtual environment created and activated."
        else
            echo -e "${RED}Warning: Running without a virtual environment on Pi 5 (Bookworm) may fail due to PEP 668.${NC}"
            read -p "Continue anyway? (y/n): " cont_anyway
            if [[ "$cont_anyway" != "y" ]]; then exit 1; fi
        fi
    fi
fi

# --- 3. Install Python Dependencies ---
echo -e "\n${YELLOW}[Step 3] Installing Python libraries...${NC}"
# Upgrade pip first to avoid wheel build issues
pip install --upgrade pip
pip install zwoasi flask opencv-python-headless

# --- 4. Check for ZWO SDK Library (.so file) ---
echo -e "\n${YELLOW}[Step 4] Checking for ZWO SDK Library...${NC}"
LIB_FILE="libASICamera2.so"

if [ ! -f "$LIB_FILE" ]; then
    echo -e "${RED}MISSING: $LIB_FILE${NC}"
    echo "----------------------------------------------------------------"
    echo "The Python script requires the ZWO C library to talk to the hardware."
    echo "I cannot download this automatically reliably as the URL changes."
    echo ""
    echo "ACTION REQUIRED:"
    echo "1. Go to: https://astronomy-imaging-camera.com/software-drivers"
    echo "2. Download the 'ASI SDK for Linux'."
    echo "3. Extract it and find 'libASICamera2.so' inside the 'lib/armv8' folder."
    echo "4. Copy that file into this folder: $(pwd)"
    echo "----------------------------------------------------------------"
    read -p "Have you placed the .so file in this folder now? (y/n): " file_ready
    if [[ "$file_ready" != "y" ]]; then
        echo "Exiting. Please get the file and run this script again."
        exit 1
    fi
else
    echo -e "${GREEN}Found $LIB_FILE.${NC}"
fi

# --- 5. Generate Python Script ---
echo -e "\n${YELLOW}[Step 5] Generating 'zwo.py'...${NC}"

cat << 'EOF' > zwo.py
#!/usr/bin/env python3
import sys
import os

# --- Safety Check for Dependencies ---
try:
    import cv2
    import zwoasi as asi
    import time
    from flask import Flask, Response
except ImportError as e:
    print("\nCRITICAL ERROR: Missing Python Libraries")
    print(f"Details: {e}")
    sys.exit(1)
# -------------------------------------

# ================= CONFIGURATION =================
LIB_FILE = './libASICamera2.so' 

# Camera Settings (Adjust these for your lighting)
GAIN = 300
EXPOSURE_US = 20000  # 20ms
# =================================================

app = Flask(__name__)

def get_camera():
    """Initializes the ZWO camera."""
    # Ensure absolute path to lib to avoid confusion
    lib_path = os.path.abspath(LIB_FILE)
    
    try:
        # Initialize the ZWO library
        asi.init(lib_path)
    except Exception as e:
        print(f"Error initializing library: {e}")
        print(f"Checked path: {lib_path}")
        return None

    num_cameras = asi.get_num_cameras()
    if num_cameras == 0:
        print("No cameras found")
        return None

    try:
        # Open the first camera found
        camera = asi.Camera(0)
        camera_info = camera.get_camera_property()
        print(f"Connected to: {camera_info['Name']}")

        # Apply settings
        camera.set_control_value(asi.ASI_GAIN, GAIN)
        camera.set_control_value(asi.ASI_EXPOSURE, EXPOSURE_US)
        camera.set_control_value(asi.ASI_BANDWIDTHOVERLOAD, 40) 
        
        try:
            camera.set_control_value(asi.ASI_HIGH_SPEED_MODE, 1)
        except:
            pass

        camera.start_video_capture()
        return camera, camera_info
        
    except Exception as e:
        print(f"Error connecting to camera: {e}")
        return None

def generate_frames(camera, cam_info):
    """Generator function that yields MJPEG frames."""
    try:
        while True:
            frame = camera.capture_video_frame()
            
            if cam_info['IsColorCam']:
                image = cv2.cvtColor(frame, cv2.COLOR_BAYER_RG2RGB)
            else:
                image = frame

            ret, buffer = cv2.imencode('.jpg', image)
            if not ret:
                continue
            
            frame_bytes = buffer.tobytes()
            yield (b'--frame\r\n'
                   b'Content-Type: image/jpeg\r\n\r\n' + frame_bytes + b'\r\n')
                   
    except Exception as e:
        print(f"Stream error: {e}")
    finally:
        try:
            camera.stop_video_capture()
            camera.close()
        except:
            pass

@app.route('/')
def index():
    return Response(stream_loader(), mimetype='multipart/x-mixed-replace; boundary=frame')

def stream_loader():
    cam_data = get_camera()
    if cam_data:
        camera, cam_info = cam_data
        return generate_frames(camera, cam_info)
    else:
        return b"Error: Camera not found. Check terminal."

if __name__ == '__main__':
    print("\n------------------------------------------------")
    print(" STREAM STARTED")
    print("------------------------------------------------")
    print(" Access the stream at: http://<YOUR_PI_IP>:5000")
    print(" Press Ctrl+C to stop.")
    print("------------------------------------------------\n")
    try:
        app.run(host='0.0.0.0', port=5000, threaded=True)
    except KeyboardInterrupt:
        print("Stopping...")
EOF

chmod +x zwo.py
echo "Script 'zwo.py' created successfully."

# --- 6. Launch ---
echo -e "\n${GREEN}[Step 6] Launching Camera Stream...${NC}"
python zwo.py
