{
  description = "Chorus UI — QML frontend for the voice core module";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
    # Core module — the sibling `core/` in this repo, pinned to GitHub so this
    # flake builds standalone. For local dev against the sibling dir:
    #   nix build --override-input voice path:../core '.#lgx-portable'
    voice.url = "github:hackyguru/chorus?dir=core";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
