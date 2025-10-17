# Sierra's macOS Backup

[![Lint](https://github.com/webdavis/sierras-macOS-backup/actions/workflows/lint.yml/badge.svg)](https://github.com/webdavis/sierras-macOS-backup/actions/workflows/lint.yml)

This repo automates the configuration of Sierra's personal macOS setup.

## Computer Specs

As of *October 8, 2025*

| Specification | Details                            |
| ------------- | ---------------------------------- |
| Device        | MacBook Pro 14-inch (M1 Pro, 2021) |
| OS Version    | `Tahoe 26.0`                       |
| Chip          | `Apple M1 Pro`                     |
| SSD           | `512 GB`                           |
| RAM           | `16 GB`                            |

## Setup

This project tracks Sierra's personal configuration files, managed using the following tools:

- [Chezmoi](https://www.chezmoi.io/) — for dotfile and configuration management.
- [Homebrew](https://brew.sh/) — for package and app management.

### Installation

1. **Install Homebrew**

   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```

1. **Install Chezmoi**

   Follow the instructions for `macOS` at
   [https://www.chezmoi.io/install/](https://www.chezmoi.io/install/), or simply run:

   ```bash
   brew install chezmoi
   ```

1. **Download and Apply this Configuration using Chezmoi**

   ```bash
   chezmoi init --apply https://github.com/webdavis/sierras-macOS-backup.git
   ```

1. **Install Homebrew Apps**

   This project tracks Sierra's apps using a `Brewfile`. Install them, like so:

   ```bash
   brew bundle install --global
   ```

## Development Environment

This project's development environment is managed using
[Nix Flakes](https://wiki.nixos.org/wiki/Flakes), and is defined in the
[`flake.nix`](./flake.nix) file.

### Prerequisite: Install Nix

Install Nix using the
[Nix Installer from Determinate Systems](https://github.com/DeterminateSystems/nix-installer):

```bash
curl -fsSL https://install.determinate.systems/nix | sh -s -- install
```

> [!IMPORTANT]
>
> If you're on macOS and using [nix-darwin](https://github.com/nix-darwin/nix-darwin), when
> prompted with `Install Determinate Nix?`, say `no`
>
> - **Why:** As of `2025-10-07`, Determinate Nix is incompatible with nix-darwin 25.05

### Using the Development Environment

You have two options for using the flake environment:

#### 1. Enter the Dev Shell

Drop into a persistent development shell with all tools provisioned by the flake:

```bash
nix develop
```

For example, once inside this shell you can lint the project's [`dot_Brewfile`](./dot_Brewfile)
with [RuboCop](https://github.com/rubocop/rubocop) by running Bundler directly:

```bash
bundle exec rubocop dot_Brewfile
```

#### 2. Run Commands Adhoc

Run a single command in a temporary environment without entering the shell:

```bash
nix develop .#adhoc --command ./scripts/lint.sh
```

> [!TIP]
>
> You can replace `./scripts/lint.sh` with any command you want to execute inside the
> development environment (e.g. `bundle exec rubocop dot_Brewfile`).

### Moving Forward...

I think it's likely that this project will transition away from Homebrew in favor of
[nix-darwin](https://github.com/nix-darwin/nix-darwin).

To see what this might look like, check out
[webdavis/mac-dev-config](https://github.com/webdavis/mac-dev-config).
