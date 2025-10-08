# Sierra's macOS Backup

This repo tracks Sierra's macOS tooling and setup.

## Setup

This repository contains Sierra's personal configuration files, managed by the following tools:

- [Chezmoi](https://www.chezmoi.io/).

### Dotfiles via Chezmoi

To use these dotfiles on your system:

1. **Install Chezmoi**

Follow the instructions for `macOS` at
[https://www.chezmoi.io/install/](https://www.chezmoi.io/install/)

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

### Prerequisite: Install Nix

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

### Using the Development Environment

You have two options for using the flake environment:

#### 1. Enter the Dev Shell

Drop into a persistent development shell with all tools provisioned by the flake:

```bash
nix develop
```

For example, you can now lint the project's [`dot_Brewfile`](./dot_Brewfile) using
[RuboCop](https://github.com/rubocop/rubocop):

```bash
bundle exec rubocop dot_Brewfile
```

#### 2. Run Commands Adhoc

Run a single command in a temporary environment without entering the shell:

```bash
nix develop .#adhoc --command bundle exec rubocop -v
```

> [!TIP]
> Replace `bundle exec rubocop -v` with any other command you want to run in the development
> environment.

### Moving Forward...

I think it's likely this project will transition away from Homebrew entirely in favor of
[nix-darwin](https://github.com/nix-darwin/nix-darwin).

For an example of what this setup might look like, see
[webdavis/mac-dev-config](https://github.com/webdavis/mac-dev-config).
