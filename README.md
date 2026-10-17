# NetworkLuki Packages

Official package repository for distributing and maintaining NetworkLuki Linux
applications, APT packages, updates, and custom-built tools.

**Website:** https://pkgs.networkluki.com
**Installer:** https://pkgs.networkluki.com/install.sh

## Installation

For an APT-based Linux distribution with a compatible, published and signed
repository release, review [install.sh](./install.sh) before running it:

```sh
curl -fsSL https://pkgs.networkluki.com/install.sh | sudo sh
sudo apt update
```

Example for a package currently available in the archive:

```sh
sudo apt install tictactoe
```

APT packages are currently published for selected distributions/releases
(e.g., Debian 13 Trixie). RPM, Pacman and APK repositories are not yet
available. A distribution is supported only when its own compatible signed
repository metadata and packages have been published.

## License and usage

**NetworkLuki Restricted Software License v1.0** applies to original,
NetworkLuki-owned code and first-party packages in this repository unless a
specific file or package provides different license terms. See [LICENSE](./LICENSE).

- You may inspect, download, install, and use original software privately
  or within your own organization, including internal business operations.
- You may not resell, commercially redistribute, republish, publicly mirror,
  or distribute modified versions of NetworkLuki-owned software without
  prior written permission.
- This repository is **source-available, not open source** under an
  OSI-approved license.
- Third-party dependencies and separately licensed packages remain subject
  to their own licenses. This repository's license does not override them.

Each distributed binary package should include its applicable license notice
in the package itself (for Debian packages, normally under
`/usr/share/doc/<package>/copyright`). Existing binary packages may need
a rebuilt release to include this notice.

## Repository security

APT repository metadata is GPG-signed. Review the installer and verify the
archive signing key fingerprint using an independently trusted source before
adding new package sources to your system.

Published archive key fingerprint:

```text
8292CD2CF489DFBF14954D2F1C3F89018DA4223D
```

The archive's **public** key is available in
[`pkgs.networkluki.com-archive.asc`](./pkgs.networkluki.com-archive.asc).
Never publish the private signing key or its passphrase.

Copyright (c) 2026 Luki Hackwell (NetworkLuki).
