#!/bin/bash

# Configuration variables
mt5file='/config/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe'
WINEPREFIX='/config/.wine'
WINEDEBUG='-all'
wine_executable="wine"
metatrader_version="5.0.36"
mt5server_port="8001"
MT5_CMD_OPTIONS="${MT5_CMD_OPTIONS:-}"
mono_url="https://dl.winehq.org/wine/wine-mono/10.3.0/wine-mono-10.3.0-x86.msi"

# Embeddable x64 Python 3.9.13 (the .exe installer fails silently under Wine)
python_embed_url="https://www.python.org/ftp/python/3.9.13/python-3.9.13-embed-amd64.zip"
get_pip_url="https://bootstrap.pypa.io/pip/3.9/get-pip.py"
# Wine path to the Python interpreter + its Linux-side location
python_path='C:\Python39\python.exe'
python_dir="/config/.wine/drive_c/Python39"
mt5setup_url="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"

# Function to display a graphical message
show_message() {
    echo $1
}

# Function to check if a dependency is installed
check_dependency() {
    if ! command -v $1 &> /dev/null; then
        echo "$1 is not installed. Please install it to continue."
        exit 1
    fi
}

# Function to check if a Python package is installed
is_python_package_installed() {
    python3 -c "import pkg_resources; exit(not pkg_resources.require('$1'))" 2>/dev/null
    return $?
}

# Function to check if a Python package is installed in Wine
is_wine_python_package_installed() {
    $wine_executable "$python_path" -c "import pkg_resources; exit(not pkg_resources.require('$1'))" 2>/dev/null
    return $?
}

# Check for necessary dependencies
check_dependency "curl"
check_dependency "$wine_executable"

# Fresh prefix: initialize it so drive_c exists before anything tries to write there
if [ ! -d "/config/.wine/drive_c" ]; then
    show_message "[0/7] Initializing Wine prefix (wineboot)..."
    $wine_executable wineboot -i
    $wine_executable wineserver -w
fi

# Install Mono if not present
if [ ! -e "/config/.wine/drive_c/windows/mono" ]; then
    show_message "[1/7] Downloading and installing Mono..."
    # Download to /tmp (Linux side) and install via the Z: drive so a fresh
    # prefix without drive_c cannot cause curl: (23)
    curl -L -o /tmp/mono.msi $mono_url
    WINEDLLOVERRIDES=mscoree=d $wine_executable msiexec /i 'Z:\tmp\mono.msi' /qn
    rm -f /tmp/mono.msi
    show_message "[1/7] Mono installed."
else
    show_message "[1/7] Mono is already installed."
fi

# MT5 anti-debug check needs Windows 11 mode + wine-staging (WineHQ bug 58043)
$wine_executable reg add "HKEY_CURRENT_USER\\Software\\Wine" /v Version /t REG_SZ /d "win11" /f

# Check if MetaTrader 5 is already installed
if [ -e "$mt5file" ]; then
    show_message "[2/7] File $mt5file already exists."
else
    show_message "[2/7] File $mt5file is not installed. Installing..."

    show_message "[3/7] Downloading MT5 installer..."
    curl -o /config/.wine/drive_c/mt5setup.exe $mt5setup_url
    show_message "[3/7] Installing MetaTrader 5..."
    $wine_executable "/config/.wine/drive_c/mt5setup.exe" "/auto" &
    wait
    rm -f /config/.wine/drive_c/mt5setup.exe
fi

# Recheck if MetaTrader 5 is installed
if [ -e "$mt5file" ]; then
    show_message "[4/7] File $mt5file is installed. Running MT5..."
    $wine_executable "$mt5file" $MT5_CMD_OPTIONS &
else
    show_message "[4/7] File $mt5file is not installed. MT5 cannot be run."
fi


# Remove old 32-bit Python (no pip, wrong arch for terminal64)
rm -rf "/config/.wine/drive_c/Program Files (x86)/Python39-32"

