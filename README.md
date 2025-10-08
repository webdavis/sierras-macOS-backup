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

## Development Environment

This project's development environment is managed using
[Nix Flakes](https://wiki.nixos.org/wiki/Flakes), and is defined in the
[`flake.nix`](./flake.nix) file.

### 1. Install Nix

Install Nix using the
[Nix Installer from Determinate Systems](https://github.com/DeterminateSystems/nix-installer):

```bash
curl -fsSL https://install.determinate.systems/nix | sh -s -- install
```

> [!IMPORTANT]
> If you're on macOS and using [nix-darwin](https://github.com/nix-darwin/nix-darwin), when
> prompted with `Install Determinate Nix?`, say `no`
>
> - **Why:** As of `2025-10-07`, Determinate Nix is incompatible with nix-darwin 25.05

### 2. Enter the Dev Environment

Enter the flake's development environment:

```bash
nix develop
```

This command drops you into a shell with all of the tools provisioned by the flake.

For example, you can now lint the project's [`dot_Brewfile`](./dot_Brewfile) using
[RuboCop](https://github.com/rubocop/rubocop):

```bash
bundle exec rubocop dot_Brewfile
```

### Moving Forward...

I think it's likely this project will transition away from Homebrew entirely in favor of
[nix-darwin](https://github.com/nix-darwin/nix-darwin).

For an example of what this setup might look like, see
[webdavis/mac-dev-config](https://github.com/webdavis/mac-dev-config).
