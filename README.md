# WLAN Share - Root Edition

Hey there! 👋

Welcome to **WLAN Share**, your personal local NAS (Network Attached Storage) solution for Android.

I built this to turn my phone into a true file server. Instead of just picking one folder, this app scans all your attached drives (internal, USB OTG, SD cards) and serves them all at once. It's like having a portable NAS in your pocket.

## 🚀 cool stuff

*   **full nas experience**: the web interface lists all your drives. click one to browse files.
*   **root power**: uses `su` and `blkid` to find every connected disk, even the ones android hides.
*   **friendly names**: identifies your drives by vendor and model (e.g. "Samsung SSD"), so you know what's what.
*   **clean ui**: simple vertical list of drives, minimal "online/offline" status, and a sleek dark theme.
*   **web access**: open the ip in any browser, see all your disks, download whatever you need.

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