# Install 64-bit embeddable Python in Wine if missing, not 64-bit, or pip is broken
if ! $wine_executable "$python_path" -c "import struct,pip,sys; sys.exit(struct.calcsize('P')!=8)" 2>/dev/null; then
    show_message "[5/7] Installing embeddable Python in Wine..."
    rm -rf "$python_dir"
    mkdir -p "$python_dir"
    curl -L $python_embed_url -o /tmp/python-embed.zip
    # Extract with Linux python3 (unzip is not guaranteed to be in the image)
    python3 -m zipfile -e /tmp/python-embed.zip "$python_dir"
    rm -f /tmp/python-embed.zip
    # Enable site-packages so pip-installed modules are importable
    pth_file=$(ls "$python_dir"/python*._pth 2>/dev/null | head -n1)
    if [ -n "$pth_file" ]; then
        sed -i 's/^#import site/import site/' "$pth_file"
        grep -q '^import site' "$pth_file" || echo 'import site' >> "$pth_file"
    fi
    # Bootstrap pip
    curl -L $get_pip_url -o /tmp/get-pip.py
    $wine_executable "$python_path" 'Z:\tmp\get-pip.py' --no-warn-script-location
    rm -f /tmp/get-pip.py
    show_message "[5/7] Embeddable Python installed in Wine."
else
    show_message "[5/7] Python is already installed in Wine."
fi

# Upgrade pip and install required packages
show_message "[6/7] Installing Python libraries"
$wine_executable "$python_path" -m pip install --upgrade --no-cache-dir pip

# Install MetaTrader5 library in Windows if not installed (needs numpy<2)
show_message "[6/7] Installing MetaTrader5 library in Windows"
if ! is_wine_python_package_installed "MetaTrader5==$metatrader_version"; then
    $wine_executable "$python_path" -m pip install --no-cache-dir MetaTrader5==$metatrader_version "numpy<2"
fi
$wine_executable "$python_path" -m pip install --no-cache-dir "numpy<2"

# Install mt5linux library in Windows if not installed
show_message "[6/7] Checking and installing mt5linux library in Windows if necessary"
if ! is_wine_python_package_installed "mt5linux"; then
    $wine_executable "$python_path" -m pip install --no-cache-dir "mt5linux==1.0.11"
fi

# Install python-dateutil if needed
if ! is_wine_python_package_installed "python-dateutil"; then
    show_message "[6/7] Installing python-dateutil library in Windows"
    $wine_executable "$python_path" -m pip install --no-cache-dir python-dateutil
fi

# Install mt5linux library in Linux if not installed
show_message "[6/7] Checking and installing mt5linux library in Linux if necessary"
if ! is_python_package_installed "mt5linux"; then
	python3 -m pip install --user --break-system-packages --no-cache-dir \
	    "mt5linux==1.0.11" \
	    "plumbum==1.7.0" \
	    "pyparsing==3.3.2" \
	    "rpyc>=6.0.0,<7" \
	    "python-dotenv" \
	    "numpy" \
	    "typing-extensions"
fi

# Install pyxdg library in Linux if not installed
show_message "[6/7] Checking and installing pyxdg library in Linux if necessary"
if ! is_python_package_installed "pyxdg"; then
    pip install --break-system-packages --no-cache-dir pyxdg
fi

# Start the MT5 server on Linux.
# mt5linux imports MetaTrader5 SERVER-side, so the server MUST run under Wine
# Python (not Linux python3).
show_message "[7/7] Starting the mt5linux server..."
$wine_executable "$python_path" -m mt5linux --host 0.0.0.0 -p $mt5server_port &

# Give the server some time to start
sleep 15

# Check if the server is running
if ss -tuln | grep ":$mt5server_port" > /dev/null; then
    show_message "[7/7] The mt5linux server is running on port $mt5server_port."
else
    show_message "[7/7] Failed to start the mt5linux server on port $mt5server_port."
fi

echo "Waiting for MT5/Wine initialization..."

ps aux | grep 'metatester64.exe /run' | grep -v grep | wc -l
