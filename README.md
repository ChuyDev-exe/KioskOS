# rpi-with-splash-screen

Add a splash screen to a custom raspberry pi image with rpi-image-gen and Plymouth.

The build process has been tested on both ARM64 Mac and AMD64 Mac laptops.

AMD is much slower as expected due to emulation.

# configure for your target board

In `macmind_rpi_customizations/config/macmind_rpi_w_splash.cfg` you will need to set the device class to either
pi4 or pi5 depending on your board

# build and install

```sh
git clone https://github.com/jonnymacs/rpi-with-splash-screen
cd rpi-with-splash-screen
./build.sh
```

Use the Raspberry Pi Imager tool to install the img file located in deploy
on an SD card or USB stick.

Observe the blockchain animation on the screen at boot.

[![Watch and Like the recorded video for this project on YouTube](https://img.youtube.com/vi/K41W-7Vu7mY/maxresdefault.jpg)](https://www.youtube.com/watch?v=K41W-7Vu7mY)

**[Watch and Like the recorded video for this project on YouTube](https://www.youtube.com/watch?v=K41W-7Vu7mY)** 

**[Subscribe to the channel for more similar content](https://www.youtube.com/@macmind-io?sub_confirmation=1)

Please refer to https://github.com/raspberrypi/rpi-image-gen for more information rpi-image-gen

[Follow me on X](https://x.com/jonnymacs), and don't forget to star [this GitHub repository](https://github.com/jonnymacs/rpi_ble_server)!