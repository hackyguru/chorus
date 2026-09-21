{
  description = "Chorus core (voice) — real-time conference calling over logos-delivery (PortAudio + Opus)";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
    delivery_module.url = "github:logos-co/logos-delivery-module";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
