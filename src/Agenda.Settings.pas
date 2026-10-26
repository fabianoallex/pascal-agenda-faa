unit Agenda.Settings;

{$I agenda.inc}

{ Settings both programs read the same way (the api and the worker), from
  the environment or a .env file (pascal-api-infra-faa's TAppConfig).

  - LINK_SIGNING_KEYS: the public links' keys (Agenda.SignedLinks); required
    unless DEV_MODE=true, which gives a development key. The worker signs the
    links its emails carry, so it needs the api's keys.
  - PUBLIC_BASE_URL: what goes before /public/... in a link, without a
    trailing "/". }

interface

uses
  Agenda.SignedLinks;

/// The configured link keys; raises without them outside DEV_MODE.
/// AWarning: the DEV_MODE warning line, '' otherwise.
function ConfiguredLinks(out AWarning: string): TSignedLinks;

/// PUBLIC_BASE_URL with no trailing "/".
function ConfiguredPublicBaseUrl: string;

implementation

uses
  SysUtils,
  PascalApi.Config;

const
  // The 32 bytes "development-link-signing-key-123": DEV_MODE only.
  DEV_LINK_KEY = 'dev:ZGV2ZWxvcG1lbnQtbGluay1zaWduaW5nLWtleS0xMjM=';

function ConfiguredLinks(out AWarning: string): TSignedLinks;
var
  LKeys: string;
begin
  AWarning := '';
  LKeys := TAppConfig.Get('LINK_SIGNING_KEYS', '');
  if LKeys = '' then
  begin
    if not TAppConfig.GetBool('DEV_MODE', False) then
      raise Exception.Create('LINK_SIGNING_KEYS is required (or DEV_MODE=true for ' +
        'development). Generate one with: openssl rand -base64 32, and set "l1:<that>".');
    AWarning := 'WARNING DEV_MODE: the public links are signed with a development key';
    LKeys := DEV_LINK_KEY;
  end;
  Result := TSignedLinks.Create(LKeys);
end;

function ConfiguredPublicBaseUrl: string;
begin
  Result := TAppConfig.Get('PUBLIC_BASE_URL', '');
  // A trailing "/" would double the one every link's path starts with.
  while (Result <> '') and (Result[Length(Result)] = '/') do
    Delete(Result, Length(Result), 1);
end;

end.
