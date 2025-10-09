{
  description = "A development shell for linting Brewfiles with Rubocop";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-darwin" ] (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        nixfmt = nixpkgs.legacyPackages.${system}.nixfmt-tree;

        baseShell = pkgs.mkShell {
          buildInputs = [
            pkgs.ruby_3_4 # This comes with Bundler included.
            nixfmt
          ];

          # Note: This project already tracks the ./bundle/config file, which the ensures that gems
          # are installed into the project-local './vendor/bundle' directory, but we enforce it
          # here as a fail-safe.
          shellHook = ''
            echo
            bundle config set path 'vendor/bundle'

            if [ ! -d vendor/bundle ] || ! bundle check > /dev/null 2>&1; then
              echo "Installing gems..."
              bundle install --jobs 4 --retry 3
              echo
            fi
          '';
        };

        interactiveShell = pkgs.mkShell {
          buildInputs = baseShell.buildInputs;
          shellHook = baseShell.shellHook + ''
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
      in
      {
        devShells.default = interactiveShell;
        devShells.adhoc = baseShell;
        formatter = nixfmt;
      }
    );
}
