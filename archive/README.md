# Archived assets

This directory contains bulky reference files that came directly from a running Raspberry Pi (kernel images, firmware blobs, etc.). They are not required to build or customize piNAS, but they are preserved here for safekeeping.

- `boot-stock-full/` – exact copy of a Pi 5 `/boot` volume captured before the repository was cleaned up. Use it only for reference; the installer scripts expect the live OS to provide these files.

Keeping these assets under `archive/` keeps the project root lean so you can focus on the scripts (`sbin/`), documentation (`docs/`), cloud-init/user-data (`boot/`), and helper tooling (`scripts/`).

