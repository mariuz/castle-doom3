// RenderDoc's in-application API (renderdoc_app.h): when the game runs
// under RenderDoc (renderdoccmd capture ... castle-doom3.exe
// --capabilities=force-modern ...: RenderDoc captures only OpenGL core
// profile contexts), renderdoc.dll is loaded into it and can be asked to
// capture the next frame, from the console ("renderdoc") or a demo script
// ("O:renderdoc"), at a known moment. Nothing happens without RenderDoc.
unit Doom3RenderDoc;

interface

{ Is RenderDoc loaded into this process? }
function RenderDocAvailable: Boolean;

{ Capture the next frame (False without RenderDoc). }
function RenderDocTriggerCapture: Boolean;

{ The number of captures made so far (-1 without RenderDoc). }
function RenderDocCaptureCount: Integer;

implementation

{$ifdef MSWINDOWS}
uses
  Windows;

type
  { RENDERDOC_API_1_1_2: function pointers, in this order }
  TRenderDocFunctions = array [0..15] of Pointer;
  PRenderDocFunctions = ^TRenderDocFunctions;
  TGetAPI = function(Version: Integer; OutAPIPointers: PPointer): Integer; cdecl;
  TVoidProc = procedure; cdecl;
  TGetNumCaptures = function: Cardinal; cdecl;

const
  { eRENDERDOC_API_Version_1_1_2 }
  ApiVersion = 10102;
  { indexes in RENDERDOC_API_1_1_2 }
  IndexGetNumCaptures = 13;
  IndexTriggerCapture = 15;

var
  Api: PRenderDocFunctions;
  Tried: Boolean;

function GetApi: PRenderDocFunctions;
var
  Module: HMODULE;
  GetAPIFunc: TGetAPI;
  P: Pointer;
begin
  if not Tried then
  begin
    Tried := True;
    Module := GetModuleHandle('renderdoc.dll');
    if Module <> 0 then
    begin
      GetAPIFunc := TGetAPI(GetProcAddress(Module, 'RENDERDOC_GetAPI'));
      P := nil;
      if Assigned(GetAPIFunc) and (GetAPIFunc(ApiVersion, @P) = 1) then
        Api := PRenderDocFunctions(P);
    end;
  end;
  Result := Api;
end;

function RenderDocAvailable: Boolean;
begin
  Result := GetApi <> nil;
end;

function RenderDocTriggerCapture: Boolean;
begin
  Result := GetApi <> nil;
  if Result then
    TVoidProc(Api^[IndexTriggerCapture])();
end;

function RenderDocCaptureCount: Integer;
begin
  if GetApi = nil then
    Exit(-1);
  Result := TGetNumCaptures(Api^[IndexGetNumCaptures])();
end;

{$else}

function RenderDocAvailable: Boolean;
begin
  Result := False;
end;

function RenderDocTriggerCapture: Boolean;
begin
  Result := False;
end;

function RenderDocCaptureCount: Integer;
begin
  Result := -1;
end;

{$endif}

end.
