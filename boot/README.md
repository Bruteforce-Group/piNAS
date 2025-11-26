# boot assets

Only the files that need to ship with the piNAS project live here:

- `user-data.example` – Template cloud-init configuration file. **Copy this to `user-data` and configure your WiFi credentials before copying to SD card.**
- `templates/config.txt` and `templates/cmdline.txt` – minimal reference copies that `scripts/setup-sdcard.sh` can apply when preparing a card.

All other files that originally came from a live Raspberry Pi boot volume (kernel images, firmware blobs, etc.) have been moved to `archive/boot-stock-full/` so the repository only tracks the assets required to reproduce a piNAS install.

## Security Note

The `user-data` file is gitignored to prevent accidentally committing WiFi credentials. Always copy from `user-data.example` and configure your network settings locally.

