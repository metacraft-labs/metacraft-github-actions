{
  # Only the tool pins (pins/README.md). No inputs: a consumer reads them
  # without fetching nixpkgs or anything else.
  description = "metacraft-github-actions: the organisation's tool pins";

  outputs =
    { self }:
    {
      pins = import ./pins;
    };
}
