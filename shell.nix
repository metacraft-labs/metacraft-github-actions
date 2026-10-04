# The pinned POSIX development shell keeps Windows support flake-free.
let
  source = builtins.fetchTree {
    type = "github";
    owner = "NixOS";
    repo = "nixpkgs";
    rev = "b40629efe5d6ec48dd1efba650c797ddbd39ace0";
    narHash = "sha256-TJ3lSQtW0E2JrznGVm8hOQGVpXjJyXY2guAxku2O9A4=";
  };
  pkgs = import source.outPath { };
  tools = with pkgs; [
    git
    bashInteractive
    python3
    uv
    prek
    editorconfig-checker
    nixfmt-rfc-style
    opentofu
    prettier
    shellcheck
    actionlint
  ];
in
pkgs.mkShell {
  packages = tools;
  PREK_NO_FAST_PATH = "1";
  shellHook = ''
    export PATH="${pkgs.lib.makeBinPath tools}:$PATH"
  '';
}
