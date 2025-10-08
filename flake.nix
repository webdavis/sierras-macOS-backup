{
  description = "A development shell for linting Brewfiles with Rubocop";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }: flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-darwin" ] (system: let
    pkgs = import nixpkgs { inherit system; };

    defaultShell = pkgs.mkShell {
      buildInputs = [
        pkgs.ruby_3_4  # This comes with Bundler included.
      ];

      # Note: This project already tracks the ./bundle/config file which sets the bundle path to vendor/bundle.
      # The `bundle config set path 'vendor/bundle'` command below also enforces it as a fail-safe.
      shellHook = ''
        bundle config set path 'vendor/bundle'
      '';
    };

    interactiveShell = pkgs.mkShell {
      buildInputs = defaultShell.buildInputs;
      shellHook = defaultShell.shellHook + ''
        red="\e[91m"
        green="\e[32m"
        blue="\e[34m"
        bold="\e[1m"
        reset="\e[0m"

        projectName="$(basename "$PWD")"

        echo -e "''${blue}Entering Brewfile linting environment...''${reset}\n"
        echo -e "''${bold}Project:''${reset} ''${green}''${projectName}''${reset}"
        echo -e "''${bold}Ruby version:''${reset} ''${red}${pkgs.ruby_3_4.version}''${reset}"
        echo -e "''${bold}Rubocop version:''${reset} ''${red}$(bundle exec rubocop -v)''${reset}"
      '';
    };

    adhocShell = defaultShell;
  in {
      devShells.default = interactiveShell;
      devShells.adhoc = adhocShell;
    }
  );
}
