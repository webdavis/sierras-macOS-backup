# Sierra's macOS Backup

This repo tracks Sierra's macOS tooling and setup.

## Setup

This repository contains Sierra's personal configuration files, managed by the following tools:

- [Chezmoi](https://www.chezmoi.io/).

### Dotfiles via Chezmoi

To use these dotfiles on your system:

1. **Install Chezmoi**

Follow the instructions for `macOS` at [https://www.chezmoi.io/install/](https://www.chezmoi.io/install/)

```bash
brew install chezmoi
```

2. **Initialize Chezmoi with this repository**

```bash
chezmoi init --apply https://github.com/webdavis/sierras-macOS-backup.git
```
