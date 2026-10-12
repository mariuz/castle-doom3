// The scene class of the map's geometry and models.
unit Doom3Scene;

{$mode objfpc}{$H+}

interface

uses
  CastleScene, CastleTransform;

type
  { A scene that prepares shadow volume data (the manifold and border edges
    of every shape) only when it casts shadows. CGE's TCastleSceneCore
    prepares it for every scene when the viewport uses shadow volumes,
    which takes long (quadratic in a shape's open edges) for the map's big
    open area geometry, which never casts. }
  TD3Scene = class(TCastleScene)
  public
    procedure PrepareResources(const Options: TPrepareResourcesOptions;
      const Params: TPrepareParams); override;
  end;

implementation

procedure TD3Scene.PrepareResources(const Options: TPrepareResourcesOptions;
  const Params: TPrepareParams);
begin
  if CastShadows then
    inherited PrepareResources(Options, Params)
  else
    inherited PrepareResources(Options - [prShadowVolume], Params);
end;

end.
