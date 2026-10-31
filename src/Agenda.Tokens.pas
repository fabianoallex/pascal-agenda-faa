unit Agenda.Tokens;

{$I agenda.inc}

{ Ids.

  Ids are 16 random bytes as 32 lower-case hex digits: the same on every
  database, no sequence to read back after an INSERT. The refresh tokens
  that lived here (format, parsing, hash) moved to pascal-api-infra-faa
  0.19.0's TRefreshTokens, with their tests; the tenant id's rule
  (IsTenantId) to its 0.31.0 ValidTenantId (PascalApi.Tenancy). }

interface

uses
  SysUtils;

/// 32 lower-case hex digits from the system's random source.
function NewId: string;

implementation

uses
  PascalCommon.Crypto,
  PascalCommon.Random;

function NewId: string;
begin
  Result := LowerCase(PcBytesToHex(PcRandomBytes(16)));
end;

end.
