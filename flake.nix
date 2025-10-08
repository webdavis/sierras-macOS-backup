{
  description = "A development shell for linting Brewfiles with Rubocop on ";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }: flake-utils.lib.eachSystem ["x86_64-linux" "aarch64-darwin"] (system: let
    pkgs = import nixpkgs { inherit system; };
  in {
    devShells.default = pkgs.mkShell {
      buildInputs = [
        pkgs.ruby_3_4
      ];

      shellHook = ''
        red="\e[91m"
        green="\e[32m"
        blue="\e[34m"
        reset="\e[0m"
        projectName="$(basename "$PWD")"

        bundle config set path 'vendor/bundle'
        # export PATH=$PWD/vendor/bundle/bin:$PATH

        echo -e "''${blue}Entering Brewfile linting environment...''${reset}"
        echo -e "Project: ''${green}''${projectName}''${reset}"
        echo -e "Ruby version: ''${red}${pkgs.ruby_3_4.version}''${reset}"
        # echo -e "Rubocop version: ''${red}${pkgs.rubyPackages_3_4.rubocop.version}''${reset}"
        bundle exec rubocop -v
      '';
    };
  });
}
