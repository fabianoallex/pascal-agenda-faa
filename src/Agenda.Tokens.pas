unit Agenda.Tokens;

{$I agenda.inc}

{ Ids and tenant ids.

  Ids are 16 random bytes as 32 lower-case hex digits: the same on every
  database, no sequence to read back after an INSERT. The refresh tokens
  that lived here (format, parsing, hash) moved to pascal-api-infra-faa
  0.19.0's TRefreshTokens, with their tests. }

interface

uses
  SysUtils;

const
  MAX_TENANT_ID_LENGTH = 40;

/// 32 lower-case hex digits from the system's random source.
function NewId: string;

/// 1 to 40 characters of a-z, 0-9 and '-': the catalog's rule for an id.
function IsTenantId(const AText: string): Boolean;

implementation

uses
  PascalCommon.Crypto,
  PascalCommon.Random;

function NewId: string;
begin
  Result := LowerCase(PcBytesToHex(PcRandomBytes(16)));
end;

function IsTenantId(const AText: string): Boolean;
var
  I: Integer;
begin
  Result := (Length(AText) >= 1) and (Length(AText) <= MAX_TENANT_ID_LENGTH);
  if Result then
    for I := 1 to Length(AText) do
      if not CharInSet(AText[I], ['a'..'z', '0'..'9', '-']) then
        Exit(False);
end;

end.
