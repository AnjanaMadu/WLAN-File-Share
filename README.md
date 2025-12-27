# WLAN Share - Root Edition

Hey there! 👋

Welcome to **WLAN Share**, a simple yet powerful tool for sharing files over your local network directly from your Android device.

I built this because I often needed to quickly grab files from my external hard drives (OTG) connected to my phone without dealing with cloud uploads or slow Bluetooth transfers. This app turns your phone into a mini HTTP server, letting you browse and download your files from any browser on the same Wi-Fi.

## 🚀 Key Features

*   **Root Access Powered**: Unlike standard file managers, this app effectively uses Root access (Superuser) to read directly from `/mnt/media_rw` and `/data`, ensuring you can access *all* your mounted drives (USB OTG, SSDs, etc.).
*   **Zero Configuration**: Just select your storage volume, pick your IP, and hit "START SERVER".
*   **Modern UI**: A clean, professional Slate-themed interface that's easy on the eyes.
*   **Power Efficient**: Simple start/stop control.
*   **Web-Based Access**: No client app needed! Just open the URL in Chrome/Firefox/Edge on your PC.

## 🛠️ Requirements

*   **Android Device**: Running Android 5.0 or newer.
*   **Root Access**: This is **mandatory** for external drive functionality. You must grant Superuser permissions when prompted.
*   **Wi-Fi Connection**: Both devices need to be on the same network (or use your phone's Hotspot).

## 📦 How to Build

If you are a developer looking to build this from source:

1.  Ensure you have Flutter installed (`3.10+` recommended).
2.  Clone this repo.
3.  Run `flutter pub get` to install dependencies.
4.  Run `flutter build apk` to generate the release package.

## 📝 Notes

*   **Safety First**: This app runs commands as Root (`su`). While it's designed to be safe (read-only listing/streaming), always be careful when granting root access to apps.
*   **Battery**: The app requests to ignore battery optimizations to ensure the server doesn't get killed while you are transferring large files in the background.

Enjoy sharing! 🚀
