# boot assets

Only the files that need to ship with the piNAS project live here:

- `user-data` – cloud-init configuration copied onto the SD card so the Pi installs piNAS automatically on first boot.
- `templates/config.txt` and `templates/cmdline.txt` – minimal reference copies that `scripts/setup-sdcard.sh` can apply when preparing a card.

All other files that originally came from a live Raspberry Pi boot volume (kernel images, firmware blobs, etc.) have been moved to `archive/boot-stock-full/` so the repository only tracks the assets required to reproduce a piNAS install.

