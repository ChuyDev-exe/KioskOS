#!/bin/bash

# Script to rotate the display using wlr-randr
# This script monitors for Wayland session availability and applies rotation immediately when ready

set -eu

# Function to check if Wayland compositor is running
check_wayland_running() {
    # Check if cage process is running
    if pgrep -f "cage" > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Wait for Wayland display to be available
wait_for_wayland() {
    local timeout=60
    local count=0
    
    echo "Waiting for Wayland session to become available..."
    
    while [ $count -lt $timeout ]; do
        # Check if cage is running and wlr-randr is available
        if check_wayland_running && command -v wlr-randr > /dev/null 2>&1; then
            # Try to connect to the Wayland display
            export WAYLAND_DISPLAY="wayland-0"
            if wlr-randr --help > /dev/null 2>&1; then
                echo "Wayland session detected after $count seconds"
                return 0
            fi
        fi
        sleep 1
        count=$((count + 1))
    done
    
    echo "ERROR: Wayland display not available after $timeout seconds"
    return 1
}

# Apply display rotation
apply_rotation() {
    echo "Applying display rotation: 90 degrees on HDMI-A-1"
    
    # Set Wayland environment
    export WAYLAND_DISPLAY="wayland-0"
    
    # Try to apply the rotation, with retries in case the output isn't ready
    local retries=10
    local count=0
    
    while [ $count -lt $retries ]; do
        if wlr-randr --output HDMI-A-1 --transform 90 2>/dev/null; then
            echo "Display rotation applied successfully"
            return 0
        else
            echo "Failed to apply rotation, retrying... ($((count + 1))/$retries)"
            sleep 1
            count=$((count + 1))
        fi
    done
    
    echo "ERROR: Failed to apply display rotation after $retries attempts"
    return 1
}

# Main execution
echo "Starting display rotation service..."

if wait_for_wayland; then
    if apply_rotation; then
        echo "Display rotation service completed successfully"
    else
        echo "Display rotation service failed"
        exit 1
    fi
else
    echo "Wayland session not available, cannot apply rotation"
    exit 1
fi